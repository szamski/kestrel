import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

// Ported from packages/client-runtime/src/work-log/presentation.test.ts and toolPresentation.test.ts.

private func entry(
  _ label: String = "Tool call",
  tone: WorkLogTone = .tool,
  status: ToolLifecycleStatus? = nil,
  itemType: ToolLifecycleItemType? = nil,
  command: String? = nil,
  detail: String? = nil,
  toolData: String? = nil
) -> WorkLogEntry {
  var value = workEntry("w1", label: label, tone: tone, at: "2026-01-01T00:00:00.000Z")
  value.toolLifecycleStatus = status
  value.itemType = itemType
  value.command = command
  value.detail = detail
  value.toolData = toolData.map { decodeJSON(JSONValue.self, $0) }
  return value
}

@Suite struct ToolFailureTests {
  @Test func errorToneAndFailedLifecycleAreFailures() {
    #expect(workEntryIndicatesToolFailure(entry("Read", tone: .error, detail: "nothing special")))
    #expect(workEntryIndicatesToolFailure(entry("Read", status: .failed)))
  }

  @Test func detectsFailureStyleOutputOfCompletedTools() {
    #expect(workEntryIndicatesToolFailure(entry("Read", status: .completed, detail: "File not found: C:\\foo\\nonexistent.ts")))
    #expect(workEntryIndicatesToolFailure(entry("Glob", detail: "No files found")))
    #expect(
      workEntryIndicatesToolFailure(
        entry("Bash", detail: "The term 'this_is_not_a_command' is not recognized as the name of a cmdlet, function, script file, or operable program.")))
    #expect(workEntryIndicatesToolFailure(entry("Bash", detail: "oops <exited with exit code 2>")))
    #expect(!workEntryIndicatesToolFailure(entry("Bash", detail: "done <exited with exit code 0>")))
    #expect(!workEntryIndicatesToolFailure(entry("Read", status: .completed, detail: "Found 3 matching files")))
  }

  @Test func doesNotTreatErrorTextInACommandAsRenderedFailure() {
    let value = entry("Ran command", status: .completed, command: #"rg "file not found""#, detail: "Found 3 matches")
    #expect(!workEntryDisplayIndicatesToolFailure(value))
    // Older activities can store output in the command field, so that path stays separate.
    #expect(workEntryIndicatesToolFailure(value))
    var found = value
    found.detail = "File not found"
    #expect(workEntryDisplayIndicatesToolFailure(found))
  }

  @Test func treatsSuccessfulToolRowsAsSuccessCandidates() {
    #expect(workEntryIndicatesToolSuccess(entry("Read", status: .completed, detail: "ok")))
    #expect(!workEntryIndicatesToolSuccess(entry("Read", status: .inProgress, detail: "…")))
    #expect(!workEntryIndicatesToolSuccess(entry("Read", tone: .thinking, detail: "…")))
    #expect(!workEntryIndicatesToolSuccess(entry("Read", status: .stopped)))
  }

  @Test func doesNotRunHeuristicsOnNonToolInfoRows() {
    #expect(!workEntryIndicatesToolFailure(entry("Context compacted", tone: .info, detail: "File not found in conversation")))
  }

  @Test func severeFailuresComeFromRuntimeErrorsAndFailedActivities() {
    var runtime = workEntry("e", tone: .error, kind: "runtime.error")
    #expect(workEntrySignalsSevereFailure(runtime))
    runtime.sourceActivityKind = "provider.turn.start.failed"
    #expect(workEntrySignalsSevereFailure(runtime))
    runtime.sourceActivityKind = "tool.completed"
    #expect(!workEntrySignalsSevereFailure(runtime))
  }
}

@Suite struct ToolGroupSummaryTests {
  @Test(arguments: [T3Timeline.ProviderRequestKind.command, .fileRead, .fileChange])
  func keepsApprovalsOutOfToolExecutionCounts(kind: T3Timeline.ProviderRequestKind) {
    var requested = workEntry("a1", label: "Approval requested", tone: .info, kind: "approval.requested")
    requested.requestKind = kind
    var resolved = workEntry("a2", label: "Approval resolved", tone: .info, kind: "approval.resolved")
    resolved.requestKind = kind
    let failed = workEntry("a3", label: "Provider approval response failed", tone: .error, kind: "provider.approval.respond.failed")
    let approvals = [requested, resolved, failed]
    var read = workEntry("r", label: "Read", tone: .tool)
    read.itemType = .dynamicToolCall
    #expect(summarizeToolGroup(approvals + [read]) == "Received 3 updates and used 1 tool")
    #expect(summarizeToolGroup(approvals) == "Received 3 updates")
    #expect(toolGroupSummaryKind(approvals) == .update)
  }

  @Test func deduplicatesNamedSourcesAheadOfOrdinaryActions() {
    let source = T3Timeline.ToolActivitySource(key: "browser-use:chrome", name: "Chrome", kind: .integration, icon: nil)
    var open = workEntry("1", label: "Open page")
    open.toolSource = source
    var inspect = workEntry("2", label: "Inspect page")
    inspect.toolSource = source
    var command = workEntry("3", label: "Ran command")
    command.itemType = .commandExecution
    command.command = "git status"
    #expect(summarizeToolGroup([open, inspect, command]) == "Used Chrome integration and ran 1 command")
  }

  @Test func omitsTheIntegrationSuffixForBrowserAndComputerSources() {
    var browser = workEntry("1", label: "Inspect page")
    browser.toolSource = T3Timeline.ToolActivitySource(key: "browser-use", name: "Browser", kind: .browser, icon: nil)
    var computer = workEntry("2", label: "Click")
    computer.toolSource = T3Timeline.ToolActivitySource(key: "computer-use", name: "Computer Use", kind: .computer, icon: nil)
    #expect(summarizeToolGroup([browser, computer]) == "Used Browser and Computer Use")
  }

  func browserEntry(_ tool: String = "preview_click", server: String = "t3-code") -> WorkLogEntry {
    entry("MCP tool call", status: .completed, itemType: .mcpToolCall, toolData: #"{"server":"\#(server)","tool":"\#(tool)"}"#)
  }

  func commandEntry() -> WorkLogEntry {
    entry("Ran command", status: .completed, itemType: .commandExecution, command: "/bin/bash -lc 'vp test run'")
  }

  @Test(arguments: [1, 18])
  func countsBrowserCallsSeparatelyFromGenericTools(count: Int) {
    let entries = (0..<count).map { _ in browserEntry() }
    #expect(summarizeToolGroup(entries) == "Used browser \(count) \(count == 1 ? "time" : "times")")
    #expect(toolGroupSummaryKind(entries) == .browser)
  }

  @Test func combinesCommandAndBrowserCountsInOneSentence() {
    let entries = (0..<4).map { _ in commandEntry() } + (0..<15).map { _ in browserEntry() }
    #expect(summarizeToolGroup(entries) == "Ran 4 commands and used browser 15 times")
    #expect(toolGroupSummaryKind(entries) == .mixed)
    #expect(summarizeToolGroup([browserEntry(), commandEntry(), browserEntry("task_status")]) == "Used browser 1 time, ran 1 command, and used 1 tool")
  }

  @Test func recognizesClaudeBrowserIdentityWithoutTreatingScriptMetadataAsAShellCommand() {
    var claude = browserEntry()
    claude.command = "node inspect-page.js"
    claude.toolData = decodeJSON(JSONValue.self, #"{"toolName":"mcp__t3_code__preview_evaluate"}"#)
    #expect(summarizeToolGroup([claude]) == "Used browser 1 time")
  }

  @Test func keepsForeignToolsAndWebSearchesOutOfTheBrowserCount() {
    var foreign = browserEntry(server: "another-server")
    foreign.label = "preview_click"
    var search = workEntry("s", label: "Search")
    search.itemType = .webSearch
    #expect(summarizeToolGroup([browserEntry(), foreign, search]) == "Used browser 1 time, used 1 tool, and searched the web 1 time")
  }

  @Test(arguments: ["device_list", "device_open", "device_screenshot", "device_close"])
  func recognizesDeviceControls(tool: String) {
    #expect(summarizeToolGroup([browserEntry(tool)]) == "Used device controls 1 time")
    #expect(toolGroupSummaryKind([browserEntry(tool)]) == .device)
  }

  @Test func summarizesDeviceCallsAlongsideShellCommands() {
    var command = workEntry("c", label: "Ran command")
    command.itemType = .commandExecution
    command.command = "pwd"
    #expect(summarizeToolGroup([command, browserEntry("device_list"), browserEntry("device_open")]) == "Ran 1 command and used device controls 2 times")
    #expect(summarizeToolGroup([browserEntry("device_open", server: "another-server")]) == "Used 1 tool")
  }

  @Test func summarizesNativePullRequestWorkSeparately() {
    var link = workEntry("1", label: "T3-code · link_pull_request")
    link.itemType = .mcpToolCall
    link.toolLifecycleStatus = .completed
    link.toolSource = T3Timeline.ToolActivitySource(key: "t3-code", name: "T3 Code", kind: .integration, icon: nil)
    var list = link
    list.label = "T3-code · list_thread_pull_requests"
    var unlink = link
    unlink.label = "T3-code · unlink_pull_request"
    #expect(summarizeToolGroup([link, link, list]) == "Linked 2 pull requests and checked linked pull requests")
    #expect(summarizeToolGroup([unlink]) == "Unlinked 1 pull request")
    #expect(toolGroupSummaryKind([link, link, list]) == .pullRequest)
    #expect(summarizeToolGroup([list, list]) == "Checked linked pull requests 2 times")
    #expect(resolveWorkEntryToolPresentation(workEntry("x", label: "mcp__another-server__link_pull_request")) == nil)
  }

  @Test func groupsLegacyClaudeImageReadsWithOtherReads() {
    var value = workEntry("r", label: "Tool call")
    value.itemType = .dynamicToolCall
    value.viewedImagePath = "/workspace/reference.png"
    #expect(toolGroupAction(value) == .read)
  }

  @Test func omitsSupersededLifecycleMarkers() {
    var marker = workEntry("marker", label: "Ran command", kind: "tool.updated")
    marker.itemType = .commandExecution
    var done = workEntry("done", label: "Ran command complete", kind: "tool.completed")
    done.itemType = .commandExecution
    done.toolLifecycleStatus = .completed
    #expect(omitSupersededLifecycleMarkers([marker, done]) { $0 }.map(\.id) == ["done"])
    #expect(omitSupersededLifecycleMarkers([done, marker]) { $0 }.map(\.id) == ["done", "marker"])
  }
}

@Suite struct ToolPresentationTests {
  @Test(arguments: [
    "mcp__t3-code__preview_click", "mcp__t3_code__preview_click", "mcp__t3code__preview_click", "T3-code.preview_click",
    "t3-code · preview_click completed", "t3_code/preview_click", "preview_click",
  ])
  func recognizesBrowserToolNamesAcrossProviders(label: String) {
    let presentation = resolveWorkEntryToolPresentation(workEntry("x", label: label))
    #expect(presentation == ToolPresentation(displayName: "Clicking in the preview browser", icon: .browser, action: nil))
  }

  @Test func labelsDeviceToolsWithTheDeviceIcon() {
    var open = workEntry("x", label: "mcp__t3-code__device_open")
    open.toolLifecycleStatus = .completed
    #expect(resolveWorkEntryToolPresentation(open) == ToolPresentation(displayName: "Opened a device in the Device panel", icon: .device, action: nil))
    #expect(resolveWorkEntryToolPresentation(workEntry("x", label: "t3-code · device_screenshot"))?.displayName == "Taking a screenshot of the device")
  }

  @Test func usesStructuredMcpIdentityWhenTheProviderSuppliesACustomTitle() {
    var value = workEntry("x", label: "Tool call complete")
    value.toolTitle = "Inspect the current page"
    value.toolData = decodeJSON(JSONValue.self, #"{"server":"t3-code","tool":"preview_snapshot","result":{"title":"Example"}}"#)
    #expect(resolveWorkEntryToolPresentation(value) == ToolPresentation(displayName: "Taking a snapshot of the preview page", icon: .browser, action: nil))
  }

  @Test func usesTheSummaryStateOnlyWhenTheProviderOmittedALifecycleStatus() {
    let plain = workEntry("x", label: "T3-code.preview_click")
    #expect(resolveWorkEntryToolPresentation(plain, fallbackStatus: .inProgress)?.displayName == "Clicking in the preview browser")
    #expect(resolveWorkEntryToolPresentation(plain, fallbackStatus: .completed)?.displayName == "Clicked in the preview browser")
    var completed = plain
    completed.toolLifecycleStatus = .completed
    #expect(resolveWorkEntryToolPresentation(completed, fallbackStatus: .inProgress)?.displayName == "Clicked in the preview browser")
    var failed = plain
    failed.toolLifecycleStatus = .failed
    #expect(resolveWorkEntryToolPresentation(failed, fallbackStatus: .completed)?.displayName == "Failed to click in the preview browser")
  }

  @Test(arguments: [
    ("preview_type", "Typing in the preview browser", "Typed in the preview browser"),
    ("preview_set_appearance", "Setting preview browser appearance", "Set preview browser appearance"),
    ("preview_snapshot", "Taking a snapshot of the preview page", "Took a snapshot of the preview page"),
    ("preview_recording_stop", "Stopping recording the preview browser", "Stopped recording the preview browser"),
    ("t3_thread_read", "Reading a T3 thread", "Read a T3 thread"),
    ("t3_thread_send", "Sending to a T3 thread", "Sent to a T3 thread"),
    ("t3_worktree_handoff", "Handing off thread to a git worktree", "Handed off thread to a git worktree"),
  ])
  func preservesVerbFormsAndTheRestOfTheLabel(tool: String, running: String, completed: String) {
    var value = workEntry("x", label: "t3-code.\(tool)")
    value.toolLifecycleStatus = .inProgress
    #expect(resolveWorkEntryToolPresentation(value)?.displayName == running)
    value.toolLifecycleStatus = .completed
    #expect(resolveWorkEntryToolPresentation(value)?.displayName == completed)
  }

  @Test func keepsT3BrandingForNonBrowserToolsAndDoesNotBrandUnknownOnes() {
    var task = workEntry("x", label: "mcp__t3_code__task_status")
    task.toolTitle = "Check the child task"
    #expect(resolveWorkEntryToolPresentation(task) == ToolPresentation(displayName: "Getting delegated task status", icon: .t3Code, action: nil))
    for label in ["mcp__github__preview_click", "t3-code.unknown_tool", "t3-code.toString", "Search files"] {
      #expect(resolveWorkEntryToolPresentation(workEntry("x", label: label)) == nil)
    }
    var foreign = workEntry("x", label: "preview_click")
    foreign.toolData = decodeJSON(JSONValue.self, #"{"server":"another-server","tool":"preview_click"}"#)
    #expect(resolveWorkEntryToolPresentation(foreign) == nil)
  }

  @Test(arguments: [
    (ToolLifecycleStatus.inProgress, "Linking PR #42"), (.completed, "Linked PR #42"), (.failed, "Failed to link PR #42"),
    (.declined, "Declined to link PR #42"), (.stopped, "Stopped linking PR #42"),
  ])
  func describesThePullRequestTargetAndStatus(status: ToolLifecycleStatus, displayName: String) {
    var value = workEntry("x", label: "MCP tool call")
    value.toolTitle = "Custom title"
    value.toolLifecycleStatus = status
    value.toolData = decodeJSON(JSONValue.self, #"{"server":"t3-code","tool":"link_pull_request","arguments":{"url":"https://github.com/acme/web/pull/42"}}"#)
    #expect(resolveWorkEntryToolPresentation(value)?.displayName == displayName)
  }

  @Test(arguments: [
    "mcp__t3-code__link_pull_request", "mcp__t3_code__link_pull_request", "T3-code · link_pull_request", "t3code/link_pull_request", "link_pull_request",
  ])
  func recognizesTheNativeLinkingTool(label: String) {
    var value = workEntry("x", label: label)
    value.toolLifecycleStatus = .completed
    #expect(resolveWorkEntryToolPresentation(value)?.displayName == "Linked a pull request")
    #expect(resolveWorkEntryToolPresentation(value)?.icon == .pullRequest)
    #expect(toolGroupAction(value) == .linkPR)
  }

  @Test func recognizesUnlinkTargetsSuppliedAsRepositoryAndNumber() {
    var value = workEntry("x", label: "MCP tool call")
    value.toolLifecycleStatus = .completed
    value.toolData = decodeJSON(JSONValue.self, #"{"toolName":"mcp__t3-code__unlink_pull_request","rawInput":{"repository":"acme/web","number":42}}"#)
    #expect(resolveWorkEntryToolPresentation(value) == ToolPresentation(displayName: "Unlinked PR #42", icon: .pullRequest, action: .unlinkPR))
  }

  @Test func parsesChangeRequestNumbersFromProviderUrls() {
    #expect(parseChangeRequestNumber("https://github.com/acme/web/pull/42") == 42)
    #expect(parseChangeRequestNumber("https://github.com/acme/web/pull/42/files") == 42)
    #expect(parseChangeRequestNumber("https://gitlab.example.com/group/sub/repo/-/merge_requests/7") == 7)
    #expect(parseChangeRequestNumber("https://bitbucket.org/acme/web/pull-requests/9") == 9)
    #expect(parseChangeRequestNumber("https://dev.azure.com/org/proj/_git/repo/pullrequest/3") == 3)
    #expect(parseChangeRequestNumber("https://github.com/acme/web/issues/42") == nil)
    #expect(parseChangeRequestNumber("javascript:alert(1)") == nil)
    #expect(parseChangeRequestNumber("not a url") == nil)
  }
}

@Suite struct CommandDetailTests {
  @Test func extractsClaudeResultBlocksAndProjectedOutput() {
    let blocks = decodeJSON(JSONValue.self, #"{"result":{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}}"#)
    #expect(extractCommandOutputText(blocks) == "first\nsecond")
    #expect(extractCommandOutputText(decodeJSON(JSONValue.self, #"{"rawOutput":{"content":"projected summary"}}"#)) == "projected summary")
    #expect(extractCommandOutputText(decodeJSON(JSONValue.self, #"{"rawOutput":{"stdout":"out","stderr":"err"}}"#)) == "out\nerr")
    #expect(extractCommandOutputText(decodeJSON(JSONValue.self, #"{"content":[{"type":"content","content":{"text":"acp"}}]}"#)) == "acp")
    #expect(extractCommandOutputText(nil) == nil)
  }

  @Test func onlyRemovesADetailWithTheMatchingToolNamePrefix() {
    let data = decodeJSON(JSONValue.self, #"{"toolName":"Bash","command":"printf hello"}"#)
    #expect(commandDetailRepeatsCommand(detail: "Bash: printf hello", command: "printf hello", rawCommand: nil, toolName: .string("Bash"), data: data))
    #expect(!commandDetailRepeatsCommand(detail: "warning: printf hello", command: "printf hello", rawCommand: nil, toolName: .string("Bash"), data: data))
  }

  @Test func treatsAnIngestionTruncatedEchoOfALongCommandAsARepeat() {
    let command = "git add -A && git commit -m \"\(String(repeating: "x", count: 200))\""
    let truncated = "Bash: \(command)".jsSlice(0, 177) + "..."
    let data = JSONValue.object(["toolName": .string("Bash"), "command": .string(command)])
    #expect(commandDetailRepeatsCommand(detail: truncated, command: command, rawCommand: nil, toolName: .string("Bash"), data: data))
    let other = JSONValue.object(["toolName": .string("Bash"), "command": .string("printf goodbye")])
    #expect(!commandDetailRepeatsCommand(detail: "Bash: printf hello...", command: "printf goodbye", rawCommand: nil, toolName: .string("Bash"), data: other))
  }

  @Test func treatsAcpCommandEchoesAsSyntheticEvenWithoutAToolKind() {
    #expect(
      commandDetailRepeatsCommand(
        detail: "pnpm test", command: "pnpm test", rawCommand: nil, toolName: nil,
        data: decodeJSON(JSONValue.self, #"{"toolCallId":"tool-1","command":"pnpm test"}"#)))
    #expect(
      !commandDetailRepeatsCommand(
        detail: "pnpm test", command: "pnpm test", rawCommand: nil, toolName: nil, data: decodeJSON(JSONValue.self, #"{"command":"pnpm test"}"#)))
  }

  @Test func returnsASingleImagePathFromSupportedReadEntries() {
    var read = workEntry("r", label: "Read")
    read.requestKind = .fileRead
    read.detail = " assets/a.png "
    #expect(workEntryViewedImagePath(read) == "assets/a.png")
    var dynamic = workEntry("r", label: "Read")
    dynamic.itemType = .dynamicToolCall
    dynamic.toolTitle = "Read file"
    dynamic.detail = "C:\\workspace\\a.webp"
    #expect(workEntryViewedImagePath(dynamic) == "C:\\workspace\\a.webp")
    var viewed = workEntry("r", label: "Read")
    viewed.itemType = .dynamicToolCall
    viewed.detail = #"Read: {"file_path":"truncated..."}"#
    viewed.viewedImagePath = " /workspace/reference image.webp "
    #expect(workEntryViewedImagePath(viewed) == "/workspace/reference image.webp")
  }

  @Test func rejectsNonImageMultiLineAndNonReadDetails() {
    var image = workEntry("r", label: "Read")
    image.itemType = .imageView
    image.detail = "a.txt"
    #expect(workEntryViewedImagePath(image) == nil)
    image.detail = "a.png\nb.png"
    #expect(workEntryViewedImagePath(image) == nil)
    var plain = workEntry("r", label: "Read")
    plain.detail = "a.png"
    #expect(workEntryViewedImagePath(plain) == nil)
  }

  @Test func readsProviderNeutralToolActivityPresentation() throws {
    let payload = decodeJSON(
      JSONValue.self,
      """
      {"toolSurface":"browser","toolIcon":{"_tag":"website","pageUrl":"https://example.com/a","faviconUrl":"https://example.com/f.ico","faviconUrlDark":"not a url"},
       "toolSource":{"key":"k","name":"Chrome","kind":"integration","icon":{"_tag":"native-app","app":{"_tag":"app-id","appId":"com.apple.Safari"}}}}
      """)
    let extracted = extractToolActivityPresentation(payload)
    #expect(extracted.toolSurface == .browser)
    #expect(extracted.toolIcon == .website(pageUrl: "https://example.com/a", faviconUrl: "https://example.com/f.ico", faviconUrlDark: nil))
    #expect(extracted.toolSource?.icon == .nativeApp(.appId("com.apple.Safari")))
    #expect(extractToolActivityPresentation(decodeJSON(JSONValue.self, #"{"toolIcon":{"_tag":"website","pageUrl":"javascript:alert(1)"}}"#)).toolIcon == nil)
    #expect(extractToolActivityPresentation(decodeJSON(JSONValue.self, #"{"toolSource":{"key":"k","name":"x","kind":"weird"}}"#)).toolSource == nil)
    #expect(extractToolActivityPresentation(decodeJSON(JSONValue.self, #"{"toolIcon":{"_tag":"native-app","app":{"_tag":"app-id","appId":"has space"}}}"#)).toolIcon == nil)
    #expect(extractToolActivityPresentation(decodeJSON(JSONValue.self, #"{"data":{"toolSurface":"browser"}}"#)).toolSurface == nil)
  }
}
