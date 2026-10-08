import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

/// Platform signals for the supervisors: network reachability and "the user came back".
public enum SystemSignals {
  /// `NWPathMonitor` as `online` / `offline` changes (the first value is the current state).
  public static func networkChanges() -> AsyncStream<NetworkStatus> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let monitor = NWPathMonitor()
      monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied ? .online : .offline) }
      continuation.onTermination = { _ in monitor.cancel() }
      monitor.start(queue: DispatchQueue(label: "codes.t3.network-monitor"))
    }
  }

  /// App became active and the system woke from sleep. Both probe the established session rather
  /// than replacing it: a dead socket is caught by the probe or the RPC ping, a healthy one is kept.
  public static func wakeups() -> AsyncStream<ConnectionWakeup> {
    #if canImport(AppKit)
    AsyncStream { continuation in
      nonisolated(unsafe) let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
        continuation.yield(.applicationActive)
      }
      nonisolated(unsafe) let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
        continuation.yield(.applicationActive)
      }
      continuation.onTermination = { _ in
        NotificationCenter.default.removeObserver(active)
        NSWorkspace.shared.notificationCenter.removeObserver(wake)
      }
    }
    #else
    AsyncStream { $0.finish() }
    #endif
  }
}
