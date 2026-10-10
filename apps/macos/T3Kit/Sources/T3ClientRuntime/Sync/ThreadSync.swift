import Foundation
import T3Contracts
import T3Protocol

/// Live detail of one thread (`makeEnvironmentThreadState`): cached or HTTP snapshot, then
/// `subscribeThread(afterSequence, requestCompletionMarker)`, replay, live, with older history on demand.
/// The pure machines own every rule (`ThreadDetailMachine` for protocol 1, `ThreadDetailMachineV2` for
/// protocol 2); this actor only does the I/O around them. Each connection speaks one protocol, so exactly
/// one durable subscription is active at a time; a replacement session of the other protocol (the server
/// was updated or replaced) drops the held data and resyncs under the new one.
public actor ThreadSync {
  public nonisolated let state: ValueHub<EnvironmentThreadState>
  private let environmentId: EnvironmentId
  private let threadId: ThreadId
  private let supervisor: EnvironmentSupervisor
  private let cache: any SnapshotCache
  private let loader: any SnapshotLoading
  private let clock: any RuntimeClock
  private let retained: ThreadResumeSnapshot?
  private var machine = ThreadDetailMachine()
  private var machineV2 = ThreadDetailMachineV2()
  /// The protocol the held data speaks; whichever machine it names is the one that publishes.
  private var active: OrchestrationProtocol = .v1
  private var writer: DebouncedWriter<V1.OrchestrationThreadDetailSnapshot>?
  private var writerV2: DebouncedWriter<OrchestrationV2ThreadDetailSnapshot>?
  private var lastWrittenSequence: Int?
  private var tasks: [Task<Void, Never>] = []

  public init(
    environmentId: EnvironmentId, threadId: ThreadId, supervisor: EnvironmentSupervisor, cache: any SnapshotCache,
    loader: any SnapshotLoading, clock: any RuntimeClock, retained: ThreadResumeSnapshot? = nil
  ) {
    self.environmentId = environmentId
    self.threadId = threadId
    self.supervisor = supervisor
    self.cache = cache
    self.loader = loader
    self.clock = clock
    self.retained = retained
    state = ValueHub(.empty)
  }

  public func start(wakeups: EventHub<ConnectionWakeup>) async {
    guard tasks.isEmpty else { return }
    let environmentId = environmentId, cache = cache
    writer = DebouncedWriter(clock: clock) { snapshot in await cache.saveThread(environmentId, snapshot) }
    writerV2 = DebouncedWriter(clock: clock) { snapshot in await cache.saveThreadV2(environmentId, snapshot) }
    // A retained state (idle cache) resumes from its own cursor; otherwise the disk cache seeds the cursor
    // so a warm cache catches up through `afterSequence` instead of re-downloading the thread.
    if let retained {
      active = retained.orchestrationProtocol
      if active == .v2 { machineV2 = ThreadDetailMachineV2(retained: retained) } else { machine = ThreadDetailMachine(retained: retained) }
    } else if await cache.cachedProtocol(environmentId) == .v2 {
      active = .v2
      machineV2 = ThreadDetailMachineV2(cached: await cache.loadThreadV2(environmentId, threadId))
    } else {
      machine = ThreadDetailMachine(cached: await cache.loadThread(environmentId, threadId))
    }
    markSynchronizing()
    publish()

    let connectionChanges = supervisor.state.changes()
    tasks.append(Task {
      for await connection in connectionChanges {
        switch connection.projectionPhase {
        case .synchronizing:
          self.machine.setConnecting()
          self.machineV2.setConnecting()
        case .disconnected:
          self.machine.setDisconnected()
          self.machineV2.setDisconnected()
        case .ready:
          self.machine.setReady()
          self.machineV2.setReady()
        }
        self.publish()
      }
    })

    let v1 = DurableSubscription(
      spec: V1.Rpc.orchestrationSubscribeThread,
      makeInput: { session in await self.makeInput(session) },
      onItem: { _, item in await self.apply(item) },
      onExpectedFailure: { _ in await self.failed("Could not synchronize the thread.") },
      onDefect: { await self.failed("Could not synchronize the thread.") })
    let v2 = DurableSubscription(
      spec: Rpc.orchestrationSubscribeThread,
      makeInput: { session in await self.makeInputV2(session) },
      onItem: { _, item in await self.applyV2(item) },
      onExpectedFailure: { _ in await self.failed("Could not synchronize the thread.") },
      onDefect: { await self.failed("Could not synchronize the thread.") })
    let clock = clock
    let sessionsV1 = sessions(supervisor.session.changes(), speaking: .v1), resubscribeV1 = resubscribeSignals(wakeups)
    let sessionsV2 = sessions(supervisor.session.changes(), speaking: .v2), resubscribeV2 = resubscribeSignals(wakeups)
    tasks.append(Task { await runDurableSubscription(v1, sessions: sessionsV1, resubscribe: resubscribeV1, clock: clock) })
    tasks.append(Task { await runDurableSubscription(v2, sessions: sessionsV2, resubscribe: resubscribeV2, clock: clock) })
  }

  /// Stops the stream and returns the state to retain for the idle cache. The settled state is saved to disk.
  public func stop() async -> ThreadResumeSnapshot {
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    tasks = []
    await writer?.flush()
    await writerV2?.flush()
    if active == .v2 {
      if let snapshot = machineV2.currentPersistRequest(), snapshot.snapshotSequence != lastWrittenSequence {
        await cache.saveThreadV2(environmentId, snapshot)
      }
      return machineV2.resumeSnapshot
    }
    if let request = machine.currentPersistRequest(), request.snapshot.snapshotSequence != lastWrittenSequence {
      await cache.saveThread(environmentId, request.snapshot)
    }
    return machine.resumeSnapshot
  }

  /// Fetches the next older page of a windowed thread; no-op without a cursor or while one is loading.
  public func loadOlderTurns() async {
    if active == .v2 { return await loadEarlierV2() }
    guard let request = machine.beginLoadOlder() else { return }
    publish()
    var response: V1.OrchestrationThreadDetailSnapshot?
    if let prepared = supervisor.prepared.value {
      response = await loader.loadThread(
        prepared, threadId: threadId, window: ThreadSnapshotWindow(turnLimit: request.turnLimit, beforeCursor: request.beforeCursor),
        reasoningMessages: request.reasoningMessages)
    }
    machine.completeLoadOlder(response, request: request)
    await afterUpdate(deleted: false)
  }

  // MARK: Internals

  private func publish() { state.set(active == .v2 ? machineV2.state : machine.state) }

  private func markSynchronizing() {
    machine.markSynchronizing()
    machineV2.markSynchronizing()
  }

  private func failed(_ message: String) {
    machine.setStreamError(message)
    machineV2.setStreamError(message)
    publish()
  }

  private func waitForPrepared() async -> PreparedConnection? {
    for await prepared in supervisor.prepared.changes() {
      if let prepared { return prepared }
      if Task.isCancelled { return nil }
    }
    return nil
  }

  /// The held data speaks another protocol than the connection that is now subscribing: drop it, on disk too,
  /// and start from a snapshot.
  private func adopt(_ version: OrchestrationProtocol) async {
    await cache.adoptProtocol(environmentId, version)
    guard active != version else { return }
    active = version
    machine = ThreadDetailMachine()
    machineV2 = ThreadDetailMachineV2()
    lastWrittenSequence = nil
    await writer?.cancel()
    await writerV2?.cancel()
  }

  /// Waits without opening the socket (a thread known to be gone is not subscribed again).
  private func parkUntilCancelled() async {
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
  }

  // MARK: Protocol 1

  private func makeInput(_ session: any EnvironmentSession) async -> V1.OrchestrationSubscribeThreadInput {
    await adopt(.v1)
    let config = session.initialConfig
    let plan = machine.beginSubscription(config: config)
    publish()
    if plan.needsSnapshot, let prepared = await waitForPrepared() {
      let window = machine.paginationSupported ? ThreadSnapshotWindow(turnLimit: ThreadPaging.initialUserTurnLimit) : nil
      if let http = await loader.loadThread(prepared, threadId: threadId, window: window, reasoningMessages: machine.reasoningMessagesSupported) {
        await apply(.snapshot(V1.OrchestrationThreadStreamItemSnapshot(snapshot: http)))
      }
    }
    let input = machine.subscribeInput(threadId: threadId, config: config)
    publish()
    return V1.OrchestrationSubscribeThreadInput(
      threadId: input.threadId, reasoningMessages: input.reasoningMessages ? true : nil, afterSequence: input.afterSequence,
      requestCompletionMarker: input.requestCompletionMarker ? true : nil, turnLimit: input.turnLimit)
  }

  private func apply(_ item: V1.OrchestrationThreadStreamItem) async {
    guard active == .v1 else { return }
    let deleted = machine.apply(item)
    await afterUpdate(deleted: deleted)
  }

  // MARK: Protocol 2

  private func makeInputV2(_ session: any EnvironmentSession) async -> OrchestrationV2SubscribeThreadInput {
    await adopt(.v2)
    let config = session.initialConfig
    let plan = machineV2.beginSubscription(config: config)
    publish()
    if plan.parked {
      await parkUntilCancelled()
      return OrchestrationV2SubscribeThreadInput(threadId: threadId)
    }
    if plan.needsSnapshot, let prepared = await waitForPrepared() {
      switch await loader.loadThreadV2(prepared, threadId: threadId) {
      case .present(let snapshot, let history):
        machineV2.applyHttp(snapshot, history: history)
        await afterUpdate(deleted: false)
      case .missing:
        // A definitive 404: clear any stale cache and do not open a socket subscription for this thread.
        machineV2.setMissing()
        await afterUpdate(deleted: true)
        await parkUntilCancelled()
        return OrchestrationV2SubscribeThreadInput(threadId: threadId)
      case .unavailable:
        break  // transient: the socket snapshot is the fallback
      }
    }
    let input = machineV2.subscribeInput(threadId: threadId, config: config)
    publish()
    return OrchestrationV2SubscribeThreadInput(
      threadId: input.threadId, afterSequence: input.afterSequence, requestCompletionMarker: input.requestCompletionMarker ? true : nil,
      acceptBoundedSnapshot: true, acceptCompactTurnItems: true)
  }

  private func applyV2(_ item: OrchestrationV2ThreadStreamItem) async {
    guard active == .v2 else { return }
    let deleted = machineV2.apply([item])
    await afterUpdate(deleted: deleted)
  }

  private func loadEarlierV2() async {
    guard case .request(let cursor) = machineV2.beginLoadEarlier() else { return }
    publish()
    var page: OrchestrationV2ThreadHistoryPage?
    var message: String?
    if let prepared = supervisor.prepared.value {
      switch await loader.loadHistoryPage(prepared, threadId: threadId, cursor: cursor) {
      case .success(let loaded): page = loaded
      case .failure(let failure): message = failure.message
      }
    } else {
      message = "Environment is not connected."
    }
    if Task.isCancelled {
      machineV2.cancelLoadEarlier(cursor: cursor)
    } else {
      _ = machineV2.completeLoadEarlier(cursor: cursor, page: page, message: message)
    }
    await afterUpdate(deleted: false)
  }

  /// Publishes, then hands the cache whatever the machine marked persistable.
  private func afterUpdate(deleted: Bool) async {
    publish()
    if deleted {
      lastWrittenSequence = nil
      await writer?.cancel()
      await writerV2?.cancel()
      await cache.removeThread(environmentId, threadId)
      return
    }
    if active == .v2 {
      if let snapshot = machineV2.takePersistRequest(), let writerV2 {
        lastWrittenSequence = snapshot.snapshotSequence
        await writerV2.submit(snapshot)
      }
    } else if let request = machine.takePersistRequest(), let writer {
      lastWrittenSequence = request.snapshot.snapshotSequence
      await writer.submit(request.snapshot)
    }
  }
}
