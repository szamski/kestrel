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
  /// Detail with the shell's authoritative metadata merged in; nil until the first data arrives.
  public private(set) var thread: OrchestrationThread?
  /// Open approvals and user-input questions derived from the activity log.
  public private(set) var pendingRequests = PendingRequests(approvals: [], userInputs: [])

  private var shell: OrchestrationThreadShell?
  private var lease: ThreadLease?
  private var tasks: [Task<Void, Never>] = []
  private var activityFingerprint: [String] = []

  init(key: ScopedThreadKey) { self.key = key }

  func attach(lease: ThreadLease, shells: AsyncStream<OrchestrationThreadShell?>) {
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
    if let data = next.data {
      let fingerprint = [String(data.activities.count), data.activities.last?.id.rawValue ?? ""]
      if fingerprint != activityFingerprint {
        activityFingerprint = fingerprint
        pendingRequests = PendingRequestDeriver.derive(data.activities)
      }
    } else {
      activityFingerprint = []
      pendingRequests = PendingRequests(approvals: [], userInputs: [])
    }
    refreshThread()
  }

  private func apply(shell next: OrchestrationThreadShell?) {
    shell = next
    refreshThread()
  }

  private func refreshThread() {
    guard let data = state.data else {
      thread = nil
      return
    }
    thread = shell.map { data.merged(with: $0) } ?? data
  }

  public var hasOlderTurns: Bool { state.hasOlderTurns }
  public var isLoadingOlder: Bool { state.page?.loadingOlder == true }

  /// Fetches the next older page of turns; no-op without a cursor or while one is loading.
  public func loadOlderTurns() async { await lease?.loadOlderTurns() }

  public func close() async {
    for task in tasks { task.cancel() }
    tasks = []
    let lease = self.lease
    self.lease = nil
    await lease?.release()
  }
}
