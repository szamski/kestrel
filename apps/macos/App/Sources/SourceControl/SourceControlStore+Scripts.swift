import Foundation
import T3ClientRuntime
import T3Contracts
import T3Keybindings

/// What the script sheet edits. `keybinding` is the server's `mod+shift+t` spelling.
struct ScriptDraft: Equatable {
  var name = ""
  var command = ""
  var icon = ProjectScriptIcon.play
  var runOnWorktreeCreate = false
  var waitForSetup = false
  var previewUrl = ""
  var autoOpenPreview = false
  var keybinding = ""
}

struct ScriptEditorRequest: Identifiable {
  let id = UUID()
  var project: EnvironmentProject
  /// nil adds a script.
  var scriptId: String?
  var initial: ScriptDraft
}

extension ProjectScript {
  /// A protocol-1 project shell carries its own `V1.ProjectScript` (no `runOnSettle`).
  init(_ script: V1.ProjectScript) {
    self.init(
      id: script.id, name: script.name, command: script.command, icon: script.icon, runOnWorktreeCreate: script.runOnWorktreeCreate,
      async: script.async, previewUrl: script.previewUrl, autoOpenPreview: script.autoOpenPreview)
  }

  init(_ item: ServerSettingsDefaultProjectScriptsItem) {
    self.init(
      id: item.id, name: item.name, command: item.command, icon: item.icon, runOnWorktreeCreate: item.runOnWorktreeCreate, async: item.async,
      previewUrl: item.previewUrl, autoOpenPreview: item.autoOpenPreview)
  }
}

private func convert<A: Encodable, B: Decodable>(_ value: A, to type: B.Type) -> B? {
  (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(B.self, from: $0) }
}

// Project scripts: the list, its edits (stored as server settings of the project), and running one in a terminal.
extension SourceControlStore {
  /// The project's actions: its own list, else the environment's (`resolveProjectScripts` of the web client).
  func scripts(for project: EnvironmentProject) -> [ProjectScript] {
    let projectScripts = project.project.scripts.map(ProjectScript.init)
    guard let settings = settings(project.environmentId) else { return projectScripts }
    let id = project.projectId.rawValue
    if let override = settings.projectSettingsOverrides[id]?.defaultProjectScripts { return override.map(ProjectScript.init) }
    let defaults = settings.defaultProjectScripts.map(ProjectScript.init)
    if settings.projectSettingsFolded { return defaults }
    switch settings.projectScriptOverrides[id] {
    case .some(.some(let list)): return list.map(ProjectScript.init)
    case .some(.none): return defaults
    case .none: return projectScripts.isEmpty ? defaults : projectScripts
    }
  }

  func draft(for script: ProjectScript, in project: EnvironmentProject) -> ScriptDraft {
    ScriptDraft(
      name: script.name, command: script.command, icon: script.icon, runOnWorktreeCreate: script.runOnWorktreeCreate,
      waitForSetup: script.runOnWorktreeCreate && script.async == false, previewUrl: script.previewUrl ?? "",
      autoOpenPreview: script.autoOpenPreview ?? false, keybinding: keybinding(forScript: script.id, in: project.environmentId) ?? "")
  }

  /// The shortcut bound to `script.<id>.run`, in the server's spelling.
  func keybinding(forScript id: String, in environmentId: EnvironmentId) -> String? {
    guard let command = ProjectScriptsLogic.command(forScriptID: id),
      let rule = runtime.serverConfigs[environmentId]?.config.keybindings.last(where: { $0.command == command })
    else { return nil }
    let shortcut = rule.shortcut
    var parts: [String] = []
    if shortcut.modKey { parts.append("mod") }
    if shortcut.ctrlKey { parts.append("ctrl") }
    if shortcut.metaKey { parts.append("meta") }
    if shortcut.altKey { parts.append("alt") }
    if shortcut.shiftKey { parts.append("shift") }
    parts.append(shortcut.key == " " ? "space" : shortcut.key == "escape" ? "esc" : shortcut.key)
    return parts.joined(separator: "+")
  }

  // MARK: Edits

  func saveScript(_ draft: ScriptDraft, scriptId: String?, project: EnvironmentProject) async throws {
    let current = scripts(for: project)
    let id = scriptId ?? ProjectScriptsLogic.nextID(for: draft.name, existing: current.map(\.id))
    let preview = draft.previewUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let script = ProjectScript(
      id: id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), command: draft.command, icon: draft.icon,
      runOnWorktreeCreate: draft.runOnWorktreeCreate, runOnSettle: current.first { $0.id == id }?.runOnSettle,
      async: draft.runOnWorktreeCreate && draft.waitForSetup ? false : nil,
      previewUrl: preview.isEmpty ? nil : preview, autoOpenPreview: preview.isEmpty ? nil : draft.autoOpenPreview)
    // Only one script runs on worktree creation.
    var next = current.map { other -> ProjectScript in
      var other = other
      if draft.runOnWorktreeCreate, other.id != id { other.runOnWorktreeCreate = false }
      return other
    }
    if let index = next.firstIndex(where: { $0.id == id }) { next[index] = script } else { next.append(script) }
    try await persist(next, project: project, keybinding: draft.keybinding.trimmingCharacters(in: .whitespaces), scriptId: id)
  }

  func deleteScript(_ id: String, project: EnvironmentProject) async {
    do {
      try await persist(scripts(for: project).filter { $0.id != id }, project: project, keybinding: "", scriptId: id)
      show(SourceControlHUD(kind: .success, title: "Deleted action"))
    } catch {
      fail("Could not delete action", error)
    }
  }

  /// Adds a script declared in the project's `t3.json`.
  func importScript(_ file: ProjectScript, project: EnvironmentProject) async {
    var draft = self.draft(for: file, in: project)
    draft.keybinding = ""
    do { try await saveScript(draft, scriptId: nil, project: project) } catch { fail("Could not import action", error) }
  }

  private func persist(_ scripts: [ProjectScript], project: EnvironmentProject, keybinding: String, scriptId: String) async throws {
    let id = project.projectId.rawValue
    let supportsOverrides = runtime.serverConfigs[project.environmentId]?.config.environment.capabilities.projectSettingsOverrides == true
    var patch = ServerSettingsPatch()
    if supportsOverrides {
      // The entry is replaced as a whole, so it carries the project's other overrides along.
      var overrides = settings(project.environmentId)?.projectSettingsOverrides[id].flatMap { convert($0, to: ProjectSettingsOverrides.self) } ?? ProjectSettingsOverrides()
      overrides.defaultProjectScripts = scripts
      patch.projectSettingsOverrides = [id: overrides]
    } else {
      patch.projectScriptOverrides = [id: scripts]
    }
    _ = try await call(project.environmentId, Rpc.serverUpdateSettings, ServerUpdateSettingsPayload(patch: patch))
    guard !keybinding.isEmpty else { return }
    guard KeybindingParser.shortcut(keybinding) != nil, let command = ProjectScriptsLogic.command(forScriptID: scriptId) else {
      throw SourceControlError("Invalid keybinding.")
    }
    _ = try await call(project.environmentId, Rpc.serverUpsertKeybinding, ServerUpsertKeybindingInput(key: keybinding, command: command))
  }

  // MARK: t3.json

  /// Actions declared in the checked-in `t3.json`, offered for import. A missing or unreadable file offers none.
  func fileScripts(for project: EnvironmentProject) async -> [ProjectScript] {
    guard let file = try? await call(project.environmentId, Rpc.projectsReadFile, ProjectReadFileInput(cwd: project.project.workspaceRoot, relativePath: "t3.json")),
      !file.truncated, let data = file.contents.data(using: .utf8),
      let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["scripts"] as? [[String: Any]]
    else { return [] }
    return list.compactMap { entry in
      guard let name = entry["name"] as? String, let command = entry["command"] as? String else { return nil }
      return ProjectScript(
        id: "", name: name, command: command, icon: ProjectScriptIcon(rawValue: entry["icon"] as? String ?? "play"),
        runOnWorktreeCreate: entry["runOnWorktreeCreate"] as? Bool ?? false, async: entry["async"] as? Bool, previewUrl: entry["previewUrl"] as? String,
        autoOpenPreview: entry["autoOpenPreview"] as? Bool)
    }
  }

  // MARK: Run

  private static let lastScriptKey = "scripts.lastInvoked"

  func preferredScript(in scripts: [ProjectScript], project: EnvironmentProject) -> ProjectScript? {
    let last = (UserDefaults.standard.dictionary(forKey: Self.lastScriptKey) as? [String: String])?[project.id]
    return scripts.first { $0.id == last } ?? ProjectScriptsLogic.primary(scripts)
  }

  /// Runs the script in the thread's terminal drawer, in the thread's checkout (like the web's "run action"). A draft has
  /// no drawer, so its script runs in a hidden terminal of its own.
  func run(_ script: ProjectScript, in info: WorkspaceInfo) {
    var last = UserDefaults.standard.dictionary(forKey: Self.lastScriptKey) as? [String: String] ?? [:]
    last[info.project.id] = script.id
    UserDefaults.standard.set(last, forKey: Self.lastScriptKey)
    if let app, !info.isDraft, TerminalDrawers.shared.runScript(script.command, in: info.key, app: app) {
      show(SourceControlHUD(kind: .info, title: "Running \(script.name)", detail: info.cwd))
      return
    }
    let environmentId = info.key.environmentId
    let threadId = info.key.threadId.rawValue
    let terminalId = "script-\(script.id)"
    var env = ["T3CODE_PROJECT_ROOT": info.project.project.workspaceRoot]
    if let worktree = info.worktreePath { env["T3CODE_WORKTREE_PATH"] = worktree }
    Task {
      do {
        _ = try await call(
          environmentId, Rpc.terminalOpen,
          TerminalOpenInput(
            threadId: threadId, terminalId: terminalId, cwd: info.cwd, worktreePath: info.worktreePath.map { .some($0) }, cols: 120, rows: 30, env: env))
        _ = try await call(environmentId, Rpc.terminalWrite, TerminalWriteInput(threadId: threadId, terminalId: terminalId, data: "\(script.command)\r"))
        show(SourceControlHUD(kind: .info, title: "Running \(script.name)", detail: info.cwd))
      } catch {
        fail("Failed to run \"\(script.name)\"", error)
      }
    }
  }
}
