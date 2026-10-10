import Foundation
import T3Contracts

// Port of deriveMessagesTimelineRows and its helpers (apps/web/src/components/chat/
// MessagesTimeline.logic.ts). TypeScript is the source of truth: comments here only explain
// where the Swift had to differ.

let liveActivityRowId = "live-activity-row"
let worktreeSetupRowId = "worktree-setup-row"
let workingIndicatorRowId = "working-indicator-row"

public func worktreeSetupAgentStarted(_ snapshot: WorktreeSetupSnapshot) -> Bool {
  snapshot.stages.contains { $0.id == .agent && $0.status == .done }
}

// MARK: - Labels

public func workEntryIsVisibleInGroup(_ entry: WorkLogEntry, expandedToolGroupEntry: Bool = false) -> Bool {
  (expandedToolGroupEntry && (entry.toolLifecycleStatus == .inProgress || entry.sourceActivityKind == "task.progress"))
    || !workEntryIndicatesToolNeutralStatus(entry)
}

private func capitalizedHeading(_ entry: WorkLogEntry) -> String {
  normalizeCompactToolLabel(entry.toolTitle.flatMap { $0.isEmpty ? nil : $0 } ?? entry.label).jsCapitalizedFirst()
}

private func singleToolCallLabel(_ entry: WorkLogEntry) -> String {
  if let presentation = resolveWorkEntryToolPresentation(entry, fallbackStatus: .completed) { return presentation.displayName }
  if let command = entry.command?.jsTrimmed, !command.isEmpty { return command }
  return capitalizedHeading(entry)
}

public func workEntryIsActiveTurnActivity(_ entry: WorkLogEntry) -> Bool {
  entry.toolLifecycleStatus == .inProgress
    || (entry.toolLifecycleStatus == nil && (entry.sourceActivityKind == "task.progress" || workLogEntryIsToolLike(entry)))
}

// MARK: - Durations and turns

private func computeElapsedMs(_ startIso: String, _ endIso: String) -> Double? {
  guard let start = jsDateParse(startIso), let end = jsDateParse(endIso) else { return nil }
  return max(0, end - start)
}

private func maxIsoTimestamp(_ a: String?, _ b: String?) -> String? {
  guard let a else { return b }
  guard let b else { return a }
  guard let aMs = jsDateParse(a) else { return b }
  guard let bMs = jsDateParse(b) else { return a }
  return bMs > aMs ? b : a
}

/// Start of the elapsed time shown for each message: the last user message or the end of the
/// previous settled assistant message.
public func computeMessageDurationStart(_ messages: [V1.OrchestrationMessage]) -> [String: String] {
  var result: [String: String] = [:]
  var lastBoundary: String?
  for message in messages {
    if message.role == .user { lastBoundary = message.createdAt.rawValue }
    result[message.id.rawValue] = lastBoundary ?? message.createdAt.rawValue
    if message.role == .assistant && !message.streaming { lastBoundary = message.updatedAt.rawValue }
  }
  return result
}

/// The session's running turn is authoritative when latestTurn briefly lags or regresses behind
/// it. Otherwise the latest turn counts as unsettled while it is still running (or has not
/// recorded a completion).
public func deriveUnsettledTurnId(latestTurn: LatestTurnTiming?, runningTurnId: V1.TurnId?) -> V1.TurnId? {
  if let runningTurnId { return runningTurnId }
  guard let latestTurn else { return nil }
  let isSettled = latestTurn.completedAt != nil && latestTurn.state != .running
  return isSettled ? nil : latestTurn.turnId
}

private func timelineEntryTurnId(_ entry: TimelineEntry) -> V1.TurnId? {
  switch entry {
  case .message(let message): message.role == .assistant || message.role == .reasoning ? message.turnId : nil
  case .proposedPlan(let plan): plan.turnId
  case .work(let work): work.turnId
  }
}

private func lastUserMessageIndex(_ entries: [TimelineEntry]) -> Int {
  entries.lastIndex { if case .message(let message) = $0 { message.role == .user } else { false } } ?? -1
}

private func isActivityEntry(_ entry: TimelineEntry) -> ActivityEntry? {
  switch entry {
  case .message(let message): message.role == .reasoning ? .message(message) : nil
  case .work(let work):
    work.agentSpawn == nil && work.questionAnswer == nil && work.sourceActivityKind != "context-compaction" && work.tone != .error
      ? .work(work) : nil
  case .proposedPlan: nil
  }
}

private func workGroupIdentity(_ timelineEntryId: String, _ entry: WorkLogEntry) -> String {
  if let toolCallId = entry.toolCallId, !toolCallId.isEmpty { return "tool:\(entry.turnId?.rawValue ?? "no-turn"):\(toolCallId)" }
  return timelineEntryId
}

private func workGroupId(_ timelineEntryId: String, _ entry: WorkLogEntry) -> String {
  "work-group:\(workGroupIdentity(timelineEntryId, entry))"
}

private func expandedWorkGroupRow(_ groupId: String, _ createdAt: String, _ groupedEntries: [WorkLogEntry]) -> TimelineRow {
  .work(WorkRow(id: "\(groupId):details", createdAt: createdAt, groupedEntries: groupedEntries, isExpandedToolGroup: true))
}

private func deriveTerminalAssistantMessageIds(_ entries: [TimelineEntry]) -> Set<String> {
  var lastAssistantMessageIdByResponseKey: [String: String] = [:]
  var nullTurnResponseIndex = 0
  for entry in entries {
    guard case .message(let message) = entry else { continue }
    if message.role == .user {
      nullTurnResponseIndex += 1
      continue
    }
    if message.role != .assistant { continue }
    let key = message.turnId.flatMap { $0.rawValue.isEmpty ? nil : "turn:\($0.rawValue)" } ?? "unkeyed:\(nullTurnResponseIndex)"
    lastAssistantMessageIdByResponseKey[key] = message.id.rawValue
  }
  return Set(lastAssistantMessageIdByResponseKey.values)
}

/// A promptless provider restart replaces the native turn without adding a user message. Keep
/// every provider turn since the latest user message in one visual response until the
/// replacement turn settles.
private func deriveActiveVisualResponseTurnIds(entries: [TimelineEntry], unsettledTurnId: V1.TurnId?, isWorking: Bool) -> Set<V1.TurnId> {
  var turnIds = Set<V1.TurnId>()
  guard let unsettledTurnId else { return turnIds }
  turnIds.insert(unsettledTurnId)
  if !isWorking { return turnIds }
  let latestUserMessageIndex = lastUserMessageIndex(entries)
  for index in (latestUserMessageIndex + 1)..<max(entries.count, latestUserMessageIndex + 1) {
    if let turnId = timelineEntryTurnId(entries[index]) { turnIds.insert(turnId) }
  }
  return turnIds
}

private struct TurnFold {
  var turnId: V1.TurnId
  var anchorEntryId: String
  var createdAt: String
  var hiddenEntryIds: Set<String>
  var label: String
}

/// Settled turns fold activity before their terminal assistant message behind a "Worked for
/// ..." row. A single ordinary activity after that message joins the fold, while larger groups
/// and failures stay visible as a trailing summary.
private func deriveTurnFolds(
  entries: [TimelineEntry],
  terminalAssistantMessageIds: Set<String>,
  latestTurn: LatestTurnTiming?,
  unfoldedTurnIds: Set<V1.TurnId>
) -> [String: TurnFold] {
  struct TurnGroup {
    var entries: [TimelineEntry] = []
    var terminalEntryId: String?
    var terminalUpdatedAt: String?
    var hasStreamingMessage = false
    /// The user message that kicked the turn off.
    var startBoundary: String?
  }
  var groupOrder: [V1.TurnId] = []
  var groups: [V1.TurnId: TurnGroup] = [:]

  var pendingUserBoundary: String?
  for entry in entries {
    if case .message(let message) = entry, message.role == .user {
      pendingUserBoundary = message.createdAt.rawValue
      continue
    }
    // Thinking is work, so it folds with the rest of it.
    let turnId: V1.TurnId?
    switch entry {
    case .message(let message): turnId = message.role == .assistant || message.role == .reasoning ? message.turnId : nil
    case .work(let work): turnId = work.turnId
    case .proposedPlan: turnId = nil
    }
    guard let turnId, !turnId.rawValue.isEmpty else { continue }
    if groups[turnId] == nil {
      // Each user boundary starts at most one turn.
      groups[turnId] = TurnGroup(startBoundary: pendingUserBoundary)
      groupOrder.append(turnId)
      pendingUserBoundary = nil
    }
    groups[turnId]!.entries.append(entry)
    if case .message(let message) = entry {
      if terminalAssistantMessageIds.contains(message.id.rawValue) {
        groups[turnId]!.terminalEntryId = entry.id
        groups[turnId]!.terminalUpdatedAt = message.updatedAt.rawValue
      }
      // Only an answer still being written may hold a fold open; a thinking block stranded by a
      // crashed provider keeps its streaming flag forever and must not.
      if message.streaming && message.role != .reasoning { groups[turnId]!.hasStreamingMessage = true }
    }
  }

  var foldsByAnchorEntryId: [String: TurnFold] = [:]
  for turnId in groupOrder {
    let group = groups[turnId]!
    if unfoldedTurnIds.contains(turnId) || group.hasStreamingMessage { continue }
    var hiddenEntryIds = Set<String>()
    let terminalEntryIndex = group.terminalEntryId.flatMap { id in group.entries.firstIndex { $0.id == id } } ?? group.entries.count
    // Thinking blocks do not count toward "one trailing activity".
    let trailingEntryCount = group.entries.enumerated().filter { index, candidate in
      guard index > terminalEntryIndex else { return false }
      if case .message(let message) = candidate, message.role == .reasoning { return false }
      return true
    }.count
    for (index, entry) in group.entries.enumerated() {
      if entry.id == group.terminalEntryId { continue }
      var isCompaction = false
      var isSingleTrailingActivity = false
      if case .work(let work) = entry {
        isCompaction = work.sourceActivityKind == "context-compaction"
        isSingleTrailingActivity = trailingEntryCount == 1 && !workEntryDisplayIndicatesToolFailure(work)
      }
      var isReasoning = false
      if case .message(let message) = entry { isReasoning = message.role == .reasoning }
      if !isCompaction && !isReasoning && index > terminalEntryIndex && !isSingleTrailingActivity { continue }
      // User input and subagent batches stay visible after their turn settles.
      if case .work(let work) = entry, work.questionAnswer != nil || work.agentSpawn != nil { continue }
      hiddenEntryIds.insert(entry.id)
    }
    if hiddenEntryIds.isEmpty { continue }
    // A lone compaction row stays visible on its own; thinking is the same.
    let hidesFoldableWork = group.entries.contains { entry in
      guard hiddenEntryIds.contains(entry.id) else { return false }
      if case .work(let work) = entry, work.sourceActivityKind == "context-compaction" { return false }
      if case .message(let message) = entry, message.role == .reasoning { return false }
      return true
    }
    if !hidesFoldableWork { continue }

    guard let firstEntry = group.entries.first, let firstHidden = group.entries.first(where: { hiddenEntryIds.contains($0.id) }),
      let lastEntry = group.entries.last
    else { continue }

    let isLatestInterruptedTurn = latestTurn?.turnId == turnId && latestTurn?.state == .interrupted
    // A turn cut short by a steer leaves trailing work entries behind its terminal message.
    let lastEntryEnd: String
    switch lastEntry {
    case .message(let message): lastEntryEnd = message.updatedAt.rawValue
    default: lastEntryEnd = lastEntry.createdAt
    }
    let elapsedMs: Double?
    if latestTurn?.turnId == turnId, let started = latestTurn?.startedAt, !started.isEmpty, let completed = latestTurn?.completedAt,
      !completed.isEmpty
    {
      elapsedMs = computeElapsedMs(started, completed)
    } else {
      elapsedMs = computeElapsedMs(
        group.startBoundary ?? firstEntry.createdAt,
        maxIsoTimestamp(group.terminalUpdatedAt, lastEntryEnd) ?? lastEntryEnd
      )
    }
    let duration = elapsedMs.map(formatDuration)
    let label =
      isLatestInterruptedTurn
      ? (duration.map { "You stopped after \($0)" } ?? "You stopped this response")
      : (duration.map { "Worked for \($0)" } ?? "Worked")
    foldsByAnchorEntryId[firstHidden.id] = TurnFold(
      turnId: turnId,
      anchorEntryId: firstHidden.id,
      createdAt: firstHidden.createdAt,
      hiddenEntryIds: hiddenEntryIds,
      label: label
    )
  }
  return foldsByAnchorEntryId
}

// MARK: - Trailing tool groups

/// When a settled turn ends with tool calls after its terminal text, treat the text and tools
/// as one visual response: the message metadata becomes the footer for the whole block.
private func attachTrailingToolGroupsToAssistant(_ rows: [TimelineRow]) -> [TimelineRow] {
  var messageRowsWithoutMeta = Set<String>()
  var metaRowsAfterIndex: [Int: AssistantMetaRow] = [:]

  for (messageIndex, row) in rows.enumerated() {
    guard case .message(let messageRow) = row, messageRow.message.role == .assistant, messageRow.showAssistantMeta,
      let turnId = messageRow.message.turnId
    else { continue }

    var lastTrailingWorkIndex = -1
    var hasTrailingToolGroup = false
    var index = messageIndex + 1
    scan: while index < rows.count {
      defer { index += 1 }
      let candidate = rows[index]
      // A thinking block can follow the answer; it is not another message in the conversation.
      if case .message(let candidateMessage) = candidate {
        if candidateMessage.message.role == .reasoning { continue }
        break scan
      }
      switch candidate {
      case .workToggle(let toggle) where toggle.turnId == turnId:
        hasTrailingToolGroup = true
        lastTrailingWorkIndex = index
        continue
      case .activityGroup(let group) where group.turnId == turnId && group.entries.contains(where: { if case .work = $0 { true } else { false } }):
        hasTrailingToolGroup = true
        lastTrailingWorkIndex = index
        continue
      case .work(let work) where work.groupedEntries.contains(where: { $0.turnId == turnId }):
        if !work.isExpandedToolGroup && work.groupedEntries.contains(where: workLogEntryIsToolLike) { hasTrailingToolGroup = true }
        if hasTrailingToolGroup { lastTrailingWorkIndex = index }
      default: break
      }
    }
    if lastTrailingWorkIndex < 0 { continue }
    messageRowsWithoutMeta.insert(messageRow.id)
    metaRowsAfterIndex[lastTrailingWorkIndex] = AssistantMetaRow(
      id: "assistant-meta:\(messageRow.message.id.rawValue)",
      createdAt: rows[lastTrailingWorkIndex].createdAt ?? messageRow.message.updatedAt.rawValue,
      message: messageRow.message,
      showAssistantCopyButton: messageRow.showAssistantCopyButton,
      assistantCopyStreaming: messageRow.assistantCopyStreaming
    )
  }

  var result: [TimelineRow] = []
  result.reserveCapacity(rows.count + metaRowsAfterIndex.count)
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

/// Match each user message to the next assistant checkpoint.
private func buildRevertTurnCountByUserMessageId(
  supportsConversationRollback: Bool,
  entries: [TimelineEntry],
  summaryByAssistantMessageId: [MessageId: V1.OrchestrationCheckpointSummary],
  inferredTurnCountByTurnId: [V1.TurnId: Int]
) -> [String: Int] {
  var byUserMessageId: [String: Int] = [:]
  guard supportsConversationRollback else { return byUserMessageId }
  for (index, entry) in entries.enumerated() {
    guard case .message(let userMessage) = entry, userMessage.role == .user else { continue }
    var nextIndex = index + 1
    while nextIndex < entries.count {
      defer { nextIndex += 1 }
      guard case .message(let next) = entries[nextIndex] else { continue }
      if next.role == .user { break }
      guard let summary = summaryByAssistantMessageId[next.id] else { continue }
      // `checkpointTurnCount` is a required Int on the wire, so the inferred count is a fallback
      // the TypeScript only reaches for summaries decoded without one.
      let turnCount = summary.checkpointTurnCount
      byUserMessageId[userMessage.id.rawValue] = max(0, turnCount - 1)
      break
    }
  }
  return byUserMessageId
}

// MARK: - Derivation

public func deriveMessagesTimelineRows(_ input: TimelineRowsInput) -> [TimelineRow] {
  let entries = input.timelineEntries
  var summaryByAssistantMessageId: [MessageId: V1.OrchestrationCheckpointSummary] = [:]
  for summary in input.turnDiffSummaries {
    if let id = summary.assistantMessageId, !id.rawValue.isEmpty { summaryByAssistantMessageId[id] = summary }
  }
  let revertTurnCountByUserMessageId = buildRevertTurnCountByUserMessageId(
    supportsConversationRollback: input.supportsConversationRollback,
    entries: entries,
    summaryByAssistantMessageId: summaryByAssistantMessageId,
    inferredTurnCountByTurnId: input.supportsConversationRollback ? inferCheckpointTurnCountByTurnId(input.turnDiffSummaries) : [:]
  )
  var nextRows: [TimelineRow] = []
  let durationStartByMessageId = computeMessageDurationStart(
    entries.compactMap { if case .message(let message) = $0 { message } else { nil } }
  )
  let terminalAssistantMessageIds = deriveTerminalAssistantMessageIds(entries)
  let unsettledTurnId = deriveUnsettledTurnId(latestTurn: input.latestTurn, runningTurnId: input.runningTurnId)
  let activeVisualResponseTurnIds = deriveActiveVisualResponseTurnIds(
    entries: entries,
    unsettledTurnId: unsettledTurnId,
    isWorking: input.isWorking
  )
  let foldsByAnchorEntryId = deriveTurnFolds(
    entries: entries,
    terminalAssistantMessageIds: terminalAssistantMessageIds,
    latestTurn: input.latestTurn,
    unfoldedTurnIds: activeVisualResponseTurnIds
  )
  var collapsedEntryIds = Set<String>()
  for fold in foldsByAnchorEntryId.values where !input.expandedTurnIds.contains(fold.turnId) {
    collapsedEntryIds.formUnion(fold.hiddenEntryIds)
  }

  var activeTurnHeaderIndex = entries.count
  if input.isWorking { activeTurnHeaderIndex = lastUserMessageIndex(entries) + 1 }
  func entryBelongsToActiveTurn(_ entry: TimelineEntry, _ index: Int) -> Bool {
    input.isWorking && index >= activeTurnHeaderIndex && (unsettledTurnId == nil || timelineEntryTurnId(entry) == unsettledTurnId)
  }
  func workEntryIsInActiveRun(_ entry: WorkLogEntry) -> Bool {
    input.isWorking && unsettledTurnId != nil && entry.toolLifecycleStatus == .inProgress && entry.turnId == unsettledTurnId
  }
  // Trailing run of ordinary work entries of the live turn; positions identify them.
  var activeToolEntries: [(index: Int, entry: WorkLogEntry)] = []
  var scanIndex = entries.count - 1
  while scanIndex >= activeTurnHeaderIndex {
    let timelineEntry = entries[scanIndex]
    guard entryBelongsToActiveTurn(timelineEntry, scanIndex), case .work(let work) = timelineEntry, work.questionAnswer == nil,
      work.sourceActivityKind != "context-compaction", work.tone != .error
    else { break }
    activeToolEntries.insert((scanIndex, work), at: 0)
    if workEntryDisplayIndicatesToolFailure(work) { break }
    scanIndex -= 1
  }
  let visibleActiveToolEntries = omitSupersededLifecycleMarkers(
    activeToolEntries.filter { workEntryIsVisibleInGroup($0.entry, expandedToolGroupEntry: true) },
    workEntryFor: { $0.entry }
  )
  let activeWorkAnchor = activeToolEntries.first
  let latestVisibleToolEntry = visibleActiveToolEntries.last
  let latestRunningToolEntry = visibleActiveToolEntries.last { candidate in
    if let spawn = candidate.entry.agentSpawn {
      guard candidate.index == latestVisibleToolEntry?.index else { return false }
      return (spawn.workflowId.map { input.liveAgentTaskIds?.contains($0) == true } ?? false)
        || spawn.agentTaskIds.contains { input.liveAgentTaskIds?.contains($0) == true }
    }
    return workEntryIsActiveTurnActivity(candidate.entry)
  }
  let latestToolFailed =
    latestRunningToolEntry == nil && latestVisibleToolEntry != nil
    && latestVisibleToolEntry!.entry.toolLifecycleStatus != .declined
    && workEntryDisplayIndicatesToolFailure(latestVisibleToolEntry!.entry)
  let latestToolKeepsActivityLive =
    latestRunningToolEntry != nil
    || (latestVisibleToolEntry != nil && latestVisibleToolEntry!.entry.agentSpawn == nil
      && (workEntryIndicatesToolSuccess(latestVisibleToolEntry!.entry)
        || (latestVisibleToolEntry!.entry.toolLifecycleStatus == .completed
          && !workEntryDisplayIndicatesToolFailure(latestVisibleToolEntry!.entry))))
  let activeWorkPlacementEntryId = latestVisibleToolEntry.map { entries[$0.index].id }
  var activeWorkRow: WorkLiveRow?
  if let anchor = activeWorkAnchor, let latestVisible = latestVisibleToolEntry, !latestToolFailed {
    let anchorId = entries[anchor.index].id
    let groupId = workGroupId(anchorId, anchor.entry)
    activeWorkRow = WorkLiveRow(
      id: latestToolKeepsActivityLive ? liveActivityRowId : "work-live:\(workGroupIdentity(anchorId, anchor.entry))",
      createdAt: entries[anchor.index].createdAt,
      entry: (latestRunningToolEntry ?? latestVisible).entry,
      groupedEntries: visibleActiveToolEntries.map(\.entry),
      groupId: groupId,
      expanded: input.expandedWorkGroupIds.contains(groupId),
      active: latestToolKeepsActivityLive
    )
  }
  let activeWorkEntryIds: Set<String> =
    activeWorkRow != nil || latestToolFailed ? Set(activeToolEntries.map { entries[$0.index].id }) : []

  func appendWorkingRow() {
    let latestUserIndex = lastUserMessageIndex(entries)
    var visualResponseStartedAt = input.activeTurnStartedAt
    if activeVisualResponseTurnIds.count > 1, latestUserIndex >= 0, case .message(let message) = entries[latestUserIndex],
      message.role == .user
    {
      visualResponseStartedAt = message.createdAt.rawValue
    }
    nextRows.append(.working(LiveIndicatorRow(id: workingIndicatorRowId, createdAt: visualResponseStartedAt)))
  }
  var hasActivityRow = false
  func appendActiveWorkRows() {
    guard let activeWorkRow else { return }
    nextRows.append(.workLive(activeWorkRow))
    hasActivityRow = hasActivityRow || activeWorkRow.active
    if !activeWorkRow.expanded || activeWorkRow.entry.agentSpawn != nil { return }
    nextRows.append(expandedWorkGroupRow(activeWorkRow.groupId, activeWorkRow.createdAt, activeWorkRow.groupedEntries))
  }
  func isLiveSpawn(_ spawn: AgentSpawn) -> Bool {
    (spawn.workflowId.map { input.liveAgentTaskIds?.contains($0) == true } ?? false)
      || spawn.agentTaskIds.contains { input.liveAgentTaskIds?.contains($0) == true }
  }

  var scannedActivityThrough = -1
  var index = 0
  while index < entries.count {
    defer { index += 1 }
    let timelineEntry = entries[index]
    if input.isWorking && index == activeTurnHeaderIndex { appendWorkingRow() }
    if timelineEntry.id == activeWorkPlacementEntryId { appendActiveWorkRows() }

    if let fold = foldsByAnchorEntryId[timelineEntry.id] {
      nextRows.append(
        .turnFold(
          TurnFoldRow(
            id: "turn-fold:\(fold.turnId.rawValue)",
            createdAt: fold.createdAt,
            turnId: fold.turnId,
            label: fold.label,
            expanded: input.expandedTurnIds.contains(fold.turnId)
          )))
    }
    if collapsedEntryIds.contains(timelineEntry.id) { continue }

    let activityTurnId = timelineEntryTurnId(timelineEntry)
    if index > scannedActivityThrough, let activityTurnId, !activityTurnId.rawValue.isEmpty, let first = isActivityEntry(timelineEntry) {
      var activityEntries = [first]
      var cursor = index + 1
      while cursor < entries.count {
        let next = entries[cursor]
        guard let nextActivity = isActivityEntry(next), timelineEntryTurnId(next) == activityTurnId,
          !collapsedEntryIds.contains(next.id), foldsByAnchorEntryId[next.id] == nil
        else { break }
        activityEntries.append(nextActivity)
        cursor += 1
      }
      scannedActivityThrough = cursor - 1
      if activityEntries.contains(where: { if case .message = $0 { true } else { false } }) {
        let active =
          input.isWorking && activityTurnId == unsettledTurnId && cursor == entries.count && !latestToolFailed
          && (latestVisibleToolEntry == nil || latestToolKeepsActivityLive)
        let groupId: String
        if case .work(let work) = timelineEntry { groupId = workGroupId(timelineEntry.id, work) } else { groupId = "activity-group:\(timelineEntry.id)" }
        nextRows.append(
          .activityGroup(
            ActivityGroupRow(
              id: active ? liveActivityRowId : groupId,
              createdAt: timelineEntry.createdAt,
              turnId: activityTurnId,
              groupId: groupId,
              entries: activityEntries,
              expanded: input.expandedWorkGroupIds.contains(groupId),
              active: active
            )))
        hasActivityRow = hasActivityRow || active
        index = cursor - 1
        continue
      }
    }

    if activeWorkEntryIds.contains(timelineEntry.id) { continue }

    if case .work(let work) = timelineEntry, work.sourceActivityKind == "context-compaction" {
      nextRows.append(.contextCompaction(ContextCompactionRow(id: timelineEntry.id, createdAt: timelineEntry.createdAt, label: work.label)))
      continue
    }

    if case .work(let work) = timelineEntry {
      if work.agentSpawn != nil || work.questionAnswer != nil || work.tone == .error {
        if let spawn = work.agentSpawn, entryBelongsToActiveTurn(timelineEntry, index) {
          hasActivityRow = hasActivityRow || isLiveSpawn(spawn)
        }
        nextRows.append(
          .work(WorkRow(id: timelineEntry.id, createdAt: timelineEntry.createdAt, groupedEntries: [work], isExpandedToolGroup: false)))
        continue
      }
      var groupedEntries = [work]
      var cursor = index + 1
      while cursor < entries.count {
        guard case .work(let nextWork) = entries[cursor], nextWork.agentSpawn == nil, nextWork.questionAnswer == nil,
          nextWork.sourceActivityKind != "context-compaction", nextWork.tone != .error,
          !activeWorkEntryIds.contains(nextWork.id), !collapsedEntryIds.contains(nextWork.id),
          foldsByAnchorEntryId[nextWork.id] == nil
        else { break }
        groupedEntries.append(nextWork)
        cursor += 1
      }
      let visibleGroupedEntries = omitSupersededLifecycleMarkers(
        groupedEntries.filter { workEntryIsVisibleInGroup($0, expandedToolGroupEntry: workEntryIsInActiveRun($0)) },
        workEntryFor: { $0 }
      )
      if !visibleGroupedEntries.isEmpty {
        let activeInProgress = visibleGroupedEntries.filter(workEntryIsInActiveRun)
        if let latestActive = activeInProgress.last {
          let groupId = workGroupId(timelineEntry.id, work)
          let expanded = input.expandedWorkGroupIds.contains(groupId)
          nextRows.append(
            .workLive(
              WorkLiveRow(
                id: "work-live:\(workGroupIdentity(timelineEntry.id, work))",
                createdAt: timelineEntry.createdAt,
                entry: latestActive,
                groupedEntries: visibleGroupedEntries,
                groupId: groupId,
                expanded: expanded,
                active: true
              )))
          hasActivityRow = true
          if expanded { nextRows.append(expandedWorkGroupRow(groupId, timelineEntry.createdAt, visibleGroupedEntries)) }
        } else if visibleGroupedEntries.count == 1, workLogEntryIsToolLike(visibleGroupedEntries[0]) {
          let single = visibleGroupedEntries[0]
          nextRows.append(
            .work(
              WorkRow(
                id: timelineEntry.id,
                createdAt: timelineEntry.createdAt,
                groupedEntries: visibleGroupedEntries,
                isExpandedToolGroup: false,
                displayLabel: toolGroupAction(single) == .edit ? summarizeToolGroup(visibleGroupedEntries) : singleToolCallLabel(single)
              )))
        } else {
          let groupId = workGroupId(timelineEntry.id, work)
          let expanded = input.expandedWorkGroupIds.contains(groupId)
          let summaryKind = toolGroupSummaryKind(visibleGroupedEntries)
          let primarySourceEntry = visibleGroupedEntries.first { $0.toolSource != nil }
          let primarySourceKey = primarySourceEntry?.toolSource?.key
          let primarySourceIcon: ToolActivityIcon? =
            primarySourceKey.flatMap { key in
              visibleGroupedEntries.first { $0.toolSource?.key == key && $0.toolIcon != nil }?.toolIcon
                ?? primarySourceEntry?.toolSource?.icon
            }
          let groupToolSurface = primarySourceEntry?.toolSurface ?? visibleGroupedEntries.last { $0.toolSurface != nil }?.toolSurface
          let groupToolIcon = primarySourceIcon ?? visibleGroupedEntries.last { $0.toolIcon != nil }?.toolIcon
          let latestToolEntry = visibleGroupedEntries.last(where: workLogEntryIsToolLike)
          let singleEntry = visibleGroupedEntries.count == 1 ? visibleGroupedEntries[0] : nil
          let usesSingleToolCallLabel = singleEntry != nil && workLogEntryIsToolLike(singleEntry!) && toolGroupAction(singleEntry!) != .edit
          let summaryToolIcon = usesSingleToolCallLabel ? resolveWorkEntryToolPresentation(singleEntry!, fallbackStatus: .completed)?.icon : nil
          let summary: String
          if usesSingleToolCallLabel {
            summary = singleToolCallLabel(singleEntry!)
          } else if let singleEntry, !workLogEntryIsToolLike(singleEntry) {
            summary = singleEntry.label
          } else {
            summary = summarizeToolGroup(visibleGroupedEntries)
          }
          nextRows.append(
            .workToggle(
              WorkToggleRow(
                id: "work-toggle:\(timelineEntry.id)",
                createdAt: timelineEntry.createdAt,
                turnId: work.turnId,
                groupId: groupId,
                hiddenCount: visibleGroupedEntries.count,
                expanded: expanded,
                summary: summary,
                summaryKind: summaryKind,
                toolSurface: groupToolSurface,
                toolIcon: groupToolIcon,
                summaryToolIcon: summaryToolIcon,
                hasFailure: latestToolEntry.map(workEntryDisplayIndicatesToolFailure) ?? false
              )))
          if expanded { nextRows.append(expandedWorkGroupRow(groupId, timelineEntry.createdAt, visibleGroupedEntries)) }
        }
      }
      index = cursor - 1
      continue
    }

    if case .proposedPlan(let plan) = timelineEntry {
      nextRows.append(.proposedPlan(ProposedPlanRow(id: timelineEntry.id, createdAt: timelineEntry.createdAt, proposedPlan: plan)))
      continue
    }

    guard case .message(let message) = timelineEntry else { continue }
    let assistantResponseStillInProgress =
      message.role == .assistant && message.turnId != nil && activeVisualResponseTurnIds.contains(message.turnId!)
    let durationStart = durationStartByMessageId[message.id.rawValue] ?? message.createdAt.rawValue
    // While the turn is still running, the latest assistant message is only provisionally
    // terminal; withhold the metadata row until the turn settles.
    let showAssistantMeta =
      message.role == .assistant && terminalAssistantMessageIds.contains(message.id.rawValue) && !assistantResponseStillInProgress
    nextRows.append(
      .message(
        MessageRow(
          id: timelineEntry.id,
          createdAt: timelineEntry.createdAt,
          message: message,
          durationStart: durationStart,
          showAssistantMeta: showAssistantMeta,
          showAssistantCopyButton: showAssistantMeta,
          assistantCopyStreaming: message.streaming || assistantResponseStillInProgress,
          assistantTurnDiffSummary: message.role == .assistant ? summaryByAssistantMessageId[message.id] : nil,
          revertTurnCount: message.role == .user ? revertTurnCountByUserMessageId[message.id.rawValue] : nil
        )))
  }

  // Until the agent's turn is live, the setup card sits under the send with the working header
  // above it. A failed or cancelled setup stays under the send so its outcome stays reachable.
  var setupRunning = false
  if let setup = input.worktreeSetup {
    let setupHandedOff = worktreeSetupAgentStarted(setup) && input.latestTurn?.startedAt != nil
    setupRunning = !setupHandedOff && setup.phase == .running
    if !setupHandedOff || setup.phase != .running {
      let setupRow = WorktreeSetupRow(id: worktreeSetupRowId, createdAt: setup.startedAt.rawValue, snapshot: setup, embedded: setupHandedOff)
      let firstUserRowIndex = nextRows.firstIndex { if case .message(let row) = $0 { row.message.role == .user } else { false } }
      let workingRowIndex = setupRunning ? nextRows.firstIndex { if case .working = $0 { true } else { false } } : nil
      if let workingRowIndex {
        nextRows.insert(.worktreeSetup(setupRow), at: workingRowIndex + 1)
      } else {
        let insertAt = firstUserRowIndex.map { $0 + 1 } ?? nextRows.count
        if setupRunning {
          nextRows.insert(
            contentsOf: [
              .working(LiveIndicatorRow(id: workingIndicatorRowId, createdAt: setup.startedAt.rawValue)),
              .worktreeSetup(setupRow),
            ], at: insertAt)
        } else {
          nextRows.insert(.worktreeSetup(setupRow), at: insertAt)
        }
      }
    }
  }
  // A running setup owns the working slot above its card and shows no activity row of its own.
  let hasWorkingRow = nextRows.contains { if case .working = $0 { true } else { false } }
  if input.isWorking && !hasWorkingRow && activeTurnHeaderIndex == entries.count { appendWorkingRow() }
  if input.isWorking && !setupRunning && (!hasActivityRow || latestToolFailed) {
    nextRows.append(.thinking(LiveIndicatorRow(id: liveActivityRowId, createdAt: input.activeTurnStartedAt)))
  }
  var rows = attachTrailingToolGroupsToAssistant(nextRows)
  for (queuedIndex, queued) in input.queuedMessages.enumerated() {
    rows.append(
      .queuedMessage(
        QueuedMessageRow(id: "queued-message:\(queued.id)", createdAt: queued.createdAt, queuedMessage: queued, isNext: queuedIndex == 0)))
  }
  return rows
}
