import SwiftUI
import T3Contracts

/// Number formats of the diagnostics page: binary byte units and the same rounding as the web tables.
enum DiagnosticsFormat {
  static func bytes(_ value: Int) -> String { value == 0 ? "0 B" : Int64(value).formatted(.byteCount(style: .memory)) }
  static func rate(_ value: Double) -> String { bytes(Int(value.rounded())) + "/s" }
  static func percent(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(1))))%" }
  static func count(_ value: Int) -> String { value.formatted() }

  static func duration(ms value: Double) -> String {
    if value < 1_000 { return "\(Int(value.rounded())) ms" }
    return "\((value / 1_000).formatted(.number.precision(.fractionLength(value >= 10_000 ? 1 : 2)))) s"
  }

  static func cpuTime(seconds: Double) -> String {
    func fixed(_ v: Double, _ digits: Int) -> String { v.formatted(.number.precision(.fractionLength(digits))) }
    if seconds < 60 { return fixed(seconds, seconds >= 10 ? 1 : 2) + "s" }
    let minutes = seconds / 60
    if minutes < 60 { return fixed(minutes, minutes >= 10 ? 1 : 2) + "m" }
    return fixed(minutes / 60, 2) + "h"
  }

  static func micros(_ value: Int) -> String {
    if value < 1_000 { return "\(value) µs" }
    if value < 1_000_000 { return "\((Double(value) / 1_000).formatted(.number.precision(.fractionLength(2)))) ms" }
    return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(2)))) s"
  }

  static func interval(ms: Int) -> String {
    if ms < 1_000 { return "\(max(0, ms)) ms" }
    let seconds = Double(ms) / 1_000
    return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) \(seconds == 1 ? "second" : "seconds")"
  }

  static func shortTrace(_ id: String) -> String { id.count <= 32 ? id : "\(id.prefix(18))...\(id.suffix(10))" }

  static func boolState(_ state: BackgroundBooleanState, true yes: String, false no: String) -> String {
    switch state {
    case .true: yes
    case .false: no
    default: "Unknown"
    }
  }

  static func thermal(_ state: HostPowerThermalState) -> String {
    switch state {
    case .unknownValue: "Unknown"
    case .unknown(let raw): raw
    default: state.rawValue.capitalized
    }
  }
}

extension IsoDateTime {
  /// The instant, or the epoch when the server sent something unreadable (it only places a row on the time axis).
  var instant: Date { date ?? .distantPast }
}
