import Foundation
import Observation
import T3ClientRuntime
import T3Contracts

extension ClientSettingsStore {
  /// Clock style for message and diff times (Settings › General › Time format).
  var timeStyle: Date.FormatStyle {
    switch client.timestampFormat {
    case .v12Hour: .dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()
    case .v24Hour: .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
    default: .dateTime.hour().minute()
    }
  }

  /// "Oct 9, 2026 at 3:41 PM" in the chosen clock style.
  func timestamp(_ date: Date) -> String {
    switch client.timestampFormat {
    case .v12Hour: date.formatted(.dateTime.month(.abbreviated).day().year().hour(.defaultDigits(amPM: .abbreviated)).minute())
    case .v24Hour: date.formatted(.dateTime.month(.abbreviated).day().year().hour(.twoDigits(amPM: .omitted)).minute())
    default: date.formatted(date: .abbreviated, time: .shortened)
    }
  }
}

/// Pushes device preferences into runtime state that is not read through the store directly.
@MainActor
enum SettingsBindings {
  private static var started = false

  /// Sidebar project grouping follows `sidebarProjectGroupingMode` and its per-project overrides.
  static func start(runtime: ClientRuntime, store: ClientSettingsStore = .shared) {
    guard !started else { return }
    started = true
    Task { @MainActor in
      for await client in Observations({ store.client }) {
        runtime.projectGrouping = ProjectGroupingSettings(
          mode: ProjectGroupingMode(rawValue: client.sidebarProjectGroupingMode.rawValue) ?? .repository,
          overrides: client.sidebarProjectGroupingOverrides.compactMapValues { ProjectGroupingMode(rawValue: $0.rawValue) })
      }
    }
  }
}
