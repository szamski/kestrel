import Foundation
import T3Contracts
import T3Protocol

public enum ThreadDetailStatus: String, Sendable { case empty, cached, synchronizing, live, deleted }

/// Pagination state of a windowed thread. Absent means the thread is fully loaded.
public struct ThreadPageState: Sendable, Equatable {
  /// Opaque exclusive cursor for the next older slice; nil when fully loaded.
  public var beforeCursor: String?
  public var hasMore: Bool
  /// True while an older page fetch is in flight.
  public var loadingOlder: Bool
}

public struct EnvironmentThreadState: Sendable, Equatable {
  /// Protocol 1: the thread detail. Nil on protocol 2, which holds `projection` instead.
  public var data: V1.OrchestrationThread?
  /// Protocol 2: the server's thread projection (runs, turn items, messages, requests, checkpoints, ...).
  public var projection: OrchestrationV2ThreadProjection?
  /// Protocol 2: progressive history of the bounded window in `projection`.
  public var history: ThreadHistoryMeta = .empty
  public var status: ThreadDetailStatus
  public var error: String?
  public var page: ThreadPageState?
  public static let empty = EnvironmentThreadState(data: nil, projection: nil, history: .empty, status: .empty, error: nil, page: nil)
  public var hasOlderTurns: Bool { page?.hasMore == true || history.hasMoreHistory }
  public var isLoadingOlder: Bool { page?.loadingOlder == true || history.loading }
  public var hasData: Bool { data != nil || projection != nil }

  /// A turn or run is starting or running: the detail should stay mounted and must not be cached mid-stream.
  public var isRunActive: Bool {
    if let session = data?.session { return session.isStartingOrRunning }
    return projection?.runs.contains { run in
      switch run.status {
      case .preparing, .queued, .starting, .running, .waiting: true
      default: false
      }
    } ?? false
  }
}

/// A thread's state together with the cursor it is consistent with. Saved only after an update
/// has been applied, so a cancelled scope can never cache a cursor ahead of its data.
public struct ThreadResumeSnapshot: Sendable, Equatable {
  public var state: EnvironmentThreadState
  public var sequence: Int
  public var persisted: Bool
  /// The data and cursor only mean something to a connection speaking the same protocol.
  public var orchestrationProtocol: OrchestrationProtocol = .v1
}

/// Detail snapshot to write to the disk cache.
public struct ThreadPersistRequest: Sendable, Equatable {
  public var snapshot: V1.OrchestrationThreadDetailSnapshot
}

/// Turn window sizes for paginated loads: the first page covers the last 10 user-anchored
/// turns; each "load earlier" fetches 20 more.
public enum ThreadPaging {
  public static let initialUserTurnLimit = 10
  public static let olderPageUserTurnLimit = 20
  /// Recent snapshots stay cached for back navigation for this long after the last consumer leaves.
  public static let snapshotIdleTTL: Duration = .seconds(300)
}

extension V1.OrchestrationSession {
  public var isStartingOrRunning: Bool { status == .starting || status == .running }
}

/// Pure thread detail state machine: port of `makeEnvironmentThreadState` minus I/O.
/// `empty | cached -> synchronizing -> live | deleted`, cursor `lastSequence`, windowed
/// history with older pages merged only after live events reached the page's watermark.
public struct ThreadDetailMachine: Sendable {
  public private(set) var state: EnvironmentThreadState
  public private(set) var lastSequence: Int
  public private(set) var awaitingCompletion = false
  public private(set) var historyEpoch = 0
  public private(set) var paginationSupported = false
  public private(set) var reasoningMessagesSupported = false
  /// Set by updates that should reach the disk cache; the owner takes it with `takePersistRequest()`.
  private var persistRequest: ThreadPersistRequest?
  private struct PendingOlderPage: Sendable {
    var snapshot: V1.OrchestrationThreadDetailSnapshot
    var epoch: Int
  }
  private var pendingOlderPage: PendingOlderPage?
  /// Only the first subscription after a warm live resume keeps the retained status.
  public private(set) var resumingLive: Bool

  public init(cached: V1.OrchestrationThreadDetailSnapshot? = nil, retained: ThreadResumeSnapshot? = nil) {
    if let retained {
      state = Self.cachedState(retained.state)
      lastSequence = retained.sequence
    } else {
      let thread = cached?.thread
      state = EnvironmentThreadState(
        data: thread, status: thread == nil ? .empty : .cached, error: nil,
        // A cached windowed snapshot restores its page cursor so "load earlier" works from cache.
        page: Self.pageState(cached?.page))
      lastSequence = cached?.snapshotSequence ?? 0
    }
    resumingLive = state.status == .live
  }

  // MARK: Helpers

  static func pageState(_ page: V1.OrchestrationThreadDetailPage?) -> ThreadPageState? {
    page.map { ThreadPageState(beforeCursor: $0.beforeCursor, hasMore: $0.hasMore, loadingOlder: false) }
  }

  /// A retained "live" state stays live; the cursor resume only replays what was missed.
  static func cachedState(_ value: EnvironmentThreadState) -> EnvironmentThreadState {
    var next = value
    if !(value.status == .deleted || (value.status == .live && value.data != nil)) {
      next.status = value.data == nil ? .empty : .cached
    }
    next.error = nil
    next.page?.loadingOlder = false
    return next
  }

  private var statusWithoutLiveData: ThreadDetailStatus { state.data == nil ? .empty : .cached }

  public var resumeSnapshot: ThreadResumeSnapshot { ThreadResumeSnapshot(state: state, sequence: lastSequence, persisted: false) }

  /// The settled state as a cache entry (used when the scope closes); nil while a turn is running or without data.
  public func currentPersistRequest() -> ThreadPersistRequest? {
    guard let thread = state.data, !(thread.session?.isStartingOrRunning ?? false) else { return nil }
    return ThreadPersistRequest(
      snapshot: V1.OrchestrationThreadDetailSnapshot(
        snapshotSequence: lastSequence, thread: thread,
        page: state.page.map { V1.OrchestrationThreadDetailPage(beforeCursor: $0.beforeCursor, hasMore: $0.hasMore, snapshotSequence: lastSequence, threadSequence: nil) }))
  }

  public mutating func takePersistRequest() -> ThreadPersistRequest? {
    defer { persistRequest = nil }
    return persistRequest
  }

  // MARK: Connection and subscription lifecycle

  public mutating func setConnecting() {
    if state.status == .deleted || state.error != nil { return }
    state.status = .synchronizing
    state.error = nil
  }

  public mutating func setReady() {
    if state.status == .live || state.status == .deleted || state.error != nil { return }
    state.status = .synchronizing
    state.error = nil
  }

  public mutating func setDisconnected() {
    awaitingCompletion = false
    // The capabilities belong to the session that advertised them: a new prepared connection can
    // exist before the new session's config arrives, and must not be sent window parameters.
    paginationSupported = false
    reasoningMessagesSupported = false
    if state.status != .deleted { state.status = statusWithoutLiveData }
  }

  public mutating func setStreamError(_ message: String) {
    awaitingCompletion = false
    if state.status != .deleted { state.status = statusWithoutLiveData }
    state.error = message
  }

  /// Clears the diagnostic only when a subscription actually tries again.
  public mutating func markSynchronizing() {
    if resumingLive { return }
    if state.status != .deleted {
      state.status = .synchronizing
      state.error = nil
    }
  }

  public struct SubscriptionPlan: Sendable, Equatable {
    /// True when the live data must be (re)loaded: no usable data and the thread is not deleted.
    public var needsSnapshot: Bool
  }

  /// First half of `makeSubscribeInput`: records the session's capabilities and decides whether
  /// a snapshot must be fetched before subscribing.
  public mutating func beginSubscription(config: ServerConfig?) -> SubscriptionPlan {
    let supportsMarker = config?.threadResumeCompletionMarker == true
    paginationSupported = config?.threadSnapshotPagination == true
    reasoningMessagesSupported = config?.reasoningMessages == true
    awaitingCompletion = supportsMarker
    markSynchronizing()
    resumingLive = false
    // A windowed cache resuming against a server without pagination is a trap: afterSequence keeps
    // only the window and older turns could never be loaded. Drop the window and reload fully.
    if !paginationSupported, state.page != nil {
      historyEpoch += 1
      state.data = nil
      if state.status != .deleted { state.status = .empty }
      state.page = nil
      lastSequence = 0
    }
    return SubscriptionPlan(needsSnapshot: state.data == nil && state.status != .deleted)
  }

  public struct SubscribeInput: Sendable, Equatable {
    public var threadId: ThreadId
    public var afterSequence: Int?
    public var requestCompletionMarker: Bool
    public var reasoningMessages: Bool
    public var turnLimit: Int?
  }

  /// Second half of `makeSubscribeInput`, after the optional HTTP snapshot was applied.
  public mutating func subscribeInput(threadId: ThreadId, config: ServerConfig?) -> SubscribeInput {
    let supportsMarker = config?.threadResumeCompletionMarker == true
    let canResume = state.data != nil
    if !supportsMarker, canResume {
      if state.status != .deleted { state.status = .live }
      state.error = nil
    }
    return SubscribeInput(
      threadId: threadId, afterSequence: canResume ? lastSequence : nil, requestCompletionMarker: supportsMarker,
      reasoningMessages: reasoningMessagesSupported, turnLimit: paginationSupported ? ThreadPaging.initialUserTurnLimit : nil)
  }

  // MARK: Applying stream items

  private mutating func setThread(_ thread: V1.OrchestrationThread, page: ThreadPageState??) {
    state.data = thread
    // Buffered values from a failed attempt can still arrive after its error.
    state.status = state.error != nil ? .cached : (awaitingCompletion ? .synchronizing : .live)
    if let page { state.page = page }
    // An active turn updates many times per second; persist once it settles.
    if !(thread.session?.isStartingOrRunning ?? false) { offerPersistence(thread, sequence: lastSequence) }
  }

  private mutating func offerPersistence(_ thread: V1.OrchestrationThread, sequence: Int) {
    persistRequest = ThreadPersistRequest(
      snapshot: V1.OrchestrationThreadDetailSnapshot(
        snapshotSequence: sequence, thread: thread,
        // Persist the window boundary with the window's content so a restore keeps paging from there.
        page: state.page.map { V1.OrchestrationThreadDetailPage(beforeCursor: $0.beforeCursor, hasMore: $0.hasMore, snapshotSequence: sequence, threadSequence: nil) }))
  }

  /// True when the thread was deleted by this item (the owner removes the cached copy).
  @discardableResult
  public mutating func apply(_ item: V1.OrchestrationThreadStreamItem) -> Bool {
    switch item {
    case .synchronized:
      awaitingCompletion = false
      if state.data != nil, state.status != .deleted, state.error == nil {
        state.status = .live
        state.error = nil
      }
      return false
    case .snapshot(let s):
      // A fresh snapshot replaces all loaded history, including older pages: a turn reverted while
      // disconnected would otherwise survive with no event left to remove it.
      historyEpoch += 1
      pendingOlderPage = nil
      lastSequence = s.snapshot.snapshotSequence
      setThread(s.snapshot.thread, page: .some(Self.pageState(s.snapshot.page)))
      return false
    case .event(let e):
      return applyEvent(e.event)
    case .unknown:
      return false
    }
  }

  private mutating func applyEvent(_ event: V1.OrchestrationEvent) -> Bool {
    guard let sequence = event.sequence else { return false }
    if sequence <= lastSequence { return false }
    lastSequence = sequence
    guard let thread = state.data else {
      if event.isThreadDeleted {
        setDeleted()
        return true
      }
      return false
    }
    // A revert rewrites loaded history: an older-page fetch in flight may straddle the removed range.
    if event.isThreadReverted { historyEpoch += 1 }
    var deleted = false
    switch ThreadReducer.apply(thread, event) {
    case .updated(let next): setThread(next, page: nil)
    case .deleted:
      setDeleted()
      deleted = true
    case .unchanged: break
    }
    tryMergePendingOlderPage()
    return deleted
  }

  private mutating func setDeleted() {
    awaitingCompletion = false
    historyEpoch += 1
    state = EnvironmentThreadState(data: nil, status: .deleted, error: nil, page: nil)
  }

  /// Applies a received batch. Plain event batches take a fast path with one state write.
  /// Returns true when the thread was deleted.
  @discardableResult
  public mutating func apply(_ items: [V1.OrchestrationThreadStreamItem]) -> Bool {
    guard var thread = state.data, pendingOlderPage == nil, !items.contains(where: Self.needsSlowPath) else {
      var deleted = false
      for item in items { deleted = apply(item) || deleted }
      return deleted
    }
    var sequence = lastSequence
    var synchronized = false
    // Retain the last settled state even if the next turn starts before this batch publishes.
    var persistable: (V1.OrchestrationThread, Int)?
    let original = thread
    for item in items {
      switch item {
      case .synchronized: synchronized = true
      case .event(let e):
        guard let eventSequence = e.event.sequence, eventSequence > sequence else { continue }
        sequence = eventSequence
        if case .updated(let next) = ThreadReducer.apply(thread, e.event) {
          thread = next
          if !(thread.session?.isStartingOrRunning ?? false) { persistable = (thread, sequence) }
        }
      default: break
      }
    }
    lastSequence = sequence
    if thread != original { setThread(thread, page: nil) }
    if let persistable, thread.session?.isStartingOrRunning ?? false { offerPersistence(persistable.0, sequence: persistable.1) }
    if synchronized { apply(.synchronized) }
    return false
  }

  private static func needsSlowPath(_ item: V1.OrchestrationThreadStreamItem) -> Bool {
    switch item {
    case .snapshot: true
    case .event(let e): e.event.isThreadReverted || e.event.isThreadDeleted
    default: false
    }
  }

  // MARK: Older pages

  public struct OlderPageRequest: Sendable, Equatable {
    public var turnLimit: Int
    public var beforeCursor: String
    public var reasoningMessages: Bool
    public var epochAtStart: Int
  }

  /// Marks an older-page fetch as started. Nil when pagination is unsupported, no cursor exists
  /// or a fetch is already running.
  public mutating func beginLoadOlder() -> OlderPageRequest? {
    guard paginationSupported, let page = state.page, !page.loadingOlder, page.hasMore, let cursor = page.beforeCursor else { return nil }
    state.page?.loadingOlder = true
    return OlderPageRequest(
      turnLimit: ThreadPaging.olderPageUserTurnLimit, beforeCursor: cursor, reasoningMessages: reasoningMessagesSupported,
      epochAtStart: historyEpoch)
  }

  /// Staleness check and merge of a fetched page. `response == nil` means the load failed.
  public mutating func completeLoadOlder(_ response: V1.OrchestrationThreadDetailSnapshot?, request: OlderPageRequest) {
    // A page older than the loaded state was read from a projection behind what we render.
    let stale = historyEpoch != request.epochAtStart || (response.map { $0.snapshotSequence < lastSequence } ?? false)
    guard let response, !stale else {
      state.page?.loadingOlder = false
      return
    }
    // A page read AHEAD of the live state may hold content the subscription has not delivered yet;
    // merging now and then replaying those events would duplicate them. Park it until the live state
    // reaches the page's thread-scoped watermark. Pre-watermark servers merge immediately.
    if let watermark = response.page?.threadSequence, watermark > lastSequence {
      pendingOlderPage = PendingOlderPage(snapshot: response, epoch: historyEpoch)
      return
    }
    mergeOlderPage(response)
  }

  private mutating func tryMergePendingOlderPage() {
    guard let pending = pendingOlderPage else { return }
    if historyEpoch != pending.epoch {
      pendingOlderPage = nil
      state.page?.loadingOlder = false
      return
    }
    if let watermark = pending.snapshot.page?.threadSequence, watermark > lastSequence { return }
    pendingOlderPage = nil
    mergeOlderPage(pending.snapshot)
  }

  /// Prepends an older disjoint page. Identity dedupe guards overlapping pages (a server bug or cursor misuse).
  private mutating func mergeOlderPage(_ snapshot: V1.OrchestrationThreadDetailSnapshot) {
    guard let loaded = state.data else { return }
    let older = snapshot.thread
    func mergeById<T>(_ olderRows: [T], _ loadedRows: [T], id: (T) -> String) -> [T] {
      let seen = Set(loadedRows.map(id))
      return olderRows.filter { !seen.contains(id($0)) } + loadedRows
    }
    let seenCheckpoints = Set(loaded.checkpoints.map(\.turnId))
    var merged = loaded  // thread metadata stays the loaded (newer) snapshot's
    merged.messages = mergeById(older.messages, loaded.messages) { $0.id.rawValue }
    merged.activities = mergeById(older.activities, loaded.activities) { $0.id.rawValue }
    merged.proposedPlans = mergeById(older.proposedPlans, loaded.proposedPlans) { $0.id }
    merged.checkpoints = older.checkpoints.filter { !seenCheckpoints.contains($0.turnId) } + loaded.checkpoints
    state.data = merged
    state.page = Self.pageState(snapshot.page)
    // Persist the widened window under the *loaded* watermark: the merged content is only known
    // consistent with the state it merged into.
    if !(merged.session?.isStartingOrRunning ?? false) {
      persistRequest = ThreadPersistRequest(
        snapshot: V1.OrchestrationThreadDetailSnapshot(
          snapshotSequence: lastSequence, thread: merged,
          page: snapshot.page.map {
            V1.OrchestrationThreadDetailPage(beforeCursor: $0.beforeCursor, hasMore: $0.hasMore, snapshotSequence: lastSequence, threadSequence: $0.threadSequence)
          }))
    }
  }
}
