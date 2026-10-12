import SwiftUI
import T3ClientRuntime
import T3Contracts

/// "Resource monitor": the live footprint of everything T3 runs, from the telemetry stream.
struct MonitorSection: View {
  let controller: DiagnosticsController

  var body: some View {
    let snapshot = controller.telemetry
    let all = snapshot?.groups.allT3
    Section {
      if let error = controller.telemetryError { ErrorLine(message: error) }
      if snapshot == nil, controller.telemetryError == nil {
        HStack(spacing: 8) { ProgressView().controlSize(.small); PanelNote(text: "Waiting for the first resource sample.") }
      }
      StatGrid {
        StatTile(title: "Current CPU", value: all.map { DiagnosticsFormat.percent($0.currentCpuPercent) } ?? "...", detail: all.map { "\(DiagnosticsFormat.cpuTime(seconds: Double($0.cpuTimeMs) / 1_000)) observed CPU time" })
        StatTile(title: "Resident memory", value: all.map { DiagnosticsFormat.bytes($0.currentRssBytes) } ?? "...", detail: all.map { "\(DiagnosticsFormat.bytes($0.peakRssBytes)) combined process peaks" })
        StatTile(title: "Processes", value: all.map { String($0.processCount) } ?? "...", detail: all.map { "\($0.processStarts) starts, \($0.processExits) exits" })
        StatTile(title: "Read throughput", value: all.map { DiagnosticsFormat.rate($0.ioReadBytesPerSecond) } ?? "...", detail: all.map { "\(DiagnosticsFormat.bytes($0.ioReadBytes)) observed" })
        StatTile(
          title: "Write throughput", value: all.map { DiagnosticsFormat.rate($0.ioWriteBytesPerSecond) } ?? "...", detail: all.map { "\(DiagnosticsFormat.bytes($0.ioWriteBytes)) observed" },
          tone: writeTone(all?.ioWriteBytesPerSecond))
        speedLimit(snapshot)
      }
      if let groups = snapshot?.groups {
        HStack(alignment: .top, spacing: 20) {
          AggregateColumn(title: "Backend + agents", aggregate: groups.backend)
          AggregateColumn(title: "Desktop", aggregate: groups.electron)
          AggregateColumn(title: "Monitor overhead", aggregate: groups.monitor)
        }
      }
    } header: {
      PanelHeader(title: "Resource monitor") {
        if let snapshot {
          SourceBadge(label: "Native", status: snapshot.health.native.status)
          Text("Sampling every \(DiagnosticsFormat.interval(ms: snapshot.sampleIntervalMs))").font(.caption).foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func writeTone(_ rate: Double?) -> StatTone {
    guard let rate else { return .normal }
    return rate >= 10 * 1_048_576 ? .danger : rate >= 1_048_576 ? .warning : .normal
  }

  private func speedLimit(_ snapshot: ResourceTelemetrySnapshot?) -> some View {
    let limit = snapshot?.speedLimitPercent
    return StatTile(
      title: "CPU speed limit", value: snapshot == nil ? "..." : limit.map { "\(Int($0.rounded()))%" } ?? "Unknown",
      detail: snapshot.map { "\(DiagnosticsFormat.thermal($0.power.thermalState)) thermal state" }, tone: (limit ?? 100) < 80 ? .warning : .normal)
  }
}

private struct AggregateColumn: View {
  let title: String
  let aggregate: ResourceTelemetryAggregate

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text("\(aggregate.processCount) \(aggregate.processCount == 1 ? "process" : "processes")").font(.caption2).foregroundStyle(.tertiary)
      }
      pair("CPU", DiagnosticsFormat.percent(aggregate.currentCpuPercent))
      pair("Memory", DiagnosticsFormat.bytes(aggregate.currentRssBytes))
      pair("Read", DiagnosticsFormat.rate(aggregate.ioReadBytesPerSecond))
      pair("Write", DiagnosticsFormat.rate(aggregate.ioWriteBytesPerSecond))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func pair(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value).font(.callout.monospacedDigit())
    }
  }
}

struct SourceBadge: View {
  let label: String
  let status: ResourceTelemetrySourceStatus
  var neutralText: String?

  var body: some View {
    let tone = color
    HStack(spacing: 5) {
      Circle().fill(tone).frame(width: 6, height: 6)
      Text("\(label) \(neutralText ?? status.rawValue)".trimmingCharacters(in: .whitespaces)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(tone.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  private var color: Color {
    if neutralText != nil { return .secondary }
    switch status {
    case .healthy: return .green
    case .starting, .degraded: return .orange
    default: return .red
    }
  }
}

/// "Host": whole-machine capacity and the power signals only a desktop host can supply.
struct HostSection: View {
  let controller: DiagnosticsController

  var body: some View {
    Section {
      if let error = controller.host.error { ErrorLine(message: error) }
      if let host = controller.host.value {
        StatGrid {
          StatTile(title: "CPU utilization", value: host.cpuUtilization.map { DiagnosticsFormat.percent($0 * 100) } ?? "Unknown", detail: "\(host.cpuCount) cores")
          StatTile(
            title: "Memory in use", value: DiagnosticsFormat.bytes(max(0, host.totalMemoryBytes - host.availableMemoryBytes)),
            detail: "\(DiagnosticsFormat.bytes(host.availableMemoryBytes)) available of \(DiagnosticsFormat.bytes(host.totalMemoryBytes))")
        }
      } else if controller.host.error == nil {
        PanelNote(text: "Reading host resources.")
      }
      if let power = controller.telemetry?.power {
        if Self.hasSignal(power) {
          LabeledContent("Power source", value: DiagnosticsFormat.boolState(power.onBattery, true: "Battery", false: "External power"))
          LabeledContent("Low power mode", value: DiagnosticsFormat.boolState(power.lowPowerMode, true: "Enabled", false: "Disabled"))
          LabeledContent("Idle", value: DiagnosticsFormat.boolState(power.idle, true: "Idle", false: "Active") + (power.idleSeconds.map { " - \(Int($0.rounded()))s" } ?? ""))
          LabeledContent("Session", value: power.suspended ? "Suspended" : DiagnosticsFormat.boolState(power.locked, true: "Locked", false: "Unlocked"))
          LabeledContent("Thermal") {
            Text(DiagnosticsFormat.thermal(power.thermalState)).foregroundStyle(power.thermalState == .serious || power.thermalState == .critical ? .red : .primary)
          }
        } else {
          VStack(alignment: .leading, spacing: 4) {
            Text("Desktop host signals not connected").font(.callout.weight(.medium))
            PanelNote(text: "Power, idle, lock, and thermal state come from the desktop host. This server's host does not report them; process telemetry is unaffected.")
          }
        }
      }
    } header: {
      PanelHeader(title: "Host") {
        RefreshControls(checkedAt: controller.host.value.map { IsoDateTime(date: Date(timeIntervalSince1970: Double($0.sampledAt) / 1_000)) }, loading: controller.host.loading, label: "Refresh host resources") {
          controller.refreshHost()
        }
      }
    }
  }

  static func hasSignal(_ power: HostPowerSnapshot) -> Bool {
    [power.onBattery, power.lowPowerMode, power.idle, power.locked].contains { $0 != .unknownValue } || power.thermalState != .unknownValue
  }
}

/// "Collection health": whether the native monitor and the desktop host are feeding the server, and what the last scan cost.
struct HealthSection: View {
  let controller: DiagnosticsController

  var body: some View {
    let snapshot = controller.telemetry
    Section {
      if let health = snapshot?.health {
        source("Native process monitor", health.native)
        source("Electron main process", health.desktop, notReported: true)
        LabeledContent("Collection time", value: DiagnosticsFormat.micros(health.collectionDurationMicros))
        LabeledContent("Process scan", value: "\(health.retainedProcessCount)/\(health.scannedProcessCount) retained")
        LabeledContent("Inaccessible") {
          Text(String(health.inaccessibleProcessCount)).foregroundStyle(health.inaccessibleProcessCount > 0 ? .orange : .primary)
        }
        LabeledContent("Sidecar", value: health.sidecarVersion.map { version in version + (health.sidecarPid.map { " - PID \($0)" } ?? "") } ?? "Unavailable")
        LabeledContent("Restarts", value: String(health.restartCount))
      } else {
        PanelNote(text: "Waiting for collector health.")
      }
    } header: {
      PanelHeader(title: "Collection health") {
        if DiagnosticsLogic.showsMonitorRetry(nativeStatus: snapshot?.health.native.status, error: controller.telemetryError), controller.canMaintain {
          Button { controller.retryMonitor() } label: {
            if controller.retrying { ProgressView().controlSize(.small) } else { Text("Retry monitor") }
          }
          .disabled(controller.retrying)
        }
      }
    }
  }

  /// `notReported`: the source belongs to a desktop shell. Without one it is unavailable by design, not failing.
  private func source(_ title: String, _ health: ResourceTelemetrySourceHealth, notReported: Bool = false) -> some View {
    let desktopOnly = health.status == .unavailable && (notReported || (health.lastError?.contains("'web' mode") ?? false))
    return LabeledContent {
      SourceBadge(label: "", status: health.status, neutralText: desktopOnly ? "Desktop only" : nil)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(desktopOnly ? "Reported only by a desktop app host. This server has none." : health.lastError ?? "No reported errors")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// "Instrumented application I/O": logical bytes by operation, reported by T3 itself.
struct AttributionSection: View {
  let controller: DiagnosticsController

  var body: some View {
    let entries = controller.telemetry?.attribution.entries ?? []
    Section {
      PanelNote(text: "Native counters say which process reads or writes. These counters name the T3 operations behind it, so a process spike can be matched to a persistence or logging path.")
      if entries.isEmpty {
        PanelNote(text: "No instrumented application I/O has been recorded yet.")
      } else {
        Table(entries) {
          TableColumn("Component", value: \.component).width(min: 90, ideal: 130)
          TableColumn("Operation", value: \.operation).width(min: 120, ideal: 200)
          TableColumn("Logical read") { Text(DiagnosticsFormat.bytes($0.logicalReadBytes)).monospacedDigit() }
          TableColumn("Logical write") { Text(DiagnosticsFormat.bytes($0.logicalWriteBytes)).monospacedDigit() }
          TableColumn("Count") { Text(DiagnosticsFormat.count($0.count)).monospacedDigit() }
          TableColumn("Time") { Text(DiagnosticsFormat.duration(ms: Double($0.durationMs))).monospacedDigit() }
        }
        .alternatingRowBackgrounds().tableHeight(rows: entries.count, maxRows: 10)
      }
    } header: {
      PanelHeader(title: "Instrumented application I/O") { Text("Logical bytes by operation").font(.caption).foregroundStyle(.tertiary) }
    }
  }
}

extension ResourceAttributionEntry: @retroactive Identifiable {
  public var id: String { "\(component)/\(operation)" }
}
