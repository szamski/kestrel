import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import T3ClientRuntime
import T3Contracts

/// The app's side of the desktop telemetry channel to the server it supervises: what DesktopTelemetryPublisher.ts does for Electron.
/// fd 4 carries newline-delimited JSON to the server (hello, host power, the app's own process metrics, the updater state) and fd 5
/// carries the server's control messages back (`setDiagnosticsDemand`, `setHostPowerIntervals`, remote update requests). The server uses
/// these for background-activity policy (idle, locked, on battery, thermal) and Settings › Diagnostics. See docs/internals/resource-telemetry.md.
///
/// Everything here runs on one serial queue. Sampling continues without a server, so a server that attaches later (a restart) gets the latest
/// snapshot at once.
final class DesktopTelemetry: @unchecked Sendable {
  static let shared = DesktopTelemetry()

  /// Update requests from the server, for `UpdateController`; called on the telemetry queue.
  var onUpdateControl: (@Sendable (DesktopTelemetryControl) -> Void)?

  private let queue = DispatchQueue(label: "dev.szamowski.kestrel.desktop-telemetry")
  private var started = false
  private var power = DesktopPowerState()
  private var schedule = DesktopSampleSchedule()
  private var speedLimit: Double?
  private var demand = false
  private var sequence = 0
  private var latestSnapshot: DesktopTelemetrySnapshot?
  private var latestReport: DesktopUpdateReport?
  private var pending: DispatchWorkItem?
  private var link: Link?
  private var nextToken = 0
  private var process = ProcessSampler()
  private var observers: [NSObjectProtocol] = []
  private var batterySource: CFRunLoopSource?

  /// The read handler's partial line; only that handler (on `queue`) touches it.
  private final class LineBox: @unchecked Sendable { var buffer = LineBuffer() }

  private final class Link {
    let token: Int
    let writeFd: Int32
    let reader: DispatchSourceRead
    init(token: Int, writeFd: Int32, reader: DispatchSourceRead) {
      self.token = token
      self.writeFd = writeFd
      self.reader = reader
    }
  }

  // MARK: Lifecycle

  /// Starts sampling and listening for system power events. Call once from the main thread.
  @MainActor func start() {
    queue.async { [self] in
      guard !started else { return }
      started = true
      power.apply(.thermal(Self.thermal(ProcessInfo.processInfo.thermalState)))
      sampleOnce(allowSuspendRecovery: false)
    }
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    let center = NotificationCenter.default
    observers = [
      workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [self] _ in event(.suspended(true)) },
      workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [self] _ in event(.suspended(false)) },
      distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [self] _ in event(.locked(true)) },
      distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [self] _ in event(.locked(false)) },
      center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [self] _ in
        event(.thermal(Self.thermal(ProcessInfo.processInfo.thermalState)))
      },
      center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [self] _ in
        event(.lowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled))
      },
    ]
    // Power source changes (plug in, unplug) arrive on the main run loop.
    let context = Unmanaged.passUnretained(self).toOpaque()
    if let source = IOPSNotificationCreateRunLoopSource({ context in
      guard let context else { return }
      Unmanaged<DesktopTelemetry>.fromOpaque(context).takeUnretainedValue().event(.onBattery(DesktopTelemetry.onBattery()))
    }, context)?.takeRetainedValue() {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
      batterySource = source
    }
  }

  /// Takes ownership of this app's ends of the pipes of a freshly spawned server: `telemetryWrite` (fd 4 of the server) and `controlRead`
  /// (fd 5 of the server). Returns a token for `detach`.
  func attach(telemetryWrite: Int32, controlRead: Int32) -> Int {
    queue.sync {
      nextToken += 1
      let token = nextToken
      if let existing = link { close(existing) }
      let reader = DispatchSource.makeReadSource(fileDescriptor: controlRead, queue: queue)
      let lines = LineBox()
      reader.setEventHandler { [weak self, weak reader] in
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(controlRead, &buffer, buffer.count)
        if count > 0 {
          lines.buffer.append(Data(buffer[0..<count])).compactMap(DesktopTelemetryControl.parse).forEach { self?.handle($0) }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
          reader?.cancel()
        }
      }
      reader.setCancelHandler { Darwin.close(controlRead) }
      _ = fcntl(controlRead, F_SETFL, fcntl(controlRead, F_GETFL) | O_NONBLOCK)
      reader.resume()
      let attached = Link(token: token, writeFd: telemetryWrite, reader: reader)
      link = attached
      send(.hello(pid: Int(getpid())))
      if let latestSnapshot { send(.snapshot(latestSnapshot)) }
      if let latestReport { send(.update(latestReport)) }
      return token
    }
  }

  /// The server of `token` is gone. A newer link is left alone.
  func detach(token: Int) {
    queue.async { [self] in
      guard let link, link.token == token else { return }
      close(link)
      self.link = nil
      if demand {
        demand = false
        triggerSample()
      }
    }
  }

  /// The updater state or the outcome of a server-triggered run. Replayed to a server that attaches later.
  func publish(_ report: DesktopUpdateReport) {
    queue.async { [self] in
      latestReport = report
      send(.update(report))
    }
  }

  // MARK: Messages

  private func handle(_ message: DesktopTelemetryControl) {
    switch message {
    case .setDiagnosticsDemand(let enabled):
      guard enabled != demand else { return }
      demand = enabled
      triggerSample()
    case .setHostPowerIntervals(let active, let idle):
      schedule.activeInterval = Double(active) / 1000
      schedule.idleInterval = Double(idle) / 1000
      triggerSample()
    case .requestDesktopUpdate, .commitDesktopUpdate, .cancelDesktopUpdate:
      onUpdateControl?(message)
    }
  }

  private func send(_ message: DesktopTelemetryMessage) {
    guard let link, let data = try? message.line() else { return }
    // ponytail: blocking write; a server that stops reading (a full 64 KB pipe) stalls telemetry until it reads or exits. Make it non-blocking if that is ever seen.
    var offset = 0
    while offset < data.count {
      let written = data[offset...].withUnsafeBytes { write(link.writeFd, $0.baseAddress, $0.count) }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        close(link)  // EPIPE: the server is gone; its exit detaches for good
        self.link = nil
        return
      }
    }
  }

  private func close(_ link: Link) {
    link.reader.cancel()
    Darwin.close(link.writeFd)
  }

  // MARK: Sampling

  private func event(_ event: DesktopPowerState.Event) {
    queue.async { [self] in
      power.apply(event)
      triggerSample()
    }
  }

  private func triggerSample() { scheduleSample(after: 0, recovering: false) }

  private func scheduleSample(after delay: TimeInterval, recovering: Bool) {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.sampleOnce(allowSuspendRecovery: recovering) }
    pending = item
    queue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  private func sampleOnce(allowSuspendRecovery: Bool) {
    let now = Date()
    let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    let idleState: DesktopPowerState.Observation.IdleState = Self.screenLocked() ? .locked : (idleSeconds >= 60 ? .idle : .active)
    power.observe(
      .init(idleState: idleState, idleSeconds: idleSeconds.isFinite ? idleSeconds : nil, onBattery: Self.onBattery(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled),
      allowSuspendRecovery: allowSuspendRecovery)
    speedLimit = Self.cpuSpeedLimit()
    // The sampler also advances its CPU deltas without demand, so the first sample of a diagnostics session is a real rate.
    let metrics = process.sample(now: now)
    sequence += 1
    let snapshot = DesktopTelemetrySnapshot(
      sequence: sequence, sampledAtUnixMs: Int(now.timeIntervalSince1970 * 1000), electronPid: Int(getpid()), power: power.snapshot(at: now), speedLimitPercent: speedLimit,
      electronProcesses: demand ? (metrics.map { [$0] } ?? []) : [])
    latestSnapshot = snapshot
    send(.snapshot(snapshot))
    scheduleSample(after: schedule.interval(power: power, diagnosticsDemand: demand), recovering: true)
  }

  // MARK: System readings

  private static func thermal(_ state: ProcessInfo.ThermalState) -> HostPowerThermalState {
    switch state {
    case .nominal: .nominal
    case .fair: .fair
    case .serious: .serious
    case .critical: .critical
    @unknown default: .unknownValue
    }
  }

  private static func screenLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  private static func onBattery() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == kIOPSBatteryPowerValue
  }

  /// `CPU_Speed_Limit` of `pmset -g therm`, 100 when nothing throttles. nil when the machine has no such record.
  private static func cpuSpeedLimit() -> Double? {
    var status: Unmanaged<CFDictionary>?
    guard IOPMCopyCPUPowerStatus(&status) == kIOReturnSuccess, let dictionary = status?.takeRetainedValue() as? [String: Any] else { return nil }
    return (dictionary["CPU_Speed_Limit"] as? NSNumber)?.doubleValue
  }
}

/// CPU and memory of this process from `proc_pid_rusage`, with the rate fields derived between two samples (what Electron's
/// `app.getAppMetrics()` reports for the main process).
private struct ProcessSampler {
  private let pid = getpid()
  private var last: (at: Date, cpuNs: Double, wakeups: UInt64)?
  private var peakResident = 0
  private let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()
  private let creationTimeMs: Int = {
    var info = proc_bsdinfo()
    guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return 0 }
    return Int(info.pbi_start_tvsec) * 1000 + Int(info.pbi_start_tvusec) / 1000
  }()

  mutating func sample(now: Date) -> DesktopProcessMetric? {
    var usage = rusage_info_current()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
    }
    guard status == 0 else { return nil }
    let cpuNs = Double(usage.ri_user_time &+ usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
    let wakeups = usage.ri_pkg_idle_wkups
    var cpuPercent = 0.0, wakeupRate = 0.0
    if let last {
      let seconds = now.timeIntervalSince(last.at)
      if seconds > 0 {
        cpuPercent = max(0, (cpuNs - last.cpuNs) / (seconds * 1e9) * 100)
        wakeupRate = Double(wakeups &- last.wakeups) / seconds
      }
    }
    last = (now, cpuNs, wakeups)
    let resident = Int(usage.ri_resident_size)
    peakResident = max(peakResident, resident)
    return DesktopProcessMetric(
      pid: Int(pid), creationTimeMs: creationTimeMs, name: "Kestrel", cpuPercent: cpuPercent, cumulativeCpuSeconds: cpuNs / 1e9, idleWakeupsPerSecond: wakeupRate,
      workingSetBytes: resident, peakWorkingSetBytes: peakResident)
  }
}
