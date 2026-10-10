import Foundation
import T3Contracts

/// Item types of the provider tool lifecycle (`ToolLifecycleItemType`).
public enum ToolLifecycleItemType: String, Sendable, Hashable, CaseIterable {
  case commandExecution = "command_execution"
  case fileChange = "file_change"
  case mcpToolCall = "mcp_tool_call"
  case dynamicToolCall = "dynamic_tool_call"
  case collabAgentToolCall = "collab_agent_tool_call"
  case webSearch = "web_search"
  case imageView = "image_view"
}

/// What an approval or a tool row is about (`ProviderRequestKind`).
public enum ProviderRequestKind: String, Sendable, Hashable, CaseIterable, Codable {
  case command
  case fileRead = "file-read"
  case fileChange = "file-change"
  case mcpElicitation = "mcp-elicitation"
  case permission
}

/// `WorkLogToolLifecycleStatus`: runtime item status plus `stopped`.
public enum ToolLifecycleStatus: String, Sendable, Hashable {
  case inProgress
  case completed
  case failed
  case declined
  case stopped
}

public enum WorkLogTone: String, Sendable, Hashable {
  case thinking
  case tool
  case info
  case error
}

public enum ToolActivitySurface: String, Sendable, Hashable {
  case browser
  case computer
}

public enum ToolActivityNativeApp: Sendable, Hashable {
  case appId(String)
  case displayName(String)
}

public enum ToolActivityIcon: Sendable, Hashable {
  case website(pageUrl: String, faviconUrl: String?, faviconUrlDark: String?)
  case nativeApp(ToolActivityNativeApp)
  case themedLogo(logoUrl: String, logoUrlDark: String?)
}

public struct ToolActivitySource: Sendable, Hashable {
  public enum Kind: String, Sendable, Hashable {
    case browser
    case computer
    case integration
  }

  public var key: String
  public var name: String
  public var kind: Kind
  public var icon: ToolActivityIcon?
}

/// Present on agent-spawn rows: one per workflow run or per-turn batch of direct spawns.
public struct AgentSpawn: Sendable, Hashable {
  /// Workflow coordinator taskId, or nil for a direct-spawn batch.
  public var workflowId: String?
  public var agentTaskIds: [String]
}

/// Answers of an asynchronous user-input request, folded into one work row
/// (`UserInputAttachmentAnswerPayload`).
public struct UserInputAnswer: Sendable, Hashable, Codable {
  public var requestId: V1.ApprovalRequestId
  public var questionTextById: [String: String]?
  public var answers: [String: JSONValue]
  public var attachmentsByQuestionId: [String: [ChatAttachment]]
}

/// One row of the work log (`WorkLogEntry` in session-logic.ts).
public struct WorkLogEntry: Sendable, Hashable, Identifiable {
  public var questionAnswer: UserInputAnswer?
  public var id: String
  public var createdAt: String
  public var turnId: V1.TurnId?
  /// Stable provider identity across in-progress and completed lifecycle updates.
  public var toolCallId: String?
  public var label: String
  public var detail: String?
  public var viewedImagePath: String?
  public var command: String?
  public var rawCommand: String?
  public var changedFiles: [String]?
  public var tone: WorkLogTone
  public var toolTitle: String?
  public var toolSurface: ToolActivitySurface?
  public var toolIcon: ToolActivityIcon?
  public var toolSource: ToolActivitySource?
  public var toolData: JSONValue?
  public var itemType: ToolLifecycleItemType?
  public var requestKind: ProviderRequestKind?
  /// From the runtime item or task payload `status` when present.
  public var toolLifecycleStatus: ToolLifecycleStatus?
  /// Originating orchestration activity kind (for example `user-input.requested`).
  public var sourceActivityKind: String?
  /// Grouping key for subagent lifecycle rows (one row per agent).
  public var taskId: String?
  public var agentRole: String?
  public var agentSpawn: AgentSpawn?

  public init(
    id: String,
    createdAt: String,
    turnId: V1.TurnId? = nil,
    label: String,
    tone: WorkLogTone,
    sourceActivityKind: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.turnId = turnId
    self.label = label
    self.tone = tone
    self.sourceActivityKind = sourceActivityKind
  }
}

/// `ActivePlanState`: the checklist the agent keeps (`turn.plan.updated`).
public struct ActivePlanState: Sendable, Hashable {
  public enum StepStatus: String, Sendable, Hashable {
    case pending
    case inProgress
    case completed
  }

  public struct Step: Sendable, Hashable {
    public var durationMs: Double?
    public var step: String
    public var status: StepStatus
  }

  public var createdAt: String
  public var turnId: V1.TurnId?
  /// `nil` when the payload had no `explanation` key; `.some(nil)` when it was null.
  public var explanation: String??
  public var steps: [Step]
}

/// `LatestProposedPlanState`.
public struct LatestProposedPlanState: Sendable, Hashable {
  public var id: String
  public var createdAt: String
  public var updatedAt: String
  public var turnId: V1.TurnId?
  public var planMarkdown: String
  public var implementedAt: String?
  public var implementationThreadId: ThreadId?
}

public typealias ProposedPlan = V1.OrchestrationProposedPlan

extension V1.OrchestrationProposedPlan {
  /// The thread read model carries plans as a structurally identical generated type.
  public init(_ item: V1.OrchestrationThreadProposedPlansItem) {
    self.init(
      id: item.id,
      turnId: item.turnId,
      planMarkdown: item.planMarkdown,
      implementedAt: item.implementedAt,
      implementationThreadId: item.implementationThreadId,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt
    )
  }
}

/// A message, plan or work row in thread order (`TimelineEntry`).
public enum TimelineEntry: Sendable, Hashable, Identifiable {
  case message(V1.OrchestrationMessage)
  case proposedPlan(ProposedPlan)
  case work(WorkLogEntry)

  public var id: String {
    switch self {
    case .message(let message): message.id.rawValue
    case .proposedPlan(let plan): plan.id
    case .work(let entry): entry.id
    }
  }

  public var createdAt: String {
    switch self {
    case .message(let message): message.createdAt.rawValue
    case .proposedPlan(let plan): plan.createdAt.rawValue
    case .work(let entry): entry.createdAt
    }
  }
}

/// `SessionPhase`.
public enum SessionPhase: String, Sendable, Hashable {
  case disconnected
  case connecting
  case ready
  case running
}
