import Foundation
import T3Contracts

/// What a thread transition announces. Port of the web's `ThreadNotificationCoordinator` rules.
public enum ThreadNotificationKind: Sendable, Equatable {
  case completion, input, approval, failed, limited

  public var title: String {
    switch self {
    case .completion: "Thread completed"
    case .input: "Input needed"
    case .approval: "Approval needed"
    case .failed: "Thread failed"
    case .limited: "Usage limit reached"
    }
  }

  /// The two sound families of the web: a finished turn, and anything that waits for the user.
  public var soundIsCompletion: Bool { self == .completion }
}

public struct ThreadNotificationEvent: Sendable, Equatable, Identifiable {
  public let key: ScopedThreadKey
  public let kind: ThreadNotificationKind
  public let threadTitle: String
  /// The system notification's identifier: a newer one for the same thread replaces the older.
  public var id: String { key.description }
}

/// Which transitions notify. Fed with each environment's live thread shells, it remembers per thread the attention it
/// last announced and the completion time it last saw. A thread seen for the first time (first sync, new thread) only
/// records its state, subagent threads never notify, and an archived thread records without announcing.
public struct ThreadNotificationTracker: Sendable {
  struct Entry: Equatable {
    var attention: String?
    var completion: Double?
  }

  private var entries: [EnvironmentId: [ThreadId: Entry]] = [:]

  public init() {}

  /// `threads` is nil while the environment's shell is not live: what it held is forgotten, so changes that happened
  /// while it was away are not announced when it syncs again.
  public mutating func scan(environmentId: EnvironmentId, threads: [OrchestrationV2ThreadShell]?) -> [ThreadNotificationEvent] {
    guard let threads else {
      entries[environmentId] = nil
      return []
    }
    let previous = entries[environmentId]
    var next: [ThreadId: Entry] = [:]
    next.reserveCapacity(threads.count)
    var events: [ThreadNotificationEvent] = []
    for thread in threads where thread.lineage.relationshipToParent != .subagent {
      let prior = previous?[thread.id]
      let status = Self.status(of: thread)
      let attention: String? =
        switch status {
        case .input, .approval, .failed, .limited: "\(thread.latestRunId?.rawValue ?? ""):\(status)"
        default: nil
        }
      // Commands left running (a dev server) read as ready; subagents and monitors wait.
      let completion = status == .ready ? Self.completedAt(of: thread) ?? prior?.completion : prior?.completion
      next[thread.id] = Entry(attention: attention, completion: completion)
      guard let prior, thread.archivedAt == nil else { continue }
      let kind: ThreadNotificationKind?
      if let attention, attention != prior.attention {
        kind = status == .approval ? .approval : status == .limited ? .limited : status == .failed ? .failed : .input
      } else if let completion, prior.completion.map({ completion > $0 }) ?? true {
        kind = .completion
      } else {
        kind = nil
      }
      if let kind { events.append(ThreadNotificationEvent(key: ScopedThreadKey(environmentId: environmentId, threadId: thread.id), kind: kind, threadTitle: thread.title)) }
    }
    entries[environmentId] = next
    return events
  }

  /// Forgets environments that are gone.
  public mutating func retain(_ environmentIds: Set<EnvironmentId>) {
    entries = entries.filter { environmentIds.contains($0.key) }
  }

  // MARK: Status

  enum Status { case approval, input, working, waiting, failed, limited, ready }

  /// `resolveSidebarThreadStatus` over the shell's runtime.
  static func status(of thread: OrchestrationV2ThreadShell) -> Status {
    if let request = thread.pendingRuntimeRequest {
      if request.kind == .user_input { return .input }
      if request.kind != .auth_refresh { return .approval }
    }
    let parkAtIdle = ShellPresentation.backgroundWorkHoldsCompletion(thread.pendingBackgroundTasks) && thread.status != .failed
    // A pull request watch can hold a thread that never ran.
    if thread.latestRunId == nil, thread.activeProviderThreadId == nil, !parkAtIdle { return .ready }
    let runtime = parkAtIdle ? .idle : (optionalValue(thread.activityRunStatus).map { OrchestrationV2ShellThreadStatus(rawValue: $0.rawValue) } ?? thread.status)
    switch runtime {
    case .preparing, .queued, .starting, .running, .waiting: return .working
    case .idle: return .waiting
    case .failed: return optionalValue(thread.lastErrorClass) == .usage_limit ? .limited : .failed
    default: return .ready
    }
  }

  /// When the latest run completed, if it did (`latestRun.status === "completed"` and a parseable `completedAt`).
  static func completedAt(of thread: OrchestrationV2ThreadShell) -> Double? {
    guard thread.latestRunId != nil, thread.status == .idle || thread.status == .completed else { return nil }
    switch thread.latestRunCompletedAt {
    case .none: return IsoTimestamp.parse(thread.updatedAt)
    case .some(let value): return value.flatMap { IsoTimestamp.parse($0) }
    }
  }
}

/// How one event reaches the user, from the device's notification settings and what the user is looking at.
public struct ThreadNotificationDelivery: Sendable, Equatable {
  public enum Surface: Sendable, Equatable { case none, banner, system }
  public var sound: Bool
  public var surface: Surface

  /// Sound plays whenever the mode asks for it. A banner appears while the app has focus on another thread; a system
  /// notification only while it does not.
  public static func decide(mode: ClientSettingsSchemaNotificationMode, inApp: Bool, appFocused: Bool, isOpenThread: Bool) -> ThreadNotificationDelivery {
    let sound = mode == .sound || mode == .notificationsAndSound
    let system = mode == .notifications || mode == .notificationsAndSound
    if inApp, appFocused, !isOpenThread { return ThreadNotificationDelivery(sound: sound, surface: .banner) }
    return ThreadNotificationDelivery(sound: sound, surface: system && !appFocused ? .system : .none)
  }
}
