import Foundation
import T3Contracts

// `deriveMessagesTimelineRows` of MessagesTimeline.logic.ts for protocol-2 entries: turn folds
// ("Worked for ..."), superseded-attempt folds, the live work row, work-log grouping and the
// assistant footer. Pure; the order of every pass follows the TypeScript.

/// The run the timeline measures settled-ness against (`TimelineLatestRun`).
public struct TimelineLatestRun: Sendable, Hashable {
  public var runId: String
  public var status: String
  public var startedAt: String?
  public var completedAt: String?

  public init(runId: String, status: String, startedAt: String?, completedAt: String?) {
    self.runId = runId
    self.status = status
    self.startedAt = startedAt
    self.completedAt = completedAt
  }
}

struct RowsInputV2 {
  var entries: [V2TimelineEntry]
  var latestRun: TimelineLatestRun?
  var runningRunId: String?
  var expandedRunIds: Set<String>
  var expandedAttemptIds: Set<String>
  var expandedWorkGroupIds: Set<String>
  var isWorking: Bool
  /// The live work has no app run (a provider-native subagent thread).
  var runlessWorkActive: Bool
  var activeTurnStartedAt: String?
  var turnDiffSummaries: [V1.OrchestrationCheckpointSummary]
  var supportsConversationRollback: Bool
  var worktreeSetup: WorktreeSetupSnapshot?
}

private func workGroupId(_ entryId: String) -> String { "work-group:\(entryId)" }

private func elapsedMs(_ start: String, _ end: String) -> Double? {
  guard let s = jsDateParse(start), let e = jsDateParse(end) else { return nil }
  return max(0, e - s)
}

private func maxIso(_ a: String?, _ b: String?) -> String? {
  guard let a else { return b }
  guard let b else { return a }
  guard let aMs = jsDateParse(a) else { return b }
  guard let bMs = jsDateParse(b) else { return a }
  return bMs > aMs ? b : a
}

// MARK: - Entry predicates

private func entryRunId(_ entry: V2TimelineEntry) -> String? {
  switch entry.kind {
  case .message(let value): value.message.role == .assistant ? value.runId : nil
  case .proposedPlan(let plan): plan.runId
  case .htmlRender, .mcpApp: entry.runId
  case .work(let work): work.turnId?.rawValue
  case .event: nil
  }
}

private func isActiveTurnActivity(_ entry: WorkLogEntry) -> Bool {
  entry.toolLifecycleStatus == .inProgress
    || (entry.toolLifecycleStatus == nil && (entry.sourceActivityKind == "task.progress" || V2Work.isToolLike(entry)))
}

private func isErrorish(_ entry: WorkLogEntry) -> Bool {
  entry.tone == .error || entry.sourceActivityKind == "runtime.error" || entry.v2Type == "system_notice" || entry.v2Type == "notification"
}

/// A work-log entry's `projectedItem.item.type == "error"` that failed at the root.
private func failedItem(_ entry: V2TimelineEntry) -> OrchestrationV2ThreadProjectionTurnItemsItemError? {
  let item: TurnItem?
  switch entry.kind {
  case .event(let event): item = event.item
  case .work(let work): item = work.v2?.item
  default: item = nil
  }
  if case .error(let error)? = item, error.status.rawValue == "failed", error.parentItemId == nil { return error }
  return nil
}

private func failedRunIds(_ entries: [V2TimelineEntry], _ latestRun: TimelineLatestRun?) -> Set<String> {
  var failed = Set<String>()
  if latestRun?.status == "failed", let id = latestRun?.runId { failed.insert(id) }
  for entry in entries { if let id = failedItem(entry)?.runId?.rawValue { failed.insert(id) } }
  return failed
}

private func startsResponse(_ entry: V2TimelineEntry) -> Bool {
  if let message = entry.message {
    return message.message.role == .user && message.inputIntent != "steer" && message.inputIntent != "promoted_queued_to_steer"
  }
  return entry.workEntry?.v2Type == "notification"
}

private func lastResponseBoundaryIndex(_ entries: [V2TimelineEntry]) -> Int { entries.lastIndex(where: startsResponse) ?? -1 }

private func foldRunId(_ entry: V2TimelineEntry, _ runlessKey: String?) -> String? {
  if let work = entry.workEntry {
    return work.v2Type == "system_notice" ? nil : (work.turnId?.rawValue ?? runlessKey)
  }
  if let message = entry.message, message.message.role == .assistant { return message.runId ?? runlessKey }
  if let event = entry.event, isPersistentResourceCard(entry) || event.type == "subagent" { return event.runId ?? runlessKey }
  return nil
}

private func deriveTerminalAssistantMessageIds(_ entries: [V2TimelineEntry]) -> Set<String> {
  var lastByKey: [String: String] = [:]
  var order: [String] = []
  var nullTurnResponseIndex = 0
  for entry in entries {
    guard let value = entry.message else { continue }
    if value.message.role == .user {
      nullTurnResponseIndex += 1
      continue
    }
    if value.message.role != .assistant { continue }
    let key = value.runId.map { "turn:\($0)" } ?? "unkeyed:\(nullTurnResponseIndex)"
    if lastByKey[key] == nil { order.append(key) }
    lastByKey[key] = value.message.id.rawValue
  }
  return Set(lastByKey.values)
}

private func deriveUnsettledRunId(_ latestRun: TimelineLatestRun?, _ runningRunId: String?) -> String? {
  if let runningRunId { return runningRunId }
  guard let latestRun else { return nil }
  let settled = latestRun.completedAt != nil && latestRun.status != "running" && latestRun.status != "starting" && latestRun.status != "waiting"
  return settled ? nil : latestRun.runId
}

private func deriveActiveVisualResponseRunIds(entries: [V2TimelineEntry], unsettledRunId: String?, isWorking: Bool) -> Set<String> {
  var runIds = Set<String>()
  guard let unsettledRunId else { return runIds }
  runIds.insert(unsettledRunId)
  if !isWorking { return runIds }
  var index = lastResponseBoundaryIndex(entries) + 1
  while index < entries.count {
    if let runId = entryRunId(entries[index]) { runIds.insert(runId) }
    index += 1
  }
  return runIds
}

// MARK: - Preparation passes

/// Delegation already has a durable child card: drop its tool row once the returned task id
/// identifies that child.
private func withoutSubagentDelegationRows(_ entries: [V2TimelineEntry]) -> [V2TimelineEntry] {
  var childrenByRun: [String: Set<String>] = [:]
  for entry in entries {
    guard case .subagent(let subagent)? = entry.event?.item, subagent.origin.rawValue == "app_owned", let runId = subagent.runId else { continue }
    childrenByRun[runId.rawValue, default: []].insert(subagent.subagentId.rawValue)
  }
  return entries.filter { entry in
    guard let work = entry.workEntry, !workEntryDisplayIndicatesToolFailure(work) else { return true }
    guard case .dynamicTool(let tool)? = work.v2?.item, let runId = tool.runId, ["running", "completed"].contains(tool.status.rawValue),
      resolveT3McpToolDefinition(tool.toolName)?.summaryAction == "delegate"
    else { return true }
    let output = compactDynamicToolOutput(tool.output)
    if output?.isError == true { return true }
    if let taskId = output?.taskId { return !(childrenByRun[runId.rawValue]?.contains(taskId) ?? false) }
    return true
  }
}

/// A steer or subsequent activity ends thinking even if the provider omits its completion.
private func settleSupersededReasoning(_ entries: [V2TimelineEntry]) -> [V2TimelineEntry] {
  entries.enumerated().map { index, entry in
    guard index != entries.count - 1, var work = entry.workEntry, work.v2Type == "reasoning", work.toolLifecycleStatus == .inProgress else { return entry }
    work.toolLifecycleStatus = .completed
    var settled = entry
    settled.kind = .work(work)
    return settled
  }
}

private func liveSubagentCardEntryIds(_ entries: [V2TimelineEntry]) -> Set<String> {
  var visible = Set<String>()
  var batch: [V2TimelineEntry] = []
  func flush() {
    if batch.contains(where: { isLiveSubagentTurnItem($0.event!.item) }) { for entry in batch { visible.insert(entry.id) } }
    batch = []
  }
  for entry in entries {
    guard let event = entry.event, event.type == "subagent" else {
      flush()
      continue
    }
    if let previous = batch.last?.event, !sameProviderTurn(previous, event) { flush() }
    batch.append(entry)
  }
  flush()
  return visible
}

private func sameProviderTurn(_ a: V2EventItem, _ b: V2EventItem) -> Bool {
  a.item.fields?.runId == b.item.fields?.runId && a.item.fields?.providerTurnId == b.item.fields?.providerTurnId
}

// MARK: - Folds

private struct TurnFold {
  var runId: String
  var anchorEntryId: String
  var createdAt: String
  var hiddenEntryIds: Set<String>
  var label: String
}

private struct SupersededAttemptFold {
  var runId: String
  var attemptId: String
  var anchorEntryId: String
  var createdAt: String
  var hiddenEntryIds: Set<String>
}

private func deriveSupersededAttemptFolds(_ entries: [V2TimelineEntry], _ unfoldedRunIds: Set<String>, _ liveSubagentEntryIds: Set<String>) -> [String: SupersededAttemptFold] {
  var byAttempt: [String: [V2TimelineEntry]] = [:]
  var order: [String] = []
  for entry in entries {
    guard let attempt = entry.attempt, attempt.status == "superseded", !unfoldedRunIds.contains(attempt.runId) else { continue }
    if let message = entry.message, message.message.role == .user { continue }
    switch entry.kind {
    case .htmlRender, .mcpApp: continue  // A published page stays visible, as it does when its turn folds.
    default: break
    }
    if isPersistentResourceCard(entry) || liveSubagentEntryIds.contains(entry.id) { continue }
    if entry.workEntry?.v2Type == "system_notice" { continue }
    if byAttempt[attempt.id] == nil { order.append(attempt.id) }
    byAttempt[attempt.id, default: []].append(entry)
  }
  var folds: [String: SupersededAttemptFold] = [:]
  for id in order {
    let group = byAttempt[id]!
    guard let first = group.first, let attempt = first.attempt else { continue }
    folds[first.id] = SupersededAttemptFold(
      runId: attempt.runId, attemptId: attempt.id, anchorEntryId: first.id, createdAt: first.createdAt, hiddenEntryIds: Set(group.map(\.id)))
  }
  return folds
}

private func deriveTurnFolds(
  entries: [V2TimelineEntry], terminalAssistantMessageIds: Set<String>, latestRun: TimelineLatestRun?, unfoldedRunIds: Set<String>,
  runlessWorkActive: Bool, liveSubagentEntryIds: Set<String>
) -> [String: TurnFold] {
  var interruptedRunIds = Set<String>()
  for entry in entries {
    if let event = entry.event, let runId = event.runId, event.type == "run_interrupt_request" || event.type == "run_interrupt_result" {
      interruptedRunIds.insert(runId)
    }
  }
  struct Group {
    var entries: [V2TimelineEntry] = []
    var terminalEntry: V2TimelineEntry?
    var hasStreamingMessage = false
    var startBoundary: String?
    var anchorEntryId: String
  }
  var groups: [String: Group] = [:]
  var groupOrder: [String] = []
  var runlessFailedKeys = Set<String>()
  var runlessKey: String?
  var pendingBoundary: (createdAt: String, anchorEntryId: String)?
  for (index, entry) in entries.enumerated() {
    if startsResponse(entry) {
      pendingBoundary = index + 1 < entries.count ? (entry.createdAt, entries[index + 1].id) : nil
      let boundaryRunId: String? = entry.message?.runId ?? entry.workEntry?.turnId?.rawValue
      runlessKey = boundaryRunId == nil ? "runless:\(entry.id)" : nil
      continue
    }
    guard let runId = foldRunId(entry, runlessKey) else { continue }
    if runId == runlessKey, failedItem(entry) != nil { runlessFailedKeys.insert(runId) }
    if groups[runId] == nil {
      // Each user boundary starts at most one turn; a second turn after the same user message
      // falls back to its own first entry.
      groups[runId] = Group(startBoundary: pendingBoundary?.createdAt, anchorEntryId: pendingBoundary?.anchorEntryId ?? entry.id)
      groupOrder.append(runId)
      pendingBoundary = nil
    }
    groups[runId]!.entries.append(entry)
    if let message = entry.message {
      if terminalAssistantMessageIds.contains(message.message.id.rawValue) { groups[runId]!.terminalEntry = entry }
      if message.message.streaming { groups[runId]!.hasStreamingMessage = true }
    }
  }

  var folds: [String: TurnFold] = [:]
  for runId in groupOrder {
    let group = groups[runId]!
    if unfoldedRunIds.contains(runId) || interruptedRunIds.contains(runId) || runlessFailedKeys.contains(runId) || (runlessWorkActive && runId == runlessKey) { continue }
    if group.hasStreamingMessage { continue }
    var hidden = Set<String>()
    let terminalIndex = group.terminalEntry.flatMap { terminal in group.entries.firstIndex { $0.id == terminal.id } } ?? group.entries.count
    for (index, entry) in group.entries.enumerated() {
      if entry.id == group.terminalEntry?.id { continue }
      let isCompaction = entry.workEntry?.sourceActivityKind == "context-compaction"
      let isFoldableTrailing = entry.workEntry.map { $0.toolLifecycleStatus != .inProgress && !workEntryDisplayIndicatesToolFailure($0) } ?? false
      if !isCompaction && index > terminalIndex && !isFoldableTrailing { continue }
      // Linked resources and still-working children can outlive their launching run.
      if isPersistentResourceCard(entry) || liveSubagentEntryIds.contains(entry.id) { continue }
      if entry.workEntry?.v2Type == "notification" { continue }
      hidden.insert(entry.id)
    }
    if hidden.isEmpty { continue }
    // A lone compaction row stays visible on its own.
    let hidesNonCompaction = group.entries.contains { hidden.contains($0.id) && $0.workEntry?.sourceActivityKind != "context-compaction" }
    if !hidesNonCompaction { continue }
    guard let first = group.entries.first, let last = group.entries.last else { continue }

    let isLatestInterrupted = latestRun?.runId == runId && latestRun?.status == "interrupted"
    // A turn cut short by a steer leaves trailing work entries behind its terminal message.
    let lastEntryEnd = last.message.map { $0.message.updatedAt.rawValue } ?? last.createdAt
    let elapsed: Double?
    if let run = latestRun, run.runId == runId, let started = run.startedAt, !started.isEmpty, let completed = run.completedAt, !completed.isEmpty {
      elapsed = elapsedMs(started, completed)
    } else {
      elapsed = elapsedMs(group.startBoundary ?? first.createdAt, maxIso(group.terminalEntry?.message?.message.updatedAt.rawValue, lastEntryEnd) ?? lastEntryEnd)
    }
    let duration = elapsed.map(formatDuration)
    let label: String
    if isLatestInterrupted {
      label = duration.map { "You stopped after \($0)" } ?? "You stopped this response"
    } else {
      label = duration.map { "Worked for \($0)" } ?? "Worked"
    }
    folds[group.anchorEntryId] = TurnFold(
      runId: runId, anchorEntryId: group.anchorEntryId, createdAt: group.startBoundary ?? first.createdAt, hiddenEntryIds: hidden, label: label)
  }
  return folds
}

// MARK: - Post passes

private func attachTrailingToolGroupsToAssistant(_ rows: [TimelineRow]) -> [TimelineRow] {
  var messageRowsWithoutMeta = Set<String>()
  var metaRowsAfterIndex: [Int: AssistantMetaRow] = [:]
  for (messageIndex, row) in rows.enumerated() {
    guard case .message(let messageRow) = row, messageRow.message.role == .assistant, messageRow.showAssistantMeta, let runId = messageRow.message.turnId?.rawValue else { continue }
    var lastTrailingWorkIndex = -1
    var hasTrailingToolGroup = false
    var index = messageIndex + 1
    scan: while index < rows.count {
      let candidate = rows[index]
      switch candidate {
      case .message: break scan
      case .workToggle(let toggle) where toggle.turnId?.rawValue == runId:
        hasTrailingToolGroup = true
        lastTrailingWorkIndex = index
      case .event(let event) where event.resourceSummary && event.item.runId == runId:
        hasTrailingToolGroup = true
        lastTrailingWorkIndex = index
      case .work(let work) where work.groupedEntries.contains(where: { $0.turnId?.rawValue == runId }):
        if !work.isExpandedToolGroup,
          work.groupedEntries.contains(where: { entry in
            V2Work.isToolLike(entry)
              || { if case .error(let error)? = entry.v2?.item { return error.status.rawValue == "failed" } else { return false } }()
          })
        {
          hasTrailingToolGroup = true
        }
        if hasTrailingToolGroup { lastTrailingWorkIndex = index }
      default: break
      }
      index += 1
    }
    if lastTrailingWorkIndex < 0 { continue }
    messageRowsWithoutMeta.insert(messageRow.id)
    metaRowsAfterIndex[lastTrailingWorkIndex] = AssistantMetaRow(
      id: "assistant-meta:\(messageRow.message.id.rawValue)", createdAt: rows[lastTrailingWorkIndex].createdAt ?? messageRow.message.updatedAt.rawValue,
      message: messageRow.message, showAssistantCopyButton: messageRow.showAssistantCopyButton, assistantCopyStreaming: messageRow.assistantCopyStreaming)
  }
  var result: [TimelineRow] = []
  for (index, row) in rows.enumerated() {
    if case .message(var messageRow) = row, messageRowsWithoutMeta.contains(messageRow.id) {
      messageRow.showAssistantMeta = false
      messageRow.showAssistantCopyButton = false
      result.append(.message(messageRow))
    } else {
      result.append(row)
    }
    if let meta = metaRowsAfterIndex[index] { result.append(.assistantMeta(meta)) }
  }
  return result
}

/// Keep created chats below the final answer even when the work that created them folds away.
private func attachCreatedThreadSummaries(_ rows: [TimelineRow], _ entries: [V2TimelineEntry]) -> [TimelineRow] {
  var terminalIndexes: [String: Int] = [:]
  var collapsedRuns = Set<String>()
  var createdByRun: [String: [EventRow]] = [:]
  for (index, row) in rows.enumerated() {
    if case .message(let message) = row, message.showAssistantMeta, let runId = message.message.turnId?.rawValue { terminalIndexes[runId] = index }
    if case .turnFold(let fold) = row, !fold.expanded { collapsedRuns.insert(fold.turnId.rawValue) }
  }
  for entry in entries {
    let projected: ProjectedItem?
    switch entry.kind {
    case .work(let work): projected = work.v2?.row
    case .event(let event): projected = event.row
    default: projected = nil
    }
    if let projected, case .threadCreated(let created) = projected.item, let runId = created.runId?.rawValue {
      createdByRun[runId, default: []].append(EventRow(id: entry.id, createdAt: entry.createdAt, item: V2EventItem(row: projected)))
    }
  }
  var out: [TimelineRow] = []
  for (index, row) in rows.enumerated() {
    if case .event(let event) = row, event.item.type == "thread_created" {
      let runId = event.item.runId
      if let runId, let terminal = terminalIndexes[runId], collapsedRuns.contains(runId) || index > terminal { continue }
    }
    out.append(row)
    if case .message(let message) = row, message.showAssistantMeta, let runId = message.message.turnId?.rawValue {
      for var summary in createdByRun[runId] ?? [] {
        summary.id = "summary:\(summary.id)"
        summary.resourceSummary = true
        out.append(.event(summary))
      }
    }
  }
  return out
}

private func isWorkLogRow(_ row: TimelineRow?) -> Bool {
  switch row {
  case .work?, .workToggle?, .workLive?, .thinking?: true
  default: false
  }
}

private func withContinuesWorkLog(_ row: TimelineRow) -> TimelineRow {
  switch row {
  case .work(var value): value.continuesWorkLog = true; return .work(value)
  case .workToggle(var value): value.continuesWorkLog = true; return .workToggle(value)
  case .workLive(var value): value.continuesWorkLog = true; return .workLive(value)
  case .thinking(var value): value.continuesWorkLog = true; return .thinking(value)
  default: return row
  }
}

// MARK: - Rows

private func expandedWorkGroupRow(_ groupId: String, _ createdAt: String, _ entries: [WorkLogEntry]) -> TimelineRow {
  .work(WorkRow(id: "\(groupId):details", createdAt: createdAt, groupedEntries: entries, isExpandedToolGroup: true, displayLabel: nil))
}

func deriveMessagesTimelineRowsV2(_ input: RowsInputV2) -> [TimelineRow] {
  let entries = withoutSubagentDelegationRows(settleSupersededReasoning(input.entries))
  var turnDiffSummaryByAssistantMessageId: [String: V1.OrchestrationCheckpointSummary] = [:]
  for summary in input.turnDiffSummaries { if let id = summary.assistantMessageId { turnDiffSummaryByAssistantMessageId[id.rawValue] = summary } }
  let revertTurnCountByUserMessageId = input.supportsConversationRollback ? deriveRevertTurnCountByUserMessageId(entries, input.turnDiffSummaries) : [:]
  var rows: [TimelineRow] = []
  // computeMessageDurationStart over the message entries.
  var durationStartByMessageId: [String: String] = [:]
  var lastBoundary: String?
  for entry in entries {
    guard let value = entry.message else { continue }
    let message = value.message
    if message.role == .user { lastBoundary = message.createdAt.rawValue }
    durationStartByMessageId[message.id.rawValue] = lastBoundary ?? message.createdAt.rawValue
    if message.role == .assistant && !message.streaming { lastBoundary = message.updatedAt.rawValue }
  }
  let terminalAssistantMessageIds = deriveTerminalAssistantMessageIds(entries)
  let unsettledRunId = deriveUnsettledRunId(input.latestRun, input.runningRunId)
  let failedRuns = failedRunIds(entries, input.latestRun)
  let liveSubagentEntryIds = liveSubagentCardEntryIds(entries)
  let supersededFolds = deriveSupersededAttemptFolds(entries, failedRuns, liveSubagentEntryIds)
  let activeVisualResponseRunIds = deriveActiveVisualResponseRunIds(entries: entries, unsettledRunId: unsettledRunId, isWorking: input.isWorking)
  let runlessWorkActive = input.isWorking && input.runlessWorkActive
  let folds = deriveTurnFolds(
    entries: entries, terminalAssistantMessageIds: terminalAssistantMessageIds, latestRun: input.latestRun,
    unfoldedRunIds: activeVisualResponseRunIds.union(failedRuns), runlessWorkActive: runlessWorkActive, liveSubagentEntryIds: liveSubagentEntryIds)
  var collapsedEntryIds = Set<String>()
  for fold in folds.values where !input.expandedRunIds.contains(fold.runId) { collapsedEntryIds.formUnion(fold.hiddenEntryIds) }
  var collapsedSupersededEntryIds = Set<String>()
  for fold in supersededFolds.values where !input.expandedAttemptIds.contains(fold.attemptId) { collapsedSupersededEntryIds.formUnion(fold.hiddenEntryIds) }
  func runIdIsActiveResponse(_ runId: String?) -> Bool { runId == nil ? runlessWorkActive : activeVisualResponseRunIds.contains(runId!) }
  func workEntryIsInActiveRun(_ entry: WorkLogEntry) -> Bool {
    input.isWorking && entry.toolLifecycleStatus == .inProgress
      && (entry.turnId == nil ? runlessWorkActive : entry.turnId?.rawValue == unsettledRunId)
  }

  // A steer continues the current turn: keep its elapsed-time header below the initiating prompt.
  let activeTurnHeaderIndex = input.isWorking ? lastResponseBoundaryIndex(entries) + 1 : entries.count

  // Contiguous trailing work entries of the active run collapse into one live row that survives
  // between actions.
  var activeToolEntries: [(entry: V2TimelineEntry, work: WorkLogEntry)] = []
  if input.isWorking && (unsettledRunId != nil || runlessWorkActive) {
    var tailAttemptId: String??
    var index = entries.count - 1
    while index >= activeTurnHeaderIndex {
      let entry = entries[index]
      guard let work = entry.workEntry, work.tone != .error, work.sourceActivityKind != "runtime.error", work.v2Type != "system_notice",
        work.v2Type != "notification", runIdIsActiveResponse(work.turnId?.rawValue), work.sourceActivityKind != "context-compaction",
        !collapsedEntryIds.contains(entry.id), !collapsedSupersededEntryIds.contains(entry.id), folds[entry.id] == nil, supersededFolds[entry.id] == nil
      else { break }
      if tailAttemptId == nil {
        tailAttemptId = .some(entry.attempt?.id)
      } else if entry.attempt?.id != tailAttemptId! {
        break
      }
      activeToolEntries.insert((entry, work), at: 0)
      index -= 1
    }
  }
  let visibleActiveToolEntries = activeToolEntries.filter { workEntryIsVisibleInGroup($0.work, expandedToolGroupEntry: true) }
  let activeWorkAnchor = activeToolEntries.first
  let latestVisibleToolEntry = visibleActiveToolEntries.last
  let latestRunningToolEntry = visibleActiveToolEntries.last { isActiveTurnActivity($0.work) }
  let latestToolKeepsActivityLive =
    latestRunningToolEntry != nil || (latestVisibleToolEntry.map { V2Work.indicatesToolSuccess($0.work) } ?? false)
  let latestToolFailed =
    latestRunningToolEntry == nil && latestVisibleToolEntry != nil && latestVisibleToolEntry!.work.toolLifecycleStatus != .declined
    && workEntryDisplayIndicatesToolFailure(latestVisibleToolEntry!.work)
  let latestThoughtEntry = visibleActiveToolEntries.last { $0.work.v2Type == "reasoning" && !($0.work.detail?.jsTrimmed ?? "").isEmpty }
  let activeWorkPlacementEntryId = latestVisibleToolEntry?.entry.id
  var activeWorkRow: WorkLiveRow?
  if let anchor = activeWorkAnchor, let latest = latestVisibleToolEntry, !latestToolFailed {
    let groupId = workGroupId(anchor.entry.id)
    activeWorkRow = WorkLiveRow(
      id: latestToolKeepsActivityLive ? liveActivityRowId : "work-live:\(anchor.entry.id)", createdAt: anchor.entry.createdAt,
      entry: (latestRunningToolEntry ?? latest).work, groupedEntries: visibleActiveToolEntries.map(\.work), groupId: groupId,
      expanded: input.expandedWorkGroupIds.contains(groupId), active: latestToolKeepsActivityLive, thought: latestThoughtEntry?.work)
  }
  let activeWorkEntryIds = Set((activeWorkRow != nil || latestToolFailed) ? activeToolEntries.map(\.entry.id) : [])

  func appendWorkingRow() {
    rows.append(.working(LiveIndicatorRow(id: "working-indicator-row", createdAt: input.activeTurnStartedAt)))
  }
  var hasActivityRow = false
  var hasActiveCompaction = false
  func appendActiveWorkRows() {
    guard let row = activeWorkRow else { return }
    rows.append(.workLive(row))
    hasActivityRow = hasActivityRow || row.active
    if !row.expanded { return }
    rows.append(expandedWorkGroupRow(row.groupId, row.createdAt, row.groupedEntries))
  }

  var index = 0
  while index < entries.count {
    let entry = entries[index]
    if input.isWorking && index == activeTurnHeaderIndex { appendWorkingRow() }
    if entry.id == activeWorkPlacementEntryId { appendActiveWorkRows() }

    // The terminal interrupt result is the useful marker; the request duplicates it.
    if entry.event?.type == "run_interrupt_request" {
      index += 1
      continue
    }
    if let fold = folds[entry.id] {
      rows.append(
        .turnFold(
          TurnFoldRow(
            id: "turn-fold:\(fold.runId)", createdAt: fold.createdAt, turnId: V1.TurnId(rawValue: fold.runId), label: fold.label,
            expanded: input.expandedRunIds.contains(fold.runId))))
    }
    if collapsedEntryIds.contains(entry.id) {
      index += 1
      continue
    }
    if let fold = supersededFolds[entry.id] {
      rows.append(
        .attemptFold(
          AttemptFoldRow(
            id: "attempt-fold:\(fold.attemptId)", createdAt: fold.createdAt, runId: fold.runId, attemptId: fold.attemptId, label: "Superseded attempt",
            expanded: input.expandedAttemptIds.contains(fold.attemptId))))
    }
    if collapsedSupersededEntryIds.contains(entry.id) {
      index += 1
      continue
    }
    if activeWorkEntryIds.contains(entry.id) {
      index += 1
      continue
    }

    if let work = entry.workEntry, work.sourceActivityKind == "context-compaction" {
      let active = workEntryIsInActiveRun(work)
      hasActiveCompaction = hasActiveCompaction || active
      rows.append(.contextCompaction(ContextCompactionRow(id: entry.id, createdAt: entry.createdAt, label: work.label, active: active)))
      index += 1
      continue
    }

    if let work = entry.workEntry {
      if (work.turnId.map { failedRuns.contains($0.rawValue) } ?? false) || (work.v2Type == "error" && work.toolLifecycleStatus == .failed) || isErrorish(work) {
        rows.append(.work(WorkRow(id: entry.id, createdAt: entry.createdAt, groupedEntries: [work], isExpandedToolGroup: false, displayLabel: nil)))
        index += 1
        continue
      }
      var groupedEntries = [work]
      var cursor = index + 1
      while cursor < entries.count {
        let next = entries[cursor]
        guard let nextWork = next.workEntry, nextWork.sourceActivityKind != "context-compaction", !isErrorish(nextWork),
          !activeWorkEntryIds.contains(next.id), !collapsedEntryIds.contains(next.id), !collapsedSupersededEntryIds.contains(next.id),
          folds[next.id] == nil, supersededFolds[next.id] == nil, nextWork.turnId?.rawValue == work.turnId?.rawValue,
          next.attempt?.id == entry.attempt?.id
        else { break }
        groupedEntries.append(nextWork)
        cursor += 1
      }
      let visibleGrouped = groupedEntries.filter { workEntryIsVisibleInGroup($0, expandedToolGroupEntry: workEntryIsInActiveRun($0)) }
      if !visibleGrouped.isEmpty {
        let activeInProgress = visibleGrouped.filter(workEntryIsInActiveRun)
        if let latestActive = activeInProgress.last {
          let groupId = workGroupId(entry.id)
          let expanded = input.expandedWorkGroupIds.contains(groupId)
          rows.append(
            .workLive(
              WorkLiveRow(
                id: "work-live:\(entry.id)", createdAt: entry.createdAt, entry: latestActive, groupedEntries: visibleGrouped, groupId: groupId, expanded: expanded,
                active: true)))
          hasActivityRow = true
          if expanded { rows.append(expandedWorkGroupRow(groupId, entry.createdAt, visibleGrouped)) }
        } else if visibleGrouped.count == 1 && V2Work.isToolLike(visibleGrouped[0]) {
          let single = visibleGrouped[0]
          rows.append(
            .work(
              WorkRow(
                id: entry.id, createdAt: entry.createdAt, groupedEntries: visibleGrouped, isExpandedToolGroup: false,
                displayLabel: toolGroupAction(single) == .edit ? V2Work.summarizeToolGroup(visibleGrouped).summary : V2Work.singleToolCallLabel(single))))
        } else {
          let groupId = workGroupId(entry.id)
          let expanded = input.expandedWorkGroupIds.contains(groupId)
          let summaryKind = V2Work.toolGroupSummaryKind(visibleGrouped)
          let primarySourceEntry = visibleGrouped.first { $0.toolSource != nil }
          let primarySourceKey = primarySourceEntry?.toolSource?.key
          let primarySourceIcon: ToolActivityIcon? = primarySourceKey.flatMap { key in
            visibleGrouped.first { $0.toolSource?.key == key && $0.toolIcon != nil }?.toolIcon ?? primarySourceEntry?.toolSource?.icon
          }
          let groupToolSurface = primarySourceEntry?.toolSurface ?? visibleGrouped.last { $0.toolSurface != nil }?.toolSurface
          let groupToolIcon = primarySourceIcon ?? visibleGrouped.last { $0.toolIcon != nil }?.toolIcon
          let latestToolEntry = visibleGrouped.last { V2Work.isToolLike($0) }
          let single = visibleGrouped.count == 1 ? visibleGrouped[0] : nil
          let usesSingleLabel = single.map { V2Work.isToolLike($0) && toolGroupAction($0) != .edit } ?? false
          let summaryToolIcon = usesSingleLabel ? V2Work.toolPresentation(single!, fallbackStatus: .completed)?.icon : nil
          let summary: String
          if usesSingleLabel {
            summary = V2Work.singleToolCallLabel(single!)
          } else if let single, !V2Work.isToolLike(single) {
            summary = single.label
          } else {
            summary = V2Work.summarizeToolGroup(visibleGrouped).summary
          }
          rows.append(
            .workToggle(
              WorkToggleRow(
                id: "work-toggle:\(entry.id)", createdAt: entry.createdAt, turnId: work.turnId, groupId: groupId, hiddenCount: visibleGrouped.count,
                expanded: expanded, summary: summary, summaryKind: summaryKind, toolSurface: groupToolSurface, toolIcon: groupToolIcon,
                summaryToolIcon: summaryToolIcon, hasFailure: latestToolEntry.map(workEntryDisplayIndicatesToolFailure) ?? false)))
          if expanded { rows.append(expandedWorkGroupRow(groupId, entry.createdAt, visibleGrouped)) }
        }
      }
      index = cursor
      continue
    }

    switch entry.kind {
    case .proposedPlan(let plan):
      rows.append(.proposedPlan(ProposedPlanRow(id: entry.id, createdAt: entry.createdAt, proposedPlan: plan.asProposedPlan, status: plan.status)))
    case .htmlRender(let html):
      rows.append(.htmlRender(HtmlRenderRow(id: entry.id, createdAt: entry.createdAt, htmlRender: html)))
    case .mcpApp(let app):
      rows.append(.mcpApp(McpAppRow(id: entry.id, createdAt: entry.createdAt, mcpApp: app)))
    case .event(let event):
      if event.type == "subagent", case .event(var previous)? = rows.last, previous.item.type == "subagent", sameProviderTurn(previous.item, event) {
        previous.subagents = (previous.subagents ?? [previous.item]) + [event]
        rows[rows.count - 1] = .event(previous)
      } else {
        rows.append(.event(EventRow(id: entry.id, createdAt: entry.createdAt, item: event)))
      }
    case .message(let value):
      let message = value.message
      let assistantStillInProgress = message.role == .assistant && runIdIsActiveResponse(value.runId)
      let durationStart = durationStartByMessageId[message.id.rawValue] ?? message.createdAt.rawValue
      // While the turn runs, the latest assistant message is only provisionally terminal.
      let showAssistantMeta = message.role == .assistant && terminalAssistantMessageIds.contains(message.id.rawValue) && !assistantStillInProgress
      rows.append(
        .message(
          MessageRow(
            id: entry.id, createdAt: entry.createdAt, message: message, durationStart: durationStart, showAssistantMeta: showAssistantMeta,
            showAssistantCopyButton: showAssistantMeta, assistantCopyStreaming: message.streaming || assistantStillInProgress,
            assistantTurnDiffSummary: message.role == .assistant ? turnDiffSummaryByAssistantMessageId[message.id.rawValue] : nil,
            revertTurnCount: message.role == .user ? revertTurnCountByUserMessageId[message.id.rawValue] : nil, inputIntent: value.inputIntent)))
    case .work:
      break
    }
    index += 1
  }

  // Worktree setup card (see the comment block in the TypeScript for the handoff rules).
  let setupHandedOff = input.worktreeSetup.map { worktreeSetupAgentStarted($0) } == true && input.latestRun?.startedAt != nil
  let setupOwnsWorkingSlot = !setupHandedOff && (input.worktreeSetup?.phase == .running || input.worktreeSetup?.phase == .done)
  if let setup = input.worktreeSetup, !setupHandedOff || setup.phase != .running {
    let setupRow = TimelineRow.worktreeSetup(
      WorktreeSetupRow(id: worktreeSetupRowId, createdAt: setup.startedAt.rawValue, snapshot: setup, embedded: setupHandedOff))
    let firstUserRowIndex = rows.firstIndex { if case .message(let row) = $0 { row.message.role == .user } else { false } }
    // While the setup runs, the working header leads the card in the same slot it keeps later.
    let workingRowIndex = setupOwnsWorkingSlot ? rows.firstIndex { if case .working = $0 { true } else { false } } : nil
    if let workingRowIndex {
      rows.insert(setupRow, at: workingRowIndex + 1)
    } else {
      let insertAt = firstUserRowIndex.map { $0 + 1 } ?? rows.count
      let inserted: [TimelineRow] =
        setupOwnsWorkingSlot
        ? [.working(LiveIndicatorRow(id: "working-indicator-row", createdAt: setup.startedAt.rawValue)), setupRow] : [setupRow]
      rows.insert(contentsOf: inserted, at: insertAt)
    }
  }

  let hasWorkingRow = rows.contains { if case .working = $0 { true } else { false } }
  if input.isWorking && !hasWorkingRow && activeTurnHeaderIndex == entries.count { appendWorkingRow() }
  if input.isWorking && !setupOwnsWorkingSlot && !hasActiveCompaction && (!hasActivityRow || latestToolFailed) {
    // A failed latest tool hands the row back to thinking, but its group stays reachable.
    if latestToolFailed, let anchor = activeWorkAnchor {
      let groupId = workGroupId(anchor.entry.id)
      let expanded = input.expandedWorkGroupIds.contains(groupId)
      rows.append(.thinking(LiveIndicatorRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt, groupId: groupId, expanded: expanded)))
      if expanded { rows.append(expandedWorkGroupRow(groupId, anchor.entry.createdAt, visibleActiveToolEntries.map(\.work))) }
    } else {
      rows.append(.thinking(LiveIndicatorRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt)))
    }
  }

  let result = attachTrailingToolGroupsToAssistant(attachCreatedThreadSummaries(rows, entries))
  return result.enumerated().map { index, row in
    isWorkLogRow(row) && isWorkLogRow(index + 1 < result.count ? result[index + 1] : nil) ? withContinuesWorkLog(row) : row
  }
}

extension V2Plan {
  var asProposedPlan: ProposedPlan {
    ProposedPlan(
      id: id, turnId: runId.map { V1.TurnId(rawValue: $0) }, planMarkdown: planMarkdown, implementedAt: nil, implementationThreadId: nil,
      createdAt: IsoDateTime(rawValue: createdAt), updatedAt: IsoDateTime(rawValue: updatedAt))
  }
}

/// `deriveRevertTurnCountByUserMessageId`.
func deriveRevertTurnCountByUserMessageId(_ entries: [V2TimelineEntry], _ checkpoints: [V1.OrchestrationCheckpointSummary]) -> [String: Int] {
  var readyByRunId: [String: V1.OrchestrationCheckpointSummary] = [:]
  for checkpoint in checkpoints where checkpoint.status.rawValue == "ready" { readyByRunId[checkpoint.turnId.rawValue] = checkpoint }
  var result: [String: Int] = [:]
  for entry in entries {
    guard let value = entry.message, value.message.role == .user, value.inputIntent == "turn_start" || value.inputIntent == "queued_turn",
      let runId = value.runId, let checkpoint = readyByRunId[runId]
    else { continue }
    result[value.message.id.rawValue] = max(0, checkpoint.checkpointTurnCount - 1)
  }
  return result
}
