import Foundation
import Synchronization
import T3Contracts

/// Hands out shared live subscriptions for one environment's threads.
///
/// Mounted consumers share one stream per thread, which stops when the last consumer releases;
/// hidden mounted views still count. The state and cursor of a stopped thread stay retained for
/// five idle minutes, so back navigation resumes with `afterSequence` instead of a new snapshot.
/// On desktop, threads whose session is starting or running are kept mounted (`reconcileKeepAlive`).
public actor ThreadSyncRegistry {
  private struct Entry {
    var sync: ThreadSync
    var refCount: Int
  }
  private struct Idle {
    var snapshot: ThreadResumeSnapshot
    var expiry: Task<Void, Never>
    var token: Int
  }

  private let environmentId: EnvironmentId
  private let supervisor: EnvironmentSupervisor
  private let cache: any SnapshotCache
  private let loader: any SnapshotLoading
  private let clock: any RuntimeClock
  private let wakeups: EventHub<ConnectionWakeup>
  private let idleTTL: Duration
  private var live: [ThreadId: Entry] = [:]
  private var idle: [ThreadId: Idle] = [:]
  private var nextToken = 0
  private var kept: [ThreadId: ThreadLease] = [:]
  private var keepWatchers: [ThreadId: Task<Void, Never>] = [:]
  private var lastRunning: Set<ThreadId> = []

  public init(
    environmentId: EnvironmentId, supervisor: EnvironmentSupervisor, cache: any SnapshotCache, loader: any SnapshotLoading,
    clock: any RuntimeClock, wakeups: EventHub<ConnectionWakeup>, idleTTL: Duration = ThreadPaging.snapshotIdleTTL
  ) {
    self.environmentId = environmentId
    self.supervisor = supervisor
    self.cache = cache
    self.loader = loader
    self.clock = clock
    self.wakeups = wakeups
    self.idleTTL = idleTTL
  }

  /// Number of threads with a running stream (tests, diagnostics).
  public var liveThreadIds: Set<ThreadId> { Set(live.keys) }
  public var idleThreadIds: Set<ThreadId> { Set(idle.keys) }
  public var keptThreadIds: Set<ThreadId> { Set(kept.keys) }

  public func acquire(_ threadId: ThreadId) async -> ThreadLease {
    if var entry = live[threadId] {
      entry.refCount += 1
      live[threadId] = entry
      return ThreadLease(threadId: threadId, state: entry.sync.state, registry: self, sync: entry.sync)
    }
    let retained = idle.removeValue(forKey: threadId).map { idle in
      idle.expiry.cancel()
      return idle.snapshot
    }
    let sync = ThreadSync(
      environmentId: environmentId, threadId: threadId, supervisor: supervisor, cache: cache, loader: loader, clock: clock,
      retained: retained)
    live[threadId] = Entry(sync: sync, refCount: 1)
    await sync.start(wakeups: wakeups)
    return ThreadLease(threadId: threadId, state: sync.state, registry: self, sync: sync)
  }

  fileprivate func release(_ threadId: ThreadId) async {
    guard var entry = live[threadId] else { return }
    entry.refCount -= 1
    if entry.refCount > 0 {
      live[threadId] = entry
      return
    }
    live[threadId] = nil
    let snapshot = await entry.sync.stop()
    // Cancellation or a quick re-acquire may have replaced this scope: only the latest owner caches.
    guard live[threadId] == nil, snapshot.state.data != nil || snapshot.state.status == .deleted else { return }
    nextToken += 1
    let token = nextToken
    let ttl = idleTTL, clock = clock
    let expiry = Task {
      do { try await clock.sleep(for: ttl) } catch { return }
      await self.evict(threadId, token: token)
    }
    idle[threadId]?.expiry.cancel()
    idle[threadId] = Idle(snapshot: snapshot, expiry: expiry, token: token)
  }

  private func evict(_ threadId: ThreadId, token: Int) {
    guard idle[threadId]?.token == token else { return }
    idle[threadId] = nil
  }

  /// Drops every stream and retained state (environment removal or shutdown).
  public func shutdown() async {
    for watcher in keepWatchers.values { watcher.cancel() }
    keepWatchers = [:]
    kept = [:]
    for (_, entry) in live { _ = await entry.sync.stop() }
    live = [:]
    for idle in idle.values { idle.expiry.cancel() }
    idle = [:]
  }

  // MARK: Desktop keep-alive

  /// A detail stream is done when it is in sync and shows a settled session, or cannot progress.
  static func isDetailDone(_ state: EnvironmentThreadState) -> Bool {
    if state.status == .deleted || state.error != nil { return true }
    return state.status == .live && !(state.data?.session?.isStartingOrRunning ?? false)
  }

  /// Keeps one stream open for every thread whose session is starting or running, so opening it later
  /// needs no replay. The shell can report a stop before the detail loads or catches up, so a stopped
  /// thread stays mounted until its own stream is live and shows the stop; then it closes and saves.
  public func reconcileKeepAlive(running: Set<ThreadId>? = nil) async {
    let running = running ?? lastRunning
    lastRunning = running
    var next = running
    for threadId in kept.keys where !running.contains(threadId) {
      let state = live[threadId]?.sync.state.value ?? .empty
      if !Self.isDetailDone(state) { next.insert(threadId) }
    }
    for threadId in kept.keys where !next.contains(threadId) {
      keepWatchers.removeValue(forKey: threadId)?.cancel()
      if let lease = kept.removeValue(forKey: threadId) { await lease.release() }
    }
    for threadId in next where kept[threadId] == nil {
      let lease = await acquire(threadId)
      kept[threadId] = lease
      // Re-evaluate when this detail finishes, not on each update.
      let changes = lease.state.changes()
      keepWatchers[threadId] = Task {
        for await state in changes where Self.isDetailDone(state) {
          await self.reconcileKeepAlive()
          return
        }
      }
    }
  }
}

/// One consumer's claim on a thread's live detail. Release it when the view goes away.
public final class ThreadLease: Sendable {
  public let threadId: ThreadId
  /// Latest state of the thread; observe with `state.changes()`.
  public let state: ValueHub<EnvironmentThreadState>
  private let registry: ThreadSyncRegistry
  private let sync: ThreadSync
  private let released = Mutex(false)

  fileprivate init(threadId: ThreadId, state: ValueHub<EnvironmentThreadState>, registry: ThreadSyncRegistry, sync: ThreadSync) {
    self.threadId = threadId
    self.state = state
    self.registry = registry
    self.sync = sync
  }

  public func loadOlderTurns() async { await sync.loadOlderTurns() }

  public func release() async {
    let first = released.withLock { released -> Bool in
      defer { released = true }
      return !released
    }
    if first { await registry.release(threadId) }
  }
}
