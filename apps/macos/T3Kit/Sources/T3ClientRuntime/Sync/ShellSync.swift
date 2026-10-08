import Foundation
import T3Contracts

/// Shell synchronisation for one environment (`makeEnvironmentShellState`): HTTP snapshot, then
/// `subscribeShell(afterSequence, requestCompletionMarker)`, replay, `synchronized`, live.
/// Drives the pure `ShellStateMachine`; the cache is read once at start and written from live data.
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
  private var writer: DebouncedWriter<OrchestrationShellSnapshot>?
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
    machine = ShellStateMachine(cached: await cache.loadShell(environmentId))
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

    let sessions = supervisor.session.changes()
    let resubscribe = AsyncStream<Void> { continuation in
      let task = Task { for await wake in wakeups.events() where wake.shouldResubscribe { continuation.yield() } }
      continuation.onTermination = { _ in task.cancel() }
    }
    let subscription = DurableSubscription(
      spec: Rpc.orchestrationSubscribeShell,
      makeInput: { session in await self.makeInput(session) },
      onItem: { _, item in await self.apply(item) },
      onExpectedFailure: { _ in await self.streamFailed() },
      onDefect: { await self.streamFailed() })
    let clock = clock
    tasks.append(Task { await runDurableSubscription(subscription, sessions: sessions, resubscribe: resubscribe, clock: clock) })
  }

  public func stop() async {
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    tasks = []
    await writer?.flush()
  }

  private func publish() { state.set(machine.state) }

  private func streamFailed() {
    machine.setStreamError()
    publish()
  }

  private func makeInput(_ session: any EnvironmentSession) async -> OrchestrationSubscribeShellInput {
    activeSessionID = session.id
    let supportsMarker = session.initialConfig.shellResumeCompletionMarker == true
    machine.beginSubscription(supportsCompletionMarker: supportsMarker)
    publish()

    // Foreground resubscriptions on the same session resume from the in-memory cursor. A new session
    // reloads the authoritative HTTP snapshot so a valid cursor cannot preserve incomplete cached data.
    var canResume = lastAuthoritativeSessionID == session.id
    if !canResume || machine.state.snapshot == nil {
      if let prepared = await waitForPrepared(), let http = await loader.loadShell(prepared) {
        await apply(.snapshot(OrchestrationShellStreamItemSnapshot(snapshot: http)))
        canResume = true
      }
    }
    // If the authoritative refresh failed, omit the cached cursor so the socket sends a complete snapshot.
    guard canResume, let snapshot = machine.state.snapshot else {
      return OrchestrationSubscribeShellInput(requestCompletionMarker: supportsMarker ? true : nil)
    }
    if !supportsMarker {
      // No completion marker means no `synchronized` signal for a resumed subscription: report live at once.
      machine.markLive()
      publish()
    }
    return OrchestrationSubscribeShellInput(afterSequence: snapshot.snapshotSequence, requestCompletionMarker: supportsMarker ? true : nil)
  }

  private func waitForPrepared() async -> PreparedConnection? {
    for await prepared in supervisor.prepared.changes() {
      if let prepared { return prepared }
      if Task.isCancelled { return nil }
    }
    return nil
  }

  private func apply(_ item: OrchestrationShellStreamItem) async {
    let result = machine.apply([item])
    guard result.changed else { return }
    if result.receivedSnapshot { lastAuthoritativeSessionID = activeSessionID }
    publish()
    if result.snapshotChanged, let snapshot = machine.state.snapshot, let writer { await writer.submit(snapshot) }
  }
}
