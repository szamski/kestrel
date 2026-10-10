import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

// Ported from packages/client-runtime/src/pendingRequests.test.ts and
// apps/web/src/pendingUserInput.test.ts.

private func request(_ id: String, _ kind: String, at: String, tone: String = "approval", _ payload: String) -> V1.OrchestrationThreadActivity {
  activity(id, kind, summary: "Request", tone: tone, at: at, payload)
}

@Suite struct PendingApprovalTests {
  @Test(arguments: ["{}", #"{"requestType":"unknown"}"#])
  func fallsBackToCommandWhenTheRequestKindIsUnrecognized(extra: String) {
    let payload = extra == "{}" ? #"{"requestId":"req-1"}"# : #"{"requestId":"req-1","requestType":"unknown"}"#
    let approvals = derivePendingPrompts([request("a", "approval.requested", at: "2026-02-23T00:00:01.000Z", payload)]).approvals
    #expect(approvals.map(\.requestKind) == [.command])
  }

  @Test(arguments: ["tool_user_input", "auth_tokens_refresh"])
  func ignoresRequestTypesThatAreNotApprovals(type: String) {
    let activities = [request("a", "approval.requested", at: "2026-02-23T00:00:01.000Z", #"{"requestId":"req-1","requestType":"\#(type)"}"#)]
    #expect(derivePendingPrompts(activities).approvals.isEmpty)
  }

  @Test func tracksOpenApprovalsAndRemovesResolvedOnesEvenWhenTheRequestArrivesLater() {
    let activities = [
      request("open", "approval.requested", at: "2026-02-23T00:00:01.000Z", #"{"requestId":"req-1","requestKind":"command","detail":"bun run lint"}"#),
      request("close", "approval.resolved", at: "2026-02-23T00:00:02.000Z", tone: "info", #"{"requestId":"req-2"}"#),
      request("closed", "approval.requested", at: "2026-02-23T00:00:01.500Z", #"{"requestId":"req-2","requestType":"unknown"}"#),
    ]
    let approvals = derivePendingPrompts(activities).approvals
    #expect(approvals.count == 1)
    #expect(approvals[0].requestId == "req-1" && approvals[0].requestKind == .command && approvals[0].detail == "bun run lint")
    #expect(approvals[0].options == nil && approvals[0].appName == nil)
  }

  @Test func mapsCanonicalRequestTypesIntoPendingApprovals() {
    let types: [(String, T3Timeline.ProviderRequestKind)] = [
      ("command_execution_approval", .command), ("exec_command_approval", .command), ("dynamic_tool_call", .command),
      ("file_read_approval", .fileRead), ("file_change_approval", .fileChange), ("apply_patch_approval", .fileChange),
      ("mcp_elicitation_approval", .mcpElicitation), ("permission_approval", .permission),
    ]
    for (index, (type, kind)) in types.enumerated() {
      let approvals = derivePendingPrompts([
        request("a", "approval.requested", at: "2026-02-23T00:00:0\(index).000Z", #"{"requestId":"req","requestType":"\#(type)","detail":"pwd"}"#)
      ]).approvals
      #expect(approvals.first?.requestKind == kind, "\(type)")
    }
  }

  @Test func keepsAppAccessApprovalsAndPersistenceChoices() {
    let payload = """
      {"requestId":"req-app","requestKind":"mcp-elicitation","appName":"Safari","detail":"Allow access?",
       "options":[{"decision":"decline","label":"Decline"},{"decision":"acceptAlways","label":"Always allow Safari"},
                  {"decision":"accept","label":"Approve","warning":"careful"},{"decision":"bogus","label":"Nope"},{"decision":"accept","label":""}]}
      """
    let approval = derivePendingPrompts([request("a", "approval.requested", at: "2026-02-23T00:00:01.000Z", payload)]).approvals[0]
    #expect(approval.appName == "Safari" && approval.requestKind == .mcpElicitation)
    #expect(approval.options?.map(\.decision) == [.decline, .acceptAlways, .accept])
    #expect(approval.options?.last?.warning == "careful")
    #expect(approval.primaryOptions.map(\.label) == ["Decline", "Approve"])
    #expect(approval.moreOptions.map(\.label) == ["Always allow Safari"])
    #expect(approval.panelLabel == "App access approval" && !approval.detailIsCode)
  }

  @Test func offersTheStandardDecisionsWhenTheProviderSendsNone() {
    let approval = derivePendingPrompts([request("a", "approval.requested", at: "2026-02-23T00:00:01.000Z", #"{"requestId":"r","requestKind":"file-change"}"#)]).approvals[0]
    #expect(approval.resolvedOptions.map(\.decision) == [.cancel, .decline, .acceptForSession, .accept])
    #expect(approval.primaryOptions.map(\.decision) == [.decline, .accept])
    #expect(approval.displayDetail == "File change approval" && approval.detailLabel == "File change" && approval.detailIsCode)
  }

  @Test func clearsStaleApprovalsButKeepsARetryableFailureOpen() {
    let open = request("a", "approval.requested", at: "2026-02-23T00:00:01.000Z", #"{"requestId":"req-1","requestKind":"command"}"#)
    func failure(_ detail: String) -> V1.OrchestrationThreadActivity {
      request("f", "provider.approval.respond.failed", at: "2026-02-23T00:00:02.000Z", tone: "error", #"{"requestId":"req-1","detail":"\#(detail)"}"#)
    }
    #expect(derivePendingPrompts([open, failure("Stale pending approval request: req-1")]).approvals.isEmpty)
    #expect(derivePendingPrompts([open, failure("Unknown pending permission request")]).approvals.isEmpty)
    #expect(derivePendingPrompts([open, failure("network down")]).approvals.count == 1)
  }
}

@Suite struct PendingQuestionTests {
  @Test func preservesNativeAnswerKeysWhileIgnoringMalformedOptions() {
    let requested = request(
      "q", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info",
      """
      {"requestId":"native-question","questions":[null,
        {"id":"  Which path?\\n","header":" Path ","question":"  Which path?\\n",
         "options":[{"label":" Keep spaces ","description":"","value":" native\\t"},{"label":42}],"multiSelect":false}]}
      """)
    let questions = derivePendingPrompts([requested]).userInputs[0].questions
    #expect(questions.count == 1)
    #expect(questions[0].id == "  Which path?\n" && questions[0].header == " Path ")
    #expect(questions[0].options == [UserInputQuestionOption(label: " Keep spaces ", description: "", value: " native\t")])
  }

  @Test func keepsFreeTextQuestionsAndOnlyMarksAsyncQuestionsDismissible() {
    let question = #"{"id":"0","header":"Question","question":"Name?","options":[],"allowCustomAnswer":true,"multiSelect":false}"#
    let async = request("a", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info", #"{"requestId":"async-1","responseMode":"message","questions":[\#(question)]}"#)
    let native = request("n", "user-input.requested", at: "2026-02-23T00:00:02.000Z", tone: "info", #"{"requestId":"native-1","questions":[\#(question)]}"#)
    let prompts = derivePendingPrompts([async, native]).userInputs
    #expect(prompts.map(\.dismissible) == [true, false])
    #expect(prompts[0].questions[0].options.isEmpty)
  }

  @Test func preservesNativeChoiceValuesAndTheCustomAnswerRestriction() {
    let question =
      #"{"id":"result","header":"Result","question":"Which?","options":[{"value":" first\t","label":"Result","description":"First"},{"value":"second","label":"Result","description":"Second"}],"allowCustomAnswer":false,"multiSelect":false}"#
    let prompt = derivePendingPrompts([request("a", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info", #"{"requestId":"r","questions":[\#(question)]}"#)]).userInputs[0]
    #expect(prompt.questions[0].allowCustomAnswer == false)
    #expect(prompt.questions[0].options.map(\.value) == [" first\t", "second"])
    // A question that offers no choice and forbids custom answers cannot be answered.
    let impossible = #"{"id":"x","header":"h","question":"q","options":[],"allowCustomAnswer":false}"#
    #expect(derivePendingPrompts([request("b", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info", #"{"requestId":"r2","questions":[\#(impossible)]}"#)]).userInputs.isEmpty)
  }

  @Test(arguments: ["user-input.resolved", "provider.user-input.respond.failed"])
  func resolvedAndStaleRequestsLeaveTheQueueButRetryableFailuresStay(kind: String) {
    let question = #"{"id":"0","header":"h","question":"q","options":[{"label":"Yes","description":""}]}"#
    let open = request("o", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info", #"{"requestId":"r","questions":[\#(question)]}"#)
    let stale = kind == "user-input.resolved" ? "{}" : #"{"detail":"Stale pending user-input request"}"#
    let payload = stale == "{}" ? #"{"requestId":"r"}"# : #"{"requestId":"r","detail":"Stale pending user-input request"}"#
    #expect(derivePendingPrompts([open, request("c", kind, at: "2026-02-23T00:00:02.000Z", tone: "info", payload)]).userInputs.isEmpty)
    if kind != "user-input.resolved" {
      #expect(derivePendingPrompts([open, request("c", kind, at: "2026-02-23T00:00:02.000Z", tone: "error", #"{"requestId":"r","detail":"timeout"}"#)]).userInputs.count == 1)
    }
  }

  @Test func sortsOpenRequestsByCreationTime() {
    let question = #"{"id":"0","header":"h","question":"q","options":[{"label":"Yes","description":""}]}"#
    let later = request("l", "user-input.requested", at: "2026-02-23T00:00:09.000Z", tone: "info", #"{"requestId":"later","questions":[\#(question)]}"#)
    let earlier = request("e", "user-input.requested", at: "2026-02-23T00:00:01.000Z", tone: "info", #"{"requestId":"earlier","questions":[\#(question)]}"#)
    #expect(derivePendingPrompts([later, earlier]).userInputs.map(\.id) == ["earlier", "later"])
  }
}

@Suite struct PendingUserInputAnswerTests {
  let singleSelect = UserInputQuestion(
    id: "scope", header: "Scope", question: "Which scope?",
    options: [
      UserInputQuestionOption(label: "Orchestration-first", description: "", value: nil), UserInputQuestionOption(label: "Provider-first", description: "", value: nil),
    ], allowCustomAnswer: nil, multiSelect: false)
  let multiSelect = UserInputQuestion(
    id: "areas", header: "Areas", question: "Which areas?",
    options: [UserInputQuestionOption(label: "Server", description: "Server", value: nil), UserInputQuestionOption(label: "Web", description: "Web", value: nil)],
    allowCustomAnswer: nil, multiSelect: true)
  let nativeChoice = UserInputQuestion(
    id: "result", header: "Result", question: "Which result?",
    options: [
      UserInputQuestionOption(label: "Result", description: "First", value: " first\t"), UserInputQuestionOption(label: "Result", description: "Second", value: "second"),
    ], allowCustomAnswer: false, multiSelect: false)

  @Test func prefersACustomAnswerOverSelectedOptions() {
    let draft = PendingUserInputDraftAnswer(selectedOptionValues: ["Orchestration-first"], customAnswer: "  Keep the envelope  ")
    #expect(resolvePendingUserInputAnswer(singleSelect, draft) == .text("Keep the envelope"))
  }

  @Test func fallsBackToTheSelectedOptionForSingleSelectAndAllSelectedForMulti() {
    #expect(resolvePendingUserInputAnswer(singleSelect, PendingUserInputDraftAnswer(selectedOptionValues: ["Provider-first"])) == .text("Provider-first"))
    #expect(resolvePendingUserInputAnswer(multiSelect, PendingUserInputDraftAnswer(selectedOptionValues: ["Server", "Web", "Server"])) == .values(["Server", "Web"]))
    #expect(resolvePendingUserInputAnswer(multiSelect, nil) == nil)
  }

  @Test func clearsThePresetSelectionWhenACustomAnswerIsEntered() {
    let draft = setPendingUserInputCustomAnswer(PendingUserInputDraftAnswer(selectedOptionValues: ["Server"]), "Something else")
    #expect(draft == PendingUserInputDraftAnswer(selectedOptionValues: nil, customAnswer: "Something else"))
    let blank = setPendingUserInputCustomAnswer(PendingUserInputDraftAnswer(selectedOptionValues: ["Server"]), "   ")
    #expect(blank.selectedOptionValues == ["Server"])
  }

  @Test func doesNotReplaceARequiredChoiceWithACustomAnswer() {
    let draft = PendingUserInputDraftAnswer(selectedOptionValues: nil, customAnswer: "typed")
    #expect(resolvePendingUserInputAnswer(nativeChoice, draft) == nil)
  }

  @Test func doesNotSubmitLabelsOrUnknownValuesWhenAnOptionHasAValue() {
    #expect(resolvePendingUserInputAnswer(nativeChoice, PendingUserInputDraftAnswer(selectedOptionValues: ["Result"])) == nil)
    #expect(resolvePendingUserInputAnswer(nativeChoice, PendingUserInputDraftAnswer(selectedOptionValues: [" first\t"])) == .text(" first\t"))
  }

  @Test func attachmentsCanStandInForAnAnswerUnlessBlocked() {
    #expect(resolvePendingUserInputAnswer(singleSelect, PendingUserInputDraftAnswer(attachmentCount: 1)) == .text(""))
    #expect(resolvePendingUserInputAnswer(multiSelect, PendingUserInputDraftAnswer(attachmentCount: 2)) == .text(""))
    #expect(resolvePendingUserInputAnswer(singleSelect, PendingUserInputDraftAnswer(customAnswer: "x", attachmentsBlocked: true)) == nil)
    #expect(resolvePendingUserInputAnswer(nativeChoice, PendingUserInputDraftAnswer(attachmentCount: 1)) == nil)
  }

  @Test func togglesOptionsForMultiSelectAndReplacesForSingleSelect() {
    var draft = togglePendingUserInputOptionSelection(multiSelect, nil, optionValue: "Server")
    draft = togglePendingUserInputOptionSelection(multiSelect, draft, optionValue: "Web")
    #expect(draft.selectedOptionValues == ["Server", "Web"] && draft.customAnswer == "")
    draft = togglePendingUserInputOptionSelection(multiSelect, draft, optionValue: "Server")
    #expect(draft.selectedOptionValues == ["Web"])
    #expect(togglePendingUserInputOptionSelection(multiSelect, togglePendingUserInputOptionSelection(multiSelect, nil, optionValue: "Web"), optionValue: "Web").selectedOptionValues == nil)
    let single = togglePendingUserInputOptionSelection(singleSelect, PendingUserInputDraftAnswer(selectedOptionValues: ["Orchestration-first"]), optionValue: "Provider-first")
    #expect(single.selectedOptionValues == ["Provider-first"])
  }

  @Test func buildsACanonicalAnswerMapOnlyForCompletePrompts() {
    let drafts = [
      "scope": PendingUserInputDraftAnswer(selectedOptionValues: ["Provider-first"]),
      "areas": PendingUserInputDraftAnswer(selectedOptionValues: ["Server", "Web"]),
    ]
    #expect(buildPendingUserInputAnswers([singleSelect, multiSelect], drafts) == ["scope": .text("Provider-first"), "areas": .values(["Server", "Web"])])
    #expect(buildPendingUserInputAnswers([singleSelect, multiSelect], ["scope": drafts["scope"]!]) == nil)
    #expect(buildPendingUserInputAnswers([], [:]) == [:])
  }

  @Test func derivesTheActiveQuestionAndAdvancementState() {
    let drafts = ["scope": PendingUserInputDraftAnswer(selectedOptionValues: ["Provider-first"])]
    let first = derivePendingUserInputProgress([singleSelect, multiSelect], drafts, questionIndex: 0)
    #expect(first.activeQuestion?.id == "scope" && first.canAdvance && !first.isLastQuestion && !first.isComplete)
    #expect(first.answeredQuestionCount == 1)
    let beyond = derivePendingUserInputProgress([singleSelect, multiSelect], drafts, questionIndex: 9)
    #expect(beyond.questionIndex == 1 && beyond.isLastQuestion && !beyond.canAdvance)
    let none = derivePendingUserInputProgress([], [:], questionIndex: 3)
    #expect(none.activeQuestion == nil && none.isLastQuestion && none.isComplete)
    let hidden = derivePendingUserInputProgress([nativeChoice], ["result": PendingUserInputDraftAnswer(customAnswer: "typed")], questionIndex: 0)
    #expect(hidden.customAnswer == "" && !hidden.usingCustomAnswer && !hidden.canAdvance)
  }

  @Test func carriesADisplacedCustomAnswerBackIntoTheThreadDraft() {
    #expect(carryDisplacedCustomAnswerIntoPrompt("draft", customAnswer: nil) == "draft")
    #expect(carryDisplacedCustomAnswerIntoPrompt("draft", customAnswer: "  ") == "draft")
    #expect(carryDisplacedCustomAnswerIntoPrompt("  ", customAnswer: " typed ") == "typed")
    #expect(carryDisplacedCustomAnswerIntoPrompt("draft  ", customAnswer: " typed ") == "draft\n\ntyped")
  }
}

@Suite struct LiveAgentTests {
  func agent(_ kind: String, _ id: String, _ extra: String = "", turn: String = "turn-1", at: Int = 0) -> V1.OrchestrationThreadActivity {
    activity("\(kind)-\(id)-\(at)", kind, tone: "info", turn: turn, at: "2026-02-23T00:00:\(String(format: "%02d", at)).000Z", #"{"taskId":"\#(id)","agentKind":"agent"\#(extra)}"#)
  }

  @Test func runningAgentsAreLiveAndSettledOnesAreNot() {
    let activities = [agent("task.started", "a"), agent("task.started", "b", at: 1), agent("task.completed", "b", #","status":"completed""#, at: 2)]
    #expect(deriveLiveAgentTaskIds(activities: activities, sessionLive: true) == ["a"])
    #expect(deriveLiveAgentTaskIds(activities: activities, sessionLive: false).isEmpty)
  }

  @Test func idleAgentsAreNotLiveButReactivateOnProgress() {
    let idle = [agent("task.started", "a"), agent("task.updated", "a", #","status":"idle""#, at: 1)]
    #expect(deriveLiveAgentTaskIds(activities: idle, sessionLive: true).isEmpty)
    #expect(deriveLiveAgentTaskIds(activities: idle + [agent("task.updated", "a", #","status":"running""#, at: 2)], sessionLive: true) == ["a"])
  }

  @Test func aSettledWorkflowCascadesItsOutcomeToMembersThatNeverReported() {
    let activities = [
      agent("task.started", "wf", #","taskType":"local_workflow""#),
      agent("task.started", "wf:wf:m1", #","parentAgentId":"wf""#, at: 1),
      agent("task.completed", "wf", #","status":"completed""#, at: 2),
    ]
    #expect(deriveLiveAgentTaskIds(activities: activities, sessionLive: true).isEmpty)
    #expect(deriveLiveAgentTaskIds(activities: Array(activities.prefix(2)), sessionLive: true) == ["wf", "wf:wf:m1"])
  }

  @Test func backgroundTasksAndLateStartRowsDoNotJoinTheRoster() {
    let shell = activity("bg", "task.started", tone: "info", #"{"taskId":"sh","agentKind":"background"}"#)
    #expect(deriveLiveAgentTaskIds(activities: [shell], sessionLive: true).isEmpty)
    let late = [agent("task.started", "a"), agent("task.completed", "a", #","status":"failed""#, at: 1), agent("task.started", "a", at: 2)]
    #expect(deriveLiveAgentTaskIds(activities: late, sessionLive: true).isEmpty)
  }
}
