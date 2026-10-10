import Foundation
import T3Contracts
import T3Protocol

/// Port of `state/shellReducer.ts` and the item handling of `state/shell.ts`.
public enum ShellReducer {
  /// Applies one shell stream event: drops sequence <= cursor, upserts whole objects.
  public static func apply(_ snapshot: V1.OrchestrationShellSnapshot, _ item: V1.OrchestrationShellStreamItem) -> V1.OrchestrationShellSnapshot {
    var next = snapshot
    switch item {
    case .projectUpserted(let e):
      guard e.sequence > snapshot.snapshotSequence else { return snapshot }
      if let i = next.projects.firstIndex(where: { $0.id == e.project.id }) { next.projects[i] = e.project } else { next.projects.append(e.project) }
      next.snapshotSequence = e.sequence
    case .projectRemoved(let e):
      guard e.sequence > snapshot.snapshotSequence else { return snapshot }
      next.projects.removeAll { $0.id == e.projectId }
      next.snapshotSequence = e.sequence
    case .threadUpserted(let e):
      guard e.sequence > snapshot.snapshotSequence else { return snapshot }
      if let i = next.threads.firstIndex(where: { $0.id == e.thread.id }) { next.threads[i] = e.thread } else { next.threads.append(e.thread) }
      next.snapshotSequence = e.sequence
    case .threadRemoved(let e):
      guard e.sequence > snapshot.snapshotSequence else { return snapshot }
      next.threads.removeAll { $0.id == e.threadId }
      next.snapshotSequence = e.sequence
    case .synchronized, .snapshot, .unknown:
      return snapshot
    }
    return next
  }

  static func sequence(_ item: V1.OrchestrationShellStreamItem) -> Int? {
    switch item {
    case .projectUpserted(let e): e.sequence
    case .projectRemoved(let e): e.sequence
    case .threadUpserted(let e): e.sequence
    case .threadRemoved(let e): e.sequence
    default: nil
    }
  }
}

public enum ShellStatus: String, Sendable { case empty, cached, synchronizing, live }

public struct EnvironmentShellState: Sendable, Equatable {
  /// The shell in the shape the sidebar derivations read. On protocol 2 it is `ShellPresentation` of `v2`.
  public var snapshot: V1.OrchestrationShellSnapshot?
  /// The protocol-2 records `snapshot` was presented from; nil on protocol 1.
  public var v2: OrchestrationV2ShellSnapshot?
  public var status: ShellStatus
  public var error: String?
  public static let empty = EnvironmentShellState(snapshot: nil, v2: nil, status: .empty, error: nil)
}

/// Shell synchronisation state machine (the pure part of `makeEnvironmentShellState`):
/// `empty | cached -> synchronizing -> live`. Transport health is separate: a failed shell
/// subscription coexists with a healthy connection and shows `error`, never "reconnecting".
public struct ShellStateMachine: Sendable {
  public static let synchronizationErrorMessage = "Could not synchronize environment data."
  public private(set) var state: EnvironmentShellState
  /// True between subscribing with a completion marker and the `synchronized` item.
  public private(set) var awaitingCompletion = false

  public init(cached: V1.OrchestrationShellSnapshot? = nil) {
    state = EnvironmentShellState(snapshot: cached, v2: nil, status: cached == nil ? .empty : .cached, error: nil)
  }

  public init(cachedV2: OrchestrationV2ShellSnapshot) {
    state = EnvironmentShellState(snapshot: ShellPresentation.snapshot(cachedV2), v2: cachedV2, status: .cached, error: nil)
  }

  /// The protocol the held data speaks; nil while empty.
  public var dataProtocol: OrchestrationProtocol? { state.v2 != nil ? .v2 : (state.snapshot != nil ? .v1 : nil) }

  /// Forgets the held data: it came from another protocol than the one the connection now speaks.
  public mutating func reset() {
    awaitingCompletion = false
    state = .empty
  }

  private var statusWithoutLiveData: ShellStatus { state.snapshot == nil ? .empty : .cached }

  public mutating func setSynchronizing() {
    state.status = .synchronizing
    state.error = nil
  }
  public mutating func setReady() {
    if state.status != .live { setSynchronizing() }
  }
  public mutating func setDisconnected() {
    awaitingCompletion = false
    state.status = statusWithoutLiveData
  }
  public mutating func setStreamError() {
    awaitingCompletion = false
    state.status = statusWithoutLiveData
    state.error = Self.synchronizationErrorMessage
  }
  public mutating func beginSubscription(supportsCompletionMarker: Bool) {
    awaitingCompletion = supportsCompletionMarker
    setSynchronizing()
  }
  /// Without a completion marker a resumed subscription has no `synchronized` signal: report live at once.
  public mutating func markLive() {
    state.status = .live
    state.error = nil
  }

  public struct ApplyResult: Sendable, Equatable {
    public var changed = false
    public var receivedSnapshot = false
    public var snapshotChanged = false
  }

  /// Applies a batch with one state write.
  @discardableResult
  public mutating func apply(_ items: [V1.OrchestrationShellStreamItem]) -> ApplyResult {
    var result = ApplyResult()
    var next = state
    var waiting = awaitingCompletion
    for item in items {
      switch item {
      case .synchronized:
        waiting = false
        if next.snapshot != nil {
          next.status = .live
          next.error = nil
        }
        result.changed = true
        continue
      case .snapshot(let e):
        next = EnvironmentShellState(snapshot: e.snapshot, v2: nil, status: waiting ? .synchronizing : .live, error: nil)
        result.receivedSnapshot = true
      case .unknown:
        continue
      default:
        guard let current = next.snapshot else { continue }
        let sequence = ShellReducer.sequence(item) ?? 0
        let reduced = sequence > current.snapshotSequence ? ShellReducer.apply(current, item) : current
        next = EnvironmentShellState(snapshot: reduced, v2: nil, status: waiting ? .synchronizing : .live, error: nil)
      }
      result.changed = true
    }
    awaitingCompletion = waiting
    result.snapshotChanged = next.snapshot != state.snapshot
    state = next
    return result
  }

  /// Applies a protocol-2 batch with one state write (`applyItems` of `shell.ts`).
  @discardableResult
  public mutating func apply(v2 items: [OrchestrationV2ShellStreamItem]) -> ApplyResult {
    var result = ApplyResult()
    var next = state
    var waiting = awaitingCompletion
    for item in items {
      switch item {
      case .synchronized:
        waiting = false
        if next.snapshot != nil {
          next.status = .live
          next.error = nil
        }
        result.changed = true
        continue
      case .snapshot(let e):
        let merged = ShellReducerV2.mergeSnapshot(previous: next.v2, e.snapshot, resolvedRoots: e.resolvedRepositoryIdentityRoots)
        next = EnvironmentShellState(
          snapshot: ShellPresentation.snapshot(merged), v2: merged, status: waiting ? .synchronizing : .live, error: nil)
        result.receivedSnapshot = true
      case .unknown:
        continue
      default:
        guard let current = next.v2, let presented = next.snapshot else { continue }
        var reduced = current
        var shown = presented
        if let sequence = ShellReducerV2.sequence(item), sequence > current.snapshotSequence {
          reduced = ShellReducerV2.apply(current, item)
          shown = ShellReducerV2.presenting(presented, item, reduced: reduced)
        }
        next = EnvironmentShellState(snapshot: shown, v2: reduced, status: waiting ? .synchronizing : .live, error: nil)
      }
      result.changed = true
    }
    awaitingCompletion = waiting
    // Every applied delta moves the cursor, so comparing it avoids an equality pass over the whole shell.
    result.snapshotChanged = result.receivedSnapshot || next.v2?.snapshotSequence != state.v2?.snapshotSequence
    state = next
    return result
  }
}
