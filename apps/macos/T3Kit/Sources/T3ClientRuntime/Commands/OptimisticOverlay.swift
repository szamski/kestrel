import Foundation
import T3Contracts

/// An optimistic shell update, applied on top of the synchronised snapshot until the server's
/// own shell event for the command has arrived (port of `state/threadLifecycle.ts`). Exactly the
/// lifecycle commands the web client applies optimistically are covered.
public enum OptimisticAction: Sendable, Equatable {
  case settle
  case unsettle
  case snooze(until: IsoDateTime)
  case unsnooze
  case pin(orderKey: String?)
  case unpin
  case reorderPinned(orderKey: String)
  case reorderActive(orderKey: String)

  /// `accepted` is true once the server acknowledged the command (its guards then already passed).
  func apply(_ thread: V1.OrchestrationThreadShell, now: IsoDateTime, accepted: Bool) -> V1.OrchestrationThreadShell {
    var t = thread
    switch self {
    case .settle:
      if !accepted, !ThreadSettled.canSnooze(thread, now: now) || thread.session?.isStartingOrRunning == true { return thread }
      t.hasPendingApprovals = false
      t.hasPendingUserInput = false
      t.settledOverride = .settled
      t.settledAt = thread.settledOverride == .settled ? (thread.settledAt ?? now) : now
      t.unsettledAt = .some(nil)
      t.activeOrderKey = .some(nil)
      t.pinnedAt = .some(nil)
      t.pinOrderKey = .some(nil)
      t.snoozedAt = .some(nil)
      t.snoozedUntil = .some(nil)
    case .unsettle:
      t.settledOverride = .active
      t.settledAt = nil
      t.unsettledAt = thread.settledOverride == .active ? (thread.unsettledAt ?? .some(nil)) : .some(now)
    case .snooze(let until):
      if !accepted, !ThreadSettled.canSnooze(thread, now: now) { return thread }
      guard let wake = IsoTimestamp.parse(until), let nowMs = IsoTimestamp.parse(now), wake > nowMs else { return thread }
      t.hasPendingApprovals = false
      t.hasPendingUserInput = false
      t.snoozedUntil = .some(until)
      t.snoozedAt = .some(optionalValue(thread.snoozedUntil) == until ? (optionalValue(thread.snoozedAt) ?? now) : now)
    case .unsnooze:
      t.snoozedUntil = .some(nil)
      t.snoozedAt = .some(nil)
    case .pin(let orderKey):
      let alreadyPinned = optionalValue(thread.pinnedAt) != nil
      t.pinnedAt = .some(optionalValue(thread.pinnedAt) ?? now)
      t.pinOrderKey = alreadyPinned ? thread.pinOrderKey : .some(orderKey)
      if thread.settledOverride == .settled {
        t.settledOverride = .active
        t.settledAt = nil
        t.unsettledAt = .some(now)
      }
      t.snoozedUntil = .some(nil)
      t.snoozedAt = .some(nil)
    case .unpin:
      t.pinnedAt = .some(nil)
      t.pinOrderKey = .some(nil)
    case .reorderPinned(let key):
      t.pinOrderKey = .some(key)
    case .reorderActive(let key):
      t.activeOrderKey = .some(key)
    }
    return t
  }
}

/// Pending optimistic updates of one environment.
public struct OptimisticOverlay: Sendable, Equatable {
  public struct Update: Sendable, Equatable, Identifiable {
    public let id: Int
    public let threadId: ThreadId
    public let action: OptimisticAction
    public let now: IsoDateTime
    /// Set once the server accepted the command: the update is shown until the shell reaches this sequence.
    public var sequence: Int?
  }

  public private(set) var updates: [Update] = []
  private var nextId = 0

  public init() {}
  public var isEmpty: Bool { updates.isEmpty }

  public mutating func add(threadId: ThreadId, action: OptimisticAction, now: IsoDateTime) -> Int {
    nextId += 1
    updates.append(Update(id: nextId, threadId: threadId, action: action, now: now, sequence: nil))
    return nextId
  }
  /// Failure or rejection: the update disappears (rollback).
  public mutating func remove(_ id: Int) { updates.removeAll { $0.id == id } }
  public mutating func accept(_ id: Int, sequence: Int) {
    if let index = updates.firstIndex(where: { $0.id == id }) { updates[index].sequence = sequence }
  }
  /// Drops updates whose acknowledged sequence the snapshot already reached.
  public mutating func reconcile(with snapshot: V1.OrchestrationShellSnapshot?) {
    updates.removeAll { update in
      guard let sequence = update.sequence else { return false }
      return snapshot.map { $0.snapshotSequence >= sequence } ?? true
    }
  }

  /// The snapshot as the user should see it: pending updates layered over the synchronised data.
  public func apply(to snapshot: V1.OrchestrationShellSnapshot) -> V1.OrchestrationShellSnapshot {
    var byThread: [ThreadId: [Update]] = [:]
    for update in updates {
      if let sequence = update.sequence, sequence <= snapshot.snapshotSequence { continue }
      byThread[update.threadId, default: []].append(update)
    }
    if byThread.isEmpty { return snapshot }
    var next = snapshot
    next.threads = snapshot.threads.map { thread in
      (byThread[thread.id] ?? []).reduce(thread) { current, update in
        update.action.apply(current, now: update.now, accepted: update.sequence != nil)
      }
    }
    return next
  }
}
