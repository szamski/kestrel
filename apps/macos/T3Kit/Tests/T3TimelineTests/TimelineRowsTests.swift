import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

// Ported from apps/web/src/components/chat/MessagesTimeline.logic.test.ts. Entry and message ids
// are one and the same here (the TypeScript tests name them separately), so row ids use the
// message ids.

private func user(_ id: String, _ text: String = "Build it", at: String = "2026-01-01T00:00:00Z") -> TimelineEntry {
  .message(message(id, "user", text: text, at: at))
}

private func assistant(_ id: String, turn: String = "turn-1", text: String = "the answer", at: String, updatedAt: String? = nil, streaming: Bool = false)
  -> TimelineEntry
{
  .message(message(id, "assistant", text: text, turn: turn, streaming: streaming, at: at, updatedAt: updatedAt))
}

private func reasoning(_ id: String, at: String, turn: String? = "turn-1", streaming: Bool = false) -> TimelineEntry {
  .message(message(id, "reasoning", text: "weighing it up", turn: turn, streaming: streaming, at: at))
}

private func tool(_ id: String, at: String, turn: String = "turn-1", configure: (inout WorkLogEntry) -> Void = { _ in }) -> TimelineEntry {
  var entry = workEntry(id, label: "Ran a command", tone: .tool, turn: turn, at: at)
  configure(&entry)
  return .work(entry)
}

@Suite struct MessageDurationTests {
  @Test func usesTheUserMessageBoundaryForTheFirstAssistantResponse() {
    let result = computeMessageDurationStart([
      message("u", "user", at: "2026-01-01T00:00:00Z"),
      message("a", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:10Z"),
    ])
    #expect(result["u"] == "2026-01-01T00:00:00Z")
    #expect(result["a"] == "2026-01-01T00:00:00Z")
  }

  @Test func usesThePreviousCompletedAssistantUpdateForLaterResponses() {
    let result = computeMessageDurationStart([
      message("u", "user", at: "2026-01-01T00:00:00Z"),
      message("a1", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:10Z"),
      message("a2", at: "2026-01-01T00:00:11Z", updatedAt: "2026-01-01T00:00:20Z"),
    ])
    #expect(result["a2"] == "2026-01-01T00:00:10Z")
  }

  @Test func doesNotAdvanceTheBoundaryForAStreamingMessage() {
    let result = computeMessageDurationStart([
      message("u", "user", at: "2026-01-01T00:00:00Z"),
      message("a1", streaming: true, at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:10Z"),
      message("a2", at: "2026-01-01T00:00:11Z"),
    ])
    #expect(result["a2"] == "2026-01-01T00:00:00Z")
  }

  @Test func resetsOnANewUserMessageAndIgnoresSystemMessages() {
    let result = computeMessageDurationStart([
      message("u1", "user", at: "2026-01-01T00:00:00Z"),
      message("a1", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:06Z"),
      message("sys", "system", at: "2026-01-01T00:00:07Z", updatedAt: "2026-01-01T00:00:08Z"),
      message("u2", "user", at: "2026-01-01T00:00:30Z"),
      message("a2", at: "2026-01-01T00:00:35Z"),
    ])
    #expect(result["sys"] == "2026-01-01T00:00:06Z")
    #expect(result["a2"] == "2026-01-01T00:00:30Z")
    #expect(computeMessageDurationStart([message("lonely", at: "2026-01-01T00:00:01Z")])["lonely"] == "2026-01-01T00:00:01Z")
    #expect(computeMessageDurationStart([]).isEmpty)
  }
}

@Suite struct AssistantMessageHelpersTests {
  @Test func copyStateFollowsTheTerminalNonStreamingTextRules() {
    let enabled = resolveAssistantMessageCopyState(text: "  Hello  ", showCopyButton: true, streaming: false)
    #expect(enabled == AssistantCopyState(text: "  Hello  ", visible: true))
    #expect(resolveAssistantMessageCopyState(text: "Hello", showCopyButton: true, streaming: true) == AssistantCopyState(text: "Hello", visible: false))
    #expect(resolveAssistantMessageCopyState(text: "   ", showCopyButton: true, streaming: false) == AssistantCopyState(text: nil, visible: false))
    #expect(resolveAssistantMessageCopyState(text: "Hello", showCopyButton: false, streaming: false) == AssistantCopyState(text: "Hello", visible: false))
    #expect(resolveAssistantMessageCopyState(text: nil, showCopyButton: true, streaming: false) == AssistantCopyState(text: nil, visible: false))
  }

  @Test func copiesTheRenderedRepresentationWhenTheHostProvidesOne() {
    let state = resolveAssistantMessageCopyState(text: "raw", showCopyButton: true, streaming: false) { "rendered(\($0))" }
    #expect(state.text == "rendered(raw)")
    let hidden = resolveAssistantMessageCopyState(text: "raw", showCopyButton: true, streaming: true) { "rendered(\($0))" }
    #expect(hidden.text == "raw")
  }

  @Test func preservesInsightLineBreaksOnly() {
    #expect(shouldPreserveAssistantLineBreaks("★ Insight ─────────────────\nFirst observation\n─────"))
    #expect(shouldPreserveAssistantLineBreaks("intro\n★ Insight\nbody"))
    #expect(!shouldPreserveAssistantLineBreaks("A normal\nmarkdown paragraph"))
  }

  @Test func normalizesCompletionWordingOfLabels() {
    #expect(normalizeCompactToolLabel("Ran command complete") == "Ran command")
    #expect(normalizeCompactToolLabel("Read file completed ") == "Read file")
    #expect(normalizeCompactToolLabel("Completed work") == "Completed work")
  }
}

@Suite struct WorkEntryLabelTests {
  var entry: WorkLogEntry { workEntry("tool-1", label: "Tool call", tone: .tool, at: "2026-09-01T12:00:00Z") }

  @Test(arguments: [
    (ToolLifecycleStatus.inProgress, "Clicking in the preview browser"),
    (.completed, "Clicked in the preview browser"),
    (.failed, "Failed to click in the preview browser"),
    (.declined, "Declined to click in the preview browser"),
    (.stopped, "Stopped clicking in the preview browser"),
  ])
  func usesTheSameFriendlyLabelInBothViews(status: ToolLifecycleStatus, label: String) {
    var browser = entry
    browser.toolTitle = "T3-code.preview_click"
    browser.detail = #"{"ok":true}"#
    browser.toolLifecycleStatus = status
    #expect(liveWorkEntryLabel(browser, workspaceRoot: nil, active: status == .inProgress) == label)
    #expect(workEntryDisplayLabel(browser, workspaceRoot: nil) == label)
  }

  @Test func usesTheActiveSummaryStateForLegacyToolsWithoutAStatus() {
    var browser = entry
    browser.toolTitle = "T3-code.preview_click"
    #expect(liveWorkEntryLabel(browser, workspaceRoot: nil, active: true) == "Clicking in the preview browser")
    #expect(liveWorkEntryLabel(browser, workspaceRoot: nil, active: false) == "Clicked in the preview browser")
    browser.toolLifecycleStatus = .completed
    #expect(liveWorkEntryLabel(browser, workspaceRoot: nil, active: true) == "Clicking in the preview browser")
  }

  @Test func keepsCustomTitlesAndOutputForUnrecognizedTools() {
    var unknown = entry
    unknown.toolTitle = "mcp__github__search_issues"
    #expect(liveWorkEntryLabel(unknown, workspaceRoot: nil, active: true) == "Mcp__github__search_issues")
    unknown.detail = "Found 3 issues"
    #expect(workEntryDisplayLabel(unknown, workspaceRoot: nil) == "Found 3 issues")
  }

  @Test func keepsCommandSummariesCompactWithoutReplacingTheFullCommand() {
    var command = entry
    command.command = "vp test run"
    command.detail = "All tests passed"
    #expect(liveWorkEntryLabel(command, workspaceRoot: nil, active: true) == "Running vp")
    #expect(liveWorkEntryLabel(command, workspaceRoot: nil, active: false) == "Ran vp")
    #expect(workEntryDisplayLabel(command, workspaceRoot: nil) == "vp test run")
    command.command = "/bin/zsh -lc 'vp test run apps/web/src/session-logic.test.ts'"
    #expect(liveWorkEntryLabel(command, workspaceRoot: nil, active: false) == "Ran vp")
    #expect(workEntryDisplayLabel(command, workspaceRoot: nil) == command.command)
  }

  @Test(arguments: [
    (ToolLifecycleStatus.inProgress, "Running vp", "Running vp"),
    (.completed, "Running vp", "Ran vp"),
    (.failed, "Failed vp", "Failed vp"),
    (.declined, "Declined vp", "Declined vp"),
    (.stopped, "Stopped vp", "Stopped vp"),
  ])
  func usesPresentTenseForALiveCommandAndTheOutcomeOnceSettled(status: ToolLifecycleStatus, live: String, settled: String) {
    var command = entry
    command.command = "/bin/bash -lc 'vp test run'"
    command.toolLifecycleStatus = status
    #expect(liveWorkEntryLabel(command, workspaceRoot: nil, active: true) == live)
    #expect(liveWorkEntryLabel(command, workspaceRoot: nil, active: false) == settled)
  }

  @Test(arguments: [("preview_click", "Clicked in the preview browser"), ("task_status", "Got delegated task status")])
  func rendersASettledLegacyCallDirectlyWithItsCompletedPresentation(toolName: String, label: String) {
    var legacy = entry
    legacy.itemType = .mcpToolCall
    legacy.toolData = .object(["server": .string("t3-code"), "tool": .string(toolName)])
    let result = rows([.work(legacy)])
    guard case .work(let row)? = result.first(where: { $0.kind == "work" }) else {
      Issue.record("no work row")
      return
    }
    #expect(row.groupedEntries.map(\.id) == ["tool-1"])
    #expect(!row.isExpandedToolGroup)
    #expect(row.displayLabel == label)
  }

  @Test func formatsWorkspaceRelativePaths() {
    #expect(formatWorkspaceRelativePath("/w/proj/src/a.ts", workspaceRoot: "/w/proj") == "proj/src/a.ts")
    #expect(formatWorkspaceRelativePath("/w/proj/src/a.ts:12:3", workspaceRoot: "/w/proj/") == "proj/src/a.ts:12:3")
    #expect(formatWorkspaceRelativePath("src/a.ts", workspaceRoot: "/w/proj") == "proj/src/a.ts")
    #expect(formatWorkspaceRelativePath("/elsewhere/a.ts", workspaceRoot: "/w/proj") == "/elsewhere/a.ts")
    #expect(formatWorkspaceRelativePath("C:\\Work\\Proj\\src\\a.ts", workspaceRoot: "c:\\work\\proj") == "proj/src/a.ts")
    #expect(formatWorkspaceRelativePath("/w/proj", workspaceRoot: "/w/proj") == "proj")
    #expect(formatWorkspaceRelativePath("a.ts", workspaceRoot: nil) == "a.ts")
    var files = workEntry("f", label: "File change")
    files.changedFiles = ["/w/proj/a.ts", "/w/proj/b.ts"]
    #expect(workEntryDisplayLabel(files, workspaceRoot: "/w/proj") == "proj/a.ts +1 more")
  }
}

@Suite struct TimelineRowsTests {
  @Test func appendsQueuedMessagesAfterTheLiveRowsMarkingTheOldestAsNext() {
    let result = rows(
      [], isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z",
      queued: [
        QueuedMessagePlaceholder(id: "q1", createdAt: "2026-01-01T00:00:01Z", text: "first"),
        QueuedMessagePlaceholder(id: "q2", createdAt: "2026-01-01T00:00:02Z", text: "second"),
      ])
    #expect(kinds(result) == ["working", "thinking", "queued-message", "queued-message"])
    guard case .queuedMessage(let first) = result[2], case .queuedMessage(let second) = result[3] else { return }
    #expect(first.id == "queued-message:q1" && first.isNext && first.queuedMessage.text == "first")
    #expect(second.id == "queued-message:q2" && !second.isNext)
  }

  func snapshot(phase: String = "running", stages: String = "[]") -> WorktreeSetupSnapshot {
    decodeJSON(
      """
      {"threadId":"thread-setup","phase":"\(phase)","startedAt":"2026-01-01T00:00:00Z","endedAt":null,"branch":"feature","baseRef":"main",
       "worktreePath":null,"setupScript":null,"stages":\(stages),"error":null,"sequence":3}
      """)
  }

  func stage(_ id: String, _ status: String) -> String {
    #"{"id":"\#(id)","status":"\#(status)","startedAt":"2026-01-01T00:00:10Z","endedAt":null,"percent":null,"detail":null,"tail":[]}"#
  }

  @Test func leadsTheWorktreeSetupCardWithTheWorkingHeader() {
    let userEntry = user("user-1", at: "2026-01-01T00:00:00Z")
    let assistantEntry = assistant("assistant-1", text: "On it", at: "2026-01-01T00:00:30Z", streaming: true)
    let running = snapshot()
    let started = "2026-01-01T00:00:00Z"

    let alone = rows([], isWorking: true, activeTurnStartedAt: started, worktreeSetup: running)
    #expect(kinds(alone) == ["working", "worktree-setup"])
    #expect(alone.map(\.id) == ["working-indicator-row", "worktree-setup-row"])

    #expect(kinds(rows([userEntry], isWorking: true, activeTurnStartedAt: started, worktreeSetup: running)) == ["message", "working", "worktree-setup"])
    let failed = rows(
      [userEntry, assistantEntry], isWorking: true, activeTurnStartedAt: started, worktreeSetup: snapshot(phase: "failed"),
      queued: [QueuedMessagePlaceholder(id: "q1", createdAt: started, text: "later")])
    #expect(kinds(failed) == ["message", "worktree-setup", "working", "message", "thinking", "queued-message"])

    // Agent stage done and the turn live: a running script leaves the timeline.
    let asyncSnapshot = snapshot(stages: "[\(stage("setup-script", "running")),\(stage("agent", "done"))]")
    let live = latestTurn("turn-1", state: .running, started: "2026-01-01T00:00:11Z", completed: nil)
    #expect(kinds(rows([userEntry], latestTurn: live, isWorking: true, activeTurnStartedAt: started, worktreeSetup: asyncSnapshot)) == ["message", "working", "thinking"])
    // Dispatched but not yet visible as a turn: the full card stays put.
    let handoff = rows([userEntry], isWorking: true, activeTurnStartedAt: started, worktreeSetup: asyncSnapshot)
    #expect(kinds(handoff) == ["message", "working", "worktree-setup"])
    if case .worktreeSetup(let card) = handoff[2] { #expect(!card.embedded) }
    // A script that outlives the reply never trails the assistant's message.
    let settled = latestTurn("turn-1", state: .completed, started: "2026-01-01T00:00:11Z", completed: "2026-01-01T00:00:40Z")
    #expect(
      kinds(rows([userEntry, assistant("assistant-1", text: "On it", at: "2026-01-01T00:00:30Z")], latestTurn: settled, worktreeSetup: asyncSnapshot))
        == ["message", "message"])
    // A failed script after the handoff keeps its row under the send.
    let failedScript = snapshot(phase: "done", stages: "[\(stage("setup-script", "failed")),\(stage("agent", "done"))]")
    let afterHandoff = rows([userEntry], latestTurn: live, isWorking: true, activeTurnStartedAt: started, worktreeSetup: failedScript)
    #expect(kinds(afterHandoff) == ["message", "worktree-setup", "working", "thinking"])
    if case .worktreeSetup(let card) = afterHandoff[1] { #expect(card.embedded) }
  }

  @Test func keepsContextCompactionVisibleOutsideFoldedWork() {
    let compaction = workEntry("compaction", label: "Compacted context 899K → 19K tokens", tone: .info, at: "2026-01-01T00:00:00Z", kind: "context-compaction")
    let result = rows([.work(compaction)])
    #expect(kinds(result) == ["context-compaction"])
    guard case .contextCompaction(let row) = result[0] else { return }
    #expect(row.label == "Compacted context 899K → 19K tokens")
    #expect(row.id == "compaction")
  }

  @Test func keepsSubagentSpawnRowsOutsideTurnFoldsEvenAfterTheySettle() {
    func entries(_ spawn: AgentSpawn) -> [TimelineEntry] {
      var batch = workEntry("spawn-entry", label: "Ran 2 subagents", tone: .tool, turn: "turn-1", at: "2026-01-01T00:00:03Z")
      batch.agentSpawn = spawn
      return deriveTimelineEntries(
        messages: [
          message("assistant-first-entry", text: "Fanning out.", at: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:02Z"),
          message("assistant-final-entry", text: "Done.", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:06Z"),
        ], proposedPlans: [], workEntries: [batch])
    }
    let direct = entries(AgentSpawn(workflowId: nil, agentTaskIds: ["agent-a", "agent-b"]))
    let workflow = entries(AgentSpawn(workflowId: "wf-1", agentTaskIds: ["wf-1", "agent-a"]))
    let unfolded = ["turn-fold:turn-1", "spawn-entry", "assistant-final-entry"]
    func ids(_ timeline: [TimelineEntry], live: Set<String>?, expanded: Set<String> = []) -> [String] {
      rows(timeline, expandedTurnIds: expanded, liveAgentTaskIds: live).map(\.id)
    }
    func active(_ timeline: [TimelineEntry], live: Set<String>, running: String = "turn-1") -> [String] {
      kinds(rows(Array(timeline.prefix(2)), runningTurnId: running, isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z", liveAgentTaskIds: live))
    }
    #expect(!active(direct, live: ["agent-b"]).contains("thinking"))
    #expect(!active(workflow, live: ["wf-1"]).contains("thinking"))
    #expect(active(direct, live: []).contains("thinking"))
    #expect(active(direct, live: ["agent-b"], running: "turn-2").contains("thinking"))

    #expect(ids(direct, live: []) == unfolded)
    #expect(ids(direct, live: ["agent-b"]) == unfolded)
    #expect(ids(workflow, live: ["wf-1"]) == unfolded)
    #expect(ids(direct, live: nil) == unfolded)
    #expect(ids(direct, live: [], expanded: ["turn-1"]) == ["turn-fold:turn-1", "assistant-first-entry", "spawn-entry", "assistant-final-entry"])
  }

  @Test func onlyEnablesAssistantCopyForTheTerminalAssistantMessageOfATurn() {
    let result = rows(
      [
        user("user-1", "Write a poem"),
        assistant("assistant-thought", text: "I should ground this first.", at: "2026-01-01T00:00:10Z", updatedAt: "2026-01-01T00:00:11Z"),
        assistant("assistant-final", text: "Here is the poem.", at: "2026-01-01T00:00:20Z", updatedAt: "2026-01-01T00:00:30Z"),
      ], expandedTurnIds: ["turn-1"])
    let copy = result.compactMap { row -> Bool? in
      if case .message(let message) = row, message.message.role == .assistant { return message.showAssistantCopyButton }
      return nil
    }
    #expect(copy == [false, true])
  }

  @Test func marksOnlyTheActiveAssistantTurnAsStreamingForCopyControls() {
    let result = rows(
      [
        assistant("assistant-one", text: "Earlier response.", at: "2026-01-01T00:00:10Z", updatedAt: "2026-01-01T00:00:11Z"),
        assistant("assistant-two", turn: "turn-2", text: "Active response.", at: "2026-01-01T00:00:20Z", updatedAt: "2026-01-01T00:00:30Z"),
      ],
      latestTurn: latestTurn("turn-2", state: .running, started: "2026-01-01T00:00:19Z", completed: nil))
    let streaming = result.compactMap { row -> Bool? in
      if case .message(let message) = row { return message.assistantCopyStreaming }
      return nil
    }
    #expect(streaming == [false, true])
  }

  @Test func projectsDiffSummariesAndRevertCountsOntoTheAffectedRows() {
    let summary: V1.OrchestrationCheckpointSummary = decodeJSON(
      """
      {"turnId":"turn-1","checkpointTurnCount":2,"checkpointRef":"checkpoint-1","status":"ready",
       "files":[{"path":"src/index.ts","kind":"modified","additions":3,"deletions":1}],
       "assistantMessageId":"assistant-1","completedAt":"2026-01-01T00:00:30Z"}
      """)
    let result = rows(
      [user("user-1", "Do the thing"), assistant("assistant-1", text: "Done", at: "2026-01-01T00:00:20Z", updatedAt: "2026-01-01T00:00:30Z")],
      summaries: [summary], rollback: true)
    guard case .message(let userRow) = result[0], case .message(let assistantRow) = result.last! else {
      Issue.record("unexpected rows \(kinds(result))")
      return
    }
    #expect(userRow.revertTurnCount == 1)
    #expect(assistantRow.assistantTurnDiffSummary == summary)
    #expect(summarizeTurnDiffStats(summary.files) == TurnDiffStat(additions: 3, deletions: 1))
  }

  @Test func foldsTheFirstAssistantMessageAndSettledWorkBeforeTheTerminalResponse() {
    let entries: [TimelineEntry] = [
      user("user-entry", "Build it"),
      assistant("assistant-first-entry", text: "Synthetic deployment checklist", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:06Z"),
      .work(workEntry("work-entry-1", label: "Ran command", turn: "turn-1", at: "2026-01-01T00:00:08Z")),
      assistant("assistant-final-entry", text: "Done", at: "2026-01-01T00:00:20Z", updatedAt: "2026-01-01T00:00:22Z"),
    ]
    let collapsed = rows(entries)
    #expect(collapsed.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-final-entry"])
    guard case .turnFold(let fold) = collapsed[1] else { return }
    #expect(fold.turnId == "turn-1" && !fold.expanded)
    // User message boundary (00:00:00) to the terminal message update (00:00:22).
    #expect(fold.label == "Worked for 22s")
    let expanded = rows(entries, expandedTurnIds: ["turn-1"])
    #expect(expanded.map(\.id) == ["user-entry", "turn-fold:turn-1", "assistant-first-entry", "work-entry-1", "assistant-final-entry"])
  }

  @Test func keepsAToolGroupAfterTheTerminalResponseVisibleWhenTheTurnIsFolded() {
    var entries: [TimelineEntry] = [
      .work(workEntry("work-before-text", label: "Status updated", tone: .info, turn: "turn-1", at: "2026-01-01T00:00:01Z")),
      assistant("assistant-final", text: "I could not finish the task.", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:06Z"),
    ]
    for index in 0..<3 {
      entries.append(
        tool("work-after-text-\(index)", at: "2026-01-01T00:00:0\(index + 7)Z") {
          $0.label = "Ran command"
          $0.itemType = .commandExecution
          $0.toolLifecycleStatus = .completed
        })
    }
    let turn = latestTurn("turn-1", state: .error, started: "2026-01-01T00:00:00Z", completed: "2026-01-01T00:00:10Z")
    let result = rows(entries, latestTurn: turn)
    #expect(result.map(\.id) == ["turn-fold:turn-1", "assistant-final", "work-toggle:work-after-text-0", "assistant-meta:assistant-final"])
    guard case .workToggle(let toggle) = result[2], case .assistantMeta(let meta) = result[3], case .message(let answer) = result[1] else { return }
    #expect(toggle.hiddenCount == 3 && toggle.summary == "Ran 3 commands")
    #expect(meta.showAssistantCopyButton)
    #expect(!answer.showAssistantMeta && !answer.showAssistantCopyButton)
    #expect(rows(Array(entries.prefix(3)), latestTurn: turn).map(\.id) == ["turn-fold:turn-1", "assistant-final"])
  }

  @Test func foldsAllAssistantMessagesBeforeTheTerminalMessage() {
    let result = rows([
      assistant("assistant-first-entry", text: "The main result is ready.", at: "2026-01-01T00:00:01Z", updatedAt: "2026-01-01T00:00:02Z"),
      assistant("assistant-middle-entry", text: "Checking one more detail.", at: "2026-01-01T00:00:03Z", updatedAt: "2026-01-01T00:00:04Z"),
      assistant("assistant-final-entry", text: "Verification finished.", at: "2026-01-01T00:00:05Z", updatedAt: "2026-01-01T00:00:06Z"),
    ])
    #expect(result.map(\.id) == ["turn-fold:turn-1", "assistant-final-entry"])
  }

  @Test func keepsAllThoughtsInOneActivityRowAsTheCurrentAndEarlierTracesStream() {
    let entries = (1...4).map { reasoning("reasoning-\($0)", at: "2026-01-01T00:00:0\($0)Z", streaming: $0 == 2 || $0 == 4) }
    let result = rows(entries, runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z")
    #expect(kinds(result) == ["working", "activity-group"])
    guard case .activityGroup(let group) = result[1] else { return }
    #expect(group.id == "live-activity-row" && group.active && !group.expanded)
    #expect(group.entries.map(\.id) == entries.map(\.id))
  }

  @Test func updatesTheSameCollapsedRowAsToolsAndThoughtsAlternate() {
    let first = reasoning("thought-first", at: "2026-01-01T00:00:01Z")
    let current = reasoning("thought-current", at: "2026-01-01T00:00:02Z", streaming: true)
    let running = tool("tool-current", at: "2026-01-01T00:00:03Z") {
      $0.command = "pwd"
      $0.toolLifecycleStatus = .inProgress
    }
    let next = reasoning("thought-next", at: "2026-01-01T00:00:04Z", streaming: true)
    for entries in [[first, current], [first, current, running], [first, current, running, next]] {
      let result = rows(entries, runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z")
      #expect(kinds(result) == ["working", "activity-group"])
      guard case .activityGroup(let group) = result[1] else { return }
      #expect(group.id == "live-activity-row" && group.active && !group.expanded)
      #expect(group.entries.map(\.id) == entries.map(\.id))
      let opened = rows(
        entries, runningTurnId: "turn-1", expandedWorkGroupIds: ["activity-group:thought-first"], isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z")
      if case .activityGroup(let expanded) = opened[1] { #expect(expanded.expanded) }
    }
  }

  @Test(arguments: ["assistant", "user", "error", "turn"])
  func keepsActivitySeparateAcrossABoundary(boundary: String) {
    let first = reasoning("reasoning-first", at: "2026-01-01T00:00:01Z")
    let last = reasoning("reasoning-last", at: "2026-01-01T00:00:03Z", turn: boundary == "turn" ? "turn-2" : "turn-1")
    var middle: [TimelineEntry] = []
    switch boundary {
    case "turn": break
    case "error": middle = [tool("error-between", at: "2026-01-01T00:00:02Z") { $0.tone = .error }]
    case "user": middle = [user("answer-between", "the answer", at: "2026-01-01T00:00:02Z")]
    default: middle = [assistant("answer-between", at: "2026-01-01T00:00:02Z")]
    }
    let result = rows([first] + middle + [last], expandedTurnIds: ["turn-1", "turn-2"])
    let groups = result.compactMap { row -> ActivityGroupRow? in if case .activityGroup(let group) = row { group } else { nil } }
    #expect(groups.map { $0.entries.map(\.id) } == [["reasoning-first"], ["reasoning-last"]])
    #expect(groups.allSatisfy { !$0.active })
    if boundary == "error" { #expect(result.contains { $0.id == "error-between" && $0.kind == "work" }) }
  }

  @Test func doesNotCombineThoughtsWithoutAKnownTurn() {
    let thoughts = (1...2).map { reasoning("unknown-\($0)", at: "2026-01-01T00:00:0\($0)Z", turn: nil) }
    #expect(rows(thoughts).map(\.id) == ["unknown-1", "unknown-2"])
  }

  @Test func keepsAThoughtOnlyTurnOutOfTheWorkFold() {
    let result = rows([reasoning("reasoning-entry", at: "2026-01-01T00:00:01Z"), assistant("assistant-entry", at: "2026-01-01T00:00:02Z")])
    #expect(!kinds(result).contains("turn-fold"))
    guard case .activityGroup(let group)? = result.first(where: { $0.kind == "activity-group" }) else { return }
    #expect(group.entries.map(\.id) == ["reasoning-entry"] && !group.expanded)
  }

  @Test func keepsTheAssistantFooterBeforeATrailingThoughtOnlyGroup() {
    let result = rows([assistant("assistant-entry", at: "2026-01-01T00:00:01Z"), reasoning("reasoning-after", at: "2026-01-01T00:00:02Z")])
    #expect(kinds(result) == ["message", "activity-group"])
    if case .message(let answer) = result[0] { #expect(answer.showAssistantMeta) }
  }

  @Test(arguments: [ToolLifecycleStatus.failed, .declined])
  func settlesTheActivityRowWhileTheLatestToolHasFailed(status: ToolLifecycleStatus) {
    let result = rows(
      [
        reasoning("reasoning-entry", at: "2026-01-01T00:00:01Z"),
        tool("last-tool", at: "2026-01-01T00:00:02Z") {
          $0.command = "echo nope"
          $0.toolCallId = "last-tool"
          $0.toolLifecycleStatus = status
          $0.sourceActivityKind = "tool.completed"
        },
      ], runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z")
    #expect(kinds(result) == ["working", "activity-group", "thinking"])
    guard case .activityGroup(let group) = result[1] else { return }
    #expect(group.id == "activity-group:reasoning-entry" && !group.active)
    #expect(result[2].id == "live-activity-row")
  }

  @Test func foldsMixedActivityUnderWorkedForAndRestoresOrderedDetailsWhenExpanded() {
    let entries = [
      reasoning("reasoning-entry", at: "2026-01-01T00:00:01Z"),
      tool("tool-entry", at: "2026-01-01T00:00:02Z"),
      reasoning("reasoning-next", at: "2026-01-01T00:00:03Z"),
    ]
    let all = entries + [assistant("assistant-entry", at: "2026-01-01T00:00:04Z")]
    #expect(kinds(rows(all)) == ["turn-fold", "message"])
    let expanded = rows(all, expandedTurnIds: ["turn-1"])
    let groups = expanded.compactMap { row -> ActivityGroupRow? in if case .activityGroup(let group) = row { group } else { nil } }
    #expect(groups.count == 1 && groups[0].entries.map(\.id) == entries.map(\.id) && !groups[0].expanded && !groups[0].active)
    let details = rows(all, expandedTurnIds: ["turn-1"], expandedWorkGroupIds: ["activity-group:reasoning-entry"])
    if case .activityGroup(let group)? = details.first(where: { $0.kind == "activity-group" }) { #expect(group.expanded) }
    #expect(rows(all) == rows(all))
  }

  @Test func stillFoldsALoneTrailingToolCallWhenAThoughtFollowsTheAnswer() {
    let ids = rows([
      tool("tool-before", at: "2026-01-01T00:00:01Z"),
      assistant("assistant-entry", at: "2026-01-01T00:00:02Z"),
      reasoning("reasoning-after", at: "2026-01-01T00:00:03Z"),
      tool("tool-after", at: "2026-01-01T00:00:04Z"),
    ]).map(\.id)
    #expect(!ids.contains("tool-after") && !ids.contains("reasoning-after"))
  }

  @Test func doesNotLetAStrandedStreamingThoughtHoldASettledTurnOpen() {
    let result = rows([
      reasoning("reasoning-stranded", at: "2026-01-01T00:00:01Z", streaming: true),
      tool("tool-entry", at: "2026-01-01T00:00:02Z"),
      assistant("assistant-entry", at: "2026-01-01T00:00:03Z"),
    ])
    #expect(kinds(result).contains("turn-fold"))
  }

  @Test func usesLatestTurnTimingsAndTheStoppedLabelForAnInterruptedLatestTurn() {
    let entries: [TimelineEntry] = [
      user("u1", at: "2026-01-01T00:00:00Z"),
      assistant("a1", text: "Partial.", at: "2026-01-01T00:00:03Z", updatedAt: "2026-01-01T00:00:03Z"),
      tool("t1", at: "2026-01-01T00:00:04Z"),
    ]
    let interrupted = latestTurn("turn-1", state: .interrupted, started: "2026-01-01T00:00:00Z", completed: "2026-01-01T00:00:12Z")
    guard case .turnFold(let fold)? = rows(entries, latestTurn: interrupted).first(where: { $0.kind == "turn-fold" }) else {
      Issue.record("expected a fold")
      return
    }
    #expect(fold.label == "You stopped after 12s")
  }

  @Test func doesNotFoldTheActiveInProgressTurn() {
    let result = rows(
      [
        user("u1", at: "2026-01-01T00:00:00Z"),
        assistant("a1", text: "Working.", at: "2026-01-01T00:00:03Z"),
        tool("t1", at: "2026-01-01T00:00:04Z"),
      ], runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:01Z")
    #expect(!kinds(result).contains("turn-fold"))
  }

  @Test func keepsAPromptlessRestartInOneActiveVisualResponse() {
    let result = rows(
      [
        user("u1", at: "2026-01-01T00:00:00Z"),
        assistant("a1", turn: "turn-1", text: "First attempt", at: "2026-01-01T00:00:02Z"),
        assistant("a2", turn: "turn-2", text: "Second attempt", at: "2026-01-01T00:00:10Z"),
      ], runningTurnId: "turn-2", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:09Z")
    #expect(!kinds(result).contains("turn-fold"))
    // The working header counts from the user message while two provider turns are one response.
    guard case .working(let header)? = result.first(where: { $0.kind == "working" }) else {
      Issue.record("expected a working row")
      return
    }
    #expect(header.createdAt == "2026-01-01T00:00:00Z")
  }

  @Test func rendersASingleCompletedToolCallDirectly() {
    // Without a turn there is nothing to fold behind "Worked for".
    var single = workEntry("t1", label: "Ran command", tone: .tool, at: "2026-01-01T00:00:01Z")
    single.command = "git status"
    single.itemType = .commandExecution
    single.toolLifecycleStatus = .completed
    let result = rows([.work(single)])
    #expect(kinds(result) == ["work"])
    guard case .work(let row) = result[0] else { return }
    #expect(row.displayLabel == "git status" && row.groupedEntries.count == 1)
  }

  @Test func groupsSeveralToolCallsBehindOneToggle() {
    func command(_ id: String, _ second: Int, _ text: String) -> TimelineEntry {
      var entry = workEntry(id, label: "Ran command", tone: .tool, at: "2026-01-01T00:00:0\(second)Z")
      entry.command = text
      entry.itemType = .commandExecution
      entry.toolLifecycleStatus = .completed
      entry.toolCallId = id
      return .work(entry)
    }
    let entries = [command("c1", 1, "ls"), command("c2", 2, "pwd")]
    let collapsed = rows(entries)
    guard case .workToggle(let toggle) = collapsed[0] else {
      Issue.record("expected a toggle")
      return
    }
    #expect(toggle.summary == "Ran 2 commands" && toggle.summaryKind == .command && toggle.hiddenCount == 2)
    let expanded = rows(entries, expandedWorkGroupIds: [toggle.groupId])
    #expect(kinds(expanded) == ["work-toggle", "work"])
    if case .work(let details) = expanded[1] { #expect(details.isExpandedToolGroup && details.id == "\(toggle.groupId):details") }
  }

  @Test func keepsAnActuallyRunningToolInTheSharedActivityRow() {
    let result = rows(
      [
        user("u1", at: "2026-01-01T00:00:00Z"),
        tool("t1", at: "2026-01-01T00:00:01Z") {
          $0.command = "sleep 10"
          $0.itemType = .commandExecution
          $0.toolLifecycleStatus = .inProgress
          $0.toolCallId = "t1"
        },
      ], runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z")
    #expect(kinds(result) == ["message", "working", "work-live"])
    guard case .workLive(let live) = result[2] else { return }
    #expect(live.id == "live-activity-row" && live.active && live.entry.id == "t1")
  }

  @Test func onlyShowsAssistantMetadataOnTheTerminalMessageAndWithholdsItWhileWorking() {
    let entries: [TimelineEntry] = [
      user("u1", at: "2026-01-01T00:00:00Z"),
      assistant("a-first", text: "Looking.", at: "2026-01-01T00:00:02Z"),
      assistant("a-final", text: "Done.", at: "2026-01-01T00:00:08Z"),
    ]
    func meta(_ result: [TimelineRow]) -> [String: Bool] {
      Dictionary(uniqueKeysWithValues: result.compactMap { row in if case .message(let m) = row { (m.id, m.showAssistantMeta) } else { nil } })
    }
    #expect(meta(rows(entries, expandedTurnIds: ["turn-1"])) == ["u1": false, "a-first": false, "a-final": true])
    #expect(meta(rows(entries, runningTurnId: "turn-1", isWorking: true, activeTurnStartedAt: "2026-01-01T00:00:00Z"))["a-final"] == false)
  }

  @Test func keepsUserInputInItsOwnRowThroughToolGroupingAndTurnFolding() {
    var answer = workEntry("answer-row", label: "User input submitted", tone: .tool, turn: "turn-1", at: "2026-01-01T00:00:03Z", kind: "user-input.answer-submitted")
    answer.questionAnswer = UserInputAnswer(requestId: "r1", questionTextById: nil, answers: ["q": .string("a")], attachmentsByQuestionId: [:])
    let result = rows([
      tool("t0", at: "2026-01-01T00:00:01Z") { $0.command = "ls"; $0.itemType = .commandExecution; $0.toolLifecycleStatus = .completed },
      .work(answer),
      assistant("final", at: "2026-01-01T00:00:05Z"),
    ])
    #expect(result.map(\.id).contains("answer-row"))
    #expect(kinds(result).contains("turn-fold"))
  }
}

@Suite struct ScrollAndMinimapTests {
  @Test func followsAppendedCallsOnlyAtTheHardEnd() {
    #expect(shouldFollowWorkGroupAppend(previous: ["a"], entries: ["a", "b"], distanceFromEnd: 0))
    #expect(!shouldFollowWorkGroupAppend(previous: ["a"], entries: ["a", "b"], distanceFromEnd: 20))
    #expect(!shouldFollowWorkGroupAppend(previous: ["a", "b"], entries: ["a", "b"], distanceFromEnd: 0))
    #expect(!shouldFollowWorkGroupAppend(previous: ["a"], entries: ["x", "a"], distanceFromEnd: 0))
    #expect(!shouldFollowWorkGroupAppend(previous: [], entries: ["a"], distanceFromEnd: 0))
  }

  @Test func restoresTheVisibleToolAndItsOffset() {
    let restored = resolveWorkGroupScrollIndex(entryIds: ["a", "b", "c"], anchor: WorkGroupScrollAnchor(entryId: "b", offset: 30))
    #expect(restored?.index == 1 && restored?.viewOffset == -30)
    #expect(resolveWorkGroupScrollIndex(entryIds: ["a"], anchor: WorkGroupScrollAnchor(entryId: "gone", offset: 1)) == nil)
    #expect(resolveWorkGroupScrollIndex(entryIds: ["a"], anchor: nil) == nil)
  }

  @Test func savesTheRowAtTheCurrentScrollOffset() {
    let tops: [Double] = [0, 100, 250, 400]
    let anchor = resolveWorkGroupScrollAnchor(entryIds: ["a", "b", "c", "d"], scroll: 260) { tops[$0] }
    #expect(anchor?.rowId == "c" && anchor?.offsetWithinRow == 10 && anchor?.scrollOffset == 260)
    #expect(resolveWorkGroupScrollAnchor(entryIds: [], scroll: 0) { _ in 0 } == nil)
    #expect(resolveWorkGroupScrollAnchor(entryIds: ["a"], scroll: .nan) { _ in 0 } == nil)
    #expect(resolveWorkGroupScrollAnchor(entryIds: ["a", "b"], scroll: 5) { $0 == 1 ? nil : 0 } == nil)
  }

  @Test func rearmsFollowWithinAStrictBandAboveTheBottom() {
    #expect(resolveTimelineIsAtEnd(nil) == nil)
    #expect(resolveTimelineIsAtEnd(TimelineEndState(isAtEnd: true)) == true)
    #expect(resolveTimelineIsAtEnd(TimelineEndState(isAtEnd: true, contentLength: 1000, scroll: 100, scrollLength: 800)) == false)
    #expect(resolveTimelineIsAtEnd(TimelineEndState(isAtEnd: false, contentLength: 1000, scroll: 170, scrollLength: 800)) == true)
  }

  @Test func derivesMinimapItemsFromUserMessageRows() {
    let result = rows(
      [
        user("u1", "  first   question\nover lines ", at: "2026-01-01T00:00:00Z"),
        assistant("a1", text: "answer one", at: "2026-01-01T00:00:02Z"),
        user("u2", "second", at: "2026-01-01T00:00:10Z"),
      ])
    let items = deriveTimelineMinimapItems(result)
    #expect(items.map(\.id) == ["u1", "u2"])
    #expect(items[0].assistantText == "answer one" && items[1].assistantText == nil)
    #expect(resolveTimelineMinimapPreview(items[0]).userText == "first question over lines")
    #expect(resolveTimelineMinimapPreview(TimelineMinimapItem(id: "x", rowIndex: 0, userText: "   ", assistantText: nil)).userText == nil)
  }

  @Test func resolvesMinimapPositions() {
    #expect(resolveTimelineMinimapTopPercent(index: 0, itemCount: 1) == 0)
    #expect(resolveTimelineMinimapTopPercent(index: 1, itemCount: 3) == 50)
    #expect(resolveTimelineMinimapTopPercent(index: 9, itemCount: 3) == 100)
    #expect(resolveTimelineMinimapIndexFromPointer(itemCount: 5, railTop: 100, railHeight: 80, pointerY: 140) == 2)
    #expect(resolveTimelineMinimapIndexFromPointer(itemCount: 5, railTop: 100, railHeight: 0, pointerY: 140) == nil)
    #expect(resolveTimelineMinimapIndexFromPointer(itemCount: 1, railTop: 0, railHeight: 10, pointerY: 99) == 0)
    let bounds = [
      TimelineMinimapItemBounds(top: nil, height: nil), TimelineMinimapItemBounds(top: 0, height: 100), TimelineMinimapItemBounds(top: 300, height: 100),
    ]
    #expect(resolveTimelineMinimapCurrentIndex(scrollTop: 50, scrollBottom: 150, itemBounds: bounds) == 1)
    #expect(resolveTimelineMinimapCurrentIndex(scrollTop: 150, scrollBottom: 250, itemBounds: bounds) == 1)
    #expect(resolveTimelineMinimapHasPersistentGutter(viewportWidth: 1000, contentWidth: 800))
    #expect(!resolveTimelineMinimapHasPersistentGutter(viewportWidth: 800, contentWidth: 780))
    #expect(resolveTimelineMinimapHitStripWidth(viewportWidth: 1000, contentWidth: 800) == 40)
    #expect(resolveTimelineMinimapHitStripWidth(viewportWidth: 800, contentWidth: 790) == 0)
  }
}
