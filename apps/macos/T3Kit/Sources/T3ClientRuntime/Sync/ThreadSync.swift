import Foundation
import T3Contracts

/// Live detail of one thread (`makeEnvironmentThreadState`): cached or HTTP snapshot, then
/// `subscribeThread(afterSequence, requestCompletionMarker)`, replay, live, with older pages on demand.
/// The pure `ThreadDetailMachine` owns every rule; this actor only does the I/O around it.
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
  private var writer: DebouncedWriter<OrchestrationThreadDetailSnapshot>?
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
    // A retained state (idle cache) resumes from its own cursor; otherwise the disk cache seeds the cursor
    // so a warm cache catches up through `afterSequence` instead of re-downloading the thread.
    let cached = retained == nil ? await cache.loadThread(environmentId, threadId) : nil
    machine = ThreadDetailMachine(cached: cached, retained: retained)
    machine.markSynchronizing()
    publish()

    let connectionChanges = supervisor.state.changes()
    tasks.append(Task {
      for await connection in connectionChanges {
        switch connection.projectionPhase {
        case .synchronizing: self.machine.setConnecting()
        case .disconnected: self.machine.setDisconnected()
        case .ready: self.machine.setReady()
        }
        self.publish()
      }
    })

    let sessions = supervisor.session.changes()
    let resubscribe = AsyncStream<Void> { continuation in
      let task = Task { for await wake in wakeups.events() where wake.shouldResubscribe { continuation.yield() } }
      continuation.onTermination = { _ in task.cancel() }
    }
    let subscription = DurableSubscription(
      spec: Rpc.orchestrationSubscribeThread,
      makeInput: { session in await self.makeInput(session) },
      onItem: { _, item in await self.apply(item) },
      onExpectedFailure: { _ in await self.failed("Could not synchronize the thread.") },
      onDefect: { await self.failed("Could not synchronize the thread.") })
    let clock = clock
    tasks.append(Task { await runDurableSubscription(subscription, sessions: sessions, resubscribe: resubscribe, clock: clock) })
  }

  /// Stops the stream and returns the state to retain for the idle cache. The settled state is saved to disk.
  public func stop() async -> ThreadResumeSnapshot {
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    tasks = []
    await writer?.flush()
    if let request = machine.currentPersistRequest(), request.snapshot.snapshotSequence != lastWrittenSequence {
      await cache.saveThread(environmentId, request.snapshot)
    }
    return machine.resumeSnapshot
  }

  /// Fetches the next older page of a windowed thread; no-op without a cursor or while one is loading.
  public func loadOlderTurns() async {
    guard let request = machine.beginLoadOlder() else { return }
    publish()
    var response: OrchestrationThreadDetailSnapshot?
    if let prepared = supervisor.prepared.value {
      response = await loader.loadThread(
        prepared, threadId: threadId, window: ThreadSnapshotWindow(turnLimit: request.turnLimit, beforeCursor: request.beforeCursor),
        reasoningMessages: request.reasoningMessages)
    }
    machine.completeLoadOlder(response, request: request)
    await afterUpdate(deleted: false)
  }

  // MARK: Internals

  private func publish() { state.set(machine.state) }

  private func failed(_ message: String) {
    machine.setStreamError(message)
    publish()
  }

  private func makeInput(_ session: any EnvironmentSession) async -> OrchestrationSubscribeThreadInput {
    let config = session.initialConfig
    let plan = machine.beginSubscription(config: config)
    publish()
    if plan.needsSnapshot, let prepared = await waitForPrepared() {
      let window = machine.paginationSupported ? ThreadSnapshotWindow(turnLimit: ThreadPaging.initialUserTurnLimit) : nil
      if let http = await loader.loadThread(prepared, threadId: threadId, window: window, reasoningMessages: machine.reasoningMessagesSupported) {
        await apply(.snapshot(OrchestrationThreadStreamItemSnapshot(snapshot: http)))
      }
    }
    let input = machine.subscribeInput(threadId: threadId, config: config)
    publish()
    return OrchestrationSubscribeThreadInput(
      threadId: input.threadId, reasoningMessages: input.reasoningMessages ? true : nil, afterSequence: input.afterSequence,
      requestCompletionMarker: input.requestCompletionMarker ? true : nil, turnLimit: input.turnLimit)
  }

  private func waitForPrepared() async -> PreparedConnection? {
    for await prepared in supervisor.prepared.changes() {
      if let prepared { return prepared }
      if Task.isCancelled { return nil }
    }
    return nil
  }

  private func apply(_ item: OrchestrationThreadStreamItem) async {
    let deleted = machine.apply(item)
    await afterUpdate(deleted: deleted)
  }

  /// Publishes, then hands the cache whatever the machine marked persistable.
  private func afterUpdate(deleted: Bool) async {
    publish()
    if deleted {
      lastWrittenSequence = nil
      await writer?.cancel()
      await cache.removeThread(environmentId, threadId)
      return
    }
    if let request = machine.takePersistRequest(), let writer {
      lastWrittenSequence = request.snapshot.snapshotSequence
      await writer.submit(request.snapshot)
    }
  }
}
