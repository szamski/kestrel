import AppKit
import Foundation
import T3Contracts
import T3Timeline
import Testing
import UniformTypeIdentifiers

@testable import T3Composer

@MainActor
@Suite("Approvals, questions, history and keyboard") struct ComposerPanelsTests {
  @Test func approvalReplacesTheEditorAndRespondsWithTheDecision() async throws {
    let fixture = try await ModelFixture.make(thread: pendingApprovalSnapshot())
    await fixture.settle { fixture.model.activeApproval != nil }
    #expect(fixture.model.isApprovalState && fixture.model.isEditorDisabled)
    #expect(fixture.model.placeholder == "Resolve this approval request to continue")
    #expect(fixture.model.activeApproval?.primaryOptions.map(\.decision) == [.decline, .accept])
    #expect(fixture.model.activeApproval?.moreOptions.map(\.decision) == [.cancel, .acceptForSession])
    fixture.type("ignored")
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.isEmpty, "nothing sends while an approval is open")
    await fixture.model.respondToApproval(.acceptForSession)
    let response = try #require(fixture.env.approvalResponses.first)
    #expect(response.requestId == "req-1" && response.decision == .acceptForSession && response.threadId == "thread-1")
  }

  @Test func aSingleSelectQuestionAdvancesAfterPickingAndRespondsWithTheValue() async throws {
    let fixture = try await ModelFixture.make(thread: pendingQuestionSnapshot(questions: 2))
    await fixture.settle { fixture.model.activeUserInput != nil }
    #expect(fixture.model.userInputProgress?.activeQuestion?.header == "Header 1")
    #expect(fixture.model.placeholder == "Type your own answer, or leave this blank to use the selected option")
    fixture.model.selectUserInputOption(questionId: "q1", value: "beta")
    #expect(fixture.model.userInputProgress?.selectedOptionValues == ["beta"])
    await fixture.settle { fixture.model.userInputProgress?.questionIndex == 1 }
    #expect(fixture.model.userInputProgress?.questionIndex == 1, "a single pick moves on by itself")
    // The second question takes a typed answer; the editor now holds that answer.
    fixture.type("my own answer")
    #expect(fixture.model.draft.prompt.isEmpty, "the thread draft is untouched")
    #expect(fixture.model.userInputProgress?.customAnswer == "my own answer")
    await fixture.model.advanceUserInput()
    let response = try #require(fixture.env.userInputResponses.first)
    #expect(response.requestId == "req-q")
    #expect(response.answers["q1"] == .string("beta") && response.answers["q2"] == .string("my own answer"))
  }

  @Test func multiSelectTogglesAndCustomAnswersDisplaceOptions() async throws {
    let fixture = try await ModelFixture.make(thread: pendingQuestionSnapshot(multiSelect: true))
    await fixture.settle { fixture.model.activeUserInput != nil }
    fixture.model.selectUserInputOption(questionId: "q1", value: "Alpha")
    fixture.model.selectUserInputOption(questionId: "q1", value: "beta")
    #expect(fixture.model.userInputProgress?.selectedOptionValues == ["Alpha", "beta"])
    fixture.model.selectUserInputOption(questionId: "q1", value: "Alpha")
    #expect(fixture.model.userInputProgress?.selectedOptionValues == ["beta"])
    // Text typed into the answer field moves back to the thread draft when an option is picked.
    fixture.type("typed answer")
    fixture.model.selectUserInputOption(questionId: "q1", value: "Alpha")
    #expect(fixture.model.draft.prompt == "typed answer")
    await fixture.model.advanceUserInput()
    #expect(fixture.env.userInputResponses.first?.answers["q1"] == .array([.string("Alpha")]), "typing cleared the earlier picks, so only the new pick remains")
  }

  @Test func choiceOnlyQuestionsDisableTheEditorAndCanBeDismissed() async throws {
    let fixture = try await ModelFixture.make(thread: pendingQuestionSnapshot(allowCustom: false))
    await fixture.settle { fixture.model.activeUserInput != nil }
    #expect(fixture.model.isChoiceOnlyQuestion && fixture.model.isEditorDisabled)
    #expect(fixture.model.placeholder == "Choose an option above")
    if fixture.model.activeUserInput?.dismissible == true {
      await fixture.model.dismissUserInput()
      #expect(fixture.env.dismissedUserInputs.count == 1)
    }
  }

  @Test func promptHistoryWalksSentPromptsAtTheCaretEdges() async throws {
    var thread = ComposerThreadSnapshot(phase: .ready)
    thread.promptHistory = [
      ComposerPromptHistoryMessage(id: "1", role: "user", text: "first prompt"), ComposerPromptHistoryMessage(id: "2", role: "assistant", text: "reply"),
      ComposerPromptHistoryMessage(id: "3", role: "user", text: "second prompt"),
    ]
    let fixture = try await ModelFixture.make(thread: thread)
    await fixture.settle { fixture.model.thread.promptHistory.count == 3 }
    let edge = ComposerKeyContext(caretOnFirstLine: true, caretOnLastLine: true)
    #expect(fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false))
    #expect(fixture.model.draft.prompt == "second prompt")
    #expect(fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false) && fixture.model.draft.prompt == "first prompt")
    #expect(!fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false), "the oldest entry stops")
    #expect(fixture.model.handleCommandKey(.arrowDown, context: edge, isTaskItem: false) && fixture.model.draft.prompt == "second prompt")
    #expect(fixture.model.handleCommandKey(.arrowDown, context: edge, isTaskItem: false) && fixture.model.draft.prompt.isEmpty, "past the newest the composer empties")
    // A typed draft is never replaced, and the arrows only claim the first and last visual line.
    fixture.type("typed")
    #expect(!fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false))
    fixture.type("")
    #expect(!fixture.model.handleCommandKey(.arrowUp, context: ComposerKeyContext(caretOnFirstLine: false), isTaskItem: false))
    #expect(!fixture.model.handleCommandKey(.arrowUp, context: ComposerKeyContext(shift: true, caretOnFirstLine: true), isTaskItem: false))
  }

  @Test func editingARecalledPromptTurnsItIntoANormalDraft() async throws {
    var thread = ComposerThreadSnapshot(phase: .ready)
    thread.promptHistory = [ComposerPromptHistoryMessage(id: "1", role: "user", text: "old prompt")]
    let fixture = try await ModelFixture.make(thread: thread)
    await fixture.settle { !fixture.model.thread.promptHistory.isEmpty }
    let edge = ComposerKeyContext(caretOnFirstLine: true, caretOnLastLine: true)
    _ = fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false)
    fixture.type("old prompt edited")
    #expect(!fixture.model.handleCommandKey(.arrowUp, context: edge, isTaskItem: false))
  }

  @Test func enterSubmitsPerTheSendShortcutAndShiftEnterDoesNot() async throws {
    let enter = try await ModelFixture.make()
    enter.type("hello")
    #expect(!enter.model.handleCommandKey(.enter, context: ComposerKeyContext(shift: true), isTaskItem: false))
    #expect(enter.env.sentTurns.isEmpty)
    #expect(enter.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false))
    await enter.settle { !enter.env.sentTurns.isEmpty }
    #expect(enter.env.sentTurns.count == 1)

    let mod = try await ModelFixture.make(sendShortcut: .modEnter)
    mod.type("hello")
    #expect(!mod.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false), "plain Enter is a newline with mod-enter")
    #expect(mod.model.handleCommandKey(.enter, context: ComposerKeyContext(modifier: true), isTaskItem: false))
    await mod.settle { !mod.env.sentTurns.isEmpty }
    #expect(mod.env.sentTurns.count == 1)

    let multiline = try await ModelFixture.make(sendShortcut: .modEnterMultiline)
    multiline.type("one line")
    #expect(multiline.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false), "single-line drafts send with plain Enter")
    await multiline.settle { !multiline.env.sentTurns.isEmpty }
    multiline.type("two\nlines")
    #expect(!multiline.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false), "multi-line drafts need the modifier")
  }

  @Test func enterAndTabContinueAndIndentLists() async throws {
    let fixture = try await ModelFixture.make(sendShortcut: .modEnter)
    fixture.type("- item")
    #expect(fixture.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.draft.prompt == "- item\n- ")
    #expect(fixture.model.editorSync.markdown == "- item\n- ")
    // An empty item exits the list.
    #expect(fixture.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.draft.prompt == "- item\n")
    fixture.type("- nested")
    #expect(fixture.model.handleCommandKey(.tab, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.draft.prompt == "  - nested")
    #expect(!fixture.model.handleCommandKey(.tab, context: ComposerKeyContext(), isTaskItem: false) == false)
  }

  @Test func menuNavigationWrapsAndEnterPicks() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("/")
    let count = fixture.model.menuItems.count
    #expect(count >= 3)
    let first = fixture.model.menuItems[0].id
    #expect(fixture.model.menuHighlightedId == first)
    #expect(fixture.model.handleCommandKey(.arrowUp, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.menuHighlightedId == fixture.model.menuItems[count - 1].id, "up from the first wraps to the last")
    #expect(fixture.model.handleCommandKey(.arrowDown, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.menuHighlightedId == first)
    #expect(fixture.model.handleCommandKey(.enter, context: ComposerKeyContext(), isTaskItem: false))
    #expect(fixture.model.isModelPickerOpen, "Enter picked /model")
  }

  @Test func theRestingLayoutFollowsScrollGesturesAndLiftsOnUse() async throws {
    let fixture = try await ModelFixture.make()
    #expect(!fixture.model.isScrollCollapsed)
    var now = 1000.0
    for _ in 0..<3 {
      now += 10
      fixture.model.timelineDidScroll(now: now, deltaPx: 60, canScrollInGestureDirection: true, scrollsTowardLogicalEnd: false)
    }
    #expect(fixture.model.isScrollCollapsed)
    #expect(fixture.model.isResting(isExistingThread: true, timelineOverflows: true))
    #expect(!fixture.model.isResting(isExistingThread: false, timelineOverflows: true))
    fixture.model.editorFocusDidChange(true)
    #expect(!fixture.model.isScrollCollapsed, "focusing the composer lifts it")
    fixture.model.timelineDidPressScrollKey("PageUp", scrollTop: 400, scrollHeight: 2000, clientHeight: 600, isAtLogicalEnd: false)
    #expect(fixture.model.isScrollCollapsed)
    fixture.model.composerWasUsed(now: 2000)
    #expect(!fixture.model.isScrollCollapsed)
  }
}
