import Foundation
import T3Contracts
import T3Timeline
import Testing

@testable import T3Composer

@MainActor
@Suite("Composer sending, queue and steer") struct ComposerSendTests {
  @Test func sendingBuildsTheTurnCommandAndClearsTheDraft() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("  Fix the bug in [main.ts](src/main.ts) please  ")
    #expect(fixture.model.canSend)
    await fixture.model.submit()
    let sent = try #require(fixture.env.sentTurns.first)
    #expect(sent.command.message.text == "Fix the bug in [main.ts](src/main.ts) please")
    #expect(sent.command.threadId == "thread-1")
    #expect(sent.command.modelSelection?.instanceId == "codex" && sent.command.modelSelection?.model == "gpt-6-astra")
    #expect(sent.command.runtimeMode == .fullAccess && sent.command.interactionMode == .default)
    #expect(sent.isFirstMessage && sent.titleSeed == "Fix the bug in [main.ts](src/main.ts) please")
    #expect(sent.command.message.attachments.isEmpty && sent.command.message.context == nil)
    #expect(fixture.model.draft.prompt.isEmpty && fixture.model.editorSync.markdown.isEmpty)
    #expect(!fixture.model.hasSendableContent)
  }

  @Test func theTitleSeedStripsChipsAndTruncates() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("![shot.png](t3-context://v1/image/image_1) " + String(repeating: "word ", count: 20))
    await fixture.model.submit()
    let seed = try #require(fixture.env.sentTurns.first?.titleSeed)
    #expect(seed.hasSuffix("...") && seed.jsLength == 53 && !seed.contains("t3-context"))
  }

  @Test func aFailedSendGivesTheDraftBack() async throws {
    let fixture = try await ModelFixture.make()
    fixture.env.failSendsWith = "boom"
    fixture.type("keep me")
    await fixture.model.submit()
    #expect(fixture.model.errorMessage == "boom")
    #expect(fixture.model.draft.prompt == "keep me" && fixture.model.editorSync.markdown == "keep me")
    #expect(fixture.env.sentTurns.isEmpty)
  }

  @Test func ultrathinkEffortIsWrittenIntoThePrompt() async throws {
    let fixture = try await ModelFixture.make()
    fixture.model.selectModel(instanceId: "claudeAgent", slug: "claude-fable-5-1")
    let state = fixture.model.traits
    let effort = try #require(state.primarySelect)
    fixture.model.selectTrait(effort, value: "ultrathink")
    #expect(fixture.model.draft.prompt == "Ultrathink:\n")
    fixture.type("Ultrathink:\nthink about it")
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.first?.command.message.text == "Ultrathink:\nthink about it")
    #expect(fixture.env.sentTurns.first?.command.modelSelection?.instanceId == "claudeAgent")
  }

  @Test func overLongPromptsAreBlockedWithTheLimitMessage() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type(String(repeating: "x", count: 120_001))
    #expect(fixture.model.validationMessage == "Prompt is 1 character over the 120,000-character limit. Shorten or split it before sending.")
    #expect(!fixture.model.canSend)
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.isEmpty && fixture.model.errorMessage?.contains("120,000") == true)
  }

  @Test func whileATurnRunsTheFollowUpIsQueuedAndGoesOutAtTheNextToolBoundary() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running, latestToolActivityId: "tool-1"))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("then do this")
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.isEmpty)
    #expect(fixture.model.queuedMessages.map(\.prompt) == ["then do this"])
    #expect(fixture.model.queuedMessages.first?.queuedAfterToolActivityId == "tool-1")
    #expect(fixture.model.draft.prompt.isEmpty)
    // No new tool call yet: still waiting.
    await fixture.push(ComposerThreadSnapshot(phase: .running, latestToolActivityId: "tool-1"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(fixture.env.sentTurns.isEmpty)
    // A tool call finished after it was queued: the boundary.
    await fixture.push(ComposerThreadSnapshot(phase: .running, latestToolActivityId: "tool-2"))
    await fixture.settle { !fixture.env.sentTurns.isEmpty }
    #expect(fixture.env.sentTurns.first?.command.message.text == "then do this")
    await fixture.settle { fixture.model.queuedMessages.isEmpty }
    #expect(fixture.model.queuedMessages.isEmpty)
  }

  @Test func aQueuedMessageGoesOutWhenTheTurnEnds() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("after the turn")
    await fixture.model.submit()
    await fixture.push(ComposerThreadSnapshot(phase: .ready))
    await fixture.settle { !fixture.env.sentTurns.isEmpty }
    #expect(fixture.env.sentTurns.count == 1)
  }

  @Test func steerSendsImmediatelyAndAlternateFlipsTheBehavior() async throws {
    let steer = try await ModelFixture.make(followUp: .steer, thread: ComposerThreadSnapshot(phase: .running))
    await steer.settle { steer.model.isRunning }
    steer.type("go left")
    await steer.model.submit()
    #expect(steer.env.sentTurns.count == 1 && steer.model.queuedMessages.isEmpty)
    // The alternate key (modifier+Enter while running) queues instead.
    steer.type("go right later")
    await steer.model.submit(intent: .alternate)
    #expect(steer.env.sentTurns.count == 1 && steer.model.queuedMessages.count == 1)

    let queue = try await ModelFixture.make(followUp: .queue, thread: ComposerThreadSnapshot(phase: .running))
    await queue.settle { queue.model.isRunning }
    queue.type("steer this one")
    await queue.model.submit(intent: .alternate)
    #expect(queue.env.sentTurns.count == 1 && queue.model.queuedMessages.isEmpty)
  }

  @Test func newMessagesLineUpBehindAQueuedOneInsteadOfOvertakingIt() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("first")
    await fixture.model.submit()
    // The provider is picking the thread up ("connecting"): the queued message is not due, and
    // the thread is not running, but a new send must still wait its turn.
    await fixture.push(ComposerThreadSnapshot(phase: .connecting))
    fixture.type("second")
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.isEmpty)
    #expect(fixture.model.queuedMessages.map(\.prompt) == ["first", "second"])
  }

  @Test func stopReturnsQueuedMessagesToTheComposerAndInterruptsTheTurn() async throws {
    var running = ComposerThreadSnapshot(phase: .running)
    running.dispatch = QueuedMessages.DispatchInput(phase: .running, session: .init(status: "running", updatedAt: "t", activeTurnId: "turn-9"))
    let fixture = try await ModelFixture.make(thread: running)
    await fixture.settle { fixture.model.canInterrupt }
    fixture.type("queued one")
    await fixture.model.submit()
    fixture.type("queued two")
    await fixture.model.submit()
    #expect(fixture.model.queuedMessages.count == 2)
    fixture.type("typed now")
    await fixture.model.interrupt()
    #expect(fixture.model.queuedMessages.isEmpty)
    #expect(fixture.model.draft.prompt == "typed now\n\nqueued one\n\nqueued two")
    #expect(fixture.env.interrupts.first?.turnId?.rawValue == "turn-9")
  }

  @Test func sendNowAndEditOnAQueuedRow() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("one")
    await fixture.model.submit()
    fixture.type("two")
    await fixture.model.submit()
    let ids = fixture.model.queuedMessages.map(\.id)
    fixture.model.editQueued(id: ids[1])
    #expect(fixture.model.draft.prompt == "two" && fixture.model.queuedMessages.map(\.id) == [ids[0]])
    fixture.model.steerQueued(id: ids[0])
    await fixture.settle { !fixture.env.sentTurns.isEmpty }
    #expect(fixture.env.sentTurns.first?.command.message.text == "one")
    await fixture.settle { fixture.model.queuedMessages.isEmpty }
  }

  @Test func approvalsAndQuestionsHoldTheQueue() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("waiting")
    await fixture.model.submit()
    await fixture.push(pendingApprovalSnapshot())
    try await Task.sleep(for: .milliseconds(30))
    #expect(fixture.env.sentTurns.isEmpty)
    fixture.model.steerQueued(id: fixture.model.queuedMessages[0].id)
    try await Task.sleep(for: .milliseconds(30))
    #expect(fixture.env.sentTurns.isEmpty, "send now waits for the approval too")
  }

  @Test func aFailedQueuedSendStaysAtTheHeadHeldForTheUser() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("will fail")
    await fixture.model.submit()
    fixture.env.failSendsWith = "offline"
    await fixture.push(ComposerThreadSnapshot(phase: .ready))
    await fixture.settle { fixture.model.queuedMessages.first?.holdUntilUserAction == true }
    #expect(fixture.model.queuedMessages.first?.holdUntilUserAction == true && fixture.model.queuedMessages.first?.sending == nil)
    #expect(fixture.services.notices.contains { $0.title == "Queued message not sent" })
    fixture.env.failSendsWith = nil
    fixture.model.steerQueued(id: fixture.model.queuedMessages[0].id)
    await fixture.settle { fixture.env.sentTurns.count == 1 }
    #expect(fixture.env.sentTurns.count == 1)
  }
}
