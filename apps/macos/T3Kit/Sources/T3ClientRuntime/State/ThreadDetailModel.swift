import Foundation
import Observation
import T3Contracts

/// Observable detail of one open thread. Created by `ClientRuntime.openThread`; call `close()` when
/// the view goes away so the shared stream can stop (it stays warm for five idle minutes).
@MainActor @Observable
public final class ThreadDetailModel {
  public let key: ScopedThreadKey
  /// The synchronised detail state: data, status (`cached` -> `synchronizing` -> `live` | `deleted`), error and page.
  public private(set) var state: EnvironmentThreadState = .empty
  /// Detail with the shell's authoritative metadata merged in; nil until the first data arrives. On a protocol-2
  /// environment this is the projection's conversation messages in the V1 shape (`ThreadPresentation.thread`):
  /// enough for messages to appear and stream; tool activity and checkpoints come from `projection`.
  public private(set) var thread: V1.OrchestrationThread?
  /// Open approvals and user-input questions (from the activity log on protocol 1, the runtime requests on protocol 2).
  public private(set) var pendingRequests = PendingRequests(approvals: [], userInputs: [])
  /// Protocol 2: the server's thread projection (runs, turn items, messages, requests, checkpoints). Nil on protocol 1.
  public var projection: OrchestrationV2ThreadProjection? { state.projection }
  /// Protocol 2: the run in flight and the messages queued behind it (empty on protocol 1).
  public private(set) var queue = ThreadQueueState.empty
  /// Protocol 2: progressive history of the loaded window (cursor, loading, last error).
  public var history: ThreadHistoryMeta { state.history }

  private var shell: V1.OrchestrationThreadShell?
  private var lease: ThreadLease?
  private var tasks: [Task<Void, Never>] = []
  private var activityFingerprint: [String] = []

  init(key: ScopedThreadKey) { self.key = key }

  /// Set by `close()`: a late re-attachment must not resurrect the model.
  private(set) var isClosed = false

  /// Follows `lease`; any earlier one (of a replaced runtime) is dropped.
  func attach(lease: ThreadLease, shells: AsyncStream<V1.OrchestrationThreadShell?>) {
    for task in tasks { task.cancel() }
    tasks = []
    if let previous = self.lease { Task { await previous.release() } }
    self.lease = lease
    let stateChanges = lease.state.changes()
    tasks.append(Task { [weak self] in
      for await next in stateChanges { self?.apply(state: next) }
    })
    tasks.append(Task { [weak self] in
      for await next in shells { self?.apply(shell: next) }
    })
  }

  private func apply(state next: EnvironmentThreadState) {
    state = next
    if let projection = next.projection {
      pendingRequests = ThreadPresentation.pendingRequests(projection)
      queue = ThreadPresentation.queue(projection)
    } else if let data = next.data {
      let fingerprint = [String(data.activities.count), data.activities.last?.id.rawValue ?? ""]
      if fingerprint != activityFingerprint {
        activityFingerprint = fingerprint
        pendingRequests = PendingRequestDeriver.derive(data.activities)
      }
      queue = .empty
    } else {
      activityFingerprint = []
      pendingRequests = PendingRequests(approvals: [], userInputs: [])
      queue = .empty
    }
    refreshThread()
  }

  private func apply(shell next: V1.OrchestrationThreadShell?) {
    shell = next
    refreshThread()
  }

  private func refreshThread() {
    if let projection = state.projection {
      // The shell carries the metadata; before it arrives there is nothing to show the thread under.
      thread = shell.map { ThreadPresentation.thread(projection, shell: $0) }
      return
    }
    guard let data = state.data else {
      thread = nil
      return
    }
    thread = shell.map { data.merged(with: $0) } ?? data
  }

  public var hasOlderTurns: Bool { state.hasOlderTurns }
  public var isLoadingOlder: Bool { state.isLoadingOlder }

  /// Fetches the next older page of turns; no-op without a cursor or while one is loading.
  public func loadOlderTurns() async { await lease?.loadOlderTurns() }

  public func close() async {
    isClosed = true
    for task in tasks { task.cancel() }
    tasks = []
    let lease = self.lease
    self.lease = nil
    await lease?.release()
  }
}
