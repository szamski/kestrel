import Foundation
import T3Contracts
import T3Protocol

/// Shell synchronisation for one environment (`makeEnvironmentShellState`): HTTP snapshot, then
/// `subscribeShell(afterSequence, requestCompletionMarker)`, replay, `synchronized`, live.
/// Drives the pure `ShellStateMachine`; the cache is read once at start and written from live data.
/// Each connection speaks one protocol: a replacement session of the other protocol drops the held data
/// (and its cache rows) and resyncs, and one durable subscription per protocol follows the sessions it fits.
public actor ShellSync {
  public nonisolated let state: ValueHub<EnvironmentShellState>
  private let environmentId: EnvironmentId
  private let supervisor: EnvironmentSupervisor
  private let cache: any SnapshotCache
  private let loader: any SnapshotLoading
  private let clock: any RuntimeClock
  private var machine = ShellStateMachine()
  /// A session whose HTTP snapshot we hold: a foreground resubscribe on it may resume from the in-memory cursor.
  private var lastAuthoritativeSessionID: Int?
  private var activeSessionID: Int?
  private var writer: DebouncedWriter<V1.OrchestrationShellSnapshot>?
  private var writerV2: DebouncedWriter<OrchestrationV2ShellSnapshot>?
  private var tasks: [Task<Void, Never>] = []

  public init(
    environmentId: EnvironmentId, supervisor: EnvironmentSupervisor, cache: any SnapshotCache, loader: any SnapshotLoading,
    clock: any RuntimeClock
  ) {
    self.environmentId = environmentId
    self.supervisor = supervisor
    self.cache = cache
    self.loader = loader
    self.clock = clock
    state = ValueHub(.empty)
  }

  public func start(wakeups: EventHub<ConnectionWakeup>) async {
    guard tasks.isEmpty else { return }
    let environmentId = environmentId, cache = cache
    writer = DebouncedWriter(clock: clock) { snapshot in await cache.saveShell(environmentId, snapshot) }
    writerV2 = DebouncedWriter(clock: clock) { snapshot in await cache.saveShellV2(environmentId, snapshot) }
    if await cache.cachedProtocol(environmentId) == .v2, let cached = await cache.loadShellV2(environmentId) {
      machine = ShellStateMachine(cachedV2: cached)
    } else {
      machine = ShellStateMachine(cached: await cache.loadShell(environmentId))
    }
    machine.setSynchronizing()
    publish()

    let stateChanges = supervisor.state.changes()
    tasks.append(Task {
      for await connection in stateChanges {
        switch connection.projectionPhase {
        case .synchronizing: self.machine.setSynchronizing()
        case .disconnected: self.machine.setDisconnected()
        case .ready: self.machine.setReady()
        }
        self.publish()
      }
    })

    let v1 = DurableSubscription(
      spec: V1.Rpc.orchestrationSubscribeShell,
      makeInput: { session in await self.makeInput(session) },
      onItem: { _, item in await self.apply(item) },
      onExpectedFailure: { _ in await self.streamFailed() },
      onDefect: { await self.streamFailed() })
    let v2 = DurableSubscription(
      spec: Rpc.orchestrationSubscribeShell,
      makeInput: { session in await self.makeInputV2(session) },
      onItem: { _, item in await self.applyV2(item) },
      onExpectedFailure: { _ in await self.streamFailed() },
      onDefect: { await self.streamFailed() })
    let clock = clock
    let sessionsV1 = sessions(supervisor.session.changes(), speaking: .v1), resubscribeV1 = resubscribeSignals(wakeups)
    let sessionsV2 = sessions(supervisor.session.changes(), speaking: .v2), resubscribeV2 = resubscribeSignals(wakeups)
    tasks.append(Task { await runDurableSubscription(v1, sessions: sessionsV1, resubscribe: resubscribeV1, clock: clock) })
    tasks.append(Task { await runDurableSubscription(v2, sessions: sessionsV2, resubscribe: resubscribeV2, clock: clock) })
  }

  public func stop() async {
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    tasks = []
    await writer?.flush()
    await writerV2?.flush()
  }

  private func publish() { state.set(machine.state) }

  private func streamFailed() {
    machine.setStreamError()
    publish()
  }

  /// The held data speaks another protocol than the connection that is now subscribing: drop it, on disk too.
  private func adopt(_ version: OrchestrationProtocol) async {
    await cache.adoptProtocol(environmentId, version)
    guard let held = machine.dataProtocol, held != version else { return }
    machine.reset()
    lastAuthoritativeSessionID = nil
    await writer?.cancel()
    await writerV2?.cancel()
    publish()
  }

  private func makeInputV2(_ session: any EnvironmentSession) async -> OrchestrationV2SubscribeShellInput {
    await adopt(.v2)
    activeSessionID = session.id
    let supportsMarker = session.initialConfig.shellResumeCompletionMarker == true
    machine.beginSubscription(supportsCompletionMarker: supportsMarker)
    publish()
    var canResume = lastAuthoritativeSessionID == session.id
    if !canResume || machine.state.v2 == nil {
      if let prepared = await waitForPrepared(), let http = await loader.loadShellV2(prepared) {
        await applyV2(.snapshot(OrchestrationV2ShellStreamItemSnapshot(snapshot: http)))
        canResume = true
      }
    }
    guard canResume, let snapshot = machine.state.v2 else {
      return OrchestrationV2SubscribeShellInput(requestCompletionMarker: supportsMarker ? true : nil)
    }
    if !supportsMarker {
      machine.markLive()
      publish()
    }
    return OrchestrationV2SubscribeShellInput(afterSequence: snapshot.snapshotSequence, requestCompletionMarker: supportsMarker ? true : nil)
  }

  private func applyV2(_ item: OrchestrationV2ShellStreamItem) async {
    let result = machine.apply(v2: [item])
    guard result.changed else { return }
    if result.receivedSnapshot { lastAuthoritativeSessionID = activeSessionID }
    publish()
    if result.snapshotChanged, let snapshot = machine.state.v2, let writerV2 { await writerV2.submit(snapshot) }
  }

  private func makeInput(_ session: any EnvironmentSession) async -> V1.OrchestrationSubscribeShellInput {
    await adopt(.v1)
    activeSessionID = session.id
    let supportsMarker = session.initialConfig.shellResumeCompletionMarker == true
    machine.beginSubscription(supportsCompletionMarker: supportsMarker)
    publish()

    // Foreground resubscriptions on the same session resume from the in-memory cursor. A new session
    // reloads the authoritative HTTP snapshot so a valid cursor cannot preserve incomplete cached data.
    var canResume = lastAuthoritativeSessionID == session.id
    if !canResume || machine.state.snapshot == nil {
      if let prepared = await waitForPrepared(), let http = await loader.loadShell(prepared) {
        await apply(.snapshot(V1.OrchestrationShellStreamItemSnapshot(snapshot: http)))
        canResume = true
      }
    }
    // If the authoritative refresh failed, omit the cached cursor so the socket sends a complete snapshot.
    guard canResume, let snapshot = machine.state.snapshot else {
      return V1.OrchestrationSubscribeShellInput(requestCompletionMarker: supportsMarker ? true : nil)
    }
    if !supportsMarker {
      // No completion marker means no `synchronized` signal for a resumed subscription: report live at once.
      machine.markLive()
      publish()
    }
    return V1.OrchestrationSubscribeShellInput(afterSequence: snapshot.snapshotSequence, requestCompletionMarker: supportsMarker ? true : nil)
  }

  private func waitForPrepared() async -> PreparedConnection? {
    for await prepared in supervisor.prepared.changes() {
      if let prepared { return prepared }
      if Task.isCancelled { return nil }
    }
    return nil
  }

  private func apply(_ item: V1.OrchestrationShellStreamItem) async {
    let result = machine.apply([item])
    guard result.changed else { return }
    if result.receivedSnapshot { lastAuthoritativeSessionID = activeSessionID }
    publish()
    if result.snapshotChanged, let snapshot = machine.state.snapshot, let writer { await writer.submit(snapshot) }
  }
}
