import Foundation
import T3Contracts

// Small pure helpers the reading window needs next to the rows: copy state, line breaks, scroll
// anchoring and the minimap geometry (MessagesTimeline.logic.ts, work-log/scrollAnchor.ts).

// MARK: - Assistant messages

public struct AssistantCopyState: Sendable, Hashable {
  public var text: String?
  public var visible: Bool
}

/// Whether the copy button shows for an assistant message and what it copies. `renderForCopy`
/// turns Codex directives (file citations, artifact templates) into plain text; it needs the
/// Markdown parser, so the host passes it in.
public func resolveAssistantMessageCopyState(
  text: String?,
  showCopyButton: Bool,
  streaming: Bool,
  renderForCopy: (String) -> String = { $0 }
) -> AssistantCopyState {
  let hasText = text.map { !$0.jsTrimmed.isEmpty } ?? false
  let visible = showCopyButton && hasText && !streaming
  return AssistantCopyState(text: hasText ? (visible ? renderForCopy(text!) : text) : nil, visible: visible)
}

/// Claude "★ Insight" blocks rely on their line breaks; regular Markdown does not.
public func shouldPreserveAssistantLineBreaks(_ text: String) -> Bool {
  text.range(of: "(?m)^★ Insight(?:\\s|─)", options: .regularExpression) != nil
}

// MARK: - Expanded work group scrolling

public struct WorkGroupScrollAnchor: Sendable, Hashable {
  public var entryId: String
  public var offset: Double

  public init(entryId: String, offset: Double) {
    self.entryId = entryId
    self.offset = offset
  }
}

/// Restore a visible tool, including a position partway through its expanded output.
public func resolveWorkGroupScrollIndex(entryIds: [String], anchor: WorkGroupScrollAnchor?) -> (index: Int, viewOffset: Double)? {
  guard let anchor, let index = entryIds.firstIndex(of: anchor.entryId) else { return nil }
  return (index, -anchor.offset)
}

/// Only newly appended calls may follow the end, never status or output updates.
public func shouldFollowWorkGroupAppend(previous: [String], entries: [String], distanceFromEnd: Double) -> Bool {
  !previous.isEmpty && entries.count > previous.count && distanceFromEnd <= 1
    && previous.enumerated().allSatisfy { index, id in entries[index] == id }
}

/// Save the row at the current offset (`resolveWorkGroupScrollAnchor`): the last row whose top
/// is at or above the scroll offset, found by binary search over `positionAtIndex`.
public func resolveWorkGroupScrollAnchor(
  entryIds: [String],
  scroll: Double,
  positionAtIndex: (Int) -> Double?
) -> (rowId: String, offsetWithinRow: Double, scrollOffset: Double)? {
  guard !entryIds.isEmpty, scroll.isFinite else { return nil }
  let scrollOffset = max(0, scroll)
  var low = 0
  var high = entryIds.count - 1
  var index = 0
  guard var rowTop = positionAtIndex(0), rowTop.isFinite else { return nil }
  while low <= high {
    let middle = (low + high) / 2
    guard let top = positionAtIndex(middle), top.isFinite else { return nil }
    if top <= scrollOffset {
      index = middle
      rowTop = top
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  return (entryIds[index], max(0, scrollOffset - rowTop), scrollOffset)
}

public struct TimelineEndState: Sendable, Hashable {
  public var isAtEnd: Bool?
  public var contentLength: Double?
  public var scroll: Double?
  public var scrollLength: Double?

  public init(isAtEnd: Bool? = nil, contentLength: Double? = nil, scroll: Double? = nil, scrollLength: Double? = nil) {
    self.isAtEnd = isAtEnd
    self.contentLength = contentLength
    self.scroll = scroll
    self.scrollLength = scrollLength
  }
}

/// Follow re-arm band above the hard bottom. Strict on purpose: re-arming within half a
/// viewport yanks a reader of history back down on the next stream chunk.
public let timelineFollowRearmThreshold: Double = 40

public func resolveTimelineIsAtEnd(_ state: TimelineEndState?) -> Bool? {
  guard let state else { return nil }
  guard let contentLength = state.contentLength, let scroll = state.scroll, let scrollLength = state.scrollLength else {
    return state.isAtEnd
  }
  // contentLength includes the composer inset spacer, but the composer hides the same amount of
  // viewport, so the inset cancels.
  return contentLength - scroll - scrollLength <= timelineFollowRearmThreshold
}

// MARK: - Minimap geometry

public let timelineMinimapMinItems = 2
private let timelineMinimapItemSpacing: Double = 8
private let timelineMinimapPersistentGutter: Double = 48
private let timelineMinimapHitStripLeft: Double = 12
private let timelineMinimapHitStripMaxWidth: Double = 40
private let timelineMinimapNavigationReach: Double = 14

/// Natural height of the rail in points, before the host caps it to the available space.
public func resolveTimelineMinimapNaturalHeight(itemCount: Int) -> Double {
  max(1, Double(itemCount - 1) * timelineMinimapItemSpacing)
}

/// Marker position along the rail, 0 ... 100.
public func resolveTimelineMinimapTopPercent(index: Int, itemCount: Int) -> Double {
  if itemCount <= 1 { return 0 }
  return Double(max(0, min(index, itemCount - 1))) / Double(itemCount - 1) * 100
}

public func resolveTimelineMinimapIndexFromPointer(itemCount: Int, railTop: Double, railHeight: Double, pointerY: Double) -> Int? {
  if itemCount <= 0 || railHeight <= 0 { return nil }
  if itemCount == 1 { return 0 }
  let progress = max(0, min(1, (pointerY - railTop) / railHeight))
  return max(0, min(itemCount - 1, Int(jsRound(progress * Double(itemCount - 1)))))
}

public struct TimelineMinimapItemBounds: Sendable, Hashable {
  public var top: Double?
  public var height: Double?

  public init(top: Double?, height: Double?) {
    self.top = top
    self.height = height
  }
}

/// The first visible marker is the turn at the reader's current position; otherwise the last
/// one above the viewport.
public func resolveTimelineMinimapCurrentIndex(scrollTop: Double, scrollBottom: Double, itemBounds: [TimelineMinimapItemBounds]) -> Int? {
  var precedingIndex: Int?
  for (index, item) in itemBounds.enumerated() {
    guard let top = item.top else { continue }
    if top < scrollBottom && top + max(1, item.height ?? 1) > scrollTop { return index }
    if top <= scrollTop { precedingIndex = index }
  }
  return precedingIndex
}

private func sideGutter(viewportWidth: Double, contentWidth: Double) -> Double {
  if !viewportWidth.isFinite || viewportWidth <= 0 || !contentWidth.isFinite { return 0 }
  return max(0, (viewportWidth - min(viewportWidth, contentWidth)) / 2)
}

public func resolveTimelineMinimapHasPersistentGutter(viewportWidth: Double, contentWidth: Double) -> Bool {
  sideGutter(viewportWidth: viewportWidth, contentWidth: contentWidth) >= timelineMinimapPersistentGutter
}

/// Width of the hover strip, capped so it never extends past the gutter into the text column.
public func resolveTimelineMinimapHitStripWidth(viewportWidth: Double, contentWidth: Double) -> Double {
  let gutter = sideGutter(viewportWidth: viewportWidth, contentWidth: contentWidth)
  return max(0, min(timelineMinimapHitStripMaxWidth, gutter.rounded(.down) - timelineMinimapHitStripLeft))
}

public func resolveTimelineMinimapNavigationInteractive(collapsedWidth: Double) -> Bool {
  collapsedWidth >= timelineMinimapNavigationReach
}
