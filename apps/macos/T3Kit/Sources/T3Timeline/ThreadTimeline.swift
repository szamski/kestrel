import Foundation
import T3Contracts

/// Client-side state the rows depend on besides the thread read model. Everything here is owned
/// by the window (expanded sections, optimistic send) or by other derivations (live agents).
public struct TimelineContext: Sendable {
  /// `nil` derives "working" from the session phase. A host adds its own busy states (a send in
  /// flight, a revert, a compaction) by passing `true`.
  public var isWorking: Bool?
  /// When the host started sending the current message, before the server acknowledged it.
  public var sendStartedAt: String?
  public var expandedTurnIds: Set<V1.TurnId>
  public var expandedWorkGroupIds: Set<String>
  public var supportsConversationRollback: Bool
  /// Subagents still working. `nil` derives them from the activity log like the web agent panel.
  public var liveAgentTaskIds: Set<String>?
  public var worktreeSetup: WorktreeSetupSnapshot?
  public var queuedMessages: [QueuedMessagePlaceholder]

  public init(
    isWorking: Bool? = nil,
    sendStartedAt: String? = nil,
    expandedTurnIds: Set<V1.TurnId> = [],
    expandedWorkGroupIds: Set<String> = [],
    supportsConversationRollback: Bool = false,
    liveAgentTaskIds: Set<String>? = nil,
    worktreeSetup: WorktreeSetupSnapshot? = nil,
    queuedMessages: [QueuedMessagePlaceholder] = []
  ) {
    self.isWorking = isWorking
    self.sendStartedAt = sendStartedAt
    self.expandedTurnIds = expandedTurnIds
    self.expandedWorkGroupIds = expandedWorkGroupIds
    self.supportsConversationRollback = supportsConversationRollback
    self.liveAgentTaskIds = liveAgentTaskIds
    self.worktreeSetup = worktreeSetup
    self.queuedMessages = queuedMessages
  }
}

/// One entry of the timeline minimap: a user message and the final assistant text of its turn.
public struct TimelineMinimapItem: Sendable, Hashable, Identifiable {
  public var id: String
  public var rowIndex: Int
  public var userText: String?
  public var assistantText: String?
}

/// Everything the reading window renders for one thread.
public struct ThreadTimeline: Sendable {
  public var workEntries: [WorkLogEntry]
  public var entries: [TimelineEntry]
  public var rows: [TimelineRow]
  public var phase: SessionPhase
  public var isWorking: Bool
  public var activeTurnStartedAt: String?
  public var runningTurnId: V1.TurnId?
  public var activePlan: ActivePlanState?
  /// The plan awaiting a decision; only offered once the latest turn has settled.
  public var activeProposedPlan: LatestProposedPlanState?
  public var minimap: [TimelineMinimapItem]
}

/// Derives the web chat view's rows from a thread (ChatView.tsx + MessagesTimeline.logic.ts).
///
/// Pure. A 500-turn thread (4000 activities, 1500 messages) derives in about 17 ms in release
/// (`PerformanceTests`); use `ThreadTimelineDeriver` to skip the work-log part (about 11 ms)
/// while only messages change, and derive off the main actor.
public func deriveThreadTimeline(
  messages: [V1.OrchestrationMessage],
  proposedPlans: [ProposedPlan],
  activities: [V1.OrchestrationThreadActivity],
  checkpoints: [V1.OrchestrationCheckpointSummary],
  latestTurn: V1.OrchestrationLatestTurn?,
  session: V1.OrchestrationSession?,
  context: TimelineContext = TimelineContext(),
  workEntries precomputed: [WorkLogEntry]? = nil
) -> ThreadTimeline {
  let phase = derivePhase(session)
  let workEntries = precomputed ?? deriveWorkLogEntries(activities)
  let entries = deriveTimelineEntries(messages: messages, proposedPlans: proposedPlans, workEntries: workEntries)
  let timing = latestTurn.map(LatestTurnTiming.init)
  // The session's running turn wins; otherwise the latest turn while it still runs.
  let runningTurnId =
    (session?.status == .running ? session?.activeTurnId : nil) ?? (latestTurn?.state == .running ? latestTurn?.turnId : nil)
  let isWorking = context.isWorking ?? (phase == .running)
  let latestUserMessageAt = messages.last { $0.role == .user }?.createdAt.rawValue
  let activeTurnStartedAt = deriveActiveWorkStartedAt(
    latestTurn: timing,
    session: session,
    sendStartedAt: context.sendStartedAt,
    latestUserMessageAt: latestUserMessageAt
  )
  let rows = deriveMessagesTimelineRows(
    TimelineRowsInput(
      timelineEntries: entries,
      latestTurn: timing,
      runningTurnId: runningTurnId,
      expandedTurnIds: context.expandedTurnIds,
      expandedWorkGroupIds: context.expandedWorkGroupIds,
      isWorking: isWorking,
      activeTurnStartedAt: activeTurnStartedAt,
      turnDiffSummaries: checkpoints,
      supportsConversationRollback: context.supportsConversationRollback,
      liveAgentTaskIds: context.liveAgentTaskIds ?? deriveLiveAgentTaskIds(activities: activities, sessionLive: phase != .disconnected),
      worktreeSetup: context.worktreeSetup,
      queuedMessages: context.queuedMessages
    ))
  return ThreadTimeline(
    workEntries: workEntries,
    entries: entries,
    rows: rows,
    phase: phase,
    isWorking: isWorking,
    activeTurnStartedAt: activeTurnStartedAt,
    runningTurnId: runningTurnId,
    activePlan: deriveActivePlanState(activities: activities, latestTurnId: latestTurn?.turnId),
    activeProposedPlan: isLatestTurnSettled(latestTurn: timing, session: session)
      ? findLatestProposedPlan(proposedPlans, latestTurnId: latestTurn?.turnId) : nil,
    minimap: deriveTimelineMinimapItems(rows)
  )
}

public func deriveThreadTimeline(_ thread: V1.OrchestrationThread, context: TimelineContext = TimelineContext()) -> ThreadTimeline {
  deriveThreadTimeline(
    messages: thread.messages,
    proposedPlans: thread.proposedPlans.map(ProposedPlan.init),
    activities: thread.activities,
    checkpoints: thread.checkpoints,
    latestTurn: thread.latestTurn,
    session: thread.session,
    context: context
  )
}

/// Keeps the work-log derivation (about two thirds of the cost) between updates that leave the
/// activity log alone, which is every streamed message delta. Hold one per open thread.
public struct ThreadTimelineDeriver: Sendable {
  private var activities: [V1.OrchestrationThreadActivity]?
  private var workEntries: [WorkLogEntry] = []

  public init() {}

  public mutating func derive(_ thread: V1.OrchestrationThread, context: TimelineContext = TimelineContext()) -> ThreadTimeline {
    if activities != thread.activities {
      workEntries = deriveWorkLogEntries(thread.activities)
      activities = thread.activities
    }
    return deriveThreadTimeline(
      messages: thread.messages,
      proposedPlans: thread.proposedPlans.map(ProposedPlan.init),
      activities: thread.activities,
      checkpoints: thread.checkpoints,
      latestTurn: thread.latestTurn,
      session: thread.session,
      context: context,
      workEntries: workEntries
    )
  }
}

// MARK: - Minimap

/// One minimap marker per user message row, with the turn's final assistant text for its preview.
public func deriveTimelineMinimapItems(_ rows: [TimelineRow]) -> [TimelineMinimapItem] {
  var items: [TimelineMinimapItem] = []
  for (index, row) in rows.enumerated() {
    guard case .message(let userRow) = row, userRow.message.role == .user else { continue }
    var finalAssistantText: String?
    scan: for next in rows[(index + 1)...] {
      guard case .message(let messageRow) = next else { continue }
      if messageRow.message.role == .user { break scan }
      if messageRow.message.role == .assistant { finalAssistantText = messageRow.message.text }
    }
    items.append(TimelineMinimapItem(id: userRow.id, rowIndex: index, userText: userRow.message.text, assistantText: finalAssistantText))
  }
  return items
}

/// Collapses whitespace for the hover preview; empty text becomes nil.
public func resolveTimelineMinimapPreview(_ item: TimelineMinimapItem) -> TimelineMinimapItem {
  func compact(_ text: String?) -> String? {
    let value = text?.jsCollapsedWhitespace ?? ""
    return value.isEmpty ? nil : value
  }
  var preview = item
  preview.userText = compact(item.userText)
  preview.assistantText = compact(item.assistantText)
  return preview
}
