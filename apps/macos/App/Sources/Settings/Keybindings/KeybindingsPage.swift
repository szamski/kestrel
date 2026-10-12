import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Keybindings

/// Settings › Keybindings: every command grouped by area with the shortcut it has now. A shortcut is recorded by pressing it;
/// the `when` condition is a typed expression, checked as you type. Changes reach the server and come back through
/// `keybindingsUpdated`.
struct KeybindingsPage: View {
  @Environment(SettingsModel.self) private var model

  var body: some View { KeybindingsContent(controller: KeybindingsController(model: model)) }
}

private struct KeybindingsContent: View {
  @State var controller: KeybindingsController
  @Environment(SettingsModel.self) private var model
  @FocusState private var searchFocused: Bool

  init(controller: KeybindingsController) { _controller = State(initialValue: controller) }

  var body: some View {
    @Bindable var controller = controller
    let all = KeybindingCatalog.rows(controller.rules)
    let visible = KeybindingCatalog.filter(all, query: controller.query)
    let groups = KeybindingCatalog.groups(visible)
    ScrollViewReader { proxy in
      Form {
        Section {
          toolbar
          if !controller.canWrite {
            Text("Connect an environment to change keybindings.").font(.callout).foregroundStyle(.secondary)
          }
        }
        .id("keybindings")
        if controller.isAdding {
          Section("New keybinding") { NewKeybindingRow(controller: controller, all: all) }
        }
        ForEach(groups) { group in
          Section(group.title) {
            ForEach(group.rows) { row in
              KeybindingRowView(controller: controller, row: row, all: all, anchored: isFirst(row, in: all)).disabled(!controller.canWrite)
            }
          }
        }
        if groups.isEmpty {
          Section { Text("No keybindings match your search.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24) }
        }
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        if id.hasPrefix("keybinding-") { controller.query = "" }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
    .onDisappear { controller.stopRecording() }
  }

  /// Only a command's first row takes the settings-search anchor.
  private func isFirst(_ row: KeybindingRow, in rows: [KeybindingRow]) -> Bool { rows.first { $0.command == row.command }?.id == row.id }

  private var toolbar: some View {
    @Bindable var controller = controller
    return HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search keybindings", text: $controller.query)
        .textFieldStyle(.plain).focused($searchFocused).onExitCommand { if controller.query.isEmpty { searchFocused = false } else { controller.query = "" } }
      if !controller.query.isEmpty {
        Button { controller.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
          .accessibilityLabel("Clear search")
      }
      Button("Add keybinding", systemImage: "plus") { controller.isAdding = true }
        .disabled(controller.isAdding || !controller.canWrite)
      Button { Task { await controller.openFile() } } label: { Image(systemName: "curlybraces") }
        .disabled(controller.configPath == nil || !controller.canWrite)
        .help("Open keybindings.json").accessibilityLabel("Open keybindings.json")
    }
  }
}
