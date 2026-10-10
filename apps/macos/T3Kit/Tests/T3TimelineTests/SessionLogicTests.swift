import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

// Ported from apps/web/src/session-logic.test.ts (plans, proposed plans, work log derivation,
// timeline entries, turn timing).

@Suite struct ActivePlanTests {
  func plan(_ id: String, at: String, turn: String = "turn-1", sequence: Int? = nil, _ payload: String) -> V1.OrchestrationThreadActivity {
    activity(id, "turn.plan.updated", summary: "Plan updated", tone: "info", turn: turn, sequence: sequence, at: at, payload)
  }

  @Test func ordersPlanSnapshotsBySequenceIgnoringUnrelatedActivities() {
    let activities = [
      plan("completed", at: "2026-02-23T00:00:05.000Z", sequence: 3, #"{"plan":[{"step":"Check","status":"completed"}]}"#),
      activity("a", "tool.completed", sequence: 4),
      plan("started", at: "2026-02-23T00:00:00.000Z", sequence: 1, #"{"plan":[{"step":"Check","status":"inProgress"}]}"#),
      activity("b", "context-window.updated", sequence: 2),
    ]
    let steps = deriveActivePlanState(activities: activities, latestTurnId: "turn-1")?.steps
    #expect(steps == [.init(durationMs: 5_000, step: "Check", status: .completed)])
    #expect(deriveActivePlanState(activities: [activity("c", "tool.completed")], latestTurnId: nil) == nil)
  }

  @Test func returnsTheLatestPlanUpdateForTheActiveTurn() {
    let activities = [
      plan("old", at: "2026-02-23T00:00:01.000Z", #"{"explanation":"Initial plan","plan":[{"step":"Inspect code","status":"pending"}]}"#),
      plan("latest", at: "2026-02-23T00:00:02.000Z", #"{"explanation":"Refined plan","plan":[{"step":"Implement","status":"inProgress"}]}"#),
    ]
    let state = deriveActivePlanState(activities: activities, latestTurnId: "turn-1")
    #expect(state?.createdAt == "2026-02-23T00:00:02.000Z")
    #expect(state?.explanation == .some("Refined plan"))
    #expect(state?.steps == [.init(durationMs: nil, step: "Implement", status: .inProgress)])
  }

  @Test func fallsBackToTheMostRecentPlanFromAPreviousTurn() {
    let activities = [plan("p", at: "2026-02-23T00:00:01.000Z", #"{"plan":[{"step":"Write tests","status":"completed"}]}"#)]
    let state = deriveActivePlanState(activities: activities, latestTurnId: "turn-2")
    #expect(state?.turnId == "turn-1")
    #expect(state?.explanation == nil)
    #expect(state?.steps.map(\.step) == ["Write tests"])
  }

  @Test func startsTimingAgainAfterAPlanIsClearedAndRecreated() {
    let activities = [
      plan("s1", at: "2026-02-23T00:00:01.000Z", #"{"plan":[{"step":"Check","status":"inProgress"}]}"#),
      plan("c1", at: "2026-02-23T00:00:05.000Z", #"{"plan":[{"step":"Check","status":"completed"}]}"#),
      plan("clear", at: "2026-02-23T00:00:06.000Z", #"{"plan":[]}"#),
      plan("s2", at: "2026-02-23T00:00:10.000Z", #"{"plan":[{"step":"Check","status":"inProgress"}]}"#),
      plan("c2", at: "2026-02-23T00:00:13.000Z", #"{"plan":[{"step":"Check","status":"completed"}]}"#),
    ]
    #expect(deriveActivePlanState(activities: activities, latestTurnId: "turn-1")?.steps.map(\.durationMs) == [3_000])
  }

  @Test func tracksRepeatedStepLabelsIndependently() {
    let activities = [
      plan("a", at: "2026-02-23T00:00:01.000Z", #"{"plan":[{"step":"Check","status":"inProgress"},{"step":"Check","status":"pending"}]}"#),
      plan("b", at: "2026-02-23T00:00:05.000Z", #"{"plan":[{"step":"Check","status":"completed"},{"step":"Check","status":"inProgress"}]}"#),
      plan("c", at: "2026-02-23T00:00:11.000Z", #"{"plan":[{"step":"Check","status":"completed"},{"step":"Check","status":"completed"}]}"#),
    ]
    #expect(deriveActivePlanState(activities: activities, latestTurnId: "turn-1")?.steps.map(\.durationMs) == [4_000, 6_000])
  }

  @Test func derivesFallbackDurationsInCompletionOrder() {
    let activities = [
      plan("a", at: "2026-02-23T00:00:01.000Z", #"{"plan":[{"step":"First","status":"pending"},{"step":"Second","status":"pending"}]}"#),
      plan("b", at: "2026-02-23T00:00:06.000Z", #"{"plan":[{"step":"First","status":"pending"},{"step":"Second","status":"completed"}]}"#),
      plan("c", at: "2026-02-23T00:00:11.000Z", #"{"plan":[{"step":"First","status":"completed"},{"step":"Second","status":"completed"}]}"#),
    ]
    #expect(deriveActivePlanState(activities: activities, latestTurnId: "turn-1")?.steps.map(\.durationMs) == [5_000, 5_000])
  }

  @Test func clearsTheActivePlanWhenALaterSnapshotHasNoSteps() {
    let activities = [
      plan("set", at: "2026-02-23T00:00:01.000Z", #"{"plan":[{"step":"Inspect code","status":"inProgress"}]}"#),
      plan("clear", at: "2026-02-23T00:00:02.000Z", #"{"plan":[]}"#),
    ]
    #expect(deriveActivePlanState(activities: activities, latestTurnId: "turn-1") == nil)
  }
}

@Suite struct ProposedPlanTests {
  func plan(_ id: String, turn: String?, _ markdown: String, created: String, updated: String, implemented: String? = nil) -> ProposedPlan {
    ProposedPlan(
      id: id, turnId: turn.map { V1.TurnId($0) }, planMarkdown: markdown, implementedAt: implemented.map { IsoDateTime($0) },
      implementationThreadId: implemented == nil ? nil : ThreadId("thread-implement"), createdAt: IsoDateTime(created), updatedAt: IsoDateTime(updated))
  }

  @Test func prefersTheLatestProposedPlanForTheActiveTurn() {
    let plans = [
      plan("plan:thread-1:turn:turn-1", turn: "turn-1", "# Older", created: "2026-02-23T00:00:01.000Z", updated: "2026-02-23T00:00:01.000Z"),
      plan("plan:thread-1:turn:turn-1", turn: "turn-1", "# Latest", created: "2026-02-23T00:00:01.000Z", updated: "2026-02-23T00:00:02.000Z"),
      plan("plan:thread-1:turn:turn-2", turn: "turn-2", "# Different turn", created: "2026-02-23T00:00:03.000Z", updated: "2026-02-23T00:00:03.000Z"),
    ]
    #expect(findLatestProposedPlan(plans, latestTurnId: "turn-1")?.planMarkdown == "# Latest")
  }

  @Test func fallsBackToTheMostRecentlyUpdatedProposedPlan() {
    let plans = [
      plan("p1", turn: "turn-1", "# First", created: "2026-02-23T00:00:01.000Z", updated: "2026-02-23T00:00:01.000Z"),
      plan("p2", turn: "turn-2", "# Latest", created: "2026-02-23T00:00:02.000Z", updated: "2026-02-23T00:00:03.000Z"),
    ]
    #expect(findLatestProposedPlan(plans, latestTurnId: nil)?.planMarkdown == "# Latest")
  }

  @Test func actionableUntilImplemented() {
    let open = plan("p", turn: "turn-1", "# Plan", created: "2026-02-23T00:00:00.000Z", updated: "2026-02-23T00:00:01.000Z")
    let done = plan("p", turn: "turn-1", "# Plan", created: "2026-02-23T00:00:00.000Z", updated: "2026-02-23T00:00:02.000Z", implemented: "2026-02-23T00:00:02.000Z")
    #expect(hasActionableProposedPlan(findLatestProposedPlan([open], latestTurnId: nil)))
    #expect(!hasActionableProposedPlan(findLatestProposedPlan([done], latestTurnId: nil)))
    #expect(!hasActionableProposedPlan(nil))
  }
}

@Suite struct NeutralStatusTests {
  @Test func keepsActiveToolsNeutralAndAgentSpawnsVisible() {
    var entry = workEntry("work-1", label: "Read")
    entry.toolLifecycleStatus = .inProgress
    #expect(workEntryIndicatesToolNeutralStatus(entry))
    var spawn = entry
    spawn.agentSpawn = AgentSpawn(workflowId: nil, agentTaskIds: ["agent-1"])
    #expect(!workEntryIndicatesToolNeutralStatus(spawn))
    entry.toolLifecycleStatus = .completed
    #expect(!workEntryIndicatesToolNeutralStatus(entry))
  }

  @Test(arguments: ["waiting", "cancelled", "interrupted"])
  func keepsTheStatusOfABackgroundTask(status: String) throws {
    let entries = deriveWorkLogEntries([
      activity("bg", "task.progress", #"{"taskId":"background-1","agentKind":"background","status":"\#(status)"}"#)
    ])
    #expect(entries.count == 1)
    #expect(entries[0].toolLifecycleStatus == (status == "waiting" ? .inProgress : .stopped))
    #expect(workEntryIndicatesToolNeutralStatus(entries[0]))
  }
}

@Suite struct WorkLogDerivationTests {
  func ids(_ activities: [V1.OrchestrationThreadActivity]) -> [String] { deriveWorkLogEntries(activities).map(\.id) }

  @Test func keepsTheLatestTaskProgressWithoutEmittingPlanUpdateEntries() {
    let activities = [
      activity("before", "tool.completed", summary: "Read files", sequence: 0),
      activity("plan-1", "turn.plan.updated", summary: "Plan updated", turn: "turn-1", sequence: 1, #"{"plan":[{"step":"Verify","status":"inProgress"}]}"#),
      activity("plan-2", "turn.plan.updated", summary: "Plan updated", turn: "turn-1", sequence: 2, #"{"plan":[{"step":"Verify","status":"completed"}]}"#),
      activity("after", "tool.completed", summary: "Ran tests", sequence: 3),
    ]
    #expect(ids(activities) == ["before", "after"])
    #expect(deriveActivePlanState(activities: activities, latestTurnId: "turn-1")?.steps.first?.status == .completed)
  }

  @Test func omitsToolStartedAndKeepsCompleted() {
    let activities = [
      activity("tool-complete", "tool.completed", summary: "Tool call complete", at: "2026-02-23T00:00:03.000Z"),
      activity("tool-start", "tool.started", at: "2026-02-23T00:00:02.000Z"),
    ]
    #expect(ids(activities) == ["tool-complete"])
  }

  @Test func omitsRoutineSetupUpdatesButKeepsFailuresAndUnrelatedInfo() {
    let setup = [
      activity("setup-requested", "setup-script.requested", summary: "Preparing setup script", tone: "info", sequence: 1),
      activity("setup-started", "setup-script.started", summary: "Setup script started", tone: "info", sequence: 2),
    ]
    #expect(ids(setup).isEmpty)
    let entries = deriveWorkLogEntries(
      setup + [
        activity("setup-failed", "setup-script.failed", summary: "Setup script failed to start", tone: "error", sequence: 2, #"{"detail":"Could not start the setup terminal"}"#),
        activity("runtime-notice", "runtime.warning", summary: "Reconnecting to provider", tone: "info", sequence: 3),
      ])
    #expect(entries.map(\.id) == ["setup-failed", "runtime-notice"])
    #expect(entries[0].label == "Setup script failed to start")
    #expect(entries[0].tone == .error)
    #expect(entries[0].detail == "Could not start the setup terminal")
    #expect(entries[0].turnId == nil)
    #expect(entries[1].tone == .info)
  }

  @Test func dropsRuntimeWarningsWithNoDisplayableContent() {
    let activities = [
      activity("noise", "runtime.warning", summary: "Claude system message 'background_tasks_changed' (no displayable text content)", tone: "info", at: "2026-02-23T00:00:01.000Z"),
      activity("signal", "runtime.warning", summary: "Reconnecting... 2/5", tone: "info", at: "2026-02-23T00:00:02.000Z"),
    ]
    #expect(ids(activities) == ["signal"])
  }

  @Test func omitsTaskStartedButShowsProgressAndCompleted() {
    let activities = [
      activity("task-start", "task.started", summary: "default task started", tone: "info", at: "2026-02-23T00:00:01.000Z", #"{"agentKind":"background"}"#),
      activity("task-progress", "task.progress", summary: "Updating files", tone: "info", at: "2026-02-23T00:00:02.000Z", #"{"agentKind":"background"}"#),
      activity("task-complete", "task.completed", summary: "Task completed", tone: "info", at: "2026-02-23T00:00:03.000Z", #"{"agentKind":"background"}"#),
    ]
    #expect(ids(activities) == ["task-progress", "task-complete"])
  }

  @Test func usesPayloadSummaryAndDetailAsTaskLabels() {
    let progress = activity("p", "task.progress", summary: "Reasoning update", tone: "info", #"{"summary":"Searching for API endpoints","agentKind":"background"}"#)
    #expect(deriveWorkLogEntries([progress])[0].label == "Searching for API endpoints")
    let failed = activity("f", "task.completed", summary: "Task failed", tone: "error", #"{"detail":"Failed to deploy changes","agentKind":"background"}"#)
    let entry = deriveWorkLogEntries([failed])[0]
    #expect(entry.label == "Failed to deploy changes")
    #expect(entry.tone == .error)
  }

  @Test func keepsToolEntriesFromEveryTurnAndTagsTheirTurn() {
    let activities = [
      activity("turn-1-tool", "tool.completed", summary: "Tool call complete", turn: "turn-1"),
      activity("turn-2-tool", "tool.completed", summary: "Tool call complete", turn: "turn-2"),
    ]
    let entries = deriveWorkLogEntries(activities)
    #expect(entries.map(\.id) == ["turn-1-tool", "turn-2-tool"])
    #expect(entries.map(\.turnId) == [V1.TurnId("turn-1"), V1.TurnId("turn-2")])
  }

  @Test func omitsCheckpointCapturedAndExitPlanModeEntries() {
    let activities = [
      activity("checkpoint", summary: "Checkpoint captured", tone: "info", at: "2026-02-23T00:00:01.000Z"),
      activity("exit-updated", "tool.updated", at: "2026-02-23T00:00:01.000Z", #"{"detail":"ExitPlanMode: {\"allowedPrompts\":[]}"}"#),
      activity("exit-completed", "tool.completed", at: "2026-02-23T00:00:02.000Z", #"{"detail":"ExitPlanMode: {}"}"#),
      activity("real", "tool.completed", summary: "Ran command", at: "2026-02-23T00:00:03.000Z", #"{"itemType":"command_execution","detail":"Bash: bun test"}"#),
    ]
    #expect(ids(activities) == ["real"])
  }

  @Test func ordersByActivitySequenceWhenPresent() {
    let both = [
      activity("second", "tool.completed", sequence: 2, at: "2026-02-23T00:00:03.000Z"),
      activity("first", "tool.completed", sequence: 1, at: "2026-02-23T00:00:04.000Z"),
    ]
    #expect(ids(both) == ["first", "second"])
    // Rows without a sequence sort before rows that have one.
    let mixed = [
      activity("sequenced", "tool.completed", sequence: 1, at: "2026-02-23T00:00:04.000Z"),
      activity("plain", "tool.completed", at: "2026-02-23T00:00:05.000Z"),
    ]
    #expect(ids(mixed) == ["plain", "sequenced"])
  }

  @Test func extractsCommandTextAndLifecycleStatus() {
    let command = deriveWorkLogEntries([
      activity("c", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","data":{"item":{"command":["bun","run","lint"]}}}"#)
    ])[0]
    #expect(command.command == "bun run lint")
    let failed = deriveWorkLogEntries([
      activity("f", "tool.updated", summary: "Glob", #"{"itemType":"mcp_tool_call","status":"failed","detail":"No files found"}"#)
    ])[0]
    #expect(failed.toolLifecycleStatus == .failed)
    let done = deriveWorkLogEntries([
      activity("d", "tool.completed", summary: "Glob", #"{"itemType":"mcp_tool_call","detail":"Found 3 files"}"#)
    ])[0]
    #expect(done.toolLifecycleStatus == .completed)
  }

  @Test func preservesMcpIdentityPresentationAndResults() throws {
    let item = #"{"type":"mcpToolCall","server":"t3-code","tool":"preview_status","arguments":{},"status":"completed","result":{"content":[{"type":"text","text":"attached"}]}}"#
    let entry = deriveWorkLogEntries([
      activity(
        "mcp", "tool.completed", summary: "t3-code · preview_status",
        """
        {"itemType":"mcp_tool_call","title":"t3-code · preview_status","toolSurface":"browser",
         "toolIcon":{"_tag":"website","pageUrl":"https://example.com/checkout"},
         "toolSource":{"key":"browser-use:browser","name":"Browser","kind":"browser"},"data":{"item":\(item)}}
        """)
    ])[0]
    #expect(entry.toolTitle == "t3-code · preview_status")
    #expect(entry.toolSurface == .browser)
    #expect(entry.toolIcon == .website(pageUrl: "https://example.com/checkout", faviconUrl: nil, faviconUrlDark: nil))
    #expect(entry.toolSource == ToolActivitySource(key: "browser-use:browser", name: "Browser", kind: .browser, icon: nil))
    #expect(entry.toolData == decodeJSON(JSONValue.self, item))
  }

  @Test(arguments: [
    ("inProgress", "Clicking in the preview browser"),
    ("completed", "Clicked in the preview browser"),
    ("failed", "Failed to click in the preview browser"),
  ])
  func preservesClaudeMcpIdentityBehindGenericTitles(status: String, displayName: String) {
    let result = status == "inProgress" ? "" : #","result":{"type":"tool_result","is_error":\#(status == "failed"),"content":"Result"}"#
    let entry = deriveWorkLogEntries([
      activity(
        "claude", status == "inProgress" ? "tool.updated" : "tool.completed", summary: "MCP tool call",
        ##"{"itemType":"mcp_tool_call","title":"MCP tool call","status":"\##(status)","data":{"toolName":"mcp__t3_code__preview_click","input":{"selector":"#submit"}\##(result)}}"##)
    ])[0]
    #expect(entry.toolTitle == "MCP tool call")
    #expect(resolveWorkEntryToolPresentation(entry)?.displayName == displayName)
    #expect(resolveWorkEntryToolPresentation(entry)?.icon == .browser)
  }

  @Test func keepsMcpPayloadsWhileCollapsingLifecycleUpdates() {
    let item = #"{"type":"mcpToolCall","server":"t3-code","tool":"preview_snapshot","arguments":{"interactiveOnly":true},"status":"completed"}"#
    let entries = deriveWorkLogEntries([
      activity("progress", "tool.updated", summary: "t3-code · preview_snapshot", #"{"itemType":"mcp_tool_call","toolCallId":"call-1","toolSurface":"browser","data":{"item":\#(item)}}"#),
      activity("complete", "tool.completed", summary: "t3-code · preview_snapshot", #"{"itemType":"mcp_tool_call","toolCallId":"call-1","toolIcon":{"_tag":"website","pageUrl":"https://example.com/result"}}"#),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].toolData == decodeJSON(JSONValue.self, item))
    #expect(entries[0].toolCallId == "call-1")
    #expect(entries[0].toolSurface == .browser)
    #expect(entries[0].toolIcon == .website(pageUrl: "https://example.com/result", faviconUrl: nil, faviconUrlDark: nil))
    #expect(resolveWorkEntryToolPresentation(entries[0])?.displayName == "Took a snapshot of the preview page")
  }

  @Test func collapsesInterleavedLifecycleUpdatesByToolCallId() {
    func tool(_ id: String, _ kind: String, _ call: String, _ second: Int, status: String, command: String? = nil) -> V1.OrchestrationThreadActivity {
      activity(
        id, kind, summary: "Tool", turn: "turn-1", at: "2026-02-23T00:00:0\(second).000Z",
        #"{"itemType":"command_execution","toolCallId":"\#(call)","status":"\#(status)"\#(command.map { #","data":{"command":"\#($0)"}"# } ?? "")}"#)
    }
    let entries = deriveWorkLogEntries([
      tool("a-progress", "tool.updated", "call-a", 1, status: "inProgress", command: "vp test run"),
      tool("b-progress", "tool.updated", "call-b", 2, status: "inProgress", command: "vp lint"),
      tool("a-complete", "tool.completed", "call-a", 3, status: "completed"),
      tool("b-complete", "tool.completed", "call-b", 4, status: "completed"),
    ])
    #expect(entries.map(\.id) == ["a-complete", "b-complete"])
    #expect(entries.map(\.command) == ["vp test run", "vp lint"])
    #expect(entries.map(\.toolLifecycleStatus) == [.completed, .completed])
  }

  @Test func doesNotMergeReusedToolCallIdsAcrossTurns() {
    let entries = deriveWorkLogEntries([
      activity("t1", "tool.updated", turn: "turn-1", at: "2026-02-23T00:00:01.000Z", #"{"itemType":"command_execution","toolCallId":"reused-call","status":"inProgress"}"#),
      activity("t2", "tool.completed", turn: "turn-2", at: "2026-02-23T00:00:02.000Z", #"{"itemType":"command_execution","toolCallId":"reused-call","status":"completed"}"#),
    ])
    #expect(entries.count == 2)
  }

  @Test func unwrapsPowerShellWrappersForDisplayedCommandText() {
    let wrapped = #""C:\\Program Files\\PowerShell\\7\\pwsh.exe" -Command 'bun run lint'"#
    let entry = deriveWorkLogEntries([
      activity("w", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","data":{"item":{"command":"\#(wrapped.replacingOccurrences(of: "\"", with: "\\\""))"}}}"#)
    ])[0]
    #expect(entry.command == "bun run lint")
    #expect(entry.rawCommand == #""C:\Program Files\PowerShell\7\pwsh.exe" -Command 'bun run lint'"#)
  }

  @Test func unwrapsPowerShellWrappersFromArgvPayloads() {
    let entry = deriveWorkLogEntries([
      activity("w", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","data":{"item":{"command":["C:\\Program Files\\PowerShell\\7\\pwsh.exe","-Command","rg -n foo ."]}}}"#)
    ])[0]
    #expect(entry.command == "rg -n foo .")
    #expect(entry.rawCommand == #""C:\Program Files\PowerShell\7\pwsh.exe" -Command "rg -n foo .""#)
  }

  @Test func extractsCommandTextFromDetailWhenStructuredMetadataIsMissing() {
    let detail = #"\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo -NoProfile -Command 'rg -n -F \"new Date()\" .' <exited with exit code 0>"#
    let entry = deriveWorkLogEntries([
      activity("d", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","detail":"\#(detail)"}"#)
    ])[0]
    #expect(entry.command == #"rg -n -F "new Date()" ."#)
    #expect(entry.rawCommand == #""C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -Command 'rg -n -F "new Date()" .'"#)
  }

  @Test func doesNotUnwrapShellCommandsWithoutAWrapperFlag() {
    let entry = deriveWorkLogEntries([
      activity("s", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","data":{"item":{"command":"bash script.sh"}}}"#)
    ])[0]
    #expect(entry.command == "bash script.sh")
    #expect(entry.rawCommand == nil)
  }

  @Test func preservesSerializedShellWrappersWithNonMatchingBoundaryQuotes() {
    let command = "/bin/zsh -lc 'git status\nsed -n '\"'1,20p' apps/web/src/components/DiffPanel.tsx\""
    let escaped = try! String(decoding: JSONEncoder().encode(command), as: UTF8.self)
    let entry = deriveWorkLogEntries([
      activity("s", "tool.completed", summary: "Ran command", #"{"itemType":"command_execution","data":{"item":{"command":\#(escaped)}}}"#)
    ])[0]
    #expect(entry.command == command)
    #expect(entry.rawCommand == nil)
  }

  @Test func keepsCompactCodexToolMetadata() {
    let entry = deriveWorkLogEntries([
      activity(
        "m", "tool.completed", summary: "bash",
        #"{"itemType":"command_execution","title":"bash","status":"completed","detail":"{ \"dev\": \"vite dev --port 3000\" } <exited with exit code 0>","data":{"item":{"command":["bun","run","dev"],"result":{"content":"{ \"dev\": \"vite dev --port 3000\" } <exited with exit code 0>","exitCode":0}}}}"#)
    ])[0]
    #expect(entry.command == "bun run dev")
    #expect(entry.detail == #"{ "dev": "vite dev --port 3000" }"#)
    #expect(entry.itemType == .commandExecution)
    #expect(entry.toolTitle == "bash")
  }

  @Test func extractsChangedFilePaths() {
    let entry = deriveWorkLogEntries([
      activity("f", "tool.completed", summary: "File change", #"{"itemType":"file_change","data":{"item":{"changes":[{"path":"apps/web/src/components/ChatView.tsx"},{"filename":"apps/web/src/session-logic.ts"}]}}}"#)
    ])[0]
    #expect(entry.changedFiles == ["apps/web/src/components/ChatView.tsx", "apps/web/src/session-logic.ts"])
  }

  @Test func dropsDuplicatedToolDetailThatOnlyRepeatsTheTitle() {
    let entry = deriveWorkLogEntries([
      activity("r", "tool.completed", summary: "Read File", #"{"itemType":"dynamic_tool_call","title":"Read File","detail":"Read File"}"#)
    ])[0]
    #expect(entry.toolTitle == "Read File")
    #expect(entry.detail == nil)
  }

  @Test func usesGrepRawOutputSummariesAndCollapsesTheSameToolCall() {
    let entries = deriveWorkLogEntries([
      activity("u", "tool.updated", summary: "grep", at: "2026-02-23T00:00:01.000Z", #"{"itemType":"web_search","title":"grep","detail":"grep","data":{"toolCallId":"tool-grep-1","kind":"search","rawInput":{}}}"#),
      activity("c", "tool.completed", summary: "grep", at: "2026-02-23T00:00:02.000Z", #"{"itemType":"web_search","title":"grep","detail":"grep","data":{"toolCallId":"tool-grep-1","kind":"search","rawOutput":{"totalFiles":19,"truncated":false}}}"#),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].id == "c")
    #expect(entries[0].detail == "19 files")
  }

  @Test func usesCompletedReadFileOutputPreviews() {
    let entries = deriveWorkLogEntries([
      activity("u", "tool.updated", summary: "Read File", at: "2026-02-23T00:00:01.000Z", #"{"itemType":"dynamic_tool_call","title":"Read File","detail":"Read File","data":{"toolCallId":"tool-read-1","kind":"read","rawInput":{}}}"#),
      activity("c", "tool.completed", summary: "Read File", at: "2026-02-23T00:00:02.000Z", #"{"itemType":"dynamic_tool_call","title":"Read File","detail":"Read File","data":{"toolCallId":"tool-read-1","kind":"read","rawOutput":{"content":"import * as Effect from \"effect/Effect\"\nimport * as Layer from \"effect/Layer\"\n"}}}"#),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].detail == #"import * as Effect from "effect/Effect""#)
  }

  @Test func doesNotUseCommandStdoutAsDetailWhenCursorOmitsTheCommand() {
    let entry = deriveWorkLogEntries([
      activity(
        "cursor", "tool.completed", summary: "Ran command",
        #"{"itemType":"command_execution","title":"Ran command","data":{"toolCallId":"toolu_x","kind":"execute","rawInput":{},"rawOutput":{"exitCode":0,"stdout":"total 960\napps\npackages\n","stderr":""}}}"#)
    ])[0]
    #expect(entry.label == "Ran command")
    #expect(entry.detail == nil)
    #expect(entry.command == nil)
  }

  @Test func collapsesRepeatedLifecycleUpdatesForTheSameToolCall() {
    let detail = #""detail":"Read: {\"file_path\":\"/tmp/app.ts\"}""#
    let entries = deriveWorkLogEntries([
      activity("u1", "tool.updated", at: "2026-02-23T00:00:01.000Z", #"{"itemType":"dynamic_tool_call","title":"Tool call",\#(detail)}"#),
      activity("u2", "tool.updated", at: "2026-02-23T00:00:02.000Z", #"{"itemType":"dynamic_tool_call","title":"Tool call",\#(detail),"data":{"item":{"command":["sed","-n","1,40p","/tmp/app.ts"]}}}"#),
      activity("done", "tool.completed", summary: "Tool call completed", at: "2026-02-23T00:00:03.000Z", #"{"itemType":"dynamic_tool_call","title":"Tool call",\#(detail)}"#),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].id == "done")
    #expect(entries[0].createdAt == "2026-02-23T00:00:03.000Z")
    #expect(entries[0].label == "Tool call completed")
    #expect(entries[0].command == "sed -n 1,40p /tmp/app.ts")
  }

  @Test func keepsSeparateEntriesWhenAnIdenticalCallStartsAfterThePriorCompleted() {
    let detail = #""detail":"Read: {\"file_path\":\"/tmp/app.ts\"}""#
    func tool(_ id: String, _ kind: String, _ second: Int) -> V1.OrchestrationThreadActivity {
      activity(id, kind, at: "2026-02-23T00:00:0\(second).000Z", #"{"itemType":"dynamic_tool_call","title":"Tool call",\#(detail)}"#)
    }
    #expect(ids([tool("1u", "tool.updated", 1), tool("1c", "tool.completed", 2), tool("2u", "tool.updated", 3), tool("2c", "tool.completed", 4)]) == ["1c", "2c"])
  }

  @Test func collapsesSameTimestampLifecycleRowsEvenWhenCompletedSortsBeforeUpdatedById() {
    let payload = #"{"itemType":"dynamic_tool_call","title":"Tool call","detail":"Read: {\"file_path\":\"/tmp/app.ts\"}"}"#
    let entries = deriveWorkLogEntries([
      activity("z-update-earlier", "tool.updated", at: "2026-02-23T00:00:01.000Z", payload),
      activity("a-complete-same-timestamp", "tool.completed", at: "2026-02-23T00:00:02.000Z", payload),
      activity("z-update-same-timestamp", "tool.updated", at: "2026-02-23T00:00:02.000Z", payload),
    ])
    #expect(entries.map(\.id) == ["a-complete-same-timestamp"])
  }

  @Test func excludesContextWindowUpdatesAndKeepsCompaction() {
    #expect(ids([activity("w", "context-window.updated", summary: "Context window updated", tone: "info")]).isEmpty)
    let compaction = deriveWorkLogEntries([activity("c", "context-compaction", summary: "Compacted context 233K → 38.4K tokens", tone: "info", #"{"state":"compacted"}"#)])
    #expect(compaction.map(\.sourceActivityKind) == ["context-compaction"])
  }
}

@Suite struct QuietTimelineTests {
  func agent(_ taskId: String, _ extra: String = "") -> String { #"{"taskId":"\#(taskId)","agentKind":"agent"\#(extra)}"# }

  @Test func concurrentSubagentsReplaceTheirLaunchToolsWithOneLifecycleRow() {
    let entries = deriveWorkLogEntries([
      activity("launch", "tool.updated", turn: "turn-1", at: "2026-02-23T00:00:01.000Z", #"{"itemType":"collab_agent_tool_call","toolCallId":"toolu-1","status":"inProgress","title":"Subagent task","data":{"toolName":"Agent"}}"#),
      activity("start-a", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:02.000Z", agent("a", #","toolUseId":"toolu-1","role":"coder""#)),
      activity("start-b", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:03.000Z", agent("b")),
      activity("progress-a", "task.progress", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:04.000Z", agent("a", #","summary":"reading""#)),
      activity("done-a", "task.completed", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:05.000Z", agent("a", #","status":"completed","summary":"A done""#)),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].agentSpawn == AgentSpawn(workflowId: nil, agentTaskIds: ["a", "b"]))
    #expect(entries[0].id == "start-a")
    #expect(entries[0].turnId == V1.TurnId("turn-1"))
  }

  @Test func aWorkflowRunAndItsMembersCollapseIntoOneRowKeyedToTheCoordinator() {
    let entries = deriveWorkLogEntries([
      activity("coordinator", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:01.000Z", agent("wf-1", #","taskType":"local_workflow","workflowName":"audit""#)),
      activity("member", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:02.000Z", agent("wf-1:wf:m1")),
      activity("member-progress", "task.progress", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:03.000Z", agent("wf-1:wf:m1", #","summary":"step""#)),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].agentSpawn?.workflowId == "wf-1")
    #expect(entries[0].agentSpawn?.agentTaskIds == ["wf-1", "wf-1:wf:m1"])
  }

  @Test func foldsTimelineBypassAgentRowsIntoOneRowAndSuppressesBypassedBackgroundShells() {
    let entries = deriveWorkLogEntries([
      activity("s", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:01.000Z", agent("cx", #","timelineBypass":true"#)),
      activity("p", "task.progress", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:02.000Z", agent("cx", #","timelineBypass":true,"summary":"x""#)),
      activity("bg", "task.progress", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:03.000Z", #"{"taskId":"sh","agentKind":"background","agentId":"owner","summary":"hidden"}"#),
    ])
    #expect(entries.count == 1)
    #expect(entries[0].agentSpawn?.agentTaskIds == ["cx"])
  }

  @Test func dropsTaskUpdatedAndToolProgressFromTheWorkLog() {
    let entries = deriveWorkLogEntries([
      activity("u", "task.updated", tone: "info", agent("a", #","status":"running""#)),
      activity("p", "tool.progress", tone: "info", #"{"taskId":"a","toolName":"Read"}"#),
    ])
    #expect(entries.isEmpty)
  }

  @Test func turnlessDirectSpawnsDoNotCollapseIntoOneGlobalBatch() {
    let entries = deriveWorkLogEntries([
      activity("a", "task.started", tone: "info", at: "2026-02-23T00:00:01.000Z", agent("t-a")),
      activity("b", "task.started", tone: "info", at: "2026-02-23T00:00:02.000Z", agent("t-b")),
    ])
    #expect(entries.map(\.id) == ["a", "b"])
  }

  @Test func eachWorkflowRunGetsItsOwnRow() {
    let entries = deriveWorkLogEntries([
      activity("c1", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:01.000Z", agent("wf-a", #","taskType":"local_workflow""#)),
      activity("c2", "task.started", tone: "info", turn: "turn-1", at: "2026-02-23T00:00:02.000Z", agent("wf-b", #","taskType":"local_workflow""#)),
    ])
    #expect(entries.map(\.id) == ["c1", "c2"])
  }
}

@Suite struct TimelineEntryTests {
  @Test func includesProposedPlansAlongsideMessagesAndWorkEntriesChronologically() {
    let plan = ProposedPlan(
      id: "plan-1", turnId: "turn-1", planMarkdown: "# Plan", implementedAt: nil, implementationThreadId: nil,
      createdAt: "2026-02-23T00:00:02.000Z", updatedAt: "2026-02-23T00:00:02.000Z")
    let entries = deriveTimelineEntries(
      messages: [message("m1", "user", at: "2026-02-23T00:00:01.000Z"), message("m2", at: "2026-02-23T00:00:04.000Z")],
      proposedPlans: [plan],
      workEntries: [workEntry("w1", at: "2026-02-23T00:00:03.000Z")]
    )
    #expect(entries.map(\.id) == ["m1", "plan-1", "w1", "m2"])
  }

  @Test func tiesKeepMessagesBeforePlansBeforeWork() {
    let at = "2026-02-23T00:00:01.000Z"
    let plan = ProposedPlan(id: "p", turnId: nil, planMarkdown: "", implementedAt: nil, implementationThreadId: nil, createdAt: IsoDateTime(at), updatedAt: IsoDateTime(at))
    let entries = deriveTimelineEntries(
      messages: [message("m", at: at)], proposedPlans: [plan], workEntries: [workEntry("w", at: at)])
    #expect(entries.map(\.id) == ["m", "p", "w"])
  }

  @Test func foldsAnAsyncAnswerIntoItsWorkRowInsteadOfShowingAUserMessage() {
    var answered = workEntry("answer", at: "2026-02-23T00:00:02.000Z", kind: "user-input.answer-submitted")
    answered.questionAnswer = UserInputAnswer(requestId: "codex-async:1", questionTextById: nil, answers: [:], attachmentsByQuestionId: [:])
    let entries = deriveTimelineEntries(
      messages: [message("async-answer:codex-async:1", "user", at: "2026-02-23T00:00:03.000Z"), message("other", "user", at: "2026-02-23T00:00:04.000Z")],
      proposedPlans: [],
      workEntries: [answered]
    )
    #expect(entries.map(\.id) == ["answer", "other"])
  }
}

@Suite struct TurnTimingTests {
  let session = { (status: String, active: String?) -> V1.OrchestrationSession in
    decodeJSON(
      """
      {"threadId":"t","status":"\(status)","providerName":"codex","providerInstanceId":"codex","runtimeMode":"full-access",
       "activeTurnId":\(active.map { "\"\($0)\"" } ?? "null"),"lastError":null,"updatedAt":"2026-02-23T00:00:00.000Z"}
      """)
  }

  @Test func latestTurnSettledOnlyWithTimestampsAndANonRunningSession() {
    let settled = latestTurn(started: "2026-02-23T00:00:00.000Z", completed: "2026-02-23T00:00:10.000Z")
    #expect(isLatestTurnSettled(latestTurn: settled, session: nil))
    #expect(isLatestTurnSettled(latestTurn: settled, session: session("ready", nil)))
    #expect(!isLatestTurnSettled(latestTurn: settled, session: session("running", "turn-1")))
    #expect(!isLatestTurnSettled(latestTurn: latestTurn(started: nil, completed: "2026-02-23T00:00:10.000Z"), session: nil))
    #expect(!isLatestTurnSettled(latestTurn: latestTurn(started: "2026-02-23T00:00:00.000Z", completed: nil), session: nil))
    #expect(!isLatestTurnSettled(latestTurn: nil, session: nil))
  }

  @Test func activeWorkStartPrefersTheInFlightTurnThenTheSendThenTheLatestUserMessage() {
    let running = latestTurn(state: .running, started: "2026-02-23T00:00:05.000Z")
    #expect(deriveActiveWorkStartedAt(latestTurn: running, session: session("running", "turn-1"), sendStartedAt: "2026-02-23T00:00:09.000Z") == "2026-02-23T00:00:05.000Z")
    #expect(deriveActiveWorkStartedAt(latestTurn: running, session: session("running", "turn-2"), sendStartedAt: "2026-02-23T00:00:09.000Z") == "2026-02-23T00:00:09.000Z")
    #expect(
      deriveActiveWorkStartedAt(latestTurn: nil, session: session("running", "turn-9"), sendStartedAt: nil, latestUserMessageAt: "2026-02-23T00:00:07.000Z")
        == "2026-02-23T00:00:07.000Z")
    let settled = latestTurn(started: "2026-02-23T00:00:00.000Z", completed: "2026-02-23T00:00:10.000Z")
    #expect(deriveActiveWorkStartedAt(latestTurn: settled, session: session("ready", nil), sendStartedAt: "2026-02-23T00:00:20.000Z") == "2026-02-23T00:00:20.000Z")
    #expect(deriveActiveWorkStartedAt(latestTurn: settled, session: nil, sendStartedAt: nil) == nil)
  }

  @Test func derivesThePhaseOfASession() {
    #expect(derivePhase(nil) == .disconnected)
    #expect(derivePhase(session("stopped", nil)) == .disconnected)
    #expect(derivePhase(session("error", nil)) == .disconnected)
    #expect(derivePhase(session("interrupted", nil)) == .disconnected)
    #expect(derivePhase(session("starting", nil)) == .connecting)
    #expect(derivePhase(session("running", "t")) == .running)
    #expect(derivePhase(session("ready", nil)) == .ready)
    #expect(derivePhase(session("idle", nil)) == .ready)
  }

  @Test func formatsDurations() {
    #expect(formatDuration(-1) == "0ms")
    #expect(formatDuration(0.2) == "1ms")
    #expect(formatDuration(999) == "999ms")
    #expect(formatDuration(1_000) == "1.0s")
    #expect(formatDuration(9_960) == "10s")
    #expect(formatDuration(12_400) == "12s")
    #expect(formatDuration(60_000) == "1m")
    #expect(formatDuration(3_725_000) == "1h 2m 5s")
  }

  @Test func parsesTimestampsLikeDateParse() {
    #expect(jsDateParse("2026-01-01T00:00:00Z") == 1_767_225_600_000)
    #expect(jsDateParse("2026-01-01T00:00:00.123456Z") == 1_767_225_600_123)
    #expect(jsDateParse("2026-01-01T01:00:00+01:00") == 1_767_225_600_000)
    #expect(jsDateParse("not a date") == nil)
  }
}
