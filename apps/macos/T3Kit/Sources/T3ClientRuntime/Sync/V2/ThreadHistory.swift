import Foundation
import T3Contracts

/// Progressive-history bookkeeping of one thread (`threadHistoryMerge.ts`).
public struct ThreadHistoryMeta: Sendable, Equatable {
  public var historyCursor: String?
  public var hasMoreHistory: Bool
  public var loading: Bool
  public var error: String?
  /// True after at least one older page was merged; skip monolithic cache growth.
  public var expanded: Bool
  /// Max local turn ordinal known for partial windows; nil when unknown.
  public var latestLocalTurnOrdinal: Int?

  public static let empty = ThreadHistoryMeta(
    historyCursor: nil, hasMoreHistory: false, loading: false, error: nil, expanded: false, latestLocalTurnOrdinal: nil)

  /// A window with more history behind it: later events must not grow it backwards.
  var isPartial: Bool { hasMoreHistory || historyCursor != nil }

  /// Whether a client timeline should offer "load earlier".
  public var showsLoadEarlier: Bool { hasMoreHistory || error != nil }
}

public enum ThreadHistory {
  private static func key(_ row: ProjectedTurnItemRow) -> String { "\(row.sourceThreadId.rawValue):\(row.sourceItemId.rawValue)" }

  private static func isLocal(_ row: ProjectedTurnItemRow, in projection: OrchestrationV2ThreadProjection) -> Bool {
    row.visibility == .local || row.sourceThreadId == projection.thread.id
  }

  /// Merges an older history page into the live projection: dedupes by source thread and item id, keeps
  /// chronological order (older first) and prefers the newer live rows already present.
  public static func mergeOlder(_ projection: OrchestrationV2ThreadProjection, _ older: [ProjectedTurnItemRow]) -> OrchestrationV2ThreadProjection {
    if older.isEmpty { return projection }
    var currentByKey: [String: ProjectedTurnItemRow] = [:]
    for row in projection.visibleTurnItems { currentByKey[key(row)] = row }
    // Insertion-ordered: the merged `turnItems` keep the order items were first seen.
    var itemOrder: [TurnItemId] = []
    var itemById: [TurnItemId: ProjectionTurnItem] = [:]
    for item in projection.turnItems {
      guard let id = item.head?.id else { continue }
      if itemById[id] == nil { itemOrder.append(id) }
      itemById[id] = item
    }
    var pageKeys = Set<String>()
    var page: [ProjectedTurnItemRow] = []
    for pageRow in older {
      let rowKey = key(pageRow)
      if pageKeys.contains(rowKey) { continue }
      var row = currentByKey[rowKey] ?? pageRow
      if currentByKey[rowKey] == nil, isLocal(row, in: projection), let current = itemById[row.sourceItemId] {
        // Hidden live items stay hidden. Cold snapshots also retain interrupt requests outside the
        // visible window; paging may reveal those requests.
        guard let head = current.head, head.type == "run_interrupt_request",
          TurnItemVisibility.isVisible(head, runs: projection.runs, attempts: projection.attempts, items: projection.turnItems)
        else { continue }
        row.item = current
      }
      pageKeys.insert(rowKey)
      page.append(row)
      if isLocal(row, in: projection), itemById[row.sourceItemId] == nil {
        itemById[row.sourceItemId] = row.item
        itemOrder.append(row.sourceItemId)
      }
    }
    if page.isEmpty { return projection }
    // Server page order fills gaps between rows of a partial conversation load. Existing rows supply
    // live values; rows outside this range keep their order.
    let visible = page + projection.visibleTurnItems.filter { !pageKeys.contains(key($0)) }
    if visible == projection.visibleTurnItems { return projection }
    var next = projection
    next.turnItems = itemOrder.compactMap { itemById[$0] }
    next.visibleTurnItems = ThreadProjectionReducer.renumber(visible)
    return next
  }

  /// The first bounded window sent with `turnItemsOmitLocalVisible`: its local rows are also its leading
  /// `turnItems`, so the server drops them from the wire and the client rebuilds them here.
  public static func restoreLocalVisibleTurnItems(_ projection: OrchestrationV2ThreadProjection) -> OrchestrationV2ThreadProjection {
    let local = projection.visibleTurnItems.filter { isLocal($0, in: projection) }.map(\.item)
    if local.isEmpty { return projection }
    var next = projection
    next.turnItems = local + projection.turnItems
    return next
  }

  /// Meta after one complete older page was merged.
  public static func applying(page: OrchestrationV2ThreadHistoryPage, to current: ThreadHistoryMeta) -> ThreadHistoryMeta {
    ThreadHistoryMeta(
      historyCursor: page.nextCursor, hasMoreHistory: page.hasMoreHistory, loading: false, error: nil, expanded: true,
      // The partial-timeline watermark survives load-earlier pages.
      latestLocalTurnOrdinal: current.latestLocalTurnOrdinal)
  }
}
