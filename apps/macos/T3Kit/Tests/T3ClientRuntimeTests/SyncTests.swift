import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Shell, thread and command flows against a fake environment server: the real RPC session and
/// supervisor run over an in-process transport, time is a manual clock.
@Suite(.timeLimit(.minutes(1))) struct SyncTests {
  struct Harness {
    let runtime: EnvironmentRuntime
    let servers: [FakeServer]
    let loader: FakeLoader
    let clock: ManualClock
    let cache: SQLiteSnapshotCache
    let driver: FakeServerDriver
    var environmentId: EnvironmentId { runtime.entry.environmentId }

    static func make(
      servers: [FakeServer], shell: OrchestrationShellSnapshot? = Data2.shell(), thread: OrchestrationThreadDetailSnapshot? = nil,
      cache: SQLiteSnapshotCache? = nil, keepAlive: Bool = false, start: Bool = true, uploadSession: URLSession = URLSession(configuration: .ephemeral)
    ) async throws -> Harness {
      let config = Fixtures.serverConfig()
      let entry = EnvironmentConnectionEntry(
        environmentId: config.environment.environmentId, label: "Fake", httpBaseURL: URL(string: "http://localhost:1")!, wsBaseURL: URL(string: "ws://localhost:1")!)
      let loader = FakeLoader(shell: shell, thread: thread)
      let clock = ManualClock()
      let cache = try cache ?? SQLiteSnapshotCache(path: nil)
      let driver = FakeServerDriver(servers)
      let runtime = EnvironmentRuntime(entry: entry, driver: driver, cache: cache, loader: loader, clock: clock, network: .online, keepRunningThreadsMounted: keepAlive, urlSession: uploadSession)
      if start { await runtime.start() }
      return Harness(runtime: runtime, servers: servers, loader: loader, clock: clock, cache: cache, driver: driver)
    }
  }

  // MARK: Shell

  @Test func shellLoadsHttpSnapshotThenResumesAfterItsCursor() async throws {
    let server = FakeServer()
    let snapshot = Data2.shell()
    let h = try await Harness.make(servers: [server], shell: snapshot)
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["afterSequence"] as? Int == snapshot.snapshotSequence)
    #expect(request.payload["requestCompletionMarker"] as? Bool == true)
    #expect(h.loader.shellCalls == 1)

    // Replay: a stale event is dropped, newer ones apply, `synchronized` flips the status to live.
    let cursor = snapshot.snapshotSequence
    try server.chunk(request, items: [Data2.threadUpserted(cursor, id: "stale"), Data2.threadUpserted(cursor + 3, id: "fresh")])
    let replaying = await waitFor(h.runtime.shell) { $0.snapshot?.snapshotSequence == cursor + 3 }
    #expect(replaying.status == .synchronizing)
    #expect(replaying.snapshot?.threads.contains { $0.id == "stale" } == false)
    #expect(replaying.snapshot?.threads.contains { $0.id == "fresh" } == true)
    try server.chunk(request, items: [OrchestrationShellStreamItem.synchronized, Data2.threadUpserted(cursor + 4, id: "live")])
    let live = await waitFor(h.runtime.shell) { $0.status == .live && $0.snapshot?.snapshotSequence == cursor + 4 }
    #expect(live.error == nil)
    await h.runtime.stop()
  }

  @Test func withoutAnHttpSnapshotTheSocketSendsTheFullSnapshot() async throws {
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], shell: nil)
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["afterSequence"] == nil, "no cursor without authoritative data")
    #expect(request.payload["requestCompletionMarker"] as? Bool == true)
    var snapshot = Data2.shell()
    snapshot.snapshotSequence = 500
    try server.chunk(request, items: [OrchestrationShellStreamItem.snapshot(.init(snapshot: snapshot)), .synchronized])
    let state = await waitFor(h.runtime.shell) { $0.status == .live }
    #expect(state.snapshot?.snapshotSequence == 500)
    await h.runtime.stop()
  }

  @Test func serversWithoutACompletionMarkerAreLiveAsSoonAsTheyResume() async throws {
    let server = FakeServer(config: Fixtures.serverConfig(markers: false))
    let h = try await Harness.make(servers: [server])
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["requestCompletionMarker"] == nil)
    let state = await waitFor(h.runtime.shell) { $0.status == .live }
    #expect(state.snapshot != nil)
    await h.runtime.stop()
  }

  @Test func aNewSessionReloadsTheAuthoritativeSnapshotAndResumesFromTheLiveCursor() async throws {
    let first = FakeServer(), second = FakeServer()
    let h = try await Harness.make(servers: [first, second])
    let cursor = Data2.shell().snapshotSequence
    let initial = await first.waitForRequest("orchestration.subscribeShell")
    try first.chunk(initial, items: [Data2.threadUpserted(cursor + 10, id: "x"), OrchestrationShellStreamItem.synchronized])
    _ = await waitFor(h.runtime.shell) { $0.status == .live && $0.snapshot?.snapshotSequence == cursor + 10 }
    first.close()  // socket lost
    _ = await waitFor(h.runtime.supervisor.state) { $0.phase == .backoff }
    let offline = await waitFor(h.runtime.shell) { $0.status == .cached }
    #expect(offline.snapshot != nil, "cached data stays readable but must not claim to be live")
    await h.clock.advance(by: .seconds(3))
    let resumed = await second.waitForRequest("orchestration.subscribeShell")
    #expect(h.loader.shellCalls == 2, "a replacement session reloads the authoritative snapshot")
    #expect(resumed.payload["afterSequence"] as? Int == cursor, "the reloaded snapshot sets the cursor")
    await h.runtime.stop()
  }

  @Test func theCacheSeedsTheFirstPaintAndLiveDataIsWrittenBack() async throws {
    let cache = try SQLiteSnapshotCache(path: nil)
    var cached = Data2.shell()
    cached.snapshotSequence = 7
    await cache.saveShell(Fixtures.environmentIdFromConfig, cached)
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], shell: nil, cache: cache, start: false)
    await h.runtime.start()
    #expect(h.runtime.shellSync.state.value.status != .empty)
    let first = await waitFor(h.runtime.shell) { $0.snapshot?.snapshotSequence == 7 }
    #expect(first.status == .cached || first.status == .synchronizing)
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["afterSequence"] == nil, "a cached cursor is not trusted without an authoritative refresh")
    await h.runtime.stop()
  }

  // MARK: Thread

  func threadHarness(_ server: FakeServer = FakeServer(), keepAlive: Bool = false) async throws -> (Harness, OrchestrationThreadDetailSnapshot, ThreadId) {
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    let snapshot = try decode(OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!)
    let h = try await Harness.make(servers: [server], thread: snapshot, keepAlive: keepAlive)
    return (h, snapshot, snapshot.thread.id)
  }

  func events(_ count: Int) throws -> [OrchestrationEvent] {
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    return try (scenario["events"] as! [Any]).prefix(count).map { try decode(OrchestrationEvent.self, $0) }
  }

  @Test func threadDetailLoadsAWindowedSnapshotThenFollowsLiveEvents() async throws {
    let server = FakeServer()
    let (h, snapshot, threadId) = try await threadHarness(server)
    let lease = await h.runtime.threads.acquire(threadId)
    let request = await server.waitForRequest("orchestration.subscribeThread")
    #expect(request.payload["threadId"] as? String == threadId.rawValue)
    #expect(request.payload["afterSequence"] as? Int == snapshot.snapshotSequence)
    #expect(request.payload["turnLimit"] as? Int == 10)
    #expect(h.loader.threadCalls == [ThreadSnapshotWindow(turnLimit: 10)])

    let deltas = try events(12).filter { if case .threadMessageSent = $0 { true } else { false } }
    try server.chunk(request, items: deltas.map { OrchestrationThreadStreamItem.event(.init(event: $0)) })
    let replaying = await waitFor(lease.state) { $0.data?.messages.first { $0.id == "m-asst-1" }?.text == "Hello world" }
    #expect(replaying.status == .synchronizing)
    #expect(replaying.data?.messages.first { $0.id == "m-asst-1" }?.text == "Hello world")
    try server.chunk(request, items: [OrchestrationThreadStreamItem.synchronized])
    let live = await waitFor(lease.state) { $0.status == .live }
    #expect(live.data?.messages.contains { $0.id == "m-user-1" } == true)
    await lease.release()
    await h.runtime.stop()
  }

  @Test func consumersShareOneStreamAndTheStateIsRetainedForFiveIdleMinutes() async throws {
    let server = FakeServer()
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    let snapshot = try decode(OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!)
    let h = try await Harness.make(servers: [server], thread: snapshot)
    let threadId = snapshot.thread.id

    let a = await h.runtime.threads.acquire(threadId)
    let b = await h.runtime.threads.acquire(threadId)
    let request = await server.waitForRequest("orchestration.subscribeThread")
    #expect(server.requests("orchestration.subscribeThread").count == 1, "mounted consumers share one live stream")
    try server.chunk(request, items: [OrchestrationThreadStreamItem.synchronized])
    _ = await waitFor(a.state) { $0.status == .live }

    await a.release()
    #expect(await h.runtime.threads.liveThreadIds == [threadId], "a hidden mounted consumer still counts")
    await b.release()
    #expect(await h.runtime.threads.liveThreadIds.isEmpty)
    #expect(await h.runtime.threads.idleThreadIds == [threadId])
    #expect(server.interrupted.count >= 1, "the stream stops with the last consumer")

    // Back navigation inside five minutes: same state, resume with the saved cursor, no new snapshot download.
    await h.clock.advance(by: .seconds(299), waitForSleeper: false)
    let calls = h.loader.threadCalls.count
    let again = await h.runtime.threads.acquire(threadId)
    #expect(again.state.value.status == .live && again.state.value.data != nil, "a retained live state stays live")
    #expect(h.loader.threadCalls.count == calls)
    await again.release()

    // Idle for the full five minutes: evicted.
    // The eviction timer may not be registered yet: keep moving time until it fires.
    var idle = await h.runtime.threads.idleThreadIds
    while !idle.isEmpty {
      await h.clock.advance(by: .seconds(301), waitForSleeper: false)
      await Task.yield()
      idle = await h.runtime.threads.idleThreadIds
    }
    let reloaded = await h.runtime.threads.acquire(threadId)
    // Evicted from memory, but the settled state was saved to disk: it seeds the view, still marked as syncing.
    #expect(reloaded.state.value.data != nil && reloaded.state.value.status == .synchronizing)
    #expect(h.loader.threadCalls.count == calls, "a disk-cached thread resumes with its cursor instead of downloading again")
    await reloaded.release()
    await h.runtime.stop()
  }

  @Test func aDeletedThreadReportsDeletedAndLeavesTheCache() async throws {
    let server = FakeServer()
    let (h, _, threadId) = try await threadHarness(server)
    let lease = await h.runtime.threads.acquire(threadId)
    let request = await server.waitForRequest("orchestration.subscribeThread")
    let all = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic")
    let deleted = try decode(OrchestrationEvent.self, (all["events"] as! [Any]).last!)
    try server.chunk(request, items: [OrchestrationThreadStreamItem.event(.init(event: deleted))])
    let state = await waitFor(lease.state) { $0.status == .deleted }
    #expect(state.data == nil)
    #expect(await h.cache.loadThread(h.environmentId, threadId) == nil)
    await lease.release()
    await h.runtime.stop()
  }

  @Test func runningThreadsStayMountedUntilTheirOwnDetailShowsTheStop() async throws {
    let server = FakeServer()
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    let snapshot = try decode(OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!)
    let h = try await Harness.make(servers: [server], thread: snapshot)
    let threadId = snapshot.thread.id
    await h.runtime.threads.reconcileKeepAlive(running: [threadId])
    #expect(await h.runtime.threads.keptThreadIds == [threadId])
    let request = await server.waitForRequest("orchestration.subscribeThread")

    // The shell says it stopped, but the detail is not live yet: stay mounted.
    await h.runtime.threads.reconcileKeepAlive(running: [])
    #expect(await h.runtime.threads.keptThreadIds == [threadId])

    // Detail catches up (synchronized, settled session): the stream closes.
    try server.chunk(request, items: [OrchestrationThreadStreamItem.synchronized])
    var kept = await h.runtime.threads.keptThreadIds
    while !kept.isEmpty { await Task.yield(); kept = await h.runtime.threads.keptThreadIds }
    #expect(await h.runtime.threads.liveThreadIds.isEmpty)
    await h.runtime.stop()
  }

  // MARK: Commands

  func firstThread(_ h: Harness) -> OrchestrationThreadShell { h.runtime.shell.value.snapshot!.threads.first { $0.settledOverride != .settled && $0.session == nil } ?? h.runtime.shell.value.snapshot!.threads[0] }

  @Test func settleShowsAtOnceStaysUntilTheShellReachesItsSequenceAndRollsBackOnFailure() async throws {
    let server = FakeServer()
    var initial = Data2.shell()
    initial.threads[0].settledOverride = nil
    initial.threads[0].session = nil
    initial.threads[0].hasPendingApprovals = false
    initial.threads[0].hasPendingUserInput = false
    initial.threads[0].latestUserMessageAt = nil
    initial.threads[0].pinnedAt = .some(nil)
    let h = try await Harness.make(servers: [server], shell: initial)
    let subscribe = await server.waitForRequest("orchestration.subscribeShell")
    try server.chunk(subscribe, items: [OrchestrationShellStreamItem.synchronized])
    let base = await waitFor(h.runtime.shell) { $0.status == .live }
    let target = base.snapshot!.threads[0]
    let cursor = base.snapshot!.snapshotSequence

    // Success path: pending -> accepted (still shown) -> reconciled by the server's own event.
    async let dispatched = h.runtime.dispatch(ThreadCommand.settle(target.id), thread: target.id, optimistic: .settle)
    let request = await server.waitForRequest("orchestration.dispatchCommand")
    #expect(request.payload["type"] as? String == "thread.settle")
    #expect(request.payload["threadId"] as? String == target.id.rawValue)
    let commandId = try #require(request.payload["commandId"] as? String)
    #expect(UUID(uuidString: commandId) != nil, "commandId is a UUID")
    let optimistic = await waitFor(h.runtime.shell) { $0.snapshot?.threads.first { $0.id == target.id }?.settledOverride == .settled }
    #expect(optimistic.snapshot?.snapshotSequence == cursor, "the overlay does not touch the synchronised cursor")
    server.succeed(request, ["sequence": cursor + 5])
    #expect(try await dispatched.sequence == cursor + 5)
    #expect(h.runtime.shell.value.snapshot?.threads.first { $0.id == target.id }?.settledOverride == .settled, "accepted but not yet confirmed by the shell")
    #expect(h.runtime.shellSync.state.value.snapshot?.threads.first { $0.id == target.id }?.settledOverride != .settled)
    let confirmed = Data2.threadUpserted(cursor + 5, id: target.id.rawValue) { $0 = target; $0.settledOverride = .settled; $0.settledAt = IsoDateTime(rawValue: "2026-10-08T12:00:00.000Z") }
    try server.chunk(subscribe, items: [confirmed])
    _ = await waitFor(h.runtime.shellSync.state) { $0.snapshot?.snapshotSequence == cursor + 5 }
    let reconciled = await waitFor(h.runtime.shell) { $0.snapshot?.threads.first { $0.id == target.id }?.settledAt?.rawValue == "2026-10-08T12:00:00.000Z" }
    #expect(reconciled.snapshot?.snapshotSequence == cursor + 5, "server data replaces the optimistic stamp")

    // Failure path: the optimistic change is rolled back.
    async let failing = h.runtime.dispatch(ThreadCommand.pin(target.id), thread: target.id, optimistic: .pin(orderKey: nil))
    let second = await server.waitForRequest("orchestration.dispatchCommand", count: 2)
    _ = await waitFor(h.runtime.shell) { optionalValue($0.snapshot?.threads.first { $0.id == target.id }?.pinnedAt) != nil }
    server.fail(second, error: ["_tag": "OrchestrationDispatchCommandError", "message": "Thread is pinned elsewhere"])
    do {
      _ = try await failing
      Issue.record("expected a rejection")
    } catch {
      #expect((error as? CommandError) == .rejected(message: "Thread is pinned elsewhere"))
    }
    #expect(optionalValue(h.runtime.shell.value.snapshot?.threads.first { $0.id == target.id }?.pinnedAt) == nil)
    await h.runtime.stop()
  }

  @Test func commandsFailFastWhenTheEnvironmentIsNotConnected() async throws {
    let h = try await Harness.make(servers: [], start: false)
    await h.runtime.start()
    do {
      _ = try await h.runtime.dispatch(ThreadCommand.archive("t"), thread: "t")
      Issue.record("expected notConnected")
    } catch {
      guard case .notConnected = error else { Issue.record("unexpected \(error)"); return }
    }
    await h.runtime.stop()
  }
}

extension Fixtures {
  static var environmentIdFromConfig: EnvironmentId { serverConfig().environment.environmentId }
}
