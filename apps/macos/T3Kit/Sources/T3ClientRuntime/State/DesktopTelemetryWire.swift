import Foundation
import T3Contracts

/// The desktop telemetry protocol of packages/contracts/src/resourceTelemetry.ts, version 1, as newline-delimited JSON:
/// messages the app writes to the server on fd 4 (`DesktopHostTelemetryMessage`) and the control messages the server
/// writes back on fd 5 (`DesktopTelemetryControlMessage`). The receiver is apps/server/src/resourceTelemetry/DesktopTelemetryReceiver.ts.

/// One process of the app (`DesktopElectronProcessMetric`). Kestrel has no helper processes, so the list is the app itself, type `Browser`
/// (Electron's name for the main process; the server files it under `electron-main`).
public struct DesktopProcessMetric: Sendable, Equatable, Encodable {
  public var pid: Int
  public var creationTimeMs: Int
  public var type = "Browser"
  public var name: String?
  public var cpuPercent: Double
  public var cumulativeCpuSeconds: Double?
  public var idleWakeupsPerSecond: Double
  public var workingSetBytes: Int
  public var peakWorkingSetBytes: Int

  public init(
    pid: Int, creationTimeMs: Int, name: String? = nil, cpuPercent: Double, cumulativeCpuSeconds: Double? = nil, idleWakeupsPerSecond: Double,
    workingSetBytes: Int, peakWorkingSetBytes: Int
  ) {
    self.pid = pid
    self.creationTimeMs = creationTimeMs
    self.name = name
    self.cpuPercent = cpuPercent
    self.cumulativeCpuSeconds = cumulativeCpuSeconds
    self.idleWakeupsPerSecond = idleWakeupsPerSecond
    self.workingSetBytes = workingSetBytes
    self.peakWorkingSetBytes = peakWorkingSetBytes
  }
}

/// `DesktopHostTelemetrySnapshot`. `electronProcesses` is empty unless a diagnostics view is open (`setDiagnosticsDemand`).
public struct DesktopTelemetrySnapshot: Sendable, Equatable, Encodable {
  public var sequence: Int
  public var sampledAtUnixMs: Int
  public var electronPid: Int
  public var power: HostPowerSnapshot
  public var speedLimitPercent: Double?
  public var electronProcesses: [DesktopProcessMetric]

  public init(sequence: Int, sampledAtUnixMs: Int, electronPid: Int, power: HostPowerSnapshot, speedLimitPercent: Double?, electronProcesses: [DesktopProcessMetric]) {
    self.sequence = sequence
    self.sampledAtUnixMs = sampledAtUnixMs
    self.electronPid = electronPid
    self.power = power
    self.speedLimitPercent = speedLimitPercent
    self.electronProcesses = electronProcesses
  }

  private enum CodingKeys: String, CodingKey { case version, type, sequence, sampledAtUnixMs, electronPid, power, speedLimitPercent, electronProcesses }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(1, forKey: .version)
    try c.encode("desktopTelemetry", forKey: .type)
    try c.encode(sequence, forKey: .sequence)
    try c.encode(sampledAtUnixMs, forKey: .sampledAtUnixMs)
    try c.encode(electronPid, forKey: .electronPid)
    try c.encode(power, forKey: .power)
    try c.encode(speedLimitPercent, forKey: .speedLimitPercent)  // OptionFromNullOr: the key is required, null is none
    try c.encode(electronProcesses, forKey: .electronProcesses)
  }
}

/// `DesktopUpdateStatusReport`: the app's updater state, with `requestId` while a server-triggered run owns the flow and `outcome` once it ends.
public struct DesktopUpdateReport: Sendable, Equatable, Encodable {
  public enum Outcome: String, Sendable { case readyToInstall = "ready-to-install", upToDate = "up-to-date", failed }

  public var requestId: String?
  public var outcome: Outcome?
  public var reason: String?
  public var state: DesktopUpdateState

  public init(requestId: String? = nil, outcome: Outcome? = nil, reason: String? = nil, state: DesktopUpdateState) {
    self.requestId = requestId
    self.outcome = outcome
    self.reason = normalizedUpdateReason(reason)
    self.state = state
  }

  private enum CodingKeys: String, CodingKey { case version, type, requestId, outcome, reason, state }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(1, forKey: .version)
    try c.encode("desktopUpdateStatus", forKey: .type)
    try c.encodeIfPresent(requestId, forKey: .requestId)
    try c.encodeIfPresent(outcome?.rawValue, forKey: .outcome)
    try c.encodeIfPresent(reason, forKey: .reason)
    try c.encode(state, forKey: .state)
  }
}

/// Messages from the app to the server, one JSON line each.
public enum DesktopTelemetryMessage: Sendable, Equatable {
  case hello(pid: Int)
  case snapshot(DesktopTelemetrySnapshot)
  case update(DesktopUpdateReport)

  public func line() throws -> Data {
    let encoder = JSONEncoder()
    var data: Data
    switch self {
    case .hello(let pid): data = try JSONSerialization.data(withJSONObject: ["version": 1, "type": "desktopTelemetryHello", "electronPid": pid] as [String: Any], options: [.sortedKeys])
    case .snapshot(let snapshot): data = try encoder.encode(snapshot)
    case .update(let report): data = try encoder.encode(report)
    }
    data.append(0x0A)
    return data
  }
}

/// A message from the server on the control channel.
public enum DesktopTelemetryControl: Sendable, Equatable {
  case setDiagnosticsDemand(Bool)
  case setHostPowerIntervals(activeMs: Int, idleMs: Int)
  case requestDesktopUpdate(requestId: String)
  case commitDesktopUpdate(requestId: String)
  case cancelDesktopUpdate(requestId: String)

  /// nil for anything that is not a valid version 1 message (the desktop logs and ignores those).
  public static func parse(_ line: String) -> DesktopTelemetryControl? {
    guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] as? Int == 1,
      let type = object["type"] as? String
    else { return nil }
    func requestId() -> String? {
      guard let id = (object["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
      return id
    }
    switch type {
    case "setDiagnosticsDemand": return (object["enabled"] as? Bool).map { DesktopTelemetryControl.setDiagnosticsDemand($0) }
    case "setHostPowerIntervals":
      guard let active = object["activeIntervalMs"] as? Int, let idle = object["idleIntervalMs"] as? Int, active > 0, idle > 0 else { return nil }
      return .setHostPowerIntervals(activeMs: active, idleMs: idle)
    case "requestDesktopUpdate": return requestId().map { .requestDesktopUpdate(requestId: $0) }
    case "commitDesktopUpdate": return requestId().map { .commitDesktopUpdate(requestId: $0) }
    case "cancelDesktopUpdate": return requestId().map { .cancelDesktopUpdate(requestId: $0) }
    default: return nil
    }
  }
}

/// Splits a byte stream into lines; a partial line waits for its newline. A line over `limit` bytes is dropped (the server never sends one).
public struct LineBuffer: Sendable {
  private var pending = Data()
  public let limit: Int
  public init(limit: Int = 64 * 1024) { self.limit = limit }

  public mutating func append(_ data: Data) -> [String] {
    pending.append(data)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: 0x0A) {
      let line = pending[pending.startIndex..<newline]
      pending.removeSubrange(pending.startIndex...newline)
      if line.count <= limit, let text = String(data: line, encoding: .utf8), !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
    }
    if pending.count > limit { pending.removeAll() }
    return lines
  }
}
