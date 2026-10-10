import Foundation
import T3Contracts

// Row model of the chat timeline (`MessagesTimelineRow` in MessagesTimeline.logic.ts).

/// A message or an ordinary work entry that can sit inside an activity group.
public enum ActivityEntry: Sendable, Hashable, Identifiable {
  case message(V1.OrchestrationMessage)
  case work(WorkLogEntry)

  public var id: String {
    switch self {
    case .message(let message): message.id.rawValue
    case .work(let entry): entry.id
    }
  }
}

/// A message the user queued while the agent is busy; the host supplies its own store.
public struct QueuedMessagePlaceholder: Sendable, Hashable, Identifiable {
  public var id: String
  public var createdAt: String
  public var text: String

  public init(id: String, createdAt: String, text: String) {
    self.id = id
    self.createdAt = createdAt
    self.text = text
  }
}

public struct ActivityGroupRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var turnId: V1.TurnId
  public var groupId: String
  public var entries: [ActivityEntry]
  public var expanded: Bool
  public var active: Bool
}

public struct WorkRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var groupedEntries: [WorkLogEntry]
  public var isExpandedToolGroup: Bool
  public var displayLabel: String?
  /// Protocol 2: the next row is more work, so the two read as one list.
  public var continuesWorkLog = false
}

public struct WorkLiveRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var entry: WorkLogEntry
  public var groupedEntries: [WorkLogEntry]
  public var groupId: String
  public var expanded: Bool
  public var active: Bool
  /// Protocol 2: the latest reasoning of the live group, shown above the status line.
  public var thought: WorkLogEntry?
  public var continuesWorkLog = false
}

public struct WorkToggleRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var turnId: V1.TurnId?
  public var groupId: String
  public var hiddenCount: Int
  public var expanded: Bool
  public var summary: String
  public var summaryKind: ToolGroupSummaryKind
  public var toolSurface: ToolActivitySurface?
  public var toolIcon: ToolActivityIcon?
  public var summaryToolIcon: ToolPresentation.Icon?
  public var hasFailure: Bool
  public var continuesWorkLog = false
}

public struct TurnFoldRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var turnId: V1.TurnId
  public var label: String
  public var expanded: Bool
}

public struct ContextCompactionRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var label: String
  /// Protocol 2: the compaction is still running.
  public var active = false
}

/// Protocol 2: provider output of an attempt a steer replaced, folded behind one row.
public struct AttemptFoldRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var runId: String
  public var attemptId: String
  public var label: String
  public var expanded: Bool
}

/// Protocol 2: a standalone item the timeline draws as its own card (fork, handoff, subagents,
/// interrupt result, secret request, created thread).
public struct EventRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var item: V2EventItem
  /// Adjacent subagent cards of one provider turn render as one grouped row.
  public var subagents: [V2EventItem]?
  /// A created thread summarised below the final answer.
  public var resourceSummary = false
}

/// Protocol 2: a page a completed `html_render` call published.
public struct HtmlRenderRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var htmlRender: HtmlRenderReference
}

/// Protocol 2: an MCP App a completed tool call captured.
public struct McpAppRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var mcpApp: McpAppEntry
}

public struct MessageRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var message: V1.OrchestrationMessage
  public var durationStart: String
  public var showAssistantMeta: Bool
  public var showAssistantCopyButton: Bool
  public var assistantCopyStreaming: Bool
  public var assistantTurnDiffSummary: V1.OrchestrationCheckpointSummary?
  public var revertTurnCount: Int?
  /// Protocol 2 user messages: `turn_start`, `steer`, `queued_turn`...
  public var inputIntent: String?
}

public struct AssistantMetaRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var message: V1.OrchestrationMessage
  public var showAssistantCopyButton: Bool
  public var assistantCopyStreaming: Bool
}

public struct ProposedPlanRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var proposedPlan: ProposedPlan
  /// Protocol 2: `draft`, `active`, `completed` or `superseded`.
  public var status: String?
}

/// The "Working for ..." header and the trailing "thinking" placeholder.
public struct LiveIndicatorRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String?
  /// Protocol 2 "thinking" row standing in for tool calls after the latest one failed.
  public var groupId: String?
  public var expanded = false
  public var continuesWorkLog = false
}

public struct WorktreeSetupRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String?
  public var snapshot: WorktreeSetupSnapshot
  /// The agent's turn is live and owns the "Working for" header, so the card drops its own
  /// header and settle-time actions.
  public var embedded: Bool
}

public struct QueuedMessageRow: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var queuedMessage: QueuedMessagePlaceholder
  /// Oldest queued message, the one the next boundary sends.
  public var isNext: Bool
}

public enum TimelineRow: Sendable, Hashable, Identifiable {
  case activityGroup(ActivityGroupRow)
  case work(WorkRow)
  case workLive(WorkLiveRow)
  case workToggle(WorkToggleRow)
  case turnFold(TurnFoldRow)
  case contextCompaction(ContextCompactionRow)
  case message(MessageRow)
  case assistantMeta(AssistantMetaRow)
  case proposedPlan(ProposedPlanRow)
  case working(LiveIndicatorRow)
  case thinking(LiveIndicatorRow)
  case worktreeSetup(WorktreeSetupRow)
  case queuedMessage(QueuedMessageRow)
  case attemptFold(AttemptFoldRow)
  case event(EventRow)
  case htmlRender(HtmlRenderRow)
  case mcpApp(McpAppRow)

  public var id: String {
    switch self {
    case .activityGroup(let row): row.id
    case .work(let row): row.id
    case .workLive(let row): row.id
    case .workToggle(let row): row.id
    case .turnFold(let row): row.id
    case .contextCompaction(let row): row.id
    case .message(let row): row.id
    case .assistantMeta(let row): row.id
    case .proposedPlan(let row): row.id
    case .working(let row), .thinking(let row): row.id
    case .worktreeSetup(let row): row.id
    case .queuedMessage(let row): row.id
    case .attemptFold(let row): row.id
    case .event(let row): row.id
    case .htmlRender(let row): row.id
    case .mcpApp(let row): row.id
    }
  }

  public var createdAt: String? {
    switch self {
    case .activityGroup(let row): row.createdAt
    case .work(let row): row.createdAt
    case .workLive(let row): row.createdAt
    case .workToggle(let row): row.createdAt
    case .turnFold(let row): row.createdAt
    case .contextCompaction(let row): row.createdAt
    case .message(let row): row.createdAt
    case .assistantMeta(let row): row.createdAt
    case .proposedPlan(let row): row.createdAt
    case .working(let row), .thinking(let row): row.createdAt
    case .worktreeSetup(let row): row.createdAt
    case .queuedMessage(let row): row.createdAt
    case .attemptFold(let row): row.createdAt
    case .event(let row): row.createdAt
    case .htmlRender(let row): row.createdAt
    case .mcpApp(let row): row.createdAt
    }
  }
}

/// Everything `deriveMessagesTimelineRows` reads besides the thread itself.
public struct TimelineRowsInput: Sendable {
  public var timelineEntries: [TimelineEntry]
  public var latestTurn: LatestTurnTiming?
  public var runningTurnId: V1.TurnId?
  /// Turn folds ("Worked for ...") the reader opened.
  public var expandedTurnIds: Set<V1.TurnId>
  /// Work groups the reader opened.
  public var expandedWorkGroupIds: Set<String>
  public var isWorking: Bool
  public var activeTurnStartedAt: String?
  public var turnDiffSummaries: [V1.OrchestrationCheckpointSummary]
  public var supportsConversationRollback: Bool
  /// Task ids of subagents still working, used by the active tool indicator.
  public var liveAgentTaskIds: Set<String>?
  /// Live bootstrap progress. Renders a stage card under the first user message.
  public var worktreeSetup: WorktreeSetupSnapshot?
  /// Messages sent during the running turn, rendered after the live rows.
  public var queuedMessages: [QueuedMessagePlaceholder]

  public init(
    timelineEntries: [TimelineEntry],
    latestTurn: LatestTurnTiming? = nil,
    runningTurnId: V1.TurnId? = nil,
    expandedTurnIds: Set<V1.TurnId> = [],
    expandedWorkGroupIds: Set<String> = [],
    isWorking: Bool,
    activeTurnStartedAt: String?,
    turnDiffSummaries: [V1.OrchestrationCheckpointSummary] = [],
    supportsConversationRollback: Bool = false,
    liveAgentTaskIds: Set<String>? = nil,
    worktreeSetup: WorktreeSetupSnapshot? = nil,
    queuedMessages: [QueuedMessagePlaceholder] = []
  ) {
    self.timelineEntries = timelineEntries
    self.latestTurn = latestTurn
    self.runningTurnId = runningTurnId
    self.expandedTurnIds = expandedTurnIds
    self.expandedWorkGroupIds = expandedWorkGroupIds
    self.isWorking = isWorking
    self.activeTurnStartedAt = activeTurnStartedAt
    self.turnDiffSummaries = turnDiffSummaries
    self.supportsConversationRollback = supportsConversationRollback
    self.liveAgentTaskIds = liveAgentTaskIds
    self.worktreeSetup = worktreeSetup
    self.queuedMessages = queuedMessages
  }
}
