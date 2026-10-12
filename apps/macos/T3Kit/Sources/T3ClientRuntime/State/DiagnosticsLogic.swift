import Foundation
import T3Contracts

/// One process of Settings › Diagnostics, from either the live telemetry stream or the server's descendant list.
/// I/O fields are zero when the source does not measure them (`hasIO` false).
public struct ProcessTreeRow: Sendable, Identifiable, Hashable {
  /// `pid:startTimeMs`: a PID alone is reused by the OS, so every signal and collapse state is keyed by both.
  public var id: String
  public var pid: Int
  public var startTimeMs: Int
  public var ppid: Int
  public var name: String
  public var command: String
  public var kind: String
  public var cpuPercent: Double
  public var memoryBytes: Int
  public var hasIO: Bool
  public var readBytesPerSecond: Double
  public var writeBytesPerSecond: Double
  public var canSignal: Bool
  /// Filled by `ProcessTree.flatten`.
  public var depth = 0
  public var hasChildren = false

  public init(
    pid: Int, startTimeMs: Int, ppid: Int, name: String, command: String, kind: String, cpuPercent: Double, memoryBytes: Int,
    hasIO: Bool = false, readBytesPerSecond: Double = 0, writeBytesPerSecond: Double = 0, canSignal: Bool
  ) {
    id = "\(pid):\(startTimeMs)"
    self.pid = pid
    self.startTimeMs = startTimeMs
    self.ppid = ppid
    self.name = name
    self.command = command
    self.kind = kind
    self.cpuPercent = cpuPercent
    self.memoryBytes = memoryBytes
    self.hasIO = hasIO
    self.readBytesPerSecond = readBytesPerSecond
    self.writeBytesPerSecond = writeBytesPerSecond
    self.canSignal = canSignal
  }
}

public enum ProcessTree {
  /// The tree in display order: parents before children, siblings in `order`, rows under a collapsed parent left out.
  /// A row whose parent is not in the list is a root. Parents are matched by PID, which is unique within one snapshot.
  public static func flatten(_ rows: [ProcessTreeRow], collapsed: Set<String>, order: [KeyPathComparator<ProcessTreeRow>]) -> [ProcessTreeRow] {
    let pids = Set(rows.map(\.pid))
    var children: [Int: [ProcessTreeRow]] = [:]
    var roots: [ProcessTreeRow] = []
    for row in rows {
      if row.ppid != row.pid, pids.contains(row.ppid) { children[row.ppid, default: []].append(row) } else { roots.append(row) }
    }
    var result: [ProcessTreeRow] = []
    var seen = Set<Int>()
    func visit(_ row: ProcessTreeRow, depth: Int) {
      guard seen.insert(row.pid).inserted else { return }
      var row = row
      let kids = (children[row.pid] ?? []).sorted(using: order)
      row.depth = depth
      row.hasChildren = !kids.isEmpty
      result.append(row)
      if !collapsed.contains(row.id) { for kid in kids { visit(kid, depth: depth + 1) } }
    }
    for root in roots.sorted(using: order) { visit(root, depth: 0) }
    return result
  }

  /// `canSignalProcess` of the web table: only processes the server started can be signalled.
  static func isSignalable(_ category: ResourceTelemetryProcessCategory) -> Bool {
    category == .serverChild || category == .providerRoot || category == .terminalRoot
  }

  public static func rows(_ processes: [ResourceTelemetryProcess]) -> [ProcessTreeRow] {
    processes.map { process in
      ProcessTreeRow(
        pid: process.identity.pid, startTimeMs: process.identity.startTimeMs, ppid: process.ppid, name: displayName(name: process.name, command: process.command),
        command: process.command.isEmpty ? process.name : process.command, kind: categoryLabel(process.category), cpuPercent: process.cpuPercent,
        memoryBytes: process.residentBytes, hasIO: process.ioSemantics != .unavailable, readBytesPerSecond: process.ioReadBytesPerSecond,
        writeBytesPerSecond: process.ioWriteBytesPerSecond, canSignal: isSignalable(process.category))
    }
  }

  /// The server's descendant list. Every row is a child of the server, so every row can be signalled.
  public static func rows(_ processes: [ServerProcessDiagnosticsEntry]) -> [ProcessTreeRow] {
    processes.map { process in
      ProcessTreeRow(
        pid: process.pid, startTimeMs: process.startTimeMs, ppid: process.ppid, name: displayName(name: "", command: process.command), command: process.command,
        kind: process.depth > 0 ? "Subprocess" : "Process", cpuPercent: process.cpuPercent, memoryBytes: process.rssBytes, canSignal: true)
    }
  }

  /// The telemetry name, else the executable of the command line.
  public static func displayName(name: String, command: String) -> String {
    if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
    let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
    let token = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    return token.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? token
  }

  public static func categoryLabel(_ category: ResourceTelemetryProcessCategory) -> String {
    switch category {
    case .server: "Server"
    case .serverChild: "Backend child"
    case .providerRoot: "Provider"
    case .terminalRoot: "Terminal"
    case .electronMain: "Electron main"
    case .electronRenderer: "Renderer"
    case .electronGpu: "GPU"
    case .electronUtility: "Electron utility"
    case .resourceMonitor: "Monitor"
    case .unknownT3: "T3 process"
    case .unknown(let raw): raw
    }
  }
}

public enum DiagnosticsLogic {
  /// `shouldShowResourceMonitorRetry`: offer a restart when the collector is down or never reported.
  public static func showsMonitorRetry(nativeStatus: ResourceTelemetrySourceStatus?, error: String?) -> Bool {
    switch nativeStatus {
    case nil: error != nil
    case .degraded?, .unavailable?, .stopped?: true
    default: false
    }
  }

  /// A signal result the server refused because the process is no longer a child of the server.
  public static func isStaleSignalMessage(_ message: String?) -> Bool { message?.contains("not a live descendant") ?? false }

  /// One line on what the server records and exports (`formatDiagnosticsDescription`).
  public static func observabilitySummary(_ observability: ServerObservability) -> String {
    let mode = observability.localTracingEnabled ? "Local trace file" : "Terminal logs only"
    let traces = observability.otlpTracesEnabled ? observability.otlpTracesUrl : nil
    let metrics = observability.otlpMetricsEnabled ? observability.otlpMetricsUrl : nil
    switch (traces, metrics) {
    case (let traces?, let metrics?):
      if traces.hasSuffix("/traces"), metrics.hasSuffix("/metrics"), traces.dropLast(7) == metrics.dropLast(8) {
        return "\(mode). Exporting OTEL to \(traces.dropLast(7))/{traces,metrics}."
      }
      return "\(mode). Exporting OTEL traces to \(traces) and metrics to \(metrics)."
    case (let traces?, nil): return "\(mode). Exporting OTEL traces to \(traces)."
    case (nil, let metrics?): return "\(mode). Exporting OTEL metrics to \(metrics)."
    case (nil, nil): return "\(mode)."
    }
  }
}
