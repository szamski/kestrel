import Foundation
import T3Contracts

// Protocol-2 turn items arrive as 24 generated variants that share a head of fields. The web
// reads them through one union type; this protocol gives the Swift port the same view without a
// 24-way switch at every use.

typealias ProjectedItem = OrchestrationV2ThreadProjectionVisibleTurnItemsItem
typealias TurnItem = OrchestrationV2ThreadProjectionTurnItemsItem

protocol TurnItemFields {
  var id: TurnItemId { get }
  var threadId: ThreadId { get }
  var runId: RunId? { get }
  var nodeId: NodeId? { get }
  var providerTurnId: ProviderTurnId? { get }
  var parentItemId: TurnItemId? { get }
  var ordinal: Int { get }
  var status: OrchestrationV2TurnItemStatus { get }
  var title: String? { get }
  var startedAt: IsoDateTime? { get }
  var completedAt: IsoDateTime? { get }
  var updatedAt: IsoDateTime { get }
  var toolSurface: T3Contracts.ToolActivitySurface? { get }
  var toolIcon: ToolActivityIcon2? { get }
  var toolSource: OrchestrationV2ThreadProjectionTurnItemsItemNotificationToolSource? { get }
}

extension OrchestrationV2ThreadProjectionTurnItemsItemNotification: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemUserMessage: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemAssistantMessage: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemReasoning: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemProposedPlan: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemTodoList: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemUserInputRequest: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemFileChange: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemCommandExecution: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemFileSearch: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemWebSearch: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemApprovalRequest: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemCheckpoint: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemRunInterruptRequest: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemRunInterruptResult: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemSystemNotice: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemError: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemCompaction: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemHandoff: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemFork: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemThreadCreated: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemSecretRequest: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemSubagent: TurnItemFields {}
extension OrchestrationV2ThreadProjectionTurnItemsItemDynamicTool: TurnItemFields {}

extension TurnItem {
  /// The head every known variant shares; nil for a variant this build does not know.
  var fields: (any TurnItemFields)? {
    switch self {
    case .notification(let v): v
    case .userMessage(let v): v
    case .assistantMessage(let v): v
    case .reasoning(let v): v
    case .proposedPlan(let v): v
    case .todoList(let v): v
    case .userInputRequest(let v): v
    case .fileChange(let v): v
    case .commandExecution(let v): v
    case .fileSearch(let v): v
    case .webSearch(let v): v
    case .approvalRequest(let v): v
    case .checkpoint(let v): v
    case .runInterruptRequest(let v): v
    case .runInterruptResult(let v): v
    case .systemNotice(let v): v
    case .error(let v): v
    case .compaction(let v): v
    case .handoff(let v): v
    case .fork(let v): v
    case .threadCreated(let v): v
    case .secretRequest(let v): v
    case .subagent(let v): v
    case .dynamicTool(let v): v
    case .unknown: nil
    }
  }

  /// The wire `type` tag (`item.type` in the web).
  var typeTag: String {
    switch self {
    case .notification: "notification"
    case .userMessage: "user_message"
    case .assistantMessage: "assistant_message"
    case .reasoning: "reasoning"
    case .proposedPlan: "proposed_plan"
    case .todoList: "todo_list"
    case .userInputRequest: "user_input_request"
    case .fileChange: "file_change"
    case .commandExecution: "command_execution"
    case .fileSearch: "file_search"
    case .webSearch: "web_search"
    case .approvalRequest: "approval_request"
    case .checkpoint: "checkpoint"
    case .runInterruptRequest: "run_interrupt_request"
    case .runInterruptResult: "run_interrupt_result"
    case .systemNotice: "system_notice"
    case .error: "error"
    case .compaction: "compaction"
    case .handoff: "handoff"
    case .fork: "fork"
    case .threadCreated: "thread_created"
    case .secretRequest: "secret_request"
    case .subagent: "subagent"
    case .dynamicTool: "dynamic_tool"
    case .unknown: "unknown"
    }
  }

  var runIdValue: String? { fields?.runId?.rawValue }
  var statusValue: String { fields?.status.rawValue ?? "unknown" }
  var titleValue: String? { fields?.title }
}

extension OrchestrationV2ThreadProjectionVisibleTurnItemsItem {
  /// `projectedItemCreatedAt`: the item's start, else its last update.
  var createdAtValue: String? { item.fields.map { ($0.startedAt ?? $0.updatedAt).rawValue } }
}
