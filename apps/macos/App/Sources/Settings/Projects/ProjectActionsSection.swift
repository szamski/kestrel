import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Keybindings

/// A project's actions (scripts). Reads and writes go through `SourceControlStore`, the same path as the chat header's
/// action menu, so the editor sheet, the t3.json import and the `script.<id>.run` shortcut behave identically.
struct ProjectActionsSection: View {
  @Environment(SettingsModel.self) private var model
  /// The checkouts the scope covers; the list is edited only when it is one.
  let members: [EnvironmentProject]
  @State private var store: SourceControlStore
  @State private var request: ScriptEditorRequest?
  @State private var deleting: ProjectScript?
  @State private var file: T3ProjectFile.State = .missing

  init(runtime: ClientRuntime, members: [EnvironmentProject]) {
    self.members = members
    _store = State(initialValue: SourceControlStore(runtime: runtime))
  }

  var body: some View {
    let lists = members.map { store.scripts(for: $0) }
    let scripts = lists.first ?? []
    let mixed = lists.contains { $0 != scripts }
    let editable = members.count == 1 ? members.first : nil
    let importable = importableScripts(scripts)
    Section {
      SettingRow(id: "project-actions", title: "Actions", help: "Commands that run in this project's checkout or its worktree, with optional shortcuts.") {
        HStack(spacing: 6) {
          if let editable, !importable.isEmpty {
            Menu("Import scripts") {
              Section("Import from t3.json") {
                ForEach(importable, id: \.name) { script in
                  Button { Task { await store.importScript(script, project: editable) } } label: { Label("\(script.name)  \(script.command)", systemImage: script.icon.symbol) }
                }
              }
            }
            .fixedSize()
          }
          Button("Add action", systemImage: "plus") {
            if let editable { request = ScriptEditorRequest(project: editable, scriptId: nil, initial: ScriptDraft()) }
          }
          .disabled(editable == nil)
        }
      }
      // One host for the section's sheet, dialog and loader: modifiers on a Section would repeat on every row.
      .sheet(item: $request) { ScriptEditorSheet(store: store, request: $0) }
      .confirmationDialog(
        "Delete action \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
      ) { script in
        Button("Delete", role: .destructive) {
          if let editable { Task { await store.deleteScript(script.id, project: editable) } }
        }
      } message: { _ in
        Text("It is removed from this project.")
      }
      .task(id: members.first?.id) { await loadFile() }
      .onChange(of: store.hud) {
        if let hud = store.hud, hud.kind == .error { model.report([hud.title, hud.detail].compactMap { $0 }.joined(separator: ". ")) }
      }
      if mixed {
        note("Different actions across environments", "Choose one environment to edit its list.")
      } else if members.count > 1 {
        note("Shared by \(members.count) checkouts", "Choose a checkout in the bar above to edit its actions.")
      }
      if !mixed {
        if scripts.isEmpty { Text("No actions yet.").foregroundStyle(.secondary) }
        ForEach(scripts, id: \.id) { script in row(script, editable: editable) }
      }
      if file == .invalid {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("t3.json is invalid")
            Text("A t3.json exists in this checkout but fails to parse, so every action and icon it declares is ignored. Check the JSON syntax and icon values.")
              .font(.callout).foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Actions")
    }
  }

  private func note(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail).font(.callout).foregroundStyle(.secondary)
    }
  }

  private func row(_ script: ProjectScript, editable: EnvironmentProject?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: script.icon.symbol).foregroundStyle(.secondary).frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(script.name)
          if script.runOnWorktreeCreate { KeybindingBadge(text: "Setup") }
          if script.runOnSettle == true { KeybindingBadge(text: "Settle") }
        }
        Text(script.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
      }
      Spacer(minLength: 8)
      if let editable, let spelling = store.keybinding(forScript: script.id, in: editable.environmentId), let shortcut = KeybindingParser.shortcut(spelling) {
        KeybindingPill(text: Keybindings.label(shortcut))
      }
      Button { if let editable { request = ScriptEditorRequest(project: editable, scriptId: script.id, initial: store.draft(for: script, in: editable)) } } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless).disabled(editable == nil).help("Edit action").accessibilityLabel("Edit \(script.name)")
      Button { deleting = script } label: { Image(systemName: "trash") }
        .buttonStyle(.borderless).disabled(editable == nil).help("Delete action").accessibilityLabel("Delete \(script.name)")
    }
  }

  private func importableScripts(_ scripts: [ProjectScript]) -> [ProjectScript] {
    guard case .valid(let declared) = file else { return [] }
    return declared.filter { script in !scripts.contains { $0.command == script.command || $0.name.lowercased() == script.name.lowercased() } }
  }

  /// t3.json of the first checkout: its declared actions are offered for import, and a broken file is called out.
  private func loadFile() async {
    guard let project = members.first,
      let result = try? await store.call(project.environmentId, Rpc.projectsReadFile, ProjectReadFileInput(cwd: project.project.workspaceRoot, relativePath: "t3.json")),
      !result.truncated
    else {
      file = .missing
      return
    }
    file = T3ProjectFile.parse(result.contents)
  }
}
