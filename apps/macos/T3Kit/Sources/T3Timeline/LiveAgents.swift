import Foundation
import T3Contracts

// The part of packages/client-runtime/src/state/subagentRuntime.ts the timeline needs: which
// subagents are still working, so a "Kicked off N subagents" row can show live status.
//
// The full fold also tracks titles, usage, results and recent activity for the Agents panel;
// none of that changes a status, so it is not ported here. What is kept is exactly what decides
// status: sticky membership per task id, activation counting, terminal first-write-wins,
// reactivation, the workflow cascade, session death and the 100-agent roster limit.

private enum AgentStatus: String {
  case pending, running, waiting, idle, completed, failed, cancelled, interrupted

  var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled || self == .interrupted }
  /// Active = the user may still need to care while it runs. Waiting needs the user.
  var isActive: Bool { self == .pending || self == .running || self == .waiting }
}

private enum AgentKind { case subagent, subagentBatch, workflow, workflowAgent }

private struct Agent {
  var id: String
  var kind: AgentKind
  var status: AgentStatus = .pending
  var activationCount = 0
  var parentAgentId: String?
  var updatedAt: String
}

private func trimmed(_ value: JSONValue?) -> String? { value.trimmedString }

private func kindFromPayload(_ payload: JSObject, id: String) -> AgentKind {
  if payload["taskType"]?.stringOrNil == "subagent_batch" { return .subagentBatch }
  if trimmed(payload["taskType"]) == "local_workflow" { return .workflow }
  if payload["parentAgentId"] != nil || id.contains(":wf:") { return .workflowAgent }
  return .subagent
}

private func fillMetadata(_ agent: inout Agent, _ payload: JSObject) {
  if payload["taskType"]?.stringOrNil == "subagent_batch" { agent.kind = .subagentBatch }
  if let parent = trimmed(payload["parentAgentId"]) {
    agent.parentAgentId = parent
    if agent.kind == .subagent { agent.kind = .workflowAgent }
  }
  if trimmed(payload["taskType"]) == "local_workflow" { agent.kind = .workflow }
}

private func applyStatus(_ agent: inout Agent, _ status: AgentStatus) {
  let wasTerminal = agent.status.isTerminal
  // Duplicate terminal events are idempotent: first write wins.
  if wasTerminal && status.isTerminal { return }
  if (wasTerminal || agent.status == .idle) && (status == .running || status == .pending) { agent.activationCount += 1 }
  agent.status = status
}

private let taskCompletedStatus: [String: AgentStatus] = ["completed": .completed, "failed": .failed, "stopped": .interrupted]

/// Ids of the subagents that are still working: active agents, and workflows that have not
/// settled (`liveAgentTaskKey` in MessagesTimeline.tsx).
///
/// `sessionLive` is false once the provider session is gone; background tasks die with it, so
/// agents whose terminal rows were lost must not read as running forever.
public func deriveLiveAgentTaskIds(activities: [OrchestrationThreadActivity], sessionLive: Bool) -> Set<String> {
  var agents: [String: Agent] = [:]
  var order: [String] = []

  func agent(_ id: String, _ payload: JSObject, _ at: String) {
    if agents[id] == nil {
      agents[id] = Agent(id: id, kind: kindFromPayload(payload, id: id), parentAgentId: trimmed(payload["parentAgentId"]), updatedAt: at)
      order.append(id)
    }
  }

  for activity in activities {
    guard let payload = activity.payload.strictRecord else { continue }
    let at = activity.createdAt.rawValue
    guard let taskId = trimmed(payload["taskId"]) else { continue }
    switch activity.kind {
    case "task.started":
      // Only real agents join the roster; shells and monitors are background work.
      if isBackgroundTaskActivity(payload) { continue }
      agent(taskId, payload, at)
      var current = agents[taskId]!
      fillMetadata(&current, payload)
      // A start row arriving after a terminal state is a late delivery and only fills metadata.
      if current.activationCount == 0 && !current.status.isTerminal {
        current.activationCount = 1
        current.status = .running
      } else if current.status == .idle {
        applyStatus(&current, .running)
      }
      current.updatedAt = at
      agents[taskId] = current
    case "task.progress":
      // Membership is sticky per taskId: later rows inherit the first row's classification.
      let existed = agents[taskId] != nil
      if !existed && isBackgroundTaskActivity(payload) { continue }
      agent(taskId, payload, at)
      var current = agents[taskId]!
      fillMetadata(&current, payload)
      if current.activationCount == 0 { current.activationCount = 1 }
      if let explicit = payload["status"]?.stringOrNil.flatMap({ AgentStatus(rawValue: $0) }) {
        applyStatus(&current, explicit)
      } else if (payload["usageSnapshot"]?.boolOrNil != true || !existed) && !current.status.isTerminal && current.status != .idle {
        applyStatus(&current, .running)
      }
      current.updatedAt = at
      agents[taskId] = current
    case "task.updated":
      if agents[taskId] == nil && isBackgroundTaskActivity(payload) { continue }
      agent(taskId, payload, at)
      var current = agents[taskId]!
      fillMetadata(&current, payload)
      // A task first seen via task.updated has run at least once.
      if current.activationCount == 0 { current.activationCount = 1 }
      if let status = payload["status"]?.stringOrNil.flatMap({ AgentStatus(rawValue: $0) }) { applyStatus(&current, status) }
      current.updatedAt = at
      agents[taskId] = current
    case "task.completed":
      if agents[taskId] == nil && isBackgroundTaskActivity(payload) { continue }
      agent(taskId, payload, at)
      var current = agents[taskId]!
      fillMetadata(&current, payload)
      if current.activationCount == 0 { current.activationCount = 1 }
      // Already terminal: status is frozen (first write wins).
      if current.status.isTerminal {
        agents[taskId] = current
        continue
      }
      applyStatus(&current, taskCompletedStatus[trimmed(payload["status"]) ?? ""] ?? .completed)
      current.updatedAt = at
      agents[taskId] = current
    case "tool.progress":
      // Agent-owned heartbeat: only freshens the roster ranking.
      agents[taskId]?.updatedAt = at
    default:
      break
    }
  }

  // When a workflow coordinator has settled, members that never received their own terminal row
  // cannot still be in flight.
  for id in order {
    guard let workflow = agents[id], workflow.kind == .workflow, workflow.status.isTerminal else { continue }
    for memberId in order where agents[memberId]!.parentAgentId == workflow.id {
      var member = agents[memberId]!
      if member.status.isTerminal || member.status == .idle { continue }
      member.status = workflow.status == .completed ? .completed : .interrupted
      member.updatedAt = workflow.updatedAt
      agents[memberId] = member
    }
  }

  // Session death orphans every live agent.
  if !sessionLive {
    for id in order where agents[id]!.status.isActive { agents[id]!.status = .interrupted }
  }

  var roster = order.map { agents[$0]! }
  let rosterLimit = 100
  if roster.count > rosterLimit {
    // Prefer live, then waiting/idle, then newest settled.
    func rank(_ agent: Agent) -> Int { agent.status.isActive ? 0 : agent.status == .idle ? 1 : 2 }
    roster = Array(
      roster.stableSorted { left, right in
        let byRank = rank(left) - rank(right)
        return byRank != 0 ? byRank : jsLocaleCompare(right.updatedAt, left.updatedAt)
      }.prefix(rosterLimit))
  }

  var live = Set<String>()
  for agent in roster {
    if agent.kind == .workflow {
      if !agent.status.isTerminal { live.insert(agent.id) }
    } else if agent.status.isActive {
      live.insert(agent.id)
    }
  }
  return live
}
