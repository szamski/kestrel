import Foundation
import T3Contracts

/// Time source for everything that waits or timestamps. Logic never calls `Task.sleep` or
/// `Date()` directly, so tests drive backoff, probes and snooze wakes with a manual clock.
public protocol RuntimeClock: Sendable {
  /// Milliseconds since the Unix epoch.
  func nowMilliseconds() -> Int64
  /// Suspends for `duration`; throws `CancellationError` when the task is cancelled.
  func sleep(for duration: Duration) async throws
}

public struct SystemClock: RuntimeClock {
  public init() {}
  public func nowMilliseconds() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
  public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

extension RuntimeClock {
  public func nowISO() -> IsoDateTime { IsoTimestamp.format(milliseconds: Double(nowMilliseconds())) }
}
