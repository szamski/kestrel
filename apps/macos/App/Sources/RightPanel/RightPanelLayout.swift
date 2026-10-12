import SwiftUI
import T3ClientRuntime

/// The thread's content with the right panel beside it. Wide windows show the panel inline, resizable and
/// maximizable; narrow ones present it as a sheet (the web does the same below 980 px).
///
/// The content keeps one width while the panel is dragged or maximized and is resized once, when the drag
/// ends, so a long timeline is not re-laid out on every frame.
struct RightPanelLayout<Content: View, Panel: View>: View {
  let key: ScopedThreadKey
  @Bindable var store: RightPanelStore
  @ViewBuilder var content: Content
  @ViewBuilder var panel: Panel

  @Environment(AppModel.self) private var app
  @Environment(CommandCenter.self) private var commands
  @State private var liveWidth: CGFloat?
  @State private var dragStart: CGFloat?

  /// The detail column's width from which the panel fits beside the chat (about the web's 980 px viewport
  /// minus its sidebar).
  static var inlineMinimum: CGFloat { 720 }
  private static var handleWidth: CGFloat { 8 }

  var body: some View {
    GeometryReader { proxy in
      let state = store.state(key)
      let inline = proxy.size.width >= Self.inlineMinimum
      let maximized = store.isMaximized(key)
      let committed = clamp(store.width, in: proxy.size.width)
      let shown = clamp(liveWidth ?? store.width, in: proxy.size.width)
      ZStack(alignment: .trailing) {
        VStack(spacing: 0) {
          content
          ThreadTerminalDrawerView(app: app, key: key, drawers: .shared)
        }
        .padding(.trailing, inline && state.isOpen ? committed : 0)
        if inline && state.isOpen {
          HStack(spacing: 0) {
            if !maximized { handle(available: proxy.size.width) }
            panel
          }
          .frame(width: maximized ? proxy.size.width : shown + Self.handleWidth, height: proxy.size.height)
          .background(Palette.canvas)
          .overlay(alignment: .leading) { Divider().opacity(maximized ? 0 : 1) }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
      .sheet(item: dialogBinding) { request in
        FileDialogView(app: app, key: key, store: store, kind: request.kind)
      }
      .sheet(isPresented: Binding(get: { !inline && store.state(key).isOpen }, set: { if !$0 { store.close(key) } })) {
        panel.frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
      }
    }
    .task(id: key) { registerCommands() }
    // Fallback until/unless the keybindings are used: the same actions as the commands.
    .toolbar {
      if previewSupported {
        ToolbarItem(placement: .primaryAction) {
          Button { store.toggle(.preview, in: key) } label: { Label("Browser", systemImage: "globe") }
            .help("Show or hide the browser: the pages your agent opens on the server")
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Show Files") { store.openFiles(in: key) }
          Button("Go to File\u{2026}") { store.goToFile(in: key) }
          Button("Search in Files\u{2026}") { store.searchContents(in: key) }
        } label: {
          Label("Files", systemImage: "folder")
        }
        .help("Files: browse, go to file, search contents")
      }
    }
  }

  /// The environment hosts server browsers, so the Preview tab has pages to show.
  private var previewSupported: Bool { app.runtime.serverConfigs[key.environmentId]?.config.environment.capabilities.serverBrowser == true }

  private var dialogBinding: Binding<FileDialogRequest?> {
    Binding(
      get: { store.fileDialog?.thread == key.description ? store.fileDialog : nil },
      set: { if $0 == nil { store.fileDialog = nil } })
  }

  /// The panel's keybinding commands act on the thread this layout shows; they are unavailable once it is not selected.
  private func registerCommands() {
    let key = key, store = store, app = app
    let here = { app.selection == key }
    commands.register(.rightPanelToggle, isAvailable: here) { store.toggleVisibility(key) }
    commands.register(.rightPanelClose, isAvailable: { here() && store.state(key).isOpen }) { store.close(key) }
    commands.register(.rightPanelToggleMaximized, isAvailable: { here() && store.state(key).isOpen }) { store.toggleMaximized(key) }
    commands.register(.diffToggle, isAvailable: here) { store.toggle(.diff, in: key) }
    commands.register(.filePickerToggle, isAvailable: here) { store.goToFile(in: key) }
    commands.register(.projectSearchToggle, isAvailable: here) { store.searchContents(in: key) }
    TerminalDrawers.shared.registerCommands(commands, app: app, key: key)
  }

  private func clamp(_ width: CGFloat, in available: CGFloat) -> CGFloat {
    min(max(width, RightPanelStore.minimumWidth), max(RightPanelStore.minimumWidth, min(1100, available - 360)))
  }

  private func handle(available: CGFloat) -> some View {
    Color.clear
      .frame(width: Self.handleWidth)
      .contentShape(Rectangle())
      .pointerStyle(.columnResize)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let start = dragStart ?? store.width
            dragStart = start
            liveWidth = clamp(start - drag.translation.width, in: available)
          }
          .onEnded { _ in
            if let liveWidth { store.width = liveWidth }
            liveWidth = nil
            dragStart = nil
          }
      )
      .accessibilityLabel("Resize panel")
  }
}
