import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Rules of the pure state machines that the differential oracle cannot see (cursors, windows, epochs).
@Suite struct ThreadDetailMachineTests {
  static func scenario() throws -> (snapshot: V1.OrchestrationThreadDetailSnapshot, events: [V1.OrchestrationEvent]) {
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    return (
      try decode(V1.OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!),
      try (scenario["events"] as! [Any]).map { try decode(V1.OrchestrationEvent.self, $0) })
  }

  static func item(_ event: V1.OrchestrationEvent) -> V1.OrchestrationThreadStreamItem { .event(.init(event: event)) }

  static func config(pagination: Bool = true, marker: Bool = true) -> ServerConfig {
    var config = Fixtures.serverConfig(markers: marker)
    config.threadSnapshotPagination = pagination
    return config
  }

  /// A machine that loaded `snapshot` as a windowed thread (more history above).
  static func windowed(_ snapshot: V1.OrchestrationThreadDetailSnapshot) -> ThreadDetailMachine {
    var machine = ThreadDetailMachine()
    _ = machine.beginSubscription(config: config())
    var windowedSnapshot = snapshot
    windowedSnapshot.page = V1.OrchestrationThreadDetailPage(beforeCursor: "cursor-1", hasMore: true, snapshotSequence: snapshot.snapshotSequence, threadSequence: nil)
    machine.apply(.snapshot(.init(snapshot: windowedSnapshot)))
    return machine
  }

  static func olderPage(of snapshot: V1.OrchestrationThreadDetailSnapshot, sequence: Int, threadSequence: Int?) -> V1.OrchestrationThreadDetailSnapshot {
    var older = snapshot
    older.snapshotSequence = sequence
    older.thread.messages = [
      V1.OrchestrationMessage(id: "older-1", role: .user, text: "earlier", turnId: nil, streaming: false, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"),
      snapshot.thread.messages[0],  // overlap: must not render twice
    ]
    older.thread.activities = []
    older.page = V1.OrchestrationThreadDetailPage(beforeCursor: nil, hasMore: false, snapshotSequence: sequence, threadSequence: threadSequence)
    return older
  }

  @Test func eventsAtOrBelowTheCursorAreDropped() throws {
    let (snapshot, events) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    let first = events[0]
    machine.apply(Self.item(first))
    let after = machine.state
    machine.apply(Self.item(first))
    #expect(machine.state == after, "a replayed event changes nothing")
    #expect(machine.lastSequence == first.sequence)
  }

  @Test func anOlderPageIsMergedOnlyAfterLiveEventsReachedItsWatermark() throws {
    let (snapshot, events) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    let started = machine.beginLoadOlder()
    let request = try #require(started)
    #expect(request.turnLimit == 20 && request.beforeCursor == "cursor-1")
    let second = machine.beginLoadOlder()
    #expect(second == nil, "one fetch at a time")
    let watermark = try #require(events[2].sequence)
    machine.completeLoadOlder(Self.olderPage(of: snapshot, sequence: watermark, threadSequence: watermark), request: request)
    #expect(machine.state.page?.loadingOlder == true, "parked pages keep the loading state")
    #expect(machine.state.data?.messages.contains { $0.id == "older-1" } == false)

    machine.apply(Self.item(events[0]))
    machine.apply(Self.item(events[1]))
    #expect(machine.state.data?.messages.contains { $0.id == "older-1" } == false, "still behind the watermark")
    machine.apply(Self.item(events[2]))
    let messages = try #require(machine.state.data?.messages)
    #expect(messages.first?.id == "older-1", "older rows are prepended")
    #expect(messages.filter { $0.id == snapshot.thread.messages[0].id }.count == 1, "overlapping rows are deduplicated")
    #expect(machine.state.page == ThreadPageState(beforeCursor: nil, hasMore: false, loadingOlder: false))
  }

  @Test func aPageWithoutAWatermarkOrBehindTheLiveStateIsHandledSafely() throws {
    let (snapshot, events) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    machine.apply(Self.item(events[0]))
    // Pre-watermark servers merge at once.
    var started = machine.beginLoadOlder()
    var request = try #require(started)
    machine.completeLoadOlder(Self.olderPage(of: snapshot, sequence: machine.lastSequence, threadSequence: nil), request: request)
    #expect(machine.state.data?.messages.first?.id == "older-1")

    // A page read from a projection behind the loaded state is discarded.
    machine = Self.windowed(snapshot)
    machine.apply(Self.item(events[0]))
    started = machine.beginLoadOlder()
    request = try #require(started)
    machine.completeLoadOlder(Self.olderPage(of: snapshot, sequence: snapshot.snapshotSequence, threadSequence: nil), request: request)
    #expect(machine.state.data?.messages.contains { $0.id == "older-1" } == false)
    #expect(machine.state.page?.loadingOlder == false)
    #expect(machine.state.page?.hasMore == true, "the cursor stays so the user can retry")
  }

  @Test func aRevertOrASnapshotWhileAPageIsInFlightDiscardsIt() throws {
    let (snapshot, events) = try Self.scenario()
    for rewrite in ["revert", "snapshot"] {
      var machine = Self.windowed(snapshot)
      let started = machine.beginLoadOlder()
    let request = try #require(started)
      if rewrite == "revert" {
        let all = try #require(try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic")["events"] as? [Any])
        let revert = try #require(all.compactMap { try? decode(V1.OrchestrationEvent.self, $0) }.first { $0.isThreadReverted })
        machine.apply(Self.item(revert))
      } else {
        machine.apply(.snapshot(.init(snapshot: snapshot)))
      }
      machine.completeLoadOlder(Self.olderPage(of: snapshot, sequence: machine.lastSequence + 100, threadSequence: nil), request: request)
      #expect(machine.state.data?.messages.contains { $0.id == "older-1" } == false, "\(rewrite): history was rewritten under the fetch")
      _ = events
    }
  }

  @Test func paginationIsOnlyUsedWhenTheServerAdvertisesIt() throws {
    let (snapshot, _) = try Self.scenario()
    var machine = ThreadDetailMachine()
    let plan = machine.beginSubscription(config: Self.config(pagination: false))
    #expect(plan.needsSnapshot)
    let noWindow = machine.subscribeInput(threadId: snapshot.thread.id, config: Self.config(pagination: false))
    #expect(noWindow.turnLimit == nil)
    machine.apply(.snapshot(.init(snapshot: snapshot)))
    let none = machine.beginLoadOlder()
    #expect(none == nil)

    // A windowed cache must not resume against a server that cannot page: reload fully.
    var cached = snapshot
    cached.page = V1.OrchestrationThreadDetailPage(beforeCursor: "c", hasMore: true, snapshotSequence: snapshot.snapshotSequence, threadSequence: nil)
    var resumed = ThreadDetailMachine(cached: cached)
    #expect(resumed.state.page?.hasMore == true && resumed.state.status == .cached)
    let resumePlan = resumed.beginSubscription(config: Self.config(pagination: false))
    #expect(resumePlan.needsSnapshot)
    #expect(resumed.state.data == nil && resumed.lastSequence == 0)
  }

  @Test func subscribeInputResumesFromTheCursorOnlyWithData() throws {
    let (snapshot, _) = try Self.scenario()
    var fresh = ThreadDetailMachine()
    _ = fresh.beginSubscription(config: Self.config())
    let cold = fresh.subscribeInput(threadId: snapshot.thread.id, config: Self.config())
    #expect(cold.afterSequence == nil && cold.requestCompletionMarker && cold.turnLimit == ThreadPaging.initialUserTurnLimit)
    fresh.apply(.snapshot(.init(snapshot: snapshot)))
    let warm = fresh.subscribeInput(threadId: snapshot.thread.id, config: Self.config())
    #expect(warm.afterSequence == snapshot.snapshotSequence)
    #expect(fresh.state.status == .synchronizing, "with a completion marker the stream proves liveness, not the resume")
    fresh.apply(.synchronized)
    #expect(fresh.state.status == .live)
  }

  @Test func aRetainedLiveStateStaysLiveAndOnlyAnErrorDowngradesIt() throws {
    let (snapshot, _) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    machine.apply(.synchronized)
    var again = ThreadDetailMachine(retained: machine.resumeSnapshot)
    #expect(again.state.status == .live && again.lastSequence == machine.lastSequence)
    again.markSynchronizing()
    #expect(again.state.status == .live, "the first subscription after a warm resume keeps the retained status")
    _ = again.beginSubscription(config: Self.config())
    #expect(again.state.status == .live)
    again.setStreamError("boom")
    #expect(again.state.status == .cached && again.state.error == "boom")
    again.setConnecting()
    #expect(again.state.error == "boom", "a diagnostic is cleared only when a subscription actually retries")
    again.markSynchronizing()
    #expect(again.state.error == nil && again.state.status == .synchronizing)
  }

  @Test func batchesApplyLikeOneByOne() throws {
    let (snapshot, events) = try Self.scenario()
    let items = events.map(Self.item) + [.synchronized]
    var sequential = Self.windowed(snapshot)
    for item in items { sequential.apply(item) }
    var batched = Self.windowed(snapshot)
    batched.apply(items)
    #expect(batched.state == sequential.state)
    #expect(batched.lastSequence == sequential.lastSequence)
  }

  @Test func runningTurnsAreNotPersistedUntilTheySettle() throws {
    let (snapshot, events) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    _ = machine.takePersistRequest()
    let running = try #require(events.first { if case .threadSessionSet(let e) = $0 { e.payload.session.status == .running } else { false } })
    machine.apply(Self.item(running))
    let whileRunning = machine.takePersistRequest()
    #expect(whileRunning == nil, "a streaming thread is the server's to keep")
    let settled = try #require(events.first { if case .threadSessionSet(let e) = $0 { e.payload.session.status == .ready } else { false } })
    machine.apply(Self.item(settled))
    let persisted = machine.takePersistRequest()
    let request = try #require(persisted)
    #expect(request.snapshot.snapshotSequence == settled.sequence)
    #expect(request.snapshot.page?.beforeCursor == "cursor-1", "the window boundary is saved with the window")
  }

  @Test func keepAliveReleasesOnlyDetailsThatAreDone() throws {
    let (snapshot, events) = try Self.scenario()
    var machine = Self.windowed(snapshot)
    #expect(!ThreadSyncRegistry.isDetailDone(machine.state), "still synchronizing")
    machine.apply(.synchronized)
    #expect(ThreadSyncRegistry.isDetailDone(machine.state))
    let running = try #require(events.first { if case .threadSessionSet(let e) = $0 { e.payload.session.status == .running } else { false } })
    machine.apply(Self.item(running))
    #expect(!ThreadSyncRegistry.isDetailDone(machine.state), "live but showing a running session")
    machine.setStreamError("x")
    #expect(ThreadSyncRegistry.isDetailDone(machine.state), "a failed stream cannot progress")
  }
}

@Suite struct ShellMachineTests {
  @Test func statusFollowsCachedSynchronizingLiveAndNeverClaimsLiveOffline() {
    var machine = ShellStateMachine(cached: Data2.shell())
    #expect(machine.state.status == .cached)
    machine.setSynchronizing()
    machine.beginSubscription(supportsCompletionMarker: true)
    let cursor = machine.state.snapshot!.snapshotSequence
    machine.apply([Data2.threadUpserted(cursor + 1, id: "a")])
    #expect(machine.state.status == .synchronizing, "replay before the marker")
    machine.apply([.synchronized])
    #expect(machine.state.status == .live)
    machine.setDisconnected()
    #expect(machine.state.status == .cached)
    machine.setStreamError()
    #expect(machine.state.error == ShellStateMachine.synchronizationErrorMessage && machine.state.status == .cached)
    machine.beginSubscription(supportsCompletionMarker: false)
    #expect(machine.state.error == nil)
  }

  @Test func withoutASnapshotNothingGoesLiveAndAnEmptyShellStaysEmpty() {
    var machine = ShellStateMachine()
    machine.beginSubscription(supportsCompletionMarker: true)
    let result = machine.apply([.synchronized, Data2.threadUpserted(5, id: "a")])
    #expect(machine.state.status == .synchronizing && machine.state.snapshot == nil, "events need a snapshot to apply to")
    #expect(result.receivedSnapshot == false)
    machine.setDisconnected()
    #expect(machine.state.status == .empty)
  }

  @Test func wholeObjectUpsertsReplaceAndAppend() {
    var machine = ShellStateMachine(cached: Data2.shell())
    let cursor = machine.state.snapshot!.snapshotSequence
    let existing = machine.state.snapshot!.threads[3].id
    machine.apply([Data2.threadUpserted(cursor + 1, id: existing.rawValue) { $0.title = "renamed" }, Data2.threadUpserted(cursor + 2, id: "brand-new")])
    let threads = machine.state.snapshot!.threads
    #expect(threads[3].title == "renamed" && threads.count == 26 && threads.last?.id == "brand-new")
  }
}

@Suite struct OptimisticOverlayTests {
  func thread() -> V1.OrchestrationThreadShell {
    var shell = Data2.shell().threads[0]
    shell.settledOverride = nil; shell.settledAt = nil; shell.session = nil
    shell.hasPendingApprovals = false; shell.hasPendingUserInput = false; shell.latestUserMessageAt = nil
    shell.pinnedAt = .some(nil); shell.pinOrderKey = .some(nil); shell.snoozedUntil = .some(nil); shell.snoozedAt = .some(nil)
    return shell
  }
  let now = IsoDateTime(rawValue: "2026-10-08T12:00:00.000Z")

  @Test func settleClearsEverythingThatKeepsAThreadInTheInbox() {
    var shell = thread()
    shell.pinnedAt = .some("2026-10-01T00:00:00.000Z")
    shell.pinOrderKey = .some("k")
    shell.activeOrderKey = .some("a")
    shell.snoozedUntil = .some("2026-10-09T00:00:00.000Z")
    let settled = OptimisticAction.settle.apply(shell, now: now, accepted: false)
    #expect(settled.settledOverride == .settled && settled.settledAt == now)
    #expect(optionalValue(settled.pinnedAt) == nil && optionalValue(settled.pinOrderKey) == nil && optionalValue(settled.activeOrderKey) == nil)
    #expect(optionalValue(settled.snoozedUntil) == nil)
    // Guarded like the server: a blocked or running thread is not settled optimistically...
    var running = thread()
    running.session = V1.OrchestrationSession(threadId: running.id, status: .running, runtimeMode: .fullAccess, updatedAt: now)
    #expect(OptimisticAction.settle.apply(running, now: now, accepted: false) == running)
    // ...unless the server already accepted the command.
    #expect(OptimisticAction.settle.apply(running, now: now, accepted: true).settledOverride == .settled)
  }

  @Test func snoozeNeedsAFutureWakeTimeAndKeepsTheOriginalSnoozeStamp() {
    let until = IsoDateTime(rawValue: "2026-10-08T15:00:00.000Z")
    var shell = thread()
    #expect(OptimisticAction.snooze(until: now).apply(shell, now: now, accepted: false) == shell, "a wake time that is not in the future is ignored")
    let snoozed = OptimisticAction.snooze(until: until).apply(shell, now: now, accepted: false)
    #expect(optionalValue(snoozed.snoozedUntil) == until && optionalValue(snoozed.snoozedAt) == now)
    shell = snoozed
    let later = IsoDateTime(rawValue: "2026-10-08T12:30:00.000Z")
    #expect(optionalValue(OptimisticAction.snooze(until: until).apply(shell, now: later, accepted: true).snoozedAt) == now, "re-snoozing to the same time keeps the stamp")
    shell.hasPendingApprovals = true
    #expect(OptimisticAction.snooze(until: until).apply(shell, now: now, accepted: false) == shell, "blocked on the user: not snoozable")
  }

  @Test func pinningWakesASettledThreadAndKeepsAnExistingPin() {
    var shell = thread()
    shell.settledOverride = .settled
    shell.settledAt = now
    let pinned = OptimisticAction.pin(orderKey: "m").apply(shell, now: now, accepted: false)
    #expect(optionalValue(pinned.pinnedAt) == now && optionalValue(pinned.pinOrderKey) == "m")
    #expect(pinned.settledOverride == .active && pinned.settledAt == nil && optionalValue(pinned.unsettledAt) == now)
    let again = OptimisticAction.pin(orderKey: "z").apply(pinned, now: IsoDateTime(rawValue: "2026-10-08T13:00:00.000Z"), accepted: true)
    #expect(optionalValue(again.pinnedAt) == now && optionalValue(again.pinOrderKey) == "m", "already pinned: nothing changes")
  }

  @Test func updatesAreDroppedOnceTheShellReachesTheirSequenceAndRolledBackOnRemove() {
    var overlay = OptimisticOverlay()
    var snapshot = Data2.shell()
    let target = snapshot.threads[0]
    snapshot.threads[0] = thread()
    let id = overlay.add(threadId: target.id, action: .reorderActive(orderKey: "zz"), now: now)
    #expect(optionalValue(overlay.apply(to: snapshot).threads[0].activeOrderKey) == "zz")
    overlay.accept(id, sequence: snapshot.snapshotSequence + 2)
    snapshot.snapshotSequence += 1
    overlay.reconcile(with: snapshot)
    #expect(!overlay.isEmpty, "not yet reached")
    snapshot.snapshotSequence += 1
    overlay.reconcile(with: snapshot)
    #expect(overlay.isEmpty)
    let failed = overlay.add(threadId: target.id, action: .unpin, now: now)
    overlay.remove(failed)
    #expect(overlay.apply(to: snapshot) == snapshot)
  }
}

@Suite struct ClientStateTests {
  @Test func visitsNeverMoveBackwardsAndUnreadStampsOneMillisecondBeforeCompletion() {
    var state = ClientState()
    state.markVisited("env:t", at: "2026-10-08T12:00:00.000Z")
    state.markVisited("env:t", at: "2026-10-08T11:00:00.000Z")
    #expect(state.threadLastVisitedAtById["env:t"]?.rawValue == "2026-10-08T12:00:00.000Z")
    state.markVisited("env:t", at: "garbage")
    #expect(state.threadLastVisitedAtById["env:t"]?.rawValue == "2026-10-08T12:00:00.000Z")
    state.markUnread("env:t", latestTurnCompletedAt: "2026-10-08T12:00:05.000Z")
    #expect(state.threadLastVisitedAtById["env:t"]?.rawValue == "2026-10-08T12:00:04.999Z")
    state.markUnread("env:t", latestTurnCompletedAt: nil)
    #expect(state.threadLastVisitedAtById["env:t"]?.rawValue == "2026-10-08T12:00:04.999Z")
  }

  @Test func unreadIsACompletionNewerThanTheLastVisit() {
    var shell = Data2.shell().threads[0]
    shell.latestTurn = V1.OrchestrationLatestTurn(
      turnId: "t", state: .completed, requestedAt: "2026-10-08T11:00:00.000Z", completedAt: "2026-10-08T12:00:00.000Z")
    #expect(!ThreadList.hasUnseenCompletion(shell, lastVisitedAt: nil), "never visited counts as read")
    #expect(ThreadList.hasUnseenCompletion(shell, lastVisitedAt: "2026-10-08T11:59:59.999Z"))
    #expect(!ThreadList.hasUnseenCompletion(shell, lastVisitedAt: "2026-10-08T12:00:00.000Z"))
    #expect(ThreadList.hasUnseenCompletion(shell, lastVisitedAt: "not a date"), "a corrupt visit stamp must not hide a completion")
  }

  @Test func removingAnEnvironmentClearsItsVisits() {
    var state = ClientState()
    state.markVisited("env-a:t1", at: "2026-10-08T12:00:00.000Z")
    state.markVisited("env-b:t1", at: "2026-10-08T12:00:00.000Z")
    state.removeEnvironment("env-a")
    #expect(Array(state.threadLastVisitedAtById.keys) == ["env-b:t1"])
  }

  @Test func timestampsParseAndFormatLikeDateParseAndToISOString() {
    for text in ["2026-10-08T12:00:00.000Z", "2026-02-28T23:59:59.999Z", "1970-01-01T00:00:00.000Z", "2024-02-29T00:00:00.001Z"] {
      let ms = IsoTimestamp.parse(text)!
      #expect(IsoTimestamp.format(milliseconds: ms).rawValue == text)
    }
    #expect(IsoTimestamp.parse("2026-10-08T12:00:00Z") == IsoTimestamp.parse("2026-10-08T12:00:00.000Z"))
    #expect(IsoTimestamp.parse("2026-10-08T14:00:00.000+02:00") == IsoTimestamp.parse("2026-10-08T12:00:00.000Z"), "offsets fall back to Foundation")
    #expect(IsoTimestamp.parse("nope") == nil)
  }
}
