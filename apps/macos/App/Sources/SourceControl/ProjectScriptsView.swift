import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

extension ProjectScriptIcon {
  static let choices: [ProjectScriptIcon] = [.play, .test, .lint, .configure, .build, .debug]

  var symbol: String {
    switch self {
    case .test: "testtube.2"
    case .lint: "checklist"
    case .configure: "wrench"
    case .build: "hammer"
    case .debug: "ladybug"
    default: "play.fill"
    }
  }

  var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Header control: run the project's primary action, with the whole list, editing and the `t3.json` import behind it.
struct ProjectScriptsMenu: View {
  let app: AppModel
  let store: SourceControlStore
  let info: WorkspaceInfo
  @State private var fileScripts: [ProjectScript] = []

  var body: some View {
    let project = info.project
    let scripts = store.scripts(for: project)
    let primary = store.preferredScript(in: scripts, project: project)
    let importable = fileScripts.filter { file in
      !scripts.contains { $0.command == file.command || $0.name.lowercased() == file.name.lowercased() }
    }
    Menu {
      ForEach(scripts, id: \.id) { script in
        Button(script.name, systemImage: script.icon.symbol) { store.run(script, in: info) }
      }
      if !scripts.isEmpty { Divider() }
      Button("Add action\u{2026}", systemImage: "plus") { add(project) }
      if !scripts.isEmpty {
        Menu("Edit action", systemImage: "pencil") {
          ForEach(scripts, id: \.id) { script in Button(script.name) { edit(script, project) } }
        }
        Menu("Delete action", systemImage: "trash") {
          ForEach(scripts, id: \.id) { script in Button(script.name, role: .destructive) { delete(script, project) } }
        }
      }
      if !importable.isEmpty {
        Menu("Import from t3.json", systemImage: "square.and.arrow.down") {
          ForEach(importable, id: \.name) { file in Button(file.name) { Task { await store.importScript(file, project: project) } } }
        }
      }
    } label: {
      Label(primary?.name ?? "Add action", systemImage: primary?.icon.symbol ?? "plus").labelStyle(.titleAndIcon)
    } primaryAction: {
      if let primary { store.run(primary, in: info) } else { add(project) }
    }
    .help(primary.map { "Run \($0.name)" } ?? "Add an action to run in this project")
    .task(id: project.id) { fileScripts = await store.fileScripts(for: project) }
  }

  private func add(_ project: EnvironmentProject) {
    store.dialog = .script(ScriptEditorRequest(project: project, scriptId: nil, initial: ScriptDraft()))
  }

  private func edit(_ script: ProjectScript, _ project: EnvironmentProject) {
    store.dialog = .script(ScriptEditorRequest(project: project, scriptId: script.id, initial: store.draft(for: script, in: project)))
  }

  private func delete(_ script: ProjectScript, _ project: EnvironmentProject) {
    app.confirm("Delete action \u{201C}\(script.name)\u{201D}?", message: "It is removed from this project.", confirmTitle: "Delete") {
      await store.deleteScript(script.id, project: project)
    }
  }
}

/// Add or edit one action: name, command, icon, when it runs and its shortcut.
struct ScriptEditorSheet: View {
  let store: SourceControlStore
  let request: ScriptEditorRequest
  @Environment(\.dismiss) private var dismiss
  @State private var draft: ScriptDraft
  @State private var error: String?
  @State private var saving = false
  @State private var recorder = ShortcutRecorder()

  init(store: SourceControlStore, request: ScriptEditorRequest) {
    self.store = store
    self.request = request
    _draft = State(initialValue: request.initial)
  }

  private var canSave: Bool {
    !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(request.scriptId == nil ? "Add action" : "Edit action").font(.headline)
      Form {
        TextField("Name", text: $draft.name)
        VStack(alignment: .leading, spacing: 4) {
          Text("Command")
          TextEditor(text: $draft.command)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 72)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
        }
        Picker("Icon", selection: $draft.icon) {
          ForEach(ProjectScriptIcon.choices, id: \.rawValue) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        HStack {
          TextField("Shortcut", text: $draft.keybinding, prompt: Text("mod+shift+t"))
          Button(recorder.isRecording ? "Press keys\u{2026}" : "Record") {
            if recorder.isRecording { recorder.stop() } else { recorder.start { draft.keybinding = $0 } }
          }
        }
        Toggle("Run automatically when a worktree is created", isOn: $draft.runOnWorktreeCreate)
        if draft.runOnWorktreeCreate {
          Toggle("Wait for it to finish before the agent starts", isOn: $draft.waitForSetup)
        }
        TextField("Preview URL", text: $draft.previewUrl, prompt: Text("http://localhost:3000"))
        if !draft.previewUrl.trimmingCharacters(in: .whitespaces).isEmpty {
          Toggle("Open the preview when it runs", isOn: $draft.autoOpenPreview)
        }
      }
      .formStyle(.columns)
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        if saving { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onDisappear { recorder.stop() }
  }

  private func save() {
    saving = true
    error = nil
    Task {
      defer { saving = false }
      do {
        try await store.saveScript(draft, scriptId: request.scriptId, project: request.project)
        dismiss()
      } catch {
        self.error = SourceControlStore.describe(error)
      }
    }
  }
}

/// Captures the next shortcut pressed (a modifier plus a key) in the server's `mod+shift+t` spelling.
@MainActor @Observable
final class ShortcutRecorder {
  private(set) var isRecording = false
  @ObservationIgnored private var monitor: Any?

  func start(_ capture: @escaping (String) -> Void) {
    stop()
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      nonisolated(unsafe) let unsafeEvent = event
      let consumed = MainActor.assumeIsolated { self?.handle(unsafeEvent, capture) ?? false }
      return consumed ? nil : event
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    isRecording = false
  }

  private func handle(_ event: NSEvent, _ capture: (String) -> Void) -> Bool {
    if event.keyCode == 53 {
      stop()
      return true
    }
    let flags = event.modifierFlags
    guard let key = Self.token(event) else { return true }
    var parts: [String] = []
    if flags.contains(.command) { parts.append("mod") }
    if flags.contains(.control) { parts.append("ctrl") }
    if flags.contains(.option) { parts.append("alt") }
    if flags.contains(.shift) { parts.append("shift") }
    // A bare key would swallow typing: a shortcut needs a modifier.
    guard !parts.isEmpty else { return true }
    capture((parts + [key]).joined(separator: "+"))
    stop()
    return true
  }

  private static func token(_ event: NSEvent) -> String? {
    switch event.keyCode {
    case 49: return "space"
    case 36: return "enter"
    case 48: return "tab"
    case 51: return "backspace"
    case 123: return "arrowleft"
    case 124: return "arrowright"
    case 125: return "arrowdown"
    case 126: return "arrowup"
    default:
      guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
      return characters
    }
  }
}
