import Foundation
import T3Contracts

/// Port of `state/orchestrationV2Projection.ts` (+ `shared/orchestrationV2Timeline.ts`): applies one
/// committed domain event to a thread projection.
public enum ProjectionUpdate: Sendable, Equatable {
  /// The event does not change what the client holds (another thread, an unloaded historical row).
  case unchanged
  case updated(OrchestrationV2ThreadProjection)
}

public struct ProjectionOptions: Sendable, Equatable {
  /// The projection holds a bounded window: items outside it are not added by later events.
  public var partialTimeline = false
  public var latestLocalTurnOrdinal: Int?
  public init(partialTimeline: Bool = false, latestLocalTurnOrdinal: Int? = nil) {
    self.partialTimeline = partialTimeline
    self.latestLocalTurnOrdinal = latestLocalTurnOrdinal
  }
}

public typealias ProjectedTurnItemRow = OrchestrationV2ThreadProjectionVisibleTurnItemsItem
public typealias ProjectionTurnItem = OrchestrationV2ThreadProjectionTurnItemsItem

// MARK: Visibility (`shared/orchestrationV2Timeline.ts`)

public enum TurnItemVisibility {
  /// Whether one item belongs in the transcript given the runs, attempts and items of its thread.
  public static func isVisible(
    _ item: TurnItemHead, runs: [OrchestrationV2Run], attempts: [OrchestrationV2RunAttempt], items: [ProjectionTurnItem]
  ) -> Bool {
    if let runId = item.runId, runs.contains(where: { $0.id == runId && $0.status == .rolled_back }) { return false }
    // A queued message is composer state: when its run is cancelled the input never reached the provider.
    if item.type == "user_message", item.inputIntent == .queued_turn, let runId = item.runId,
      runs.contains(where: { $0.id == runId && $0.status == .cancelled })
    {
      return false
    }
    return !isSupersededInterrupt(item, attempts: attempts, items: items)
  }

  static func isSupersededInterrupt(_ item: TurnItemHead, attempts: [OrchestrationV2RunAttempt], items: [ProjectionTurnItem]) -> Bool {
    guard item.type == "run_interrupt_result", let runId = item.runId, let nodeId = item.nodeId else { return false }
    guard attempts.contains(where: { $0.runId == runId && $0.rootNodeId == nodeId && $0.status == .superseded }) else { return false }
    // Paired stop-then-steer results have a matching request on the same run and stay visible.
    return !items.contains { $0.head?.type == "run_interrupt_request" && $0.head?.runId == runId }
  }

  /// Indexes once when a whole timeline is reconciled after run or attempt state changed.
  static func makeVisibility(
    runs: [OrchestrationV2Run], attempts: [OrchestrationV2RunAttempt], items: [ProjectionTurnItem]
  ) -> (TurnItemHead) -> Bool {
    var statuses: [RunId: OrchestrationV2RunStatus] = [:]
    for run in runs { statuses[run.id] = run.status }
    var supersededRoots: [RunId: Set<NodeId>] = [:]
    for attempt in attempts where attempt.status == .superseded { supersededRoots[attempt.runId, default: []].insert(attempt.rootNodeId) }
    var interruptRuns = Set<RunId>()
    for item in items {
      if let head = item.head, head.type == "run_interrupt_request", let runId = head.runId { interruptRuns.insert(runId) }
    }
    return { item in
      let status = item.runId.flatMap { statuses[$0] }
      if status == .rolled_back { return false }
      if status == .cancelled, item.type == "user_message", item.inputIntent == .queued_turn { return false }
      if item.type == "run_interrupt_result", let runId = item.runId, let nodeId = item.nodeId,
        supersededRoots[runId]?.contains(nodeId) == true, !interruptRuns.contains(runId)
      {
        return false
      }
      return true
    }
  }
}

// MARK: Reducer

public enum ThreadProjectionReducer {
  public static func apply(
    _ projection: OrchestrationV2ThreadProjection, _ event: OrchestrationV2DomainEvent, options: ProjectionOptions = ProjectionOptions()
  ) -> ProjectionUpdate {
    guard event.threadId == projection.thread.id, let occurredAt = event.occurredAt else { return .unchanged }
    var base = projection
    base.updatedAt = occurredAt
    switch event {
    case .threadCreated(let e):
      base.thread = e.payload
      return .updated(base)
    case .threadArchived(let e):
      // Visited tracking is read state, not activity: skip the updatedAt bump.
      switch e.type {
      case .threadVisited, .threadMarkedUnread:
        var next = projection
        next.thread = e.payload
        return .updated(next)
      default:
        base.thread = e.payload
        return .updated(base)
      }
    case .runCreated(let e): return .updated(withVisibleRows(runsChangedIn: &base) { upsert(&$0.runs, e.payload, id: \.id) })
    case .runUpdated(let e): return .updated(withVisibleRows(runsChangedIn: &base) { upsert(&$0.runs, e.payload, id: \.id) })
    case .runBackgroundWorkCancelled(let e):
      if let index = base.runs.firstIndex(where: { $0.id == e.payload.runId }) {
        base.runs[index].restartCancelledBackgroundWork = e.payload.restartCancelledBackgroundWork
      }
      return .updated(base)
    case .runAttemptCreated(let e): return .updated(withVisibleRows(runsChangedIn: &base) { upsert(&$0.attempts, e.payload, id: \.id) })
    case .runAttemptUpdated(let e): return .updated(withVisibleRows(runsChangedIn: &base) { upsert(&$0.attempts, e.payload, id: \.id) })
    case .nodeUpdated(let e):
      upsert(&base.nodes, e.payload, id: \.id)
      return .updated(base)
    case .subagentUpdated(let e):
      upsert(&base.subagents, e.payload, id: \.id)
      return .updated(base)
    case .providerSessionAttached(let e):
      upsert(&base.providerSessions, e.payload, id: \.id)
      return .updated(base)
    case .providerSessionDetached(let e):
      base.providerSessions.removeAll { $0.id == e.payload.providerSessionId }
      return .updated(base)
    case .providerThreadUpdated(let e):
      upsert(&base.providerThreads, e.payload, id: \.id)
      return .updated(base)
    case .providerTurnUpdated(let e):
      var turn = e.payload
      // A later update without usage keeps the last known usage.
      if turn.tokenUsage == nil { turn.tokenUsage = base.providerTurns.first { $0.id == turn.id }?.tokenUsage }
      upsert(&base.providerTurns, turn, id: \.id)
      return .updated(base)
    case .runtimeRequestUpdated(let e):
      upsert(&base.runtimeRequests, e.payload, id: \.id)
      return .updated(base)
    case .messageUpdated(let e):
      upsert(&base.messages, e.payload, id: \.id)
      return .updated(base)
    case .planUpdated(let e):
      if let id = planId(e.payload) {
        if let index = base.plans.firstIndex(where: { planId($0) == id }) { base.plans[index] = e.payload } else { base.plans.append(e.payload) }
      } else {
        base.plans.append(e.payload)
      }
      return .updated(base)
    case .turnItemUpdated(let e): return applyTurnItem(e.payload, projection: projection, base: base, options: options)
    case .checkpointScopeCreated(let e):
      upsert(&base.checkpointScopes, e.payload, id: \.id)
      return .updated(base)
    case .checkpointCaptured(let e):
      upsert(&base.checkpoints, e.payload, id: \.id)
      return .updated(base)
    case .checkpointRollbackRequested:
      return .updated(base)
    case .contextHandoffUpdated(let e):
      upsert(&base.contextHandoffs, e.payload, id: \.id)
      return .updated(base)
    case .contextTransferCreated(let e):
      upsert(&base.contextTransfers, e.payload, id: \.id)
      return .updated(base)
    case .contextTransferUpdated(let e):
      upsert(&base.contextTransfers, e.payload, id: \.id)
      return .updated(base)
    case .unknown:
      return .unchanged
    }
  }

  private static func planId(_ plan: OrchestrationV2PlanArtifact) -> PlanId? {
    switch plan {
    case .proposedPlan(let p): p.id
    case .todoList(let p): p.id
    case .unknown: nil
    }
  }

  private static func upsert<T, ID: Equatable>(_ items: inout [T], _ item: T, id: KeyPath<T, ID>) {
    if let index = items.firstIndex(where: { $0[keyPath: id] == item[keyPath: id] }) { items[index] = item } else { items.append(item) }
  }

  /// Run and attempt changes can hide or reveal rows already in the timeline.
  private static func withVisibleRows(
    runsChangedIn projection: inout OrchestrationV2ThreadProjection, _ change: (inout OrchestrationV2ThreadProjection) -> Void
  ) -> OrchestrationV2ThreadProjection {
    change(&projection)
    projection.visibleTurnItems = activeVisibleTurnItems(projection)
    return projection
  }

  // MARK: Turn items

  private static func applyTurnItem(
    _ payload: OrchestrationV2TurnItem, projection: OrchestrationV2ThreadProjection, base: OrchestrationV2ThreadProjection,
    options: ProjectionOptions
  ) -> ProjectionUpdate {
    guard let item = payload.projectionItem, let head = item.head else { return .unchanged }
    if options.partialTimeline, !projection.turnItems.contains(where: { $0.head?.id == head.id }),
      shouldDropMissingPartialTurnItem(projection, head, options.latestLocalTurnOrdinal)
    {
      return .unchanged
    }
    var next = base
    let previousIndex = projection.turnItems.firstIndex { $0.head?.id == head.id }
    if let index = previousIndex { next.turnItems[index] = item } else { next.turnItems.append(item) }
    // Only interrupt requests can change another item's visibility. Streaming text/tool updates
    // must not recheck every row against every run.
    var visible = next
    if head.type == "run_interrupt_request" || previousIndex.flatMap({ projection.turnItems[$0].head?.type }) == "run_interrupt_request" {
      visible.visibleTurnItems = activeVisibleTurnItems(next)
    }
    let showLocal = TurnItemVisibility.isVisible(head, runs: next.runs, attempts: next.attempts, items: next.turnItems)
    next.visibleTurnItems =
      showLocal
      ? upsertVisibleTurnItem(visible, item, head, options) : removeVisibleItem(visible.visibleTurnItems, head.id)
    return .updated(next)
  }

  static func renumber(_ rows: [ProjectedTurnItemRow]) -> [ProjectedTurnItemRow] {
    rows.enumerated().map { position, row in
      guard row.position != position else { return row }
      var next = row
      next.position = position
      return next
    }
  }

  private static func removeVisibleItem(_ rows: [ProjectedTurnItemRow], _ sourceItemId: TurnItemId) -> [ProjectedTurnItemRow] {
    guard let index = rows.firstIndex(where: { $0.sourceItemId == sourceItemId }) else { return rows }
    var next = rows
    next.remove(at: index)
    return renumber(next)
  }

  private static func activeVisibleTurnItems(_ projection: OrchestrationV2ThreadProjection) -> [ProjectedTurnItemRow] {
    let rows = projection.visibleTurnItems
    let isVisible = TurnItemVisibility.makeVisibility(runs: projection.runs, attempts: projection.attempts, items: projection.turnItems)
    let kept = rows.filter { row in row.visibility != .local || (row.item.head.map(isVisible) ?? true) }
    return kept.count == rows.count ? rows : renumber(kept)
  }

  private static func oldestLocalTurnOrdinal(_ rows: [ProjectedTurnItemRow]) -> Int? {
    rows.filter { $0.visibility == .local }.compactMap { $0.item.head?.ordinal }.min()
  }

  /// A bounded window does not take items older than what it holds.
  private static func shouldDropMissingPartialTurnItem(
    _ projection: OrchestrationV2ThreadProjection, _ item: TurnItemHead, _ latestLocalTurnOrdinal: Int?
  ) -> Bool {
    if projection.visibleTurnItems.contains(where: { $0.sourceItemId == item.id }) { return false }
    if let latest = latestLocalTurnOrdinal, item.ordinal <= latest { return true }
    if let oldest = oldestLocalTurnOrdinal(projection.visibleTurnItems) { return item.ordinal < oldest }
    return false
  }

  private static func upsertVisibleTurnItem(
    _ projection: OrchestrationV2ThreadProjection, _ item: ProjectionTurnItem, _ head: TurnItemHead, _ options: ProjectionOptions
  ) -> [ProjectedTurnItemRow] {
    let rows = projection.visibleTurnItems
    let index = rows.firstIndex { $0.sourceItemId == head.id }
    let row = ProjectedTurnItemRow(position: 0, visibility: .local, sourceThreadId: head.threadId, sourceItemId: head.id, item: item)
    if let index {
      let previous = rows[index]
      if previous.visibility == row.visibility, previous.sourceThreadId == row.sourceThreadId, previous.item == item { return rows }
    } else if options.partialTimeline, shouldDropMissingPartialTurnItem(projection, head, options.latestLocalTurnOrdinal) {
      return rows
    }
    var updated = rows
    if let index { updated.remove(at: index) }
    // ponytail: ids tie-break by code unit order, the web client uses locale order; ids are lowercase slugs or uuids.
    let insertion = updated.firstIndex { candidate in
      guard candidate.visibility == .local, let other = candidate.item.head else { return false }
      return other.ordinal > head.ordinal || (other.ordinal == head.ordinal && other.id.rawValue > head.id.rawValue)
    }
    updated.insert(row, at: insertion ?? updated.count)
    return renumber(updated)
  }
}
