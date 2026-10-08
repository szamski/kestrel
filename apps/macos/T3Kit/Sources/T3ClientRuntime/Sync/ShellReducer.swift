import Foundation
import T3Contracts

/// Port of `state/shellReducer.ts` and the item handling of `state/shell.ts`.
public enum ShellReducer {
  /// Applies one shell stream event: drops sequence <= cursor, upserts whole objects.
  public static func apply(_ snapshot: OrchestrationShellSnapshot, _ item: OrchestrationShellStreamItem) -> OrchestrationShellSnapshot {
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

  static func sequence(_ item: OrchestrationShellStreamItem) -> Int? {
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
  public var snapshot: OrchestrationShellSnapshot?
  public var status: ShellStatus
  public var error: String?
  public static let empty = EnvironmentShellState(snapshot: nil, status: .empty, error: nil)
}

/// Shell synchronisation state machine (the pure part of `makeEnvironmentShellState`):
/// `empty | cached -> synchronizing -> live`. Transport health is separate: a failed shell
/// subscription coexists with a healthy connection and shows `error`, never "reconnecting".
public struct ShellStateMachine: Sendable {
  public static let synchronizationErrorMessage = "Could not synchronize environment data."
  public private(set) var state: EnvironmentShellState
  /// True between subscribing with a completion marker and the `synchronized` item.
  public private(set) var awaitingCompletion = false

  public init(cached: OrchestrationShellSnapshot? = nil) {
    state = EnvironmentShellState(snapshot: cached, status: cached == nil ? .empty : .cached, error: nil)
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
  public mutating func apply(_ items: [OrchestrationShellStreamItem]) -> ApplyResult {
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
        next = EnvironmentShellState(snapshot: e.snapshot, status: waiting ? .synchronizing : .live, error: nil)
        result.receivedSnapshot = true
      case .unknown:
        continue
      default:
        guard let current = next.snapshot else { continue }
        let sequence = ShellReducer.sequence(item) ?? 0
        let reduced = sequence > current.snapshotSequence ? ShellReducer.apply(current, item) : current
        next = EnvironmentShellState(snapshot: reduced, status: waiting ? .synchronizing : .live, error: nil)
      }
      result.changed = true
    }
    awaitingCompletion = waiting
    result.snapshotChanged = next.snapshot != state.snapshot
    state = next
    return result
  }
}
