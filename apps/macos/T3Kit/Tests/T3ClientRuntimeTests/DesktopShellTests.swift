import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// The desktop-shell protocols (telemetry on fds 4/5, update reports, the `t3 app` socket) against the contract shapes in
/// packages/contracts/src/{resourceTelemetry,desktopAppActivation}.ts.
@Suite struct DesktopShellTests {
  static func object(_ data: Data) throws -> [String: Any] {
    #expect(data.last == 0x0A)  // one JSON object per line
    return try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
  }

  static func state(_ status: DesktopUpdateState.Status = .idle) -> DesktopUpdateState {
    DesktopUpdateState(enabled: true, status: status, channel: .latest, currentVersion: "0.1.0", hostArch: "arm64", appArch: "arm64")
  }

  // MARK: Telemetry

  @Test func snapshotCarriesEveryRequiredKeyWithExplicitNulls() throws {
    var power = DesktopPowerState()
    power.observe(.init(idleState: .active, idleSeconds: 3.5, onBattery: true, lowPowerMode: false), allowSuspendRecovery: false)
    power.apply(.thermal(.fair))
    let process = DesktopProcessMetric(
      pid: 42, creationTimeMs: 1_700_000_000_123, name: "Kestrel", cpuPercent: 12.5, cumulativeCpuSeconds: 3, idleWakeupsPerSecond: 4, workingSetBytes: 1000, peakWorkingSetBytes: 2000)
    let snapshot = DesktopTelemetrySnapshot(
      sequence: 7, sampledAtUnixMs: 1_700_000_000_000, electronPid: 42, power: power.snapshot(at: Date(timeIntervalSince1970: 1_700_000_000.25)), speedLimitPercent: nil,
      electronProcesses: [process])
    let json = try Self.object(DesktopTelemetryMessage.snapshot(snapshot).line())
    #expect(json["version"] as? Int == 1 && json["type"] as? String == "desktopTelemetry")
    #expect(json["sequence"] as? Int == 7 && json["electronPid"] as? Int == 42)
    #expect(json["speedLimitPercent"] is NSNull)  // OptionFromNullOr: required key, null for none
    let encodedPower = try #require(json["power"] as? [String: Any])
    #expect(Set(encodedPower.keys) == ["source", "idle", "idleSeconds", "locked", "suspended", "onBattery", "lowPowerMode", "thermalState", "stale", "updatedAt"])
    #expect(encodedPower["source"] as? String == "electron-main" && encodedPower["onBattery"] as? String == "true" && encodedPower["thermalState"] as? String == "fair")
    #expect(encodedPower["updatedAt"] as? String == "2023-11-14T22:13:20.250Z")
    let processes = try #require(json["electronProcesses"] as? [[String: Any]])
    #expect(processes.first?["type"] as? String == "Browser" && processes.first?["pid"] as? Int == 42)
    #expect(Set(try #require(processes.first).keys) == ["pid", "creationTimeMs", "type", "name", "cpuPercent", "cumulativeCpuSeconds", "idleWakeupsPerSecond", "workingSetBytes", "peakWorkingSetBytes"])
  }

  @Test func helloAndUpdateReportsMatchTheirSchemas() throws {
    let hello = try Self.object(DesktopTelemetryMessage.hello(pid: 9).line())
    #expect(hello as NSDictionary == ["version": 1, "type": "desktopTelemetryHello", "electronPid": 9] as NSDictionary)

    var state = Self.state(.downloaded)
    state.downloadedVersion = "0.2.0"
    let report = try Self.object(DesktopTelemetryMessage.update(DesktopUpdateReport(requestId: "r1", outcome: .readyToInstall, reason: "  ", state: state)).line())
    #expect(report["type"] as? String == "desktopUpdateStatus" && report["requestId"] as? String == "r1" && report["outcome"] as? String == "ready-to-install")
    #expect(report["reason"] == nil)  // a blank reason would fail TrimmedNonEmptyString and drop the terminal report
    let encoded = try #require(report["state"] as? [String: Any])
    #expect(Set(encoded.keys) == ["enabled", "status", "channel", "currentVersion", "hostArch", "appArch", "runningUnderArm64Translation", "availableVersion", "downloadedVersion", "releaseNotes", "omittedReleaseCount", "downloadPercent", "checkedAt", "message", "errorContext", "canRetry"])
    #expect(encoded["availableVersion"] is NSNull && encoded["downloadedVersion"] as? String == "0.2.0" && encoded["status"] as? String == "downloaded")

    // The attach snapshot carries neither a request id nor an outcome.
    let attach = try Self.object(DesktopTelemetryMessage.update(DesktopUpdateReport(state: Self.state())).line())
    #expect(attach["requestId"] == nil && attach["outcome"] == nil)
  }

  @Test func controlMessagesParseAndInvalidOnesAreIgnored() {
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"setDiagnosticsDemand","enabled":true}"#) == .setDiagnosticsDemand(true))
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"setHostPowerIntervals","activeIntervalMs":30000,"idleIntervalMs":120000}"#) == .setHostPowerIntervals(activeMs: 30_000, idleMs: 120_000))
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"requestDesktopUpdate","requestId":"abc"}"#) == .requestDesktopUpdate(requestId: "abc"))
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"commitDesktopUpdate","requestId":"abc"}"#) == .commitDesktopUpdate(requestId: "abc"))
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"cancelDesktopUpdate","requestId":"abc"}"#) == .cancelDesktopUpdate(requestId: "abc"))
    #expect(DesktopTelemetryControl.parse(#"{"version":2,"type":"setDiagnosticsDemand","enabled":true}"#) == nil)
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"setHostPowerIntervals","activeIntervalMs":0,"idleIntervalMs":1}"#) == nil)
    #expect(DesktopTelemetryControl.parse(#"{"version":1,"type":"requestDesktopUpdate","requestId":" "}"#) == nil)
    #expect(DesktopTelemetryControl.parse("not json") == nil)
  }

  @Test func lineBufferWaitsForTheNewlineAndDropsOversizedLines() {
    var buffer = LineBuffer(limit: 16)
    #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
    #expect(buffer.append(Data(":2}\n\n".utf8)) == ["{\"b\":2}"])
    #expect(buffer.append(Data((String(repeating: "x", count: 40) + "\nok\n").utf8)) == ["ok"])
  }

  @Test func aSystemEventWinsOverThePollUntilThePollAgrees() {
    var power = DesktopPowerState()
    let unlocked = DesktopPowerState.Observation(idleState: .active, idleSeconds: 0, onBattery: false, lowPowerMode: false)
    power.observe(unlocked, allowSuspendRecovery: false)
    #expect(power.locked == .false && power.idle == .false)
    power.apply(.locked(true))
    power.observe(unlocked, allowSuspendRecovery: false)  // the poll still says unlocked: the lock event stays
    #expect(power.locked == .true)
    power.observe(.init(idleState: .locked, idleSeconds: 90, onBattery: false, lowPowerMode: false), allowSuspendRecovery: false)  // now it agrees
    power.observe(unlocked, allowSuspendRecovery: false)
    #expect(power.locked == .false)

    power.apply(.suspended(true))
    power.observe(unlocked, allowSuspendRecovery: true)  // the sleep event survives the sample it arrived in
    #expect(power.suspended)
    power.observe(unlocked, allowSuspendRecovery: true)  // a timer sample after that means the machine runs again
    #expect(!power.suspended)
  }

  @Test func sampleIntervalFollowsDemandAndPower() {
    var schedule = DesktopSampleSchedule()
    var power = DesktopPowerState()
    power.observe(.init(idleState: .active, idleSeconds: 0, onBattery: false, lowPowerMode: false), allowSuspendRecovery: false)
    #expect(schedule.interval(power: power, diagnosticsDemand: false) == 30)
    schedule.activeInterval = 10
    #expect(schedule.interval(power: power, diagnosticsDemand: false) == 10)
    #expect(schedule.interval(power: power, diagnosticsDemand: true) == 1)
    power.apply(.onBattery(true))
    #expect(schedule.interval(power: power, diagnosticsDemand: true) == 5)
    power.apply(.thermal(.serious))
    #expect(schedule.interval(power: power, diagnosticsDemand: true) == 15)
    power.observe(.init(idleState: .idle, idleSeconds: 90, onBattery: false, lowPowerMode: false), allowSuspendRecovery: false)
    #expect(schedule.interval(power: power, diagnosticsDemand: false) == 120)
  }

  // MARK: Updates

  @Test func updateStateFollowsASparkleSession() {
    var state = Self.state()
    state.apply(.checkStarted)
    #expect(state.status == .checking)
    state.apply(.found(version: "0.2.0"))
    #expect(state.status == .available && state.availableVersion == "0.2.0" && state.checkedAt != nil)
    state.apply(.downloadStarted)
    state.apply(.downloadProgress(140))
    #expect(state.summary == "Downloading version 0.2.0 (100%)")
    #expect(state.status == .downloading && state.downloadPercent == 100)
    state.apply(.downloaded(version: "0.2.0"))
    #expect(state.status == .downloaded && state.downloadedVersion == "0.2.0")
    state.apply(.failed("disk full", .install))
    #expect(state.status == .error && state.errorContext == .install && !state.canRetry && state.downloadedVersion == "0.2.0")

    state.apply(.checkStarted)
    state.apply(.sessionEnded)  // cancelled before it answered
    #expect(state.status == .idle)

    var disabled = DesktopUpdateState(enabled: false, channel: .latest, currentVersion: "0.1.0", message: "No feed")
    disabled.apply(.checkStarted)
    #expect(disabled.status == .disabled && disabled.message == "No feed")
  }

  @Test func channelDefaultsFollowTheVersion() {
    #expect(DesktopUpdateChannel.defaultFor(version: "0.1.0") == .latest)
    #expect(DesktopUpdateChannel.defaultFor(version: "0.1.0-nightly.20261012.3") == .nightly)
    #expect(DesktopUpdateChannel.defaultFor(version: "0.1.0-preview.20261012.3") == .latest)
  }

  @Test func restartMarkerSitsInTheRuntimeDirectoryOfTheHome() {
    #expect(desktopUpdateRestartMarker(t3Home: URL(filePath: "/h/.t3")).path == "/h/.t3/runtime/desktop-update-restart")
  }

  // MARK: Activation

  @Test func addressMatchesTheNodeResolverForTheSameStateDirectory() {
    // Golden value computed with resolveDesktopAppControlAddress (packages/shared/src/desktopAppControl.ts).
    let address = DesktopAppActivation.controlAddress(
      stateDir: "/Users/x/Library/Application Support/T3 Code Dev/server-home/userdata", tempDir: "/var/folders/ab/cd/T/", userId: 501)
    #expect(address.directory == "/var/folders/ab/cd/T/t3code-501")
    #expect(address.address == "/var/folders/ab/cd/T/t3code-501/8b2a948f7e48786036cadec3.sock")
  }

  @Test func requestsParseLikeTheDesktopSchema() {
    let good = #"{"version":1,"requestId":"r-1","type":"open-workspace","workspaceRoot":"/tmp/p","platform":"darwin"}"#
    #expect(DesktopAppActivation.parse(line: Data(good.utf8)) == .request(.init(requestId: "r-1", workspaceRoot: "/tmp/p", platform: "darwin")))
    // Invalid but readable: the answer keeps the client's request id, so the CLI accepts it as the response to its request.
    let wrongType = #"{"version":1,"requestId":"r-2","type":"close","workspaceRoot":"/tmp/p","platform":"darwin"}"#
    #expect(DesktopAppActivation.parse(line: Data(wrongType.utf8)) == .invalid(requestId: "r-2", message: "The desktop app request is invalid."))
    let noRoot = #"{"version":1,"requestId":"r-3","type":"open-workspace","workspaceRoot":"  ","platform":"darwin"}"#
    #expect(DesktopAppActivation.parse(line: Data(noRoot.utf8)) == .invalid(requestId: "r-3", message: "The desktop app request is invalid."))
    #expect(DesktopAppActivation.parse(line: Data(#"{"version":1,"requestId":"r","type":"open-workspace","workspaceRoot":"/p","platform":"amiga"}"#.utf8)) != .request(.init(requestId: "r", workspaceRoot: "/p", platform: "amiga")))
    #expect(DesktopAppActivation.parse(line: Data("nope".utf8)) == .invalid(requestId: "invalid-request", message: "The desktop app request is not valid JSON."))
  }

  @Test func responsesCarryTheContractFields() throws {
    let ok = try Self.object(DesktopAppActivation.success(requestId: "r", projectId: "p", threadId: "t"))
    #expect(ok as NSDictionary == ["version": 1, "requestId": "r", "ok": true, "projectId": "p", "threadId": "t"] as NSDictionary)
    let failed = try Self.object(DesktopAppActivation.failure(requestId: "r", .platformMismatch, "no"))
    #expect(failed as NSDictionary == ["version": 1, "requestId": "r", "ok": false, "code": "platform-mismatch", "message": "no"] as NSDictionary)
  }
}
