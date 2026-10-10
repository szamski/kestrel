import Foundation
import T3Contracts

/// The fields every V2 turn item shares. The generator emitted the same 24 item variants twice
/// (the projection's `turnItems` and the `turn-item.updated` event payload); the reducers only
/// need this head, and `projectionItem` bridges the two shapes.
public struct TurnItemHead: Sendable, Equatable {
  public var id: TurnItemId
  public var threadId: ThreadId
  public var runId: RunId?
  public var nodeId: NodeId?
  public var ordinal: Int
  /// The wire `type` tag.
  public var type: String
  public var inputIntent: OrchestrationV2UserMessageInputIntent?

  init(id: TurnItemId, threadId: ThreadId, runId: RunId?, nodeId: NodeId?, ordinal: Int, type: String, inputIntent: OrchestrationV2UserMessageInputIntent? = nil) {
    self.id = id
    self.threadId = threadId
    self.runId = runId
    self.nodeId = nodeId
    self.ordinal = ordinal
    self.type = type
    self.inputIntent = inputIntent
  }

  /// A variant this build does not know keeps its identity so ordering and removal still work.
  init?(unknown json: JSONValue) {
    guard case .object(let o) = json, case .string(let id)? = o["id"], case .string(let thread)? = o["threadId"], case .int(let ordinal)? = o["ordinal"] else { return nil }
    func string(_ key: String) -> String? { if case .string(let s)? = o[key] { s } else { nil } }
    self.init(
      id: TurnItemId(rawValue: id), threadId: ThreadId(rawValue: thread), runId: string("runId").map(RunId.init(rawValue:)),
      nodeId: string("nodeId").map(NodeId.init(rawValue:)), ordinal: ordinal, type: string("type") ?? "unknown")
  }
}

extension OrchestrationV2ThreadProjectionTurnItemsItem {
  public var head: TurnItemHead? {
    switch self {
      case .notification(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "notification")
      case .userMessage(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "user_message", inputIntent: v.inputIntent)
      case .assistantMessage(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "assistant_message")
      case .reasoning(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "reasoning")
      case .proposedPlan(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "proposed_plan")
      case .todoList(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "todo_list")
      case .userInputRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "user_input_request")
      case .fileChange(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "file_change")
      case .commandExecution(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "command_execution")
      case .fileSearch(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "file_search")
      case .webSearch(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "web_search")
      case .approvalRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "approval_request")
      case .checkpoint(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "checkpoint")
      case .runInterruptRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "run_interrupt_request")
      case .runInterruptResult(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "run_interrupt_result")
      case .systemNotice(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "system_notice")
      case .error(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "error")
      case .compaction(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "compaction")
      case .handoff(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "handoff")
      case .fork(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "fork")
      case .threadCreated(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "thread_created")
      case .secretRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "secret_request")
      case .subagent(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "subagent")
      case .dynamicTool(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "dynamic_tool")
    case .unknown(let json): TurnItemHead(unknown: json)
    }
  }
}

extension OrchestrationV2TurnItem {
  public var head: TurnItemHead? {
    switch self {
      case .notification(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "notification")
      case .userMessage(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "user_message", inputIntent: v.inputIntent)
      case .assistantMessage(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "assistant_message")
      case .reasoning(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "reasoning")
      case .proposedPlan(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "proposed_plan")
      case .todoList(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "todo_list")
      case .userInputRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "user_input_request")
      case .fileChange(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "file_change")
      case .commandExecution(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "command_execution")
      case .fileSearch(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "file_search")
      case .webSearch(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "web_search")
      case .approvalRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "approval_request")
      case .checkpoint(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "checkpoint")
      case .runInterruptRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "run_interrupt_request")
      case .runInterruptResult(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "run_interrupt_result")
      case .systemNotice(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "system_notice")
      case .error(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "error")
      case .compaction(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "compaction")
      case .handoff(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "handoff")
      case .fork(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "fork")
      case .threadCreated(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "thread_created")
      case .secretRequest(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "secret_request")
      case .subagent(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "subagent")
      case .dynamicTool(let v): TurnItemHead(id: v.id, threadId: v.threadId, runId: v.runId, nodeId: v.nodeId, ordinal: v.ordinal, type: "dynamic_tool")
    case .unknown(let json): TurnItemHead(unknown: json)
    }
  }

  /// The same item as the projection stores it (the generator declared the two shapes separately).
  public var projectionItem: OrchestrationV2ThreadProjectionTurnItemsItem? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(OrchestrationV2ThreadProjectionTurnItemsItem.self, from: data)
  }
}
