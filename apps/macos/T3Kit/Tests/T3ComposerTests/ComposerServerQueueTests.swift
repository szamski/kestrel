import Foundation
import T3Contracts
import T3Timeline
import Testing

@testable import T3Composer

private func item(_ n: Int, text: String? = nil) -> ComposerServerQueue.Item {
  ComposerServerQueue.Item(runId: RunId(rawValue: "run-\(n)"), messageId: MessageId(rawValue: "msg-\(n)"), text: text ?? "queued \(n)")
}

private func running(_ items: [ComposerServerQueue.Item] = [], canReorder: Bool = true, canSteer: Bool = true, held: Bool = false) -> ComposerThreadSnapshot {
  ComposerThreadSnapshot(
    phase: .running, serverQueue: ComposerServerQueue(items: items, activeRunId: RunId(rawValue: "run-0"), isHeld: held, canReorder: canReorder, canPromoteToSteer: canSteer))
}

@MainActor
@Suite("Composer on the server queue (protocol 2)") struct ComposerServerQueueTests {
  @Test func followUpsJoinTheRunAsTheFollowUpBehaviorSays() async throws {
    let queue = try await ModelFixture.make(followUp: .queue, thread: running())
    await queue.settle { queue.model.isRunning }
    queue.type("later")
    await queue.model.submit()
    // The alternate key flips queue to steer.
    queue.type("now")
    await queue.model.submit(intent: .alternate)
    #expect(queue.env.deliveries == [.queue, .steer])
    #expect(queue.model.queuedMessages.isEmpty)

    let steer = try await ModelFixture.make(followUp: .steer, thread: running())
    await steer.settle { steer.model.isRunning }
    steer.type("now")
    await steer.model.submit()
    steer.type("later")
    await steer.model.submit(intent: .alternate)
    #expect(steer.env.deliveries == [.steer, .queue])

    let idle = try await ModelFixture.make(followUp: .queue, thread: ComposerThreadSnapshot(phase: .ready, serverQueue: ComposerServerQueue()))
    await idle.settle { idle.model.serverQueue != nil }
    idle.type("first")
    await idle.model.submit()
    #expect(idle.env.deliveries == [.auto])
  }

  @Test func protocolOneKeepsItsOwnQueue() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .running))
    await fixture.settle { fixture.model.isRunning }
    fixture.type("local")
    await fixture.model.submit()
    #expect(fixture.env.sentTurns.isEmpty && fixture.model.queuedMessages.count == 1 && fixture.model.serverQueue == nil)
  }

  @Test func queueCommandsHonorTheProvidersCapabilities() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1), item(2), item(3)]))
    await fixture.settle { fixture.model.serverQueue?.items.count == 3 }
    fixture.model.steerServerQueued(RunId(rawValue: "run-1"))
    await fixture.settle { fixture.model.busyQueueRunId == nil && !fixture.env.queueCalls.isEmpty }
    // Dropping onto a later row lands after it, onto an earlier one before it.
    fixture.model.dropServerQueued(RunId(rawValue: "run-1"), onto: RunId(rawValue: "run-2"))
    await fixture.settle { fixture.model.busyQueueRunId == nil && fixture.env.queueCalls.count == 2 }
    fixture.model.dropServerQueued(RunId(rawValue: "run-3"), onto: RunId(rawValue: "run-1"))
    await fixture.settle { fixture.model.busyQueueRunId == nil && fixture.env.queueCalls.count == 3 }
    fixture.model.dropServerQueued(RunId(rawValue: "run-1"), onto: RunId(rawValue: "run-3"))
    await fixture.settle { fixture.model.busyQueueRunId == nil && fixture.env.queueCalls.count == 4 }
    fixture.model.cancelServerQueued(RunId(rawValue: "run-2"))
    await fixture.settle { fixture.model.busyQueueRunId == nil && fixture.env.queueCalls.count == 5 }
    #expect(
      fixture.env.queueCalls == [
        "steer run-1 into run-0", "move run-1 before run-3", "move run-3 before run-1", "move run-1 before end", "cancel run-2",
      ])

    let limited = try await ModelFixture.make(thread: running([item(1), item(2)], canReorder: false, canSteer: false))
    await limited.settle { limited.model.serverQueue?.items.count == 2 }
    limited.model.steerServerQueued(RunId(rawValue: "run-1"))
    limited.model.moveServerQueued(RunId(rawValue: "run-2"), before: RunId(rawValue: "run-1"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(limited.env.queueCalls.isEmpty)
  }

  @Test func stopHoldsTheQueueAndTheButtonResumesIt() async throws {
    let fixture = try await ModelFixture.make(thread: ComposerThreadSnapshot(phase: .ready, serverQueue: ComposerServerQueue(items: [item(1)], isHeld: true)))
    await fixture.settle { fixture.model.canResumeQueue }
    #expect(fixture.model.primaryAction == .resume)
    fixture.model.resumeServerQueue()
    await fixture.settle { fixture.env.queueCalls == ["resume"] }
    #expect(fixture.env.queueCalls == ["resume"])
    // Typing something turns the button back into Send.
    fixture.type("hello")
    #expect(fixture.model.primaryAction == .send)
  }

  @Test func stopDoesNotPullTheServerQueueIntoTheComposer() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1)]))
    await fixture.settle { fixture.model.canInterrupt }
    await fixture.model.interrupt()
    #expect(fixture.env.interrupts.count == 1 && fixture.model.draft.prompt.isEmpty)
  }

  @Test func editingParksTheDraftSavesInPlaceAndGivesTheDraftBack() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1, text: "old text")]))
    await fixture.settle { fixture.model.serverQueue?.items.count == 1 }
    fixture.type("my draft")
    fixture.model.editServerQueued(RunId(rawValue: "run-1"))
    #expect(fixture.model.draft.prompt == "old text" && fixture.model.primaryAction == .saveEdit)
    fixture.type("new text")
    await fixture.model.submit()
    #expect(fixture.env.queueCalls == ["edit run-1: new text [0]"] && fixture.env.sentTurns.isEmpty)
    #expect(fixture.model.editingQueued == nil && fixture.model.draft.prompt == "my draft")
  }

  @Test func cancellingAnEditRestoresTheDraft() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1)]))
    await fixture.settle { fixture.model.serverQueue?.items.count == 1 }
    fixture.type("mine")
    fixture.model.editServerQueued(RunId(rawValue: "run-1"))
    fixture.model.cancelQueuedEdit()
    #expect(fixture.model.editingQueued == nil && fixture.model.draft.prompt == "mine" && fixture.env.queueCalls.isEmpty)
  }

  @Test func anEditSurvivesItsRunStartingElsewhereWhenTheDraftIsEmpty() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1, text: "queued 1")]))
    await fixture.settle { fixture.model.serverQueue?.items.count == 1 }
    fixture.model.editServerQueued(RunId(rawValue: "run-1"))
    fixture.type("queued 1, changed")
    await fixture.push(running([]))
    await fixture.settle { fixture.model.editingQueued == nil }
    #expect(fixture.model.editingQueued == nil && fixture.model.draft.prompt == "queued 1, changed")
    #expect(fixture.services.notices.first?.title == "Queued message is no longer queued")
  }

  @Test func aSavingFailureKeepsTheEdit() async throws {
    let fixture = try await ModelFixture.make(thread: running([item(1)]))
    await fixture.settle { fixture.model.serverQueue?.items.count == 1 }
    fixture.model.editServerQueued(RunId(rawValue: "run-1"))
    fixture.env.failSendsWith = "nope"
    await fixture.model.submit()
    #expect(fixture.model.editingQueued != nil && fixture.model.errorMessage == "nope")
  }

  @Test func theUnconfiguredDefaultInstancesRunWithoutSettings() throws {
    // Codex and Claude start on without a `providerInstances` entry; other defaults and stale instances stay off.
    let catalog = try OracleCatalog.load()
    let codex = catalog.entry(0, "codex")
    #expect(codex.enabled)
    #expect(ModelCatalog.resolveInstanceEnabled(driver: "cursor", enabled: nil, configEnabled: nil) == false)
    #expect(ModelCatalog.resolveInstanceEnabled(driver: "codex", enabled: nil, configEnabled: nil))
    #expect(ModelCatalog.resolveInstanceEnabled(driver: "codex", enabled: true, configEnabled: false) == false)
    #expect(ModelCatalog.resolveInstanceEnabled(driver: "opencode", enabled: nil, configEnabled: true))
  }
}
