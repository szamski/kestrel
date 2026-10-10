import Foundation
import T3Contracts

// Port of the work-log half of apps/web/src/session-logic.ts: turns the raw activity log into
// the ordered, collapsed rows the chat shows between messages.

/// `compareActivitiesByOrder`: provider sequence first, then time, lifecycle stage and id.
func compareActivitiesByOrder(_ left: V1.OrchestrationThreadActivity, _ right: V1.OrchestrationThreadActivity) -> Int {
  if let l = left.sequence, let r = right.sequence {
    if l != r { return l - r }
  } else if left.sequence != nil {
    return 1
  } else if right.sequence != nil {
    return -1
  }
  let createdAt = jsLocaleCompare(left.createdAt.rawValue, right.createdAt.rawValue)
  if createdAt != 0 { return createdAt }
  let rank = activityLifecycleRank(left.kind) - activityLifecycleRank(right.kind)
  if rank != 0 { return rank }
  return jsLocaleCompare(left.id.rawValue, right.id.rawValue)
}

private func activityLifecycleRank(_ kind: String) -> Int {
  if kind.hasSuffix(".started") || kind == "tool.started" { return 0 }
  if kind.hasSuffix(".progress") || kind.hasSuffix(".updated") { return 1 }
  if kind.hasSuffix(".completed") || kind.hasSuffix(".resolved") { return 2 }
  return 1
}

/// Classification happens once, server-side (the persisted `agentKind` stamp). Rows without a
/// stamp are background by definition and render in the ordinary work log.
func isBackgroundTaskActivity(_ payload: JSObject) -> Bool {
  payload["agentKind"]?.stringOrNil != "agent"
}

// MARK: - Activity classification

private func payloadRecord(_ activity: V1.OrchestrationThreadActivity) -> JSObject? { activity.payload.looseRecord }

/// Agent (non-background) task.started rows seed spawn CTA batches.
private func isAgentTaskStartedActivity(_ activity: V1.OrchestrationThreadActivity) -> Bool {
  guard let payload = payloadRecord(activity), payload["taskId"]?.stringOrNil != nil else { return false }
  return !isBackgroundTaskActivity(payload)
}

private func isAgentInternalActivity(_ activity: V1.OrchestrationThreadActivity) -> Bool {
  guard let payload = payloadRecord(activity) else { return false }
  let isTaskRow = ["task.started", "task.progress", "task.updated", "task.completed"].contains(activity.kind)
  // Task rows classify by the server stamp: a subagent's own background shell is
  // agent-internal, but a nested AGENT stays visible so its rows can anchor a spawn row.
  if isTaskRow {
    let ownedByAgent = !(payload["agentId"]?.stringOrNil?.jsTrimmed ?? "").isEmpty
    if ownedByAgent || payload["timelineBypass"]?.boolOrNil == true {
      let isAgentTaskRow =
        activity.kind != "task.updated" && payload["taskId"]?.stringOrNil != nil && !isBackgroundTaskActivity(payload)
      return !isAgentTaskRow
    }
    return false
  }
  if payload["timelineBypass"]?.boolOrNil == true { return true }
  return !(payload["agentId"]?.stringOrNil?.jsTrimmed ?? "").isEmpty
}

/// Adapters forward unknown wire-only SDK messages as runtime warnings; one with no displayable
/// text carries nothing a user can act on.
private func isNoContentRuntimeWarning(_ activity: V1.OrchestrationThreadActivity) -> Bool {
  activity.kind == "runtime.warning" && activity.summary.hasSuffix("(no displayable text content)")
}

private func isPlanBoundaryToolActivity(_ activity: V1.OrchestrationThreadActivity) -> Bool {
  guard activity.kind == "tool.updated" || activity.kind == "tool.completed" else { return false }
  return payloadRecord(activity)?["detail"]?.stringOrNil?.hasPrefix("ExitPlanMode:") == true
}

func requestKindFromRequestType(_ requestType: JSONValue?) -> ProviderRequestKind? {
  switch requestType?.stringOrNil {
  case "command_execution_approval", "exec_command_approval", "dynamic_tool_call": .command
  case "file_read_approval": .fileRead
  case "file_change_approval", "apply_patch_approval": .fileChange
  case "mcp_elicitation_approval": .mcpElicitation
  case "permission_approval": .permission
  default: nil
  }
}

private func extractWorkLogRequestKind(_ payload: JSObject?) -> ProviderRequestKind? {
  switch payload?["requestKind"]?.stringOrNil {
  case "command": return .command
  case "file-read": return .fileRead
  case "file-change": return .fileChange
  case "permission": return .permission
  default: return requestKindFromRequestType(payload?["requestType"])
  }
}

// MARK: - Derived entry

/// A work-log row plus the bookkeeping the collapse pass needs (`DerivedWorkLogEntry`).
private struct DerivedEntry {
  var entry: WorkLogEntry
  var collapseKey: String?
  var isWorkflowCoordinator = false
  /// Shell/monitor/plan tasks: ordinary work-log rows, never spawn CTAs.
  var isBackgroundTask = false
  var sourceActivityKind: String { entry.sourceActivityKind ?? "" }
}

private func decodeQuestionAnswer(_ payload: JSONValue) -> UserInputAnswer? {
  guard case .object = payload, let data = try? JSONEncoder().encode(payload) else { return nil }
  return try? JSONDecoder().decode(UserInputAnswer.self, from: data)
}

private func toDerivedEntry(_ activity: V1.OrchestrationThreadActivity) -> DerivedEntry {
  let payload = payloadRecord(activity)
  let commandPreview = extractToolCommand(payload)
  let changedFiles = extractChangedFiles(payload)
  let title = payload?["title"].trimmedString
  let toolPresentation = extractToolActivityPresentation(activity.payload)
  let isTask = ["task.started", "task.progress", "task.completed"].contains(activity.kind)
  let payloadSummary = payload?["summary"]?.stringOrNil
  let taskSummary = isTask ? payloadSummary.flatMap { $0.isEmpty ? nil : $0 } : nil
  let payloadDetail = payload?["detail"]?.stringOrNil
  let taskDetailAsLabel = isTask && taskSummary == nil ? payloadDetail.flatMap { $0.isEmpty ? nil : $0 } : nil
  let taskLabel = taskSummary ?? taskDetailAsLabel
  let detail: String?
  if isTask {
    if taskDetailAsLabel == nil, let payloadDetail, !payloadDetail.isEmpty {
      detail = stripTrailingExitCode(payloadDetail)
    } else {
      detail = nil
    }
  } else {
    detail = extractToolDetail(payload, heading: title ?? activity.summary)
  }
  let toolCallId = isTask ? nil : (payload?["toolCallId"].trimmedString ?? payload?["data"].looseRecord?["toolCallId"].trimmedString)

  var entry = WorkLogEntry(
    id: activity.id.rawValue,
    createdAt: activity.createdAt.rawValue,
    turnId: activity.turnId,
    label: taskLabel ?? activity.summary,
    tone: workLogTone(of: activity),
    sourceActivityKind: activity.kind
  )
  if activity.kind == "user-input.answer-submitted" { entry.questionAnswer = decodeQuestionAnswer(activity.payload) }
  let itemType = extractWorkLogItemType(payload)
  let requestKind = extractWorkLogRequestKind(payload)
  let viewedImagePath = payload?["data"].looseRecord?["imagePath"].trimmedString
  if let detail {
    entry.detail = detail
  } else if activity.kind == "runtime.error" || activity.kind == "runtime.warning" {
    if let message = payload?["message"].trimmedString,
      normalizePreviewForComparison(message) != normalizePreviewForComparison(activity.summary)
    {
      entry.detail = message
    }
  }
  if let viewedImagePath { entry.viewedImagePath = viewedImagePath }
  if let command = commandPreview.command, !command.isEmpty { entry.command = command }
  if let rawCommand = commandPreview.rawCommand, !rawCommand.isEmpty { entry.rawCommand = rawCommand }
  if !changedFiles.isEmpty { entry.changedFiles = changedFiles }
  if let title { entry.toolTitle = title }
  entry.toolSurface = toolPresentation.toolSurface
  entry.toolIcon = toolPresentation.toolIcon
  entry.toolSource = toolPresentation.toolSource
  if itemType == .mcpToolCall {
    let data = payload?["data"].looseRecord
    let toolData: JSONValue?
    if data?["toolName"]?.stringOrNil != nil, let data {
      // `data.item ?? data`
      toolData = data["item"].flatMap { $0.isNullish ? nil : $0 } ?? .object(data)
    } else {
      toolData = data?["item"]
    }
    if let toolData { entry.toolData = toolData }
  }
  entry.itemType = itemType
  entry.requestKind = requestKind
  entry.toolCallId = toolCallId
  var lifecycle = extractWorkLogToolLifecycleStatus(activity.payload)
  if lifecycle == nil && activity.kind == "tool.completed" { lifecycle = .completed }
  entry.toolLifecycleStatus = lifecycle
  if isTask, let taskId = payload?["taskId"]?.stringOrNil, !taskId.isEmpty { entry.taskId = taskId }
  if isTask, let role = payload?["role"]?.stringOrNil, !role.isEmpty { entry.agentRole = role }
  var derived = DerivedEntry(entry: entry)
  if isTask,
    payload?["taskType"]?.stringOrNil == "local_workflow" || !(payload?["workflowName"]?.stringOrNil ?? "").isEmpty
  {
    derived.isWorkflowCoordinator = true
  }
  if isTask, let payload, isBackgroundTaskActivity(payload) { derived.isBackgroundTask = true }
  derived.collapseKey = toolLifecycleCollapseKey(derived)
  return derived
}

private func workLogTone(of activity: V1.OrchestrationThreadActivity) -> WorkLogTone {
  if activity.kind == "task.progress" { return .thinking }
  switch activity.tone {
  case .tool: return .tool
  case .error: return .error
  case .info, .approval: return .info
  case .unknown: return .info
  }
}

// MARK: - Collapsing

private func agentSpawnGroupKey(_ derived: DerivedEntry) -> String {
  let entry = derived.entry
  let taskId = entry.taskId ?? ""
  if let slot = taskId.range(of: ":wf:") { return "wf:\(taskId[..<slot.lowerBound])" }
  if let workflowId = entry.agentSpawn?.workflowId, !workflowId.isEmpty { return "wf:\(workflowId)" }
  if derived.isWorkflowCoordinator { return "wf:\(taskId)" }
  // No turn id means no batch signal at all: one group per task, so unrelated turn-less spawns
  // never collapse into one immortal "direct:no-turn" row.
  if let turnId = entry.turnId, !turnId.rawValue.isEmpty { return "direct:\(turnId.rawValue)" }
  return "direct:task:\(taskId)"
}

private func isToolLifecycleKind(_ kind: String) -> Bool { kind == "tool.updated" || kind == "tool.completed" }

private func toolLifecycleCollapseMapKey(_ derived: DerivedEntry) -> String? {
  guard isToolLifecycleKind(derived.sourceActivityKind), let toolCallId = derived.entry.toolCallId, !toolCallId.isEmpty else {
    return nil
  }
  return "tool:\(derived.entry.turnId?.rawValue ?? "no-turn"):\(toolCallId)"
}

private func toolLifecycleCollapseKey(_ derived: DerivedEntry) -> String? {
  let entry = derived.entry
  // Subagent lifecycle rows collapse by agent identity: one row per agent.
  if let taskId = entry.taskId, !taskId.isEmpty,
    entry.sourceActivityKind == "task.progress" || entry.sourceActivityKind == "task.completed"
  {
    return "task\(taskId)"
  }
  guard isToolLifecycleKind(derived.sourceActivityKind) else { return nil }
  if let toolCallId = entry.toolCallId, !toolCallId.isEmpty { return "tool:\(entry.turnId?.rawValue ?? "no-turn"):\(toolCallId)" }
  let normalizedLabel = normalizeCompactToolLabel(entry.toolTitle ?? entry.label)
  let detail = entry.detail?.jsTrimmed ?? ""
  let itemType = entry.itemType?.rawValue ?? ""
  if normalizedLabel.isEmpty && detail.isEmpty && itemType.isEmpty { return nil }
  return [itemType, normalizedLabel, detail].joined(separator: "\u{1F}")
}

private func shouldCollapseToolLifecycleEntries(_ previous: DerivedEntry, _ next: DerivedEntry) -> Bool {
  guard isToolLifecycleKind(previous.sourceActivityKind), isToolLifecycleKind(next.sourceActivityKind) else { return false }
  if previous.entry.turnId != next.entry.turnId { return false }
  if previous.sourceActivityKind == "tool.completed" { return false }
  if let key = previous.collapseKey, key == next.collapseKey { return true }
  return previous.entry.toolCallId != nil && next.entry.toolCallId == nil && previous.entry.itemType == next.entry.itemType
    && normalizeCompactToolLabel(previous.entry.toolTitle ?? previous.entry.label)
      == normalizeCompactToolLabel(next.entry.toolTitle ?? next.entry.label)
}

/// `{...previous, ...next}` with the explicit overrides of `mergeDerivedWorkLogEntries`.
private func mergeDerived(_ previous: DerivedEntry, _ next: DerivedEntry) -> DerivedEntry {
  var merged = next
  var entry = next.entry
  let p = previous.entry
  var files: [String] = []
  var seen = Set<String>()
  for file in (p.changedFiles ?? []) + (next.entry.changedFiles ?? []) where seen.insert(file).inserted { files.append(file) }
  entry.changedFiles = files.isEmpty ? nil : files
  entry.detail = next.entry.detail ?? p.detail
  entry.viewedImagePath = next.entry.viewedImagePath ?? p.viewedImagePath
  entry.command = next.entry.command ?? p.command
  entry.rawCommand = next.entry.rawCommand ?? p.rawCommand
  entry.toolTitle = next.entry.toolTitle ?? p.toolTitle
  entry.toolSurface = next.entry.toolSurface ?? p.toolSurface
  entry.toolIcon = next.entry.toolIcon ?? p.toolIcon
  entry.toolSource = next.entry.toolSource ?? p.toolSource
  entry.itemType = next.entry.itemType ?? p.itemType
  entry.requestKind = next.entry.requestKind ?? p.requestKind
  entry.toolCallId = next.entry.toolCallId ?? p.toolCallId
  entry.toolLifecycleStatus = next.entry.toolLifecycleStatus ?? p.toolLifecycleStatus
  // `next.toolData ?? previous.toolData` (null counts as missing), falling back to the spread.
  let nextData = next.entry.toolData.flatMap { $0.isNullish ? nil : $0 }
  entry.toolData = nextData ?? p.toolData ?? next.entry.toolData
  // Fields only the previous row may carry survive the spread.
  entry.questionAnswer = next.entry.questionAnswer ?? p.questionAnswer
  entry.taskId = next.entry.taskId ?? p.taskId
  entry.agentRole = next.entry.agentRole ?? p.agentRole
  entry.agentSpawn = next.entry.agentSpawn ?? p.agentSpawn
  if entry.turnId == nil { entry.turnId = p.turnId }
  merged.entry = entry
  merged.collapseKey = next.collapseKey ?? previous.collapseKey
  merged.isWorkflowCoordinator = next.isWorkflowCoordinator || previous.isWorkflowCoordinator
  merged.isBackgroundTask = next.isBackgroundTask || previous.isBackgroundTask
  return merged
}

private func collapseDerivedEntries(_ entries: [DerivedEntry]) -> [DerivedEntry] {
  var collapsed: [DerivedEntry] = []
  // Subagent rows collapse by spawn group, not adjacency: a workflow run (or a turn's batch of
  // direct spawns) is ONE narrative event in the chat, however its progress rows interleave.
  var spawnRowIndex: [String: Int] = [:]
  // Batch membership is decided once, at the FIRST row seen for a taskId.
  var groupKeyByTaskId: [String: String] = [:]
  var toolLifecycleRowIndex: [String: Int] = [:]
  for derived in entries {
    let entry = derived.entry
    let kind = derived.sourceActivityKind
    let isTaskRow =
      entry.taskId != nil && !derived.isBackgroundTask && (kind == "task.started" || kind == "task.progress" || kind == "task.completed")
    if isTaskRow, let taskId = entry.taskId {
      let remembered = groupKeyByTaskId[taskId]
      let groupKey = remembered ?? agentSpawnGroupKey(derived)
      if remembered == nil { groupKeyByTaskId[taskId] = groupKey }
      let workflowId = groupKey.hasPrefix("wf:") ? String(groupKey.dropFirst(3)) : nil
      if let existingIndex = spawnRowIndex[groupKey] {
        let existing = collapsed[existingIndex]
        let existingIds = existing.entry.agentSpawn?.agentTaskIds ?? []
        let agentTaskIds = existingIds.contains(taskId) ? existingIds : existingIds + [taskId]
        var merged = mergeDerived(existing, derived)
        // The CTA row keeps the group's ANCHOR identity, not the last agent's, so it renders
        // where the run launched instead of drifting to the newest progress tick.
        merged.entry.id = existing.entry.id
        merged.entry.createdAt = existing.entry.createdAt
        merged.entry.turnId = existing.entry.turnId
        if let existingTaskId = existing.entry.taskId { merged.entry.taskId = existingTaskId }
        merged.entry.label = existing.entry.label
        merged.entry.agentSpawn = AgentSpawn(workflowId: workflowId, agentTaskIds: agentTaskIds)
        collapsed[existingIndex] = merged
        continue
      }
      spawnRowIndex[groupKey] = collapsed.count
      var seeded = derived
      seeded.entry.agentSpawn = AgentSpawn(workflowId: workflowId, agentTaskIds: [taskId])
      collapsed.append(seeded)
      continue
    }
    let lifecycleKey = toolLifecycleCollapseMapKey(derived)
    if let lifecycleKey {
      if let index = toolLifecycleRowIndex[lifecycleKey], shouldCollapseToolLifecycleEntries(collapsed[index], derived) {
        collapsed[index] = mergeDerived(collapsed[index], derived)
        continue
      }
      toolLifecycleRowIndex[lifecycleKey] = nil
    }
    if let previous = collapsed.last, shouldCollapseToolLifecycleEntries(previous, derived) {
      let previousIndex = collapsed.count - 1
      if let previousKey = toolLifecycleCollapseMapKey(previous) { toolLifecycleRowIndex[previousKey] = nil }
      let merged = mergeDerived(previous, derived)
      collapsed[previousIndex] = merged
      if let mergedKey = toolLifecycleCollapseMapKey(merged) { toolLifecycleRowIndex[mergedKey] = previousIndex }
      continue
    }
    collapsed.append(derived)
    if let lifecycleKey { toolLifecycleRowIndex[lifecycleKey] = collapsed.count - 1 }
  }
  return collapsed
}

// MARK: - Entry point

/// Quiet-timeline guarantee: the work log carries the parent's narrative plus at most one row
/// per agent. Everything an agent does internally lives in the Agents surface.
public func deriveWorkLogEntries(_ activities: [V1.OrchestrationThreadActivity]) -> [WorkLogEntry] {
  let ordered = activities.stableSorted(by: compareActivitiesByOrder)
  // A launch tool and its task lifecycle describe the same run. Only hide launch rows once
  // their tool-use id has an agent row to replace them.
  var agentLaunchToolIds = Set<String>()
  for activity in ordered
  where ["task.started", "task.progress", "task.completed"].contains(activity.kind) && isAgentTaskStartedActivity(activity) {
    if let toolUseId = payloadRecord(activity)?["toolUseId"].trimmedString { agentLaunchToolIds.insert(toolUseId) }
  }
  var entries: [DerivedEntry] = []
  for activity in foldUserInputActivities(ordered) {
    if isWorktreeSetupActivity(activity.kind) && (activity.tone != .error || activity.kind == "worktree-setup") { continue }
    if activity.kind == "tool.started" { continue }
    // Agent task.started rows are CTA seeds; they collapse into the batch's single row.
    if activity.kind == "task.started" && !isAgentTaskStartedActivity(activity) { continue }
    if activity.kind == "task.updated" || activity.kind == "tool.progress" || activity.kind == "context-window.updated"
      || activity.kind == "turn.plan.updated"
    {
      continue
    }
    if activity.summary == "Checkpoint captured" { continue }
    if isNoContentRuntimeWarning(activity) || isPlanBoundaryToolActivity(activity) || isAgentInternalActivity(activity) { continue }
    let derived = toDerivedEntry(activity)
    let entry = derived.entry
    // Native agent launches get their visible row from task.started. Defer their active tool
    // row so another launch cannot duplicate the batch.
    if activity.kind == "tool.updated" && entry.itemType == .collabAgentToolCall && entry.toolLifecycleStatus == .inProgress
      && entry.tone != .error
    {
      let toolName = payloadRecord(activity)?["data"].looseRecord?["toolName"]?.stringOrNil
      if toolName == "Agent" || toolName == "Task" { continue }
    }
    if isToolLifecycleKind(activity.kind), let toolCallId = entry.toolCallId, agentLaunchToolIds.contains(toolCallId),
      entry.tone != .error, entry.toolLifecycleStatus != .failed
    {
      continue
    }
    entries.append(derived)
  }
  return collapseDerivedEntries(entries).map(\.entry)
}
