import AppKit
import SwiftUI

public struct DiffReveal: Equatable, Sendable {
  public var fileId: String
  public var token: Int

  public init(fileId: String, token: Int) {
    self.fileId = fileId
    self.token = token
  }
}

public struct DiffTableActions {
  public var toggleCollapse: @MainActor (String) -> Void = { _ in }
  public var select: @MainActor (DiffSelection?) -> Void = { _ in }
  public var copyPath: @MainActor (DiffFile) -> Void = { _ in }
  public var openInEditor: @MainActor (DiffFile) -> Void = { _ in }
  public var reveal: @MainActor (DiffFile) -> Void = { _ in }

  public init() {}

  public init(
    toggleCollapse: @escaping @MainActor (String) -> Void, select: @escaping @MainActor (DiffSelection?) -> Void,
    copyPath: @escaping @MainActor (DiffFile) -> Void, openInEditor: @escaping @MainActor (DiffFile) -> Void, reveal: @escaping @MainActor (DiffFile) -> Void
  ) {
    self.toggleCollapse = toggleCollapse
    self.select = select
    self.copyPath = copyPath
    self.openInEditor = openInEditor
    self.reveal = reveal
  }
}

/// The diff list: one `NSTableView` row per header, hunk or line (or line pair in split layout), so only the
/// visible rows exist as views and a very large diff scrolls like a small one. File headers are group rows and
/// float at the top while their file scrolls past.
///
/// `revision` must change whenever `files`, `rows`, `layout` or `wordWrap` do; everything else redraws in place.
public struct DiffTable: NSViewRepresentable {
  public var files: [DiffFile]
  public var rows: [DiffRow]
  public var revision: Int
  public var layout: DiffLayoutMode
  public var wordWrap: Bool
  public var selection: DiffSelection?
  public var markers: [String: [ClosedRange<Int>]]
  public var reveal: DiffReveal?
  public var actions: DiffTableActions

  public init(
    files: [DiffFile], rows: [DiffRow], revision: Int, layout: DiffLayoutMode, wordWrap: Bool, selection: DiffSelection?,
    markers: [String: [ClosedRange<Int>]], reveal: DiffReveal?, actions: DiffTableActions
  ) {
    self.files = files
    self.rows = rows
    self.revision = revision
    self.layout = layout
    self.wordWrap = wordWrap
    self.selection = selection
    self.markers = markers
    self.reveal = reveal
    self.actions = actions
  }

  public func makeCoordinator() -> Coordinator { Coordinator() }

  public func makeNSView(context: Context) -> NSScrollView {
    let coordinator = context.coordinator
    let table = DiffNSTableView()
    table.context = coordinator.render
    coordinator.render.table = table
    let column = NSTableColumn(identifier: .init("diff"))
    column.minWidth = 100
    column.resizingMask = []
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .plain
    table.selectionHighlightStyle = .none
    table.intercellSpacing = .zero
    table.usesAutomaticRowHeights = false
    table.floatsGroupRows = true
    table.backgroundColor = .clear
    table.allowsColumnSelection = false
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.dataSource = coordinator
    table.delegate = coordinator

    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.contentView.postsFrameChangedNotifications = true
    coordinator.attach(scroll: scroll, table: table)
    return scroll
  }

  public func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    let render = coordinator.render
    render.actions = actions
    render.markers = markers
    var redraw = false
    if render.selection != selection { render.selection = selection; redraw = true }
    if coordinator.revision != revision {
      coordinator.revision = revision
      render.setContent(files: files, rows: rows, layout: layout, wordWrap: wordWrap)
      coordinator.reload()
    } else if redraw || coordinator.markersDirty(markers) {
      render.table?.redrawVisibleRows()
    }
    if let reveal, reveal != coordinator.lastReveal {
      coordinator.lastReveal = reveal
      coordinator.scroll(toFile: reveal.fileId)
    }
  }

  @MainActor
  public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let render = DiffRenderContext()
    var revision = -1
    var lastReveal: DiffReveal?
    private var lastMarkers: [String: [ClosedRange<Int>]] = [:]
    private weak var scroll: NSScrollView?
    private weak var table: DiffNSTableView?
    private var lastColumns = 0
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    func attach(scroll: NSScrollView, table: DiffNSTableView) {
      self.scroll = scroll
      self.table = table
      observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.viewportChanged() }
      }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func markersDirty(_ markers: [String: [ClosedRange<Int>]]) -> Bool {
      defer { lastMarkers = markers }
      return markers != lastMarkers
    }

    func reload() {
      guard let table else { return }
      applyWidth()
      lastColumns = currentColumns
      table.reloadData()
    }

    private var currentColumns: Int { render.layout == .split ? render.geometry.splitColumns : render.geometry.stackedColumns }

    private func applyWidth() {
      guard let scroll, let table else { return }
      render.viewportWidth = max(200, scroll.contentView.bounds.width)
      table.tableColumns.first?.width = render.contentWidth
    }

    private func viewportChanged() {
      guard let scroll, let table, abs(scroll.contentView.bounds.width - render.viewportWidth) > 0.5 else { return }
      applyWidth()
      // Wrapped heights depend on the column count; without wrapping nothing but the width changes.
      if render.wordWrap, currentColumns != lastColumns {
        lastColumns = currentColumns
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<render.rows.count))
      }
      table.redrawVisibleRows()
    }

    func scroll(toFile id: String) {
      guard let scroll, let table, let file = render.files.firstIndex(where: { $0.id == id }),
        let row = render.rows.firstIndex(where: { $0.file == file && $0.kind == .fileHeader })
      else { return }
      let clip = scroll.contentView
      clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: table.rect(ofRow: row).minY))
      scroll.reflectScrolledClipView(clip)
    }

    // MARK: NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { render.rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { render.height(ofRow: row) }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
      row < render.rows.count && render.rows[row].kind == .fileHeader
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let id = NSUserInterfaceItemIdentifier("diffRowChrome")
      return (tableView.makeView(withIdentifier: id, owner: nil) as? DiffRowChrome) ?? { let view = DiffRowChrome(); view.identifier = id; return view }()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      let id = NSUserInterfaceItemIdentifier("diffRowCell")
      let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? DiffRowCell) ?? { let view = DiffRowCell(); view.identifier = id; return view }()
      cell.configure(render, index: row)
      return cell
    }
  }
}

/// Group rows must not paint AppKit's own group background; the row cell draws an opaque one so the lines
/// scrolling under a floating header do not show through.
final class DiffRowChrome: NSTableRowView {
  override func drawBackground(in dirtyRect: NSRect) {}
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawSeparator(in dirtyRect: NSRect) {}
}

@MainActor
final class DiffNSTableView: NSTableView {
  weak var context: DiffRenderContext?

  override var acceptsFirstResponder: Bool { true }

  func redrawVisibleRows() {
    enumerateAvailableRowViews { rowView, _ in
      for subview in rowView.subviews { subview.needsDisplay = true }
    }
  }

  @objc func copy(_ sender: Any?) {
    guard let text = context?.selectedText() else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  override func cancelOperation(_ sender: Any?) { context?.clearSelection() }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) { return context?.selection != nil }
    return super.validateUserInterfaceItem(item)
  }
}
