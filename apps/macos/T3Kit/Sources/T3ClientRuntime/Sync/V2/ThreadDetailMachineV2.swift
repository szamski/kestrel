import Foundation
import T3Contracts

/// Pure thread detail state machine of protocol 2: port of `makeEnvironmentThreadState`
/// (client-runtime `state/threads.ts`) minus I/O. `empty | cached -> synchronizing -> live | deleted`,
/// cursor `lastSequence`, a bounded recent window with older pages merged on demand.
public struct ThreadDetailMachineV2: Sendable {
  public private(set) var state: EnvironmentThreadState
  public private(set) var lastSequence: Int
  public private(set) var awaitingCompletion = false
  /// Only the first subscription after a warm live resume keeps the retained status.
  public private(set) var resumingLive: Bool
  /// Set by updates that should reach the disk cache; the owner takes it with `takePersistRequest()`.
  private var persistRequest: OrchestrationV2ThreadDetailSnapshot?

  public init(cached: OrchestrationV2ThreadDetailSnapshot? = nil, retained: ThreadResumeSnapshot? = nil) {
    if let retained {
      state = Self.cachedState(retained.state)
      lastSequence = retained.sequence
    } else {
      state = EnvironmentThreadState(
        data: nil, projection: cached?.projection, history: cached.map(Self.historyMeta) ?? .empty,
        status: cached == nil ? .empty : .cached, error: nil, page: nil)
      lastSequence = cached?.snapshotSequence ?? 0
    }
    resumingLive = state.status == .live
  }

  // MARK: Helpers

  /// A retained "live" state stays live; the cursor resume only replays what was missed.
  static func cachedState(_ value: EnvironmentThreadState) -> EnvironmentThreadState {
    var next = value
    if !(value.status == .deleted || (value.status == .live && value.projection != nil)) {
      next.status = value.projection == nil ? .empty : .cached
    }
    next.error = nil
    next.history.loading = false
    next.history.error = nil
    return next
  }

  static func historyMeta(_ snapshot: OrchestrationV2ThreadDetailSnapshot) -> ThreadHistoryMeta {
    ThreadHistoryMeta(
      historyCursor: optionalValue(snapshot.historyCursor), hasMoreHistory: snapshot.hasMoreHistory ?? false, loading: false, error: nil,
      // The cache never stores expanded progressive history (load-earlier growth).
      expanded: false, latestLocalTurnOrdinal: optionalValue(snapshot.latestLocalTurnOrdinal))
  }

  private var statusWithoutLiveData: ThreadDetailStatus { state.projection == nil ? .empty : .cached }

  public var resumeSnapshot: ThreadResumeSnapshot {
    ThreadResumeSnapshot(state: state, sequence: lastSequence, persisted: false, orchestrationProtocol: .v2)
  }

  /// After the user loads older pages the in-memory timeline can grow large: keep it out of the cache. A run
  /// in flight updates many times per second: persist once it settles.
  static func shouldPersist(_ projection: OrchestrationV2ThreadProjection, _ history: ThreadHistoryMeta) -> Bool {
    if history.expanded { return false }
    return !projection.runs.contains { $0.status == .preparing || $0.status == .starting || $0.status == .running }
  }

  static func detail(sequence: Int, projection: OrchestrationV2ThreadProjection, history: ThreadHistoryMeta) -> OrchestrationV2ThreadDetailSnapshot {
    // A complete bounded snapshot still proves paging support: keep the evidence so a thread that grows
    // while closed can resume with a bounded fallback.
    OrchestrationV2ThreadDetailSnapshot(
      snapshotSequence: sequence, projection: projection, historyCursor: .some(history.historyCursor), hasMoreHistory: history.hasMoreHistory,
      latestLocalTurnOrdinal: .some(history.latestLocalTurnOrdinal))
  }

  /// The settled state as a cache entry (used when the scope closes); nil while a run is active or without data.
  public func currentPersistRequest() -> OrchestrationV2ThreadDetailSnapshot? {
    guard let projection = state.projection, Self.shouldPersist(projection, state.history) else { return nil }
    return Self.detail(sequence: lastSequence, projection: projection, history: state.history)
  }

  public mutating func takePersistRequest() -> OrchestrationV2ThreadDetailSnapshot? {
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

  /// First half of `makeSubscribeInput`: records the session's capability and says whether a snapshot is needed.
  public mutating func beginSubscription(config: ServerConfig?) -> (needsSnapshot: Bool, parked: Bool) {
    // A prior definitive miss (or delete event) already cleared this thread: do not retry against a known-missing id.
    if state.status == .deleted { return (false, true) }
    awaitingCompletion = config?.threadResumeCompletionMarker == true
    markSynchronizing()
    resumingLive = false
    return (state.projection == nil, false)
  }

  /// A definitive HTTP 404: forget cache and state; the socket is not opened for this thread again.
  public mutating func setMissing() { setDeleted() }

  /// The seed from HTTP, installed atomically with its progressive meta so a bounded window never persists as a full timeline.
  public mutating func applyHttp(_ snapshot: OrchestrationV2ThreadDetailSnapshot, history: ThreadHistoryMeta?) {
    lastSequence = snapshot.snapshotSequence
    setThread(snapshot.projection, history: history ?? .empty)
  }

  public struct SubscribeInput: Sendable, Equatable {
    public var threadId: ThreadId
    public var afterSequence: Int?
    public var requestCompletionMarker: Bool
  }

  /// Second half of `makeSubscribeInput`, after the optional HTTP snapshot was applied.
  public mutating func subscribeInput(threadId: ThreadId, config: ServerConfig?) -> SubscribeInput {
    let supportsMarker = config?.threadResumeCompletionMarker == true
    let canResume = state.projection != nil
    if !supportsMarker, canResume {
      if state.status != .deleted { state.status = .live }
      state.error = nil
    }
    return SubscribeInput(threadId: threadId, afterSequence: canResume ? lastSequence : nil, requestCompletionMarker: supportsMarker)
  }

  // MARK: Applying stream items

  private mutating func setThread(_ projection: OrchestrationV2ThreadProjection, history: ThreadHistoryMeta?) {
    state.projection = projection
    if let history { state.history = history }
    // Buffered values from a failed attempt can arrive after its error.
    state.status = state.error != nil ? .cached : (awaitingCompletion ? .synchronizing : .live)
    if Self.shouldPersist(projection, state.history) { persistRequest = Self.detail(sequence: lastSequence, projection: projection, history: state.history) }
  }

  private mutating func setDeleted() {
    awaitingCompletion = false
    state = EnvironmentThreadState(data: nil, projection: nil, history: .empty, status: .deleted, error: nil, page: nil)
  }

  /// Applies a received batch. Returns true when the thread was deleted by it (the owner removes the cached copy).
  @discardableResult
  public mutating func apply(_ items: [OrchestrationV2ThreadStreamItem]) -> Bool {
    var events: [(sequence: Int, event: OrchestrationV2DomainEvent?)] = []
    var deleted = false
    for item in items {
      switch item {
      case .unknownEvent(let e): events.append((e.sequence, nil))
      case .event(let e) where !e.event.isThreadDeleted: events.append((e.sequence, e.event))
      case .event(let e):
        deleted = applyEvents(events) || deleted
        events = []
        deleted = applyEvents([(e.sequence, e.event)]) || deleted
      case .synchronized:
        deleted = applyEvents(events) || deleted
        events = []
        awaitingCompletion = false
        if state.projection != nil, state.status != .deleted, state.error == nil {
          state.status = .live
          state.error = nil
        }
      case .snapshot(let snapshot):
        deleted = applyEvents(events) || deleted
        events = []
        applySocketSnapshot(snapshot)
      case .unknown: continue
      }
    }
    return applyEvents(events) || deleted
  }

  private mutating func applySocketSnapshot(_ snapshot: OrchestrationV2ThreadStreamItemSnapshot) {
    lastSequence = snapshot.snapshotSequence
    let projection = snapshot.turnItemsOmitLocalVisible == true ? ThreadHistory.restoreLocalVisibleTurnItems(snapshot.projection) : snapshot.projection
    // Bounded socket fallbacks carry their cursor; full snapshots omit these fields and reset progressive state.
    let hasProgressiveHistory = snapshot.historyCursor != nil || snapshot.hasMoreHistory != nil || snapshot.latestLocalTurnOrdinal != nil
    setThread(
      projection,
      history: hasProgressiveHistory
        ? ThreadHistoryMeta(
          historyCursor: optionalValue(snapshot.historyCursor), hasMoreHistory: snapshot.hasMoreHistory ?? false, loading: false, error: nil,
          expanded: false, latestLocalTurnOrdinal: optionalValue(snapshot.latestLocalTurnOrdinal))
        : .empty)
  }

  /// `applyEventsLocked`: an event type from a newer server still moves the resume cursor past it.
  private mutating func applyEvents(_ items: [(sequence: Int, event: OrchestrationV2DomainEvent?)]) -> Bool {
    var sequence = lastSequence
    var fresh: [OrchestrationV2DomainEvent] = []
    for item in items where item.sequence > sequence {
      sequence = item.sequence
      if let event = item.event { fresh.append(event) }
    }
    if sequence == lastSequence { return false }
    lastSequence = sequence
    var applied = false
    for event in fresh {
      if state.status == .deleted { continue }
      guard let projection = state.projection else {
        if event.isThreadDeleted {
          setDeleted()
          return true
        }
        continue
      }
      if event.isThreadDeleted {
        setDeleted()
        return true
      }
      // Incomplete progressive windows only (more history or an open cursor). `expanded` stays true after the
      // last page as a cache marker, so it is not the signal.
      let options = state.history.isPartial ? ProjectionOptions(partialTimeline: true, latestLocalTurnOrdinal: state.history.latestLocalTurnOrdinal) : ProjectionOptions()
      guard case .updated(let next) = ThreadProjectionReducer.apply(projection, event, options: options) else { continue }
      if options.partialTimeline, case .turnItemUpdated(let e) = event, let ordinal = e.payload.head?.ordinal {
        if state.history.latestLocalTurnOrdinal.map({ ordinal > $0 }) ?? true { state.history.latestLocalTurnOrdinal = ordinal }
      }
      state.projection = next
      state.status = awaitingCompletion ? .synchronizing : .live
      state.error = nil
      applied = true
    }
    if applied, let projection = state.projection, Self.shouldPersist(projection, state.history) {
      persistRequest = Self.detail(sequence: lastSequence, projection: projection, history: state.history)
    }
    return false
  }

  // MARK: Older pages

  public enum LoadEarlierStart: Sendable, Equatable {
    /// Fetch the page behind this cursor.
    case request(cursor: String)
    case noop
    case busy
  }

  public mutating func beginLoadEarlier() -> LoadEarlierStart {
    guard state.status != .deleted, state.projection != nil, state.history.hasMoreHistory, let cursor = state.history.historyCursor else { return .noop }
    if state.history.loading { return .busy }
    state.history.loading = true
    state.history.error = nil
    return .request(cursor: cursor)
  }

  public enum LoadEarlierResult: Sendable, Equatable { case loaded, noop, error(String) }

  /// A response only applies while the cursor that started it is still the active one: a socket or new
  /// bounded snapshot may have replaced progressive meta meanwhile.
  public mutating func completeLoadEarlier(cursor: String, page: OrchestrationV2ThreadHistoryPage?, message: String?) -> LoadEarlierResult {
    guard state.history.historyCursor == cursor else { return .noop }
    guard let page else {
      let message = message ?? "Could not load earlier activity."
      state.history.loading = false
      state.history.error = message
      return .error(message)
    }
    guard let projection = state.projection, state.status != .deleted else {
      state.history = .empty
      return .noop
    }
    state.projection = ThreadHistory.mergeOlder(projection, page.items)
    if awaitingCompletion { state.status = .synchronizing }
    state.history = ThreadHistory.applying(page: page, to: state.history)
    return .loaded
  }

  /// The load was cancelled: clear the loading flag when its cursor is still active; never touch status or error.
  public mutating func cancelLoadEarlier(cursor: String) {
    if state.history.historyCursor == cursor, state.history.loading { state.history.loading = false }
  }
}
