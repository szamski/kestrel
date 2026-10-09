import AppKit
import SwiftUI
import T3ClientRuntime

/// ⌘K. The palette is an overlay of the main window's content (`T3CodeApp` shows `PaletteView` while
/// `isOpen`), so it follows the window and shares its appearance. Focus goes back to where it was.
@MainActor @Observable
final class PaletteController {
  private(set) var isOpen = false
  private(set) var mode: PaletteMode = .root
  @ObservationIgnored private var previousResponder: NSView?

  func toggle(mode: PaletteMode = .root) {
    if isOpen { dismiss() } else { present(mode: mode) }
  }

  func present(mode: PaletteMode = .root) {
    guard !isOpen else { return }
    // An inactive app has no key window; fall back to the first document-style window.
    let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
    guard window?.attachedSheet == nil else { return }
    previousResponder = window?.firstResponder as? NSView
    self.mode = mode
    isOpen = true
  }

  func dismiss() {
    guard isOpen else { return }
    isOpen = false
    // The view is gone after this update; hand the keyboard back to the composer (or whatever had it).
    if let previous = previousResponder {
      DispatchQueue.main.async { previous.window?.makeFirstResponder(previous) }
    }
    previousResponder = nil
  }
}

struct PaletteView: View {
  let app: AppModel
  let commands: CommandCenter
  let startMode: PaletteMode
  let close: () -> Void

  @State private var query = ""
  @State private var mode: PaletteMode
  @State private var highlighted: String?
  @FocusState private var searchFocused: Bool

  init(app: AppModel, commands: CommandCenter, startMode: PaletteMode, close: @escaping () -> Void) {
    self.app = app
    self.commands = commands
    self.startMode = startMode
    self.close = close
    _mode = State(initialValue: startMode)
  }

  private var content: PaletteContent {
    PaletteContent(
      app: app, commands: commands,
      finish: { action in
        close()
        action()
      },
      switchMode: { newMode in
        mode = newMode
        query = ""
        highlighted = nil
      })
  }

  var body: some View {
    let sections = content.sections(mode: mode, query: query)
    let flat = sections.flatMap(\.items)
    let current = flat.first { $0.id == highlighted } ?? flat.first
    ZStack(alignment: .top) {
      Color.black.opacity(0.18).onTapGesture(perform: close).accessibilityHidden(true)
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: mode == .root ? "magnifyingglass" : "folder.badge.plus").foregroundStyle(.secondary)
          TextField(mode == .root ? "Search threads, projects and commands" : "Choose a project", text: $query)
            .textFieldStyle(.plain).font(.system(size: 15)).focused($searchFocused)
            .onSubmit { current?.run() }
            .accessibilityLabel("Command palette")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              if flat.isEmpty { Text("No results").foregroundStyle(.secondary).padding(14) }
              ForEach(sections) { section in
                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                  .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                ForEach(section.items) { item in
                  PaletteRow(item: item, isHighlighted: item.id == current?.id)
                    .id(item.id)
                    .onTapGesture { item.run() }
                    .onHover { if $0 { highlighted = item.id } }
                }
              }
            }
            .padding(.horizontal, 6).padding(.bottom, 6)
          }
          .frame(maxHeight: 380)
          .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
        }
      }
      .frame(width: 580)
      .glassEffect(in: .rect(cornerRadius: 16))
      .padding(.top, 70)
      .onKeyPress(.downArrow) { move(flat, current: current, by: 1); return .handled }
      .onKeyPress(.upArrow) { move(flat, current: current, by: -1); return .handled }
      .onKeyPress(.escape) { close(); return .handled }
      .onKeyPress(.delete) {
        guard query.isEmpty, mode != .root else { return .ignored }
        mode = .root
        highlighted = nil
        return .handled
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Command palette")
    }
    .onAppear { searchFocused = true }
    .onChange(of: query) { _, _ in highlighted = nil }
  }

  private func move(_ items: [PaletteItem], current: PaletteItem?, by delta: Int) {
    guard !items.isEmpty else { return }
    let index = current.flatMap { item in items.firstIndex { $0.id == item.id } } ?? 0
    highlighted = items[(index + delta + items.count) % items.count].id
  }
}

private struct PaletteRow: View {
  let item: PaletteItem
  let isHighlighted: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
      Text(item.title).lineLimit(1)
      if let subtitle = item.subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
      Spacer(minLength: 8)
      if let trailing = item.trailing { Text(trailing).font(.callout).foregroundStyle(.tertiary) }
      if let shortcut = item.shortcut { Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary) }
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}
