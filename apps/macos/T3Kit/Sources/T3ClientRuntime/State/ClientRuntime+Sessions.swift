import Foundation
import T3Contracts

extension ClientRuntime {
  /// The ready session of an environment as it changes: nil while it connects, backs off or is removed, and a new session after
  /// every reconnect. Pairing the environment again (the local server does so at each launch) replaces its whole runtime;
  /// this follows the replacement, which watching one runtime's supervisor would not.
  public func sessions(for environmentId: EnvironmentId) -> AsyncStream<(any EnvironmentSession)?> {
    let runtimes = registry.runtimes
    return AsyncStream { continuation in
      let follow = Task {
        var current: ObjectIdentifier?
        var inner: Task<Void, Never>?
        defer { inner?.cancel() }
        for await all in runtimes.changes() {
          guard let runtime = all.first(where: { $0.entry.environmentId == environmentId }) else {
            inner?.cancel()
            current = nil
            continuation.yield(nil)
            continue
          }
          guard ObjectIdentifier(runtime) != current else { continue }
          current = ObjectIdentifier(runtime)
          inner?.cancel()
          let sessions = runtime.supervisor.session
          inner = Task { for await session in sessions.changes() { continuation.yield(session) } }
        }
      }
      continuation.onTermination = { _ in follow.cancel() }
    }
  }
}
