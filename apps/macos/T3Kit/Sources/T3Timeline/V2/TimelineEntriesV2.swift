import Foundation
import T3Contracts

// `deriveTimelineEntriesFromVisibleTurnItems` of session-logic.ts: the protocol-2 timeline in the
// exact order the server committed (`visibleTurnItems`), each item presented directly.

/// The attempt a timeline entry belongs to, resolved from its execution node.
public struct TimelineAttempt: Sendable, Hashable {
  public var id: String
  public var runId: String
  /// `superseded` marks provider output a steer replaced.
  public var status: String
}

public struct V2Message: Sendable, Hashable {
  public var message: V1.OrchestrationMessage
  /// `turn_start`, `steer`, `queued_turn`, ... (user messages only).
  public var inputIntent: String?
  public var runId: String? { message.turnId?.rawValue }
}

public struct V2Plan: Sendable, Hashable {
  public var id: String
  public var runId: String?
  public var planMarkdown: String
  /// `draft`, `active`, `completed` or `superseded`.
  public var status: String
  public var createdAt: String
  public var updatedAt: String
}

/// A published MCP App card: the owning thread and item, and what hosts it.
public struct McpAppEntry: Sendable, Hashable {
  public var sourceThreadId: String
  public var itemId: String
  /// `live` while the item runs, then its last update (the detail cache key).
  public var revision: String
  public var app: McpAppReference
}

/// A standalone item the timeline draws as its own card (a fork, a handoff, a subagent...).
public struct V2EventItem: Sendable, Hashable, Identifiable {
  var row: ProjectedItem
  public var id: String { row.sourceItemId.rawValue }
  public var item: OrchestrationV2ThreadProjectionTurnItemsItem { row.item }
  public var sourceThreadId: String { row.sourceThreadId.rawValue }
  public var type: String { row.item.typeTag }
  public var runId: String? { row.item.runIdValue }
}

public enum V2EntryKind: Sendable, Hashable {
  case message(V2Message)
  case proposedPlan(V2Plan)
  case htmlRender(HtmlRenderReference)
  case mcpApp(McpAppEntry)
  case work(WorkLogEntry)
  case event(V2EventItem)
}

public struct V2TimelineEntry: Sendable, Hashable, Identifiable {
  public var id: String
  public var createdAt: String
  public var kind: V2EntryKind
  public var attempt: TimelineAttempt?
  /// The owning run of the item behind the entry (nil for a runless item).
  public var runId: String?

  var workEntry: WorkLogEntry? {
    if case .work(let entry) = kind { return entry }
    return nil
  }

  var message: V2Message? {
    if case .message(let message) = kind { return message }
    return nil
  }

  var event: V2EventItem? {
    if case .event(let event) = kind { return event }
    return nil
  }
}

private let standaloneItemTypes: Set<String> = ["fork", "handoff", "run_interrupt_request", "run_interrupt_result", "secret_request", "subagent"]
private let persistentResourceTypes: Set<String> = ["fork", "thread_created", "secret_request"]

/// `timelineEntryIsPersistentResourceCard`.
func isPersistentResourceCard(_ entry: V2TimelineEntry) -> Bool {
  guard let event = entry.event else { return false }
  return persistentResourceTypes.contains(event.type)
}

private let workspacePreparationInput = "Preparing workspace"
private let workspacePreparationFailureCode = "workspace_preparation_failed"

/// `turnItemIsWorkspacePreparation`: workspace setup is client bookkeeping.
func turnItemIsWorkspacePreparation(_ item: TurnItem) -> Bool {
  switch item {
  case .commandExecution(let command): command.input == workspacePreparationInput
  case .error(let error): error.status.rawValue == "cancelled" && error.failure.code == workspacePreparationFailureCode
  default: false
  }
}

/// `isLiveSubagentTurnItem`: a subagent card whose child is still working.
func isLiveSubagentTurnItem(_ item: TurnItem) -> Bool {
  guard case .subagent(let subagent) = item else { return false }
  return ["pending", "running", "waiting"].contains(subagent.status.rawValue)
}

private func detailRevision(_ fields: any TurnItemFields) -> String {
  ["idle", "pending", "running", "waiting"].contains(fields.status.rawValue) ? "live" : fields.updatedAt.rawValue
}

/// A user or assistant message item as the V1-shaped message the views render.
private func chatMessage(_ item: TurnItem, createdAt: String) -> V2Message? {
  switch item {
  case .userMessage(let value):
    let attachments: [ChatAttachment]? = value.attachments.isEmpty ? nil : jsonBridge(value.attachments)
    let context: OrchestrationMessageContext? = value.context.flatMap { jsonBridge($0) }
    let message = V1.OrchestrationMessage(
      id: value.messageId, role: .user, text: value.text, attachments: attachments, context: context,
      turnId: value.runId.map { V1.TurnId(rawValue: $0.rawValue) }, streaming: false, createdAt: IsoDateTime(rawValue: createdAt), updatedAt: value.updatedAt)
    return V2Message(message: message, inputIntent: value.inputIntent.rawValue)
  case .assistantMessage(let value):
    let attachments: [ChatAttachment]? = (value.attachments?.isEmpty ?? true) ? nil : value.attachments.flatMap { jsonBridge($0) }
    let message = V1.OrchestrationMessage(
      id: value.messageId, role: .assistant, text: value.text, attachments: attachments, context: nil,
      turnId: value.runId.map { V1.TurnId(rawValue: $0.rawValue) }, streaming: value.streaming, createdAt: IsoDateTime(rawValue: createdAt),
      updatedAt: value.updatedAt)
    return V2Message(message: message, inputIntent: nil)
  default:
    return nil
  }
}

func deriveTimelineEntriesV2(
  visibleTurnItems: [ProjectedItem],
  attempts: [OrchestrationV2RunAttempt],
  nodes: [OrchestrationV2ExecutionNode],
  plans: [OrchestrationV2PlanArtifact]
) -> [V2TimelineEntry] {
  var attemptByRootNodeId: [NodeId: OrchestrationV2RunAttempt] = [:]
  for attempt in attempts { attemptByRootNodeId[attempt.rootNodeId] = attempt }
  var nodeById: [NodeId: OrchestrationV2ExecutionNode] = [:]
  for node in nodes { nodeById[node.id] = node }
  var planById: [PlanId: OrchestrationV2PlanArtifact] = [:]
  for plan in plans {
    switch plan {
    case .proposedPlan(let value): planById[value.id] = plan
    case .todoList(let value): planById[value.id] = plan
    case .unknown: break
    }
  }

  func resolveAttempt(_ fields: any TurnItemFields) -> TimelineAttempt? {
    guard var nodeId = fields.nodeId, let runId = fields.runId else { return nil }
    var visited = Set<NodeId>()
    while !visited.contains(nodeId) {
      visited.insert(nodeId)
      if let direct = attemptByRootNodeId[nodeId], direct.runId == runId {
        return TimelineAttempt(id: direct.id.rawValue, runId: direct.runId.rawValue, status: direct.status.rawValue)
      }
      guard let node = nodeById[nodeId] else { return nil }
      if let root = attemptByRootNodeId[node.rootNodeId], root.runId == runId {
        return TimelineAttempt(id: root.id.rawValue, runId: root.runId.rawValue, status: root.status.rawValue)
      }
      guard let parent = node.parentNodeId else { return nil }
      nodeId = parent
    }
    return nil
  }

  var foldedAnswerMessageIds = Set<String>()
  for row in visibleTurnItems {
    if case .userInputRequest(let request) = row.item, let answer = request.questionAnswer {
      foldedAnswerMessageIds.insert("async-answer:\(answer.requestId)")
    }
  }

  var entries: [V2TimelineEntry] = []
  for row in visibleTurnItems {
    let item = row.item
    guard let fields = item.fields else { continue }
    if turnItemIsWorkspacePreparation(item) { continue }
    // Task progress belongs in the composer, not between conversation entries.
    if case .todoList = item { continue }
    if case .checkpoint = item { continue }
    if case .userMessage(let message) = item, foldedAnswerMessageIds.contains(message.messageId.rawValue) { continue }
    let createdAt = (fields.startedAt ?? fields.updatedAt).rawValue
    let attempt = resolveAttempt(fields)
    let id = fields.id.rawValue
    let runId = fields.runId?.rawValue

    if case .notification(let notification) = item {
      var entry = WorkLogEntry(id: id, createdAt: createdAt, turnId: fields.runId.map { V1.TurnId(rawValue: $0.rawValue) }, label: notification.summary, tone: .info)
      entry.v2 = V2WorkItem(row: row)
      entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .work(entry), attempt: attempt, runId: runId))
      continue
    }
    if let message = chatMessage(item, createdAt: createdAt) {
      entries.append(V2TimelineEntry(id: message.message.id.rawValue, createdAt: createdAt, kind: .message(message), attempt: attempt, runId: runId))
      continue
    }
    if case .proposedPlan(let value) = item {
      var status = "active"
      if case .proposedPlan(let artifact)? = planById[value.planId] { status = artifact.status.rawValue }
      let plan = V2Plan(
        id: value.planId.rawValue, runId: value.runId?.rawValue, planMarkdown: value.markdown, status: status, createdAt: createdAt,
        updatedAt: value.updatedAt.rawValue)
      entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .proposedPlan(plan), attempt: attempt, runId: runId))
      continue
    }
    if case .dynamicTool(let tool) = item, tool.status.rawValue == "completed" {
      if let html = htmlRenderFromToolItem(toolName: tool.toolName, output: tool.output) {
        entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .htmlRender(html), attempt: attempt, runId: runId))
        continue
      }
      if let app = mcpAppFromToolItem(toolName: tool.toolName, output: tool.output) {
        let entry = McpAppEntry(sourceThreadId: row.sourceThreadId.rawValue, itemId: row.sourceItemId.rawValue, revision: detailRevision(fields), app: app)
        entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .mcpApp(entry), attempt: attempt, runId: runId))
        continue
      }
    }
    if standaloneItemTypes.contains(item.typeTag) {
      entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .event(V2EventItem(row: row)), attempt: attempt, runId: runId))
      continue
    }
    entries.append(V2TimelineEntry(id: id, createdAt: createdAt, kind: .work(projectedWorkEntry(row)), attempt: attempt, runId: runId))
  }
  return entries
}
