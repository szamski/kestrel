import Foundation
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// Protocol-2 sync and commands against a fake environment server: the real RPC session and supervisor run over an
/// in-process transport, the descriptor's protocol is chosen per connection attempt, time is a manual clock.
@Suite(.timeLimit(.minutes(1))) struct V2FlowTests {
  struct Harness {
    let runtime: EnvironmentRuntime
    let loader: FakeLoader
    let clock: ManualClock
    let cache: SQLiteSnapshotCache
    var environmentId: EnvironmentId { runtime.entry.environmentId }

    static func make(
      servers: [FakeServer], protocols: [OrchestrationProtocol] = [.v2], loader: FakeLoader, cache: SQLiteSnapshotCache? = nil
    ) async throws -> Harness {
      let config = Fixtures.serverConfig()
      let entry = EnvironmentConnectionEntry(
        environmentId: config.environment.environmentId, label: "Fake", httpBaseURL: URL(string: "http://localhost:1")!, wsBaseURL: URL(string: "ws://localhost:1")!)
      let clock = ManualClock()
      let cache = try cache ?? SQLiteSnapshotCache(path: nil)
      let driver = FakeServerDriver(servers, protocols: protocols)
      let runtime = EnvironmentRuntime(entry: entry, driver: driver, cache: cache, loader: loader, clock: clock, network: .online, keepRunningThreadsMounted: false)
      await runtime.start()
      _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected }
      return Harness(runtime: runtime, loader: loader, clock: clock, cache: cache)
    }

    /// Lets the backoff after a lost connection run out. The state says `backoff` slightly before the supervisor
    /// sleeps, and other sleepers (cache writers) can satisfy `advance` first, so advance until it left the backoff.
    func reconnect() async {
      _ = await waitFor(runtime.supervisor.state) { $0.phase == .backoff }
      while runtime.supervisor.state.value.phase == .backoff {
        await clock.advance(by: .seconds(3))
        try? await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  private func shellSnapshot() throws -> OrchestrationV2ShellSnapshot { try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot") }
  private func bounded() throws -> OrchestrationV2ThreadBoundedSnapshot { try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot") }
  private let threadId = ThreadId(rawValue: "thread-v2")

  // MARK: Shell

  @Test func theShellLoadsOverHttpThenResumesAfterItsCursorAndReplaysDeltas() async throws {
    let server = FakeServer()
    let snapshot = try shellSnapshot()
    let h = try await Harness.make(servers: [server], loader: FakeLoader(shellV2: snapshot))
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["afterSequence"] as? Int == 100 && request.payload["requestCompletionMarker"] as? Bool == true)
    let updates = try WireFixture.decode([OrchestrationV2ShellStreamItem].self, "v2-shell-stream-updates")
    try server.chunk(request, items: Array(updates.dropFirst().prefix(2)))
    let replaying = await waitFor(h.runtime.shell) { $0.v2?.snapshotSequence == 102 }
    #expect(replaying.status == .synchronizing, "replay is not live until the completion marker")
    #expect(replaying.snapshot?.threads.first?.title == "Updated fixture thread" && replaying.snapshot?.projects.first?.title == "Updated fixture project")
    try server.chunk(request, items: [updates[0]])
    let live = await waitFor(h.runtime.shell) { $0.status == .live }
    #expect(live.error == nil)
    // The thread removed by the next delta leaves the sidebar-shaped snapshot too.
    try server.chunk(request, items: [updates[3]])
    let removed = await waitFor(h.runtime.shell) { $0.v2?.snapshotSequence == 103 }
    #expect(removed.snapshot?.threads.isEmpty == true)
    await h.runtime.stop()
  }

  @Test func aServerThatChangedProtocolDropsTheOldCacheAndResyncsFromItsOwnSnapshot() async throws {
    let cache = try SQLiteSnapshotCache(path: nil)
    var old = Data2.shell()
    old.snapshotSequence = 9_999
    await cache.saveShell(Fixtures.environmentIdFromConfig, old)
    #expect(await cache.cachedProtocol(Fixtures.environmentIdFromConfig) == .v1)
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], protocols: [.v2], loader: FakeLoader(shellV2: try shellSnapshot()), cache: cache)
    let request = await server.waitForRequest("orchestration.subscribeShell")
    #expect(request.payload["afterSequence"] as? Int == 100, "the V1 cursor 9999 must not be sent to a protocol-2 server")
    let state = await waitFor(h.runtime.shell) { $0.v2 != nil }
    #expect(state.snapshot?.snapshotSequence == 100)
    #expect(await cache.cachedProtocol(Fixtures.environmentIdFromConfig) == .v2)
    #expect(await cache.loadShell(Fixtures.environmentIdFromConfig) == nil, "the protocol-1 rows are gone")
    await h.runtime.stop()
  }

  @Test func theNextConnectionRereadsTheProtocolAndSwitchesTheSyncOver() async throws {
    let first = FakeServer(), second = FakeServer()
    let h = try await Harness.make(servers: [first, second], protocols: [.v2, .v1], loader: FakeLoader(shell: Data2.shell()))
    let initial = await first.waitForRequest("orchestration.subscribeShell")
    try first.chunk(initial, items: [OrchestrationV2ShellStreamItem.synchronized])
    // (the shell snapshot is empty without an HTTP answer: the socket sends it)
    _ = await waitFor(h.runtime.shell) { $0.status != .empty || true }
    first.close()
    await h.reconnect()
    let resumed = await second.waitForRequest("orchestration.subscribeShell")
    #expect(h.runtime.orchestrationProtocol == .v1)
    #expect(resumed.payload["afterSequence"] as? Int == Data2.shell().snapshotSequence, "the protocol-1 snapshot sets the cursor")
    let state = await waitFor(h.runtime.shell) { $0.v2 == nil && $0.snapshot != nil }
    #expect(state.snapshot?.snapshotSequence == Data2.shell().snapshotSequence)
    #expect(await h.cache.cachedProtocol(Fixtures.environmentIdFromConfig) == .v1)
    await h.runtime.stop()
  }

  // MARK: Thread

  @Test func aThreadOpensItsBoundedWindowThenReplaysEventsAndPagesBackThroughHistory() async throws {
    let server = FakeServer()
    let bounded = try bounded()
    let page = try WireFixture.decode(OrchestrationV2ThreadHistoryPage.self, "v2-thread-older-history")
    let loader = FakeLoader(
      shellV2: try shellSnapshot(), threadV2: .present(HTTPSnapshotLoader.detail(bounded), history: ThreadHistoryMeta.of(bounded)),
      historyPages: ["fixture-v2-before-10": page])
    let h = try await Harness.make(servers: [server], loader: loader)
    let lease = await h.runtime.threads.acquire(threadId)
    let request = await server.waitForRequest("orchestration.subscribeThread")
    #expect(request.payload["threadId"] as? String == "thread-v2" && request.payload["afterSequence"] as? Int == 100)
    #expect(request.payload["requestCompletionMarker"] as? Bool == true)
    #expect(request.payload["acceptBoundedSnapshot"] as? Bool == true && request.payload["acceptCompactTurnItems"] as? Bool == true)

    let events = try WireFixture.decode([OrchestrationV2ThreadStreamItem].self, "v2-thread-stream-events")
    try server.chunk(request, items: Array(events.dropLast()))
    let replayed = await waitFor(lease.state) { $0.projection != nil && $0.status == .synchronizing && $0.history.latestLocalTurnOrdinal == 18 }
    #expect(replayed.projection?.updatedAt != bounded.projection.updatedAt)
    try server.chunk(request, items: [events.last!])
    let live = await waitFor(lease.state) { $0.status == .live }
    let after = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-after-events-snapshot")
    #expect(live.projection == after.projection)
    #expect(live.hasOlderTurns)

    await lease.loadOlderTurns()
    #expect(loader.historyCursors == ["fixture-v2-before-10"])
    let merged = await waitFor(lease.state) { !$0.history.hasMoreHistory }
    let expected = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-with-history-snapshot")
    #expect(merged.projection == expected.projection)
    await lease.release()
    await h.runtime.stop()
  }

  @Test func aMissingThreadIsDeletedWithoutOpeningASocketSubscription() async throws {
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], loader: FakeLoader(shellV2: try shellSnapshot(), threadV2: .missing))
    let lease = await h.runtime.threads.acquire(threadId)
    let state = await waitFor(lease.state) { $0.status == .deleted }
    #expect(state.projection == nil)
    #expect(await h.cache.loadThreadV2(h.environmentId, threadId) == nil)
    _ = await server.waitForRequest("orchestration.subscribeShell")
    #expect(server.requests("orchestration.subscribeThread").isEmpty)
    await lease.release()
    await h.runtime.stop()
  }

  // MARK: Commands

  private func dispatch(_ h: Harness, _ server: FakeServer, count: Int = 1, sequence: Int = 7) async -> FakeServer.Request {
    let request = await server.waitForRequest("orchestration.dispatchCommand", count: count)
    server.succeed(request, ["sequence": sequence])
    return request
  }

  @Test func v1ShapedCommandsBecomeProtocolTwoCommandsAndKeepTheirOptimisticUpdate() async throws {
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], loader: FakeLoader(shellV2: try shellSnapshot()))
    _ = await waitFor(h.runtime.shell) { $0.v2 != nil }
    let command = ThreadCommand.pin(threadId)
    async let result = h.runtime.dispatch(command, thread: threadId, optimistic: .pin(orderKey: nil))
    let request = await server.waitForRequest("orchestration.dispatchCommand")
    #expect(request.payload["type"] as? String == "thread.pin" && request.payload["threadId"] as? String == "thread-v2")
    let shown = await waitFor(h.runtime.shell) { optionalValue($0.snapshot?.threads.first?.pinnedAt) != nil }
    #expect(optionalValue(shown.v2?.threads.first?.pinnedAt) == nil, "only the displayed shell carries the optimistic pin")
    server.succeed(request, ["sequence": 101])
    #expect(try await result.sequence == 101)
    await h.runtime.stop()
  }

  @Test func theFirstMessageOfADraftLaunchesTheThreadAndLaterOnesDispatchWithTheServersDelivery() async throws {
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], loader: FakeLoader(shellV2: try shellSnapshot()))
    let model = ModelSelection(instanceId: "codex", model: "gpt-5")
    let created = V1.ClientOrchestrationCommandThreadTurnStartBootstrapCreateThread(
      projectId: "project-v2", title: "New thread", modelSelection: model, runtimeMode: .fullAccess, interactionMode: .default, createdAt: "2026-08-07T12:00:00.000Z")
    let first = ThreadCommand.startTurn(
      "thread-new", message: .init(messageId: "m1", text: "hello", attachments: []), runtimeMode: .fullAccess, interactionMode: .default,
      bootstrap: .init(createThread: created), meta: .fresh())
    let launched = Task { try await h.runtime.dispatch(first, thread: "thread-new").sequence }
    let launch = await server.waitForRequest("orchestration.launchThread")
    #expect(launch.payload["threadId"] as? String == "thread-new" && launch.payload["projectId"] as? String == "project-v2")
    #expect((launch.payload["workspaceStrategy"] as? [String: Any])?["type"] as? String == "root")
    #expect((launch.payload["initialMessage"] as? [String: Any])?["text"] as? String == "hello")
    server.succeed(launch, NSNull())  // the launch result is not read
    _ = try? await launched.value

    let later = ThreadCommand.startTurn(
      threadId, message: .init(messageId: "m2", text: "more", attachments: []), runtimeMode: .fullAccess, interactionMode: .default, meta: .fresh())
    let sent = Task { try await h.runtime.dispatch(later, thread: threadId).sequence }
    let send = await dispatch(h, server)
    #expect(send.payload["type"] as? String == "message.dispatch" && send.payload["deliveryIntent"] as? String == "auto")
    #expect((send.payload["dispatchMode"] as? [String: Any])?["type"] as? String == "start_immediately")
    #expect(try await sent.value == 7)
    await h.runtime.stop()
  }

  @Test func stopTargetsTheActiveRunOfTheShellAndSteerAndQueueUseTheirOwnCommands() async throws {
    let server = FakeServer()
    var snapshot = try shellSnapshot()
    snapshot.threads[0].activeRunId = "run-v2-active"
    let h = try await Harness.make(servers: [server], loader: FakeLoader(shellV2: snapshot))
    _ = await waitFor(h.runtime.shell) { $0.v2 != nil }
    async let stop = h.runtime.dispatch(ThreadCommand.interruptTurn(threadId), thread: threadId)
    let interrupt = await dispatch(h, server)
    #expect(interrupt.payload["type"] as? String == "run.interrupt" && interrupt.payload["runId"] as? String == "run-v2-active")
    #expect(interrupt.payload["holdQueue"] as? Bool == true)
    _ = try await stop

    async let queued = h.runtime.dispatch(
      ThreadCommandV2.send(threadId, messageId: "m3", text: "later", delivery: .queue), thread: threadId)
    let queue = await dispatch(h, server, count: 2)
    #expect((queue.payload["dispatchMode"] as? [String: Any])?["type"] as? String == "queue_after_active" && queue.payload["deliveryIntent"] == nil)
    _ = try await queued

    async let steered = h.runtime.dispatch(ThreadCommandV2.promoteQueuedToSteer(threadId, queuedRunId: "run-q", targetRunId: "run-v2-active"), thread: threadId)
    let steer = await dispatch(h, server, count: 3)
    #expect(steer.payload["type"] as? String == "queued-message.promote-to-steer" && steer.payload["queuedRunId"] as? String == "run-q")
    _ = try await steered
    await h.runtime.stop()
  }

  @Test func aProtocolOneEnvironmentRefusesProtocolTwoOnlyCommands() async throws {
    let server = FakeServer()
    let h = try await Harness.make(servers: [server], protocols: [.v1], loader: FakeLoader(shell: Data2.shell()))
    _ = await server.waitForRequest("orchestration.subscribeShell")
    await #expect(throws: CommandError.self) { try await h.runtime.dispatch(ThreadCommandV2.resumeQueue(threadId), thread: threadId) }
    await h.runtime.stop()
  }
}

@Suite struct CommandTranslationTests {
  @Test func lifecycleCommandsKeepTheirIdsAndFields() throws {
    let meta = CommandMeta(commandId: "c1", createdAt: "2026-08-07T12:00:00.000Z")
    let plan = try CommandTranslation.plan(for: ThreadCommand.snooze("t1", until: "2026-08-08T09:00:00.000Z", meta: meta))
    guard case .command(.threadSnooze(let snooze)) = plan.first else {
      Issue.record("expected thread.snooze")
      return
    }
    #expect(snooze.commandId == "c1" && snooze.threadId == "t1" && snooze.snoozedUntil == "2026-08-08T09:00:00.000Z")
    let rename = try CommandTranslation.plan(for: ThreadCommand.updateMetadata("t1", title: "T", modelSelection: ModelSelection(instanceId: "codex", model: "m"), meta: meta))
    #expect(rename.count == 2, "a title and a model change are two commands")
    guard case .command(.threadModelSelectionSet(let model)) = rename.last else {
      Issue.record("expected the model change last")
      return
    }
    #expect(model.commandId.rawValue == "c1:model-selection", "the second command id derives from the first so a retry stays idempotent")
  }

  @Test func revertStopAndInterruptNeedTheThreadStateAndAreResolvedAtDispatch() throws {
    let meta = CommandMeta.fresh()
    guard case .rollback(let thread, let turnCount, let restoreFiles, _) = try CommandTranslation.plan(for: ThreadCommand.revert("t1", toTurnCount: 2, restoreFiles: false, meta: meta)).first else {
      Issue.record("a revert resolves its checkpoint at dispatch")
      return
    }
    #expect(thread == "t1" && turnCount == 2 && !restoreFiles)
    guard case .detachSessions = try CommandTranslation.plan(for: ThreadCommand.stopSession("t1")).first else {
      Issue.record("stop detaches sessions")
      return
    }
    guard case .interrupt(_, let run, _) = try CommandTranslation.plan(for: ThreadCommand.interruptTurn("t1", turnId: "run-1")).first else {
      Issue.record("interrupt")
      return
    }
    #expect(run == "run-1")
  }

  @Test func sendBuildsTheServerResolvedDeliveryShapes() throws {
    func wire(_ delivery: SendDelivery) throws -> [String: Any] {
      let data = try JSONEncoder().encode(ThreadCommandV2.send("t1", messageId: "m1", text: "x", delivery: delivery))
      return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let auto = try wire(.auto), steer = try wire(.steer), queue = try wire(.queue), start = try wire(.start(continuing: "run-0"))
    #expect(auto["deliveryIntent"] as? String == "auto" && (auto["dispatchMode"] as? [String: Any])?["type"] as? String == "start_immediately")
    #expect(steer["deliveryIntent"] as? String == "steer")
    #expect(queue["deliveryIntent"] == nil && (queue["dispatchMode"] as? [String: Any])?["type"] as? String == "queue_after_active")
    #expect(start["manualContinuationOfRunId"] as? String == "run-0" && start["deliveryIntent"] == nil)
    #expect(auto["createdBy"] as? String == "user" && auto["creationSource"] as? String == "web")
  }
}
