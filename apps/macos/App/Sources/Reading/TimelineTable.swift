import AppKit
import SwiftUI
import T3Markdown

/// The virtualized timeline: a view-based `NSTableView` of SwiftUI rows with cached heights.
///
/// Why a table: heights are known before a row appears (measured through one offscreen hosting
/// view, text heights cached in `MarkdownLayout`), so scroll position is exact, prepending older
/// turns can keep the reader's anchor and the bottom can stick while streaming. Rows near the
/// viewport are measured synchronously; the rest are measured in small idle slices, nearest first,
/// so the scroller converges without ever laying out a whole 500-turn thread at once.
struct TimelineTable: NSViewRepresentable {
  let items: [TimelineItem]
  let host: TimelineHost
  let hasOlder: Bool
  let loadOlder: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> TimelineController { TimelineController(host: host) }

  func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

  func updateNSView(_ view: NSScrollView, context: Context) {
    let controller = context.coordinator
    controller.hasOlder = hasOlder
    controller.loadOlder = loadOlder
    controller.setAppearance(colorScheme == .dark)
    controller.apply(items)
  }
}

/// Hosts one row. Reports when SwiftUI says its ideal size changed (an image arrived, say) so the
/// table can re-measure the row.
final class TimelineHostingView: NSHostingView<TimelineCellRoot> {
  var onContentSizeInvalidated: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onContentSizeInvalidated?()
  }
}

struct TimelineCellRoot: View {
  var item: TimelineItem?
  var host: TimelineHost
  /// Set for offscreen measurement; cells fill the column the table gives them.
  var fixedWidth: CGFloat?

  var body: some View {
    if let item {
      TimelineRowContainer(item: item)
        .environment(\.timelineHost, host)
        .environment(\.timelineRowID, item.id)
        .frame(width: fixedWidth)
        .fixedSize(horizontal: false, vertical: fixedWidth != nil)
    }
  }
}

final class TimelineCellView: NSView {
  static let identifier = NSUserInterfaceItemIdentifier("TimelineCell")
  let hosting: TimelineHostingView

  init(item: TimelineItem, host: TimelineHost) {
    hosting = TimelineHostingView(rootView: TimelineCellRoot(item: item, host: host))
    super.init(frame: .zero)
    identifier = Self.identifier
    hosting.sizingOptions = [.intrinsicContentSize]
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = bounds
    addSubview(hosting)
  }

  required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class TimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let scrollView = NSScrollView()
  private let table = NSTableView()
  private let host: TimelineHost
  private let measurer: NSHostingView<TimelineCellRoot>

  var hasOlder = false
  var loadOlder: () -> Void = {}

  private var items: [TimelineItem] = []
  private var heights: [CGFloat] = []
  /// True when `heights[i]` was measured at `measuredWidth` for the current content.
  private var measured: [Bool] = []
  private var measuredWidth: CGFloat = 0
  private var dirtyRows: Set<String> = []
  private var flushScheduled = false
  private var refineTask: Task<Void, Never>?
  private var stickToBottom = true
  private var applying = false
  private var userScrolling = false
  private var olderRequestedForCount = -1
  private var isDark: Bool?
  private var themeObserver: NSObjectProtocol?
  /// Counters for the performance report.
  private(set) var measureCount = 0
  private(set) var measureTime: Double = 0

  #if DEBUG
  static weak var current: TimelineController?
  var debugCellCalls = 0
  var debugStats: (count: Int, seconds: Double, rows: Int, unmeasured: Int, cellCalls: Int) { (measureCount, measureTime, items.count, measured.filter { !$0 }.count, debugCellCalls) }
  #endif

  init(host: TimelineHost) {
    self.host = host
    measurer = NSHostingView(rootView: TimelineCellRoot(item: nil, host: host, fixedWidth: 600))
    super.init()
    host.rowChanged = { [weak self] in self?.contentSizeInvalidated(rowID: $0) }
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.style = .plain
    table.selectionHighlightStyle = .none
    table.allowsColumnSelection = false
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.usesAutomaticRowHeights = false
    table.rowSizeStyle = .custom
    table.gridStyleMask = []
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    #if DEBUG
    Self.current = self
    #endif
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.scrollerStyle = .overlay
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
    center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    // A new theme can change fonts, so every height is stale; the rows repaint themselves.
    themeObserver = center.addObserver(forName: .t3ThemeDidChange, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidateAllHeights()
        self.ensureMeasuredNearViewport()
        self.scheduleRefine()
      }
    }
  }

  isolated deinit {
    refineTask?.cancel()
    if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
  }

  // MARK: Updates from SwiftUI

  func setAppearance(_ dark: Bool) {
    guard isDark != dark else { return }
    if isDark != nil { invalidateAllHeights() }
    isDark = dark
    measurer.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  func apply(_ new: [TimelineItem]) {
    guard new != items else { return }
    let width = columnWidth
    let oldIDs = items.map(\.id)
    let sameIDs = oldIDs == new.map(\.id)
    let anchor = captureAnchor()
    let pinned = stickToBottom
    applying = true
    defer { applying = false }

    var oldIndex: [String: Int] = [:]
    oldIndex.reserveCapacity(items.count)
    for (index, id) in oldIDs.enumerated() { oldIndex[id] = index }
    var newHeights = [CGFloat](repeating: 0, count: new.count)
    var newMeasured = [Bool](repeating: false, count: new.count)
    var changed = IndexSet()
    for (index, item) in new.enumerated() {
      if let old = oldIndex[item.id] {
        newHeights[index] = heights[old]
        if items[old] == item { newMeasured[index] = measured[old] } else { changed.insert(index) }
      } else {
        newHeights[index] = estimateHeight(item, width: width)
      }
    }
    items = new
    heights = newHeights
    measured = newMeasured

    if sameIDs {
      // Same rows, some changed (a streamed delta, a toggled group): re-measure those now.
      for index in changed { measureNow(index) }
      table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
      table.noteHeightOfRows(withIndexesChanged: changed)
    } else {
      table.reloadData()
    }
    restore(anchor: anchor, pinned: pinned)
    ensureMeasuredNearViewport()
    requestOlderIfNeeded()
    scheduleRefine()
  }

  // MARK: Geometry

  private var columnWidth: CGFloat { max(scrollView.contentSize.width, 1) }

  @objc private func frameChanged(_ note: Notification) {
    let width = columnWidth
    guard abs(width - measuredWidth) > 0.5 else { return }
    invalidateAllHeights()
    let anchor = captureAnchor()
    let pinned = stickToBottom
    applying = true
    table.reloadData()
    restore(anchor: anchor, pinned: pinned)
    ensureMeasuredNearViewport()
    applying = false
    scheduleRefine()
  }

  private func invalidateAllHeights() {
    measured = [Bool](repeating: false, count: items.count)
    measuredWidth = 0
  }

  // MARK: Anchor handling

  private struct Anchor {
    var id: String
    var offset: CGFloat
  }

  private func captureAnchor() -> Anchor? {
    guard !items.isEmpty else { return nil }
    let visible = scrollView.contentView.bounds
    let row = table.row(at: NSPoint(x: 0, y: visible.minY + 1))
    guard row >= 0, row < items.count else { return nil }
    return Anchor(id: items[row].id, offset: visible.minY - table.rect(ofRow: row).minY)
  }

  /// Puts the same row at the same place (or the bottom, when following).
  private func restore(anchor: Anchor?, pinned: Bool) {
    table.layoutSubtreeIfNeeded()
    if pinned {
      scrollToBottom()
    } else if let anchor, let row = items.firstIndex(where: { $0.id == anchor.id }) {
      scroll(toY: table.rect(ofRow: row).minY + anchor.offset)
    }
  }

  private func scroll(toY y: CGFloat) {
    let clip = scrollView.contentView
    let maxY = max(0, table.bounds.height - clip.bounds.height)
    clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
    scrollView.reflectScrolledClipView(clip)
  }

  func scrollToBottom() { scroll(toY: .greatestFiniteMagnitude) }

  // MARK: Scroll events

  @objc private func boundsChanged(_ note: Notification) {
    if !applying {
      let visible = scrollView.contentView.bounds
      stickToBottom = visible.maxY >= table.bounds.height - 24
    }
    ensureMeasuredNearViewport()
    requestOlderIfNeeded()
  }

  @objc private func liveScrollStarted(_ note: Notification) { userScrolling = true }

  @objc private func liveScrollEnded(_ note: Notification) {
    userScrolling = false
    scheduleRefine()
  }

  private func requestOlderIfNeeded() {
    guard hasOlder, !items.isEmpty, scrollView.contentView.bounds.minY < 400, olderRequestedForCount != items.count else { return }
    olderRequestedForCount = items.count
    loadOlder()
  }

  // MARK: Measurement

  private func estimateHeight(_ item: TimelineItem, width: CGFloat) -> CGFloat {
    let textWidth = max(width - 2 * timelineHorizontalInset, 200)
    func textHeight(_ text: String, per: CGFloat = 22) -> CGFloat {
      let cpl = max(textWidth / 7.4, 20)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(CGFloat(0)) { $0 + max(1, ceil(CGFloat($1.count) / cpl)) }
      return lines * per
    }
    switch item.row {
    case .message(let row):
      switch row.message.role {
      case .user: return textHeight(row.message.text) + 48
      case .assistant: return textHeight(row.message.text) + 24 + (row.showAssistantMeta ? 28 : 0)
      default: return item.expanded ? textHeight(row.message.text) + 36 : 32
      }
    case .assistantMeta: return 30
    case .turnFold, .contextCompaction: return 36
    case .proposedPlan: return item.expanded ? 420 : 330
    case .worktreeSetup: return 170
    case .work(let row): return row.isExpandedToolGroup ? CGFloat(row.groupedEntries.count) * 26 + 4 : 28
    case .activityGroup(let row): return row.expanded ? CGFloat(row.entries.count) * 30 + 32 : 28
    default: return 28
    }
  }

  private func measureNow(_ index: Int) {
    let width = columnWidth
    let started = CFAbsoluteTimeGetCurrent()
    measurer.rootView = TimelineCellRoot(item: items[index], host: host, fixedWidth: width)
    measurer.frame = NSRect(x: 0, y: 0, width: width, height: 10)
    let height = ceil(measurer.fittingSize.height)
    measureTime += CFAbsoluteTimeGetCurrent() - started
    measureCount += 1
    heights[index] = max(height, 1)
    measured[index] = true
    measuredWidth = width
  }

  /// Rows within a viewport and a half of the visible area are exact before they can scroll in.
  private func ensureMeasuredNearViewport() {
    guard !items.isEmpty else { return }
    let visible = scrollView.contentView.bounds
    let margin = max(visible.height * 1.5, 800)
    let range = table.rows(in: NSRect(x: 0, y: visible.minY - margin, width: 1, height: visible.height + 2 * margin))
    guard range.length > 0 else { return }
    var changed = IndexSet()
    for row in range.location..<min(range.location + range.length, items.count) where !measured[row] {
      let before = heights[row]
      measureNow(row)
      if abs(heights[row] - before) > 0.5 { changed.insert(row) }
    }
    if !changed.isEmpty { applyHeights(changed) }
  }

  /// Applies new heights without moving what the reader looks at.
  private func applyHeights(_ rows: IndexSet) {
    let wasApplying = applying
    applying = true
    defer { applying = wasApplying }
    let anchor = captureAnchor()
    let pinned = stickToBottom
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      table.noteHeightOfRows(withIndexesChanged: rows)
    }
    restore(anchor: anchor, pinned: pinned)
  }

  // MARK: Idle refinement

  private func scheduleRefine() {
    guard refineTask == nil, measured.contains(false) else { return }
    refineTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled, refineSlice() { try? await Task.sleep(for: .milliseconds(6)) }
      self?.refineTask = nil
    }
  }

  /// Measures unmeasured rows nearest the viewport for about 3 ms. Returns whether work remains.
  private func refineSlice() -> Bool {
    guard !userScrolling else { return true }
    let remaining = measured.indices.filter { !measured[$0] }
    guard !remaining.isEmpty else { return false }
    let visible = scrollView.contentView.bounds
    let center = visible.midY
    let ordered = remaining.sorted { abs(table.rect(ofRow: $0).midY - center) < abs(table.rect(ofRow: $1).midY - center) }
    let started = CFAbsoluteTimeGetCurrent()
    var changed = IndexSet()
    for row in ordered {
      let before = heights[row]
      measureNow(row)
      if abs(heights[row] - before) > 0.5 { changed.insert(row) }
      if CFAbsoluteTimeGetCurrent() - started > 0.003 { break }
    }
    if !changed.isEmpty { applyHeights(changed) }
    return measured.contains(false)
  }

  // MARK: Row content size changes

  fileprivate func contentSizeInvalidated(rowID: String) {
    dirtyRows.insert(rowID)
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in self?.flushDirtyRows() }
  }

  private func flushDirtyRows() {
    flushScheduled = false
    let ids = dirtyRows
    dirtyRows = []
    var changed = IndexSet()
    for (index, item) in items.enumerated() where ids.contains(item.id) {
      let before = heights[index]
      measureNow(index)
      if abs(heights[index] - before) > 0.5 { changed.insert(index) }
    }
    if !changed.isEmpty { applyHeights(changed) }
  }

  // MARK: NSTableViewDataSource / Delegate

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    row < heights.count ? heights[row] : 28
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row < items.count else { return nil }
    #if DEBUG
    debugCellCalls += 1
    #endif
    let item = items[row]
    let root = TimelineCellRoot(item: item, host: host)
    let cell = (tableView.makeView(withIdentifier: TimelineCellView.identifier, owner: nil) as? TimelineCellView) ?? TimelineCellView(item: item, host: host)
    cell.hosting.rootView = root
    let id = item.id
    cell.hosting.onContentSizeInvalidated = { [weak self] in
      MainActor.assumeIsolated { self?.contentSizeInvalidated(rowID: id) }
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
