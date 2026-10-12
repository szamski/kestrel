import Foundation
import T3Contracts

/// Host power state as the desktop shell reports it (the logic of DesktopTelemetryPublisher.ts, minus the Electron calls): events from the
/// system (lock, sleep, battery, thermal) win over the next poll until the poll agrees with them, so a short lock or sleep is not lost between samples.
public struct DesktopPowerState: Sendable, Equatable {
  public enum Event: Sendable, Equatable {
    case locked(Bool)
    case suspended(Bool)
    case onBattery(Bool)
    case thermal(HostPowerThermalState)
    case lowPowerMode(Bool)
  }

  /// What a poll saw.
  public struct Observation: Sendable, Equatable {
    public enum IdleState: Sendable { case active, idle, locked, unknown }
    public var idleState: IdleState
    public var idleSeconds: Double?
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public init(idleState: IdleState, idleSeconds: Double?, onBattery: Bool, lowPowerMode: Bool) {
      self.idleState = idleState
      self.idleSeconds = idleSeconds
      self.onBattery = onBattery
      self.lowPowerMode = lowPowerMode
    }
  }

  public var idle: BackgroundBooleanState = .unknownValue
  public var idleSeconds: Double?
  public var locked: BackgroundBooleanState = .unknownValue
  public var suspended = false
  public var onBattery: BackgroundBooleanState = .unknownValue
  public var lowPowerMode: BackgroundBooleanState = .unknownValue
  public var thermalState: HostPowerThermalState = .unknownValue
  private var lockedEventPending = false
  private var suspendedEventPending = false
  private var onBatteryEventPending = false

  public init() {}

  static func state(_ value: Bool) -> BackgroundBooleanState { value ? .true : .false }

  public mutating func apply(_ event: Event) {
    switch event {
    case .locked(let value): locked = Self.state(value); lockedEventPending = true
    case .suspended(let value): suspended = value; suspendedEventPending = value
    case .onBattery(let value): onBattery = Self.state(value); onBatteryEventPending = true
    case .thermal(let value): thermalState = value
    case .lowPowerMode(let value): lowPowerMode = Self.state(value)
    }
  }

  /// Folds a poll in. `allowSuspendRecovery` is true when the sample was triggered by the interval timer rather than an event:
  /// the machine is running again, so a missed wake notification cannot leave `suspended` stuck.
  public mutating func observe(_ observation: Observation, allowSuspendRecovery: Bool) {
    let polledLocked = observation.idleState == .unknown ? locked : Self.state(observation.idleState == .locked)
    let polledOnBattery = Self.state(observation.onBattery)
    switch observation.idleState {
    case .active: idle = .false
    case .idle, .locked: idle = .true
    case .unknown: idle = .unknownValue
    }
    idleSeconds = observation.idleSeconds
    if !lockedEventPending { locked = polledLocked }
    lockedEventPending = lockedEventPending && (observation.idleState == .unknown || polledLocked != locked)
    if allowSuspendRecovery && !suspendedEventPending { suspended = false }
    suspendedEventPending = false
    if !onBatteryEventPending { onBattery = polledOnBattery }
    onBatteryEventPending = onBatteryEventPending && polledOnBattery != onBattery
    lowPowerMode = Self.state(observation.lowPowerMode)
  }

  public func snapshot(at date: Date) -> HostPowerSnapshot {
    HostPowerSnapshot(
      source: .electronMain, idle: idle, idleSeconds: idleSeconds, locked: locked, suspended: suspended, onBattery: onBattery,
      lowPowerMode: lowPowerMode, thermalState: thermalState, stale: false, updatedAt: IsoDateTime(date: date))
  }
}

/// How often the app samples (`sampleInterval` in DesktopTelemetryPublisher.ts). The server sets the two background intervals with
/// `setHostPowerIntervals`; with a diagnostics view open the fixed live cadence applies, slowed on battery and when constrained.
public struct DesktopSampleSchedule: Sendable, Equatable {
  public var activeInterval: TimeInterval = 30
  public var idleInterval: TimeInterval = 120

  public init() {}

  public func interval(power: DesktopPowerState, diagnosticsDemand: Bool) -> TimeInterval {
    if !diagnosticsDemand {
      return power.suspended || power.locked == .true || power.idle == .true ? idleInterval : activeInterval
    }
    if power.suspended || power.locked == .true || power.thermalState == .serious || power.thermalState == .critical { return 15 }
    return power.onBattery == .true ? 5 : 1
  }
}
