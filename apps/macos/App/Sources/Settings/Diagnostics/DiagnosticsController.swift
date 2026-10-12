import AppKit
import Observation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// One read of a diagnostics RPC: the last value, the error of the last attempt, and whether a request is out.
struct Panel<Value: Sendable>: Sendable {
  var value: Value?
  var error: String?
  var loading = false
}

/// A history period and the bucket width the server groups it into.
struct HistoryWindow: Hashable, Identifiable, Sendable {
  let label: String
  let windowMs: Int
  let bucketMs: Int
  var id: Int { windowMs }

  /// Resource timeline (`HISTORY_WINDOWS` of ResourceTelemetryDiagnostics).
  static let telemetry = [
    HistoryWindow(label: "5m", windowMs: 5 * 60_000, bucketMs: 15_000), HistoryWindow(label: "15m", windowMs: 15 * 60_000, bucketMs: 30_000),
    HistoryWindow(label: "30m", windowMs: 30 * 60_000, bucketMs: 60_000), HistoryWindow(label: "1h", windowMs: 60 * 60_000, bucketMs: 120_000),
  ]
  /// Process CPU history (`RESOURCE_HISTORY_WINDOWS` of DiagnosticsSettings).
  static let processes = [
    HistoryWindow(label: "5m", windowMs: 5 * 60_000, bucketMs: 30_000), HistoryWindow(label: "15m", windowMs: 15 * 60_000, bucketMs: 60_000),
    HistoryWindow(label: "30m", windowMs: 30 * 60_000, bucketMs: 120_000), HistoryWindow(label: "1h", windowMs: 60 * 60_000, bucketMs: 300_000),
  ]
}

/// A signal waiting for the user's confirmation.
struct PendingSignal: Identifiable {
  let row: ProcessTreeRow
  let signal: ServerProcessSignal
  /// Which table asked: signalling rechecks the process against that table's data.
  let source: Source
  enum Source { case telemetry, diagnostics }
  var id: String { "\(row.id):\(signal.rawValue)" }
  var name: String { signal == .SIGKILL ? "SIGKILL" : "SIGINT" }
}

/// State of Settings › Diagnostics for one environment. Reads follow the environment's ready session: the live telemetry
/// stream runs only while the page is on screen (the server samples only while someone listens), and each other panel is
/// read on open and on its refresh button. The timeline is re-read at most once per bucket, driven by the stream, so a chart
/// never redraws faster than its data changes.
@MainActor @Observable
final class DiagnosticsController {
  let model: SettingsModel
  let environmentId: EnvironmentId

  // Live telemetry
  private(set) var telemetry: ResourceTelemetrySnapshot?
  private(set) var telemetryError: String?
  private(set) var retrying = false
  /// Real `speedLimitPercent` samples seen while the page was open; the server keeps no thermal or power history.
  private(set) var speedLimit: [SpeedLimitSample] = []

  // Panels
  private(set) var history = Panel<ResourceTelemetryHistory>()
  private(set) var processes = Panel<ServerProcessDiagnosticsResult>()
  private(set) var processHistory = Panel<ServerProcessResourceHistoryResult>()
  private(set) var trace = Panel<ServerTraceDiagnosticsResult>()
  private(set) var host = Panel<HostResourcesSnapshot>()

  var historyWindow = HistoryWindow.telemetry[1] { didSet { if historyWindow != oldValue { history.value = nil; refreshHistory() } } }
  var processWindow = HistoryWindow.processes[1] { didSet { if processWindow != oldValue { processHistory.value = nil; refreshProcessHistory() } } }

  // Access and actions
  private(set) var grants: AuthSessionState?
  private(set) var accessError: String?
  var pendingSignal: PendingSignal?
  private(set) var signaling: Set<String> = []
  private(set) var openingLogs = false

  @ObservationIgnored private var session: (any EnvironmentSession)?
  @ObservationIgnored private var lastHistoryRead = Date.distantPast
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

  struct SpeedLimitSample: Identifiable, Sendable {
    let id: Int
    let date: Date
    let percent: Double
  }

  init(model: SettingsModel, environmentId: EnvironmentId) {
    self.model = model
    self.environmentId = environmentId
  }

  // MARK: Reading state

  var config: ServerConfig? { model.runtime.serverConfigs[environmentId]?.config }
  var settings: ServerSettings { config?.settings ?? ServerSettings() }
  var environmentLabel: String { model.runtime.environments.first { $0.environmentId == environmentId }?.label ?? "this environment" }
  var isLocal: Bool {
    ["localhost", "127.0.0.1", "::1", "[::1]"].contains(model.runtime.connectionEntry(environmentId)?.httpBaseURL.host(percentEncoded: false) ?? "")
  }
  /// The server checks every call; these only decide what the page offers. Unknown grants (a relay route) offer everything.
  var canMaintain: Bool { grants.map { AuthAccess.grants(.environmentMaintain, in: $0) } ?? true }
  private var canRead: Bool { grants.map { AuthAccess.grants(.diagnosticsRead, in: $0) } ?? true }
  var logsDirectory: String? { config?.observability.logsDirectoryPath }
  var canOpenLogs: Bool { isLocal && !(logsDirectory ?? "").isEmpty && !openingLogs }

  // MARK: Following the session

  func run() async {
    var current: Task<Void, Never>?
    defer { current?.cancel() }
    for await ready in model.runtime.sessions(for: environmentId) {
      current?.cancel()
      session = ready
      guard let ready else { continue }  // keep what is shown while the connection comes back
      current = Task { await follow(ready) }
    }
  }

  private func follow(_ ready: any EnvironmentSession) async {
    await loadGrants()
    guard canRead else {
      accessError = "This session cannot read diagnostics on \(environmentLabel)."
      return
    }
    accessError = nil
    refreshAll()
    await stream(ready)
  }

  /// `GET /api/auth/session` with this environment's own bearer; without one (relay) the server alone decides.
  private func loadGrants() async {
    guard let local = await model.runtime.directAuthorization(for: environmentId) else { return grants = nil }
    grants = try? await EnvironmentHTTPClient(baseURL: local.httpBaseURL).get(Http.authSession.path, auth: local.authorization)
  }

  private func stream(_ ready: any EnvironmentSession) async {
    do {
      for try await snapshot in ready.subscribe(Rpc.subscribeResourceTelemetry, EmptyObject()) {
        telemetry = snapshot
        telemetryError = nil
        record(speedLimit: snapshot)
        if Date().timeIntervalSince(lastHistoryRead) >= Double(max(historyWindow.bucketMs, 15_000)) / 1_000 { refreshHistory() }
      }
    } catch is CancellationError {
    } catch {
      telemetryError = Self.message(error)
    }
  }

  private func record(speedLimit snapshot: ResourceTelemetrySnapshot) {
    guard let percent = snapshot.speedLimitPercent else { return }
    speedLimit.append(SpeedLimitSample(id: (speedLimit.last?.id ?? 0) + 1, date: snapshot.readAt.date ?? Date(), percent: percent))
    if speedLimit.count > 240 { speedLimit.removeFirst(speedLimit.count - 240) }
  }

  // MARK: Panels

  func refreshAll() {
    refreshHost()
    refreshProcesses()
    refreshHistory()
    refreshProcessHistory()
    refreshTrace()
  }

  /// Runs one read and files its outcome in `panel`; an answer for a replaced request (another window) is dropped.
  private func read<Value: Sendable>(
    _ key: String, _ panel: ReferenceWritableKeyPath<DiagnosticsController, Panel<Value>>, stillWanted: @escaping @MainActor () -> Bool = { true },
    _ fetch: @escaping @Sendable (any EnvironmentSession) async throws -> Value
  ) {
    guard let session else { return }
    tasks[key]?.cancel()
    self[keyPath: panel].loading = true
    tasks[key] = Task { @MainActor in
      defer { if !Task.isCancelled { self[keyPath: panel].loading = false } }
      do {
        let value = try await fetch(session)
        guard !Task.isCancelled, stillWanted() else { return }
        self[keyPath: panel].value = value
        self[keyPath: panel].error = nil
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        self[keyPath: panel].error = Self.message(error)
      }
    }
  }

  func refreshHost() { read("host", \.host) { try await $0.call(Rpc.serverGetHostResources, EmptyObject()) } }
  func refreshProcesses() { read("processes", \.processes) { try await $0.call(Rpc.serverGetProcessDiagnostics, EmptyObject()) } }
  func refreshTrace() { read("trace", \.trace) { try await $0.call(Rpc.serverGetTraceDiagnostics, EmptyObject()) } }

  func refreshHistory() {
    lastHistoryRead = Date()
    let window = historyWindow
    read("history", \.history, stillWanted: { [weak self] in self?.historyWindow == window }) {
      try await $0.call(Rpc.serverGetResourceTelemetryHistory, ResourceTelemetryHistoryInput(windowMs: window.windowMs, bucketMs: window.bucketMs))
    }
  }

  func refreshProcessHistory() {
    let window = processWindow
    read("processHistory", \.processHistory, stillWanted: { [weak self] in self?.processWindow == window }) {
      try await $0.call(Rpc.serverGetProcessResourceHistory, ServerProcessResourceHistoryInput(windowMs: window.windowMs, bucketMs: window.bucketMs))
    }
  }

  /// Asks the server to start the native monitor again; its first snapshot replaces the stale one.
  func retryMonitor() {
    guard let session, !retrying else { return }
    retrying = true
    Task { @MainActor in
      defer { retrying = false }
      do {
        telemetry = try await session.call(Rpc.serverRetryResourceTelemetry, EmptyObject()).snapshot
        telemetryError = nil
      } catch {
        model.report("Could not restart the resource monitor. \(Self.message(error))")
      }
    }
  }

  // MARK: Signals

  /// Asks for confirmation; the signal is sent from `confirm`.
  func request(_ signal: ServerProcessSignal, for row: ProcessTreeRow, from source: PendingSignal.Source) {
    guard canMaintain, !signaling.contains(row.id) else { return }
    pendingSignal = PendingSignal(row: row, signal: signal, source: source)
  }

  /// Sends the confirmed signal with the identity (PID and start time) the user saw. The row must still be the same
  /// process, and the server rechecks it against a fresh sample.
  func confirm(_ pending: PendingSignal) {
    pendingSignal = nil
    guard let session, canMaintain, signaling.insert(pending.row.id).inserted else { return }
    let current: Bool
    switch pending.source {
    case .telemetry: current = telemetry?.processes.contains { $0.identity.pid == pending.row.pid && $0.identity.startTimeMs == pending.row.startTimeMs } ?? false
    case .diagnostics: current = processes.value?.processes.contains { $0.pid == pending.row.pid && $0.startTimeMs == pending.row.startTimeMs } ?? false
    }
    guard current else {
      signaling.remove(pending.row.id)
      return model.report("\(pending.row.name) has already exited.")
    }
    Task { @MainActor in
      defer { signaling.remove(pending.row.id) }
      do {
        let result = try await session.call(
          Rpc.serverSignalProcess, ServerSignalProcessInput(pid: pending.row.pid, startTimeMs: pending.row.startTimeMs, signal: pending.signal))
        if !result.signaled {
          if DiagnosticsLogic.isStaleSignalMessage(result.message) {
            model.report("Process already exited. It is not a child of the T3 server any more.")
          } else {
            model.report("Could not send \(pending.name). \(result.message ?? "")")
          }
        }
        refreshProcesses()
      } catch {
        model.report("Could not send \(pending.name). \(Self.message(error))")
      }
    }
  }

  // MARK: Logs and settings

  /// The logs live on the server's machine, so only this Mac's own server can show them in Finder.
  func openLogs() {
    guard canOpenLogs, let path = logsDirectory else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return model.report("The logs folder does not exist yet: \(path)")
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
  }

  func save(_ patch: ServerSettingsPatch, failure: String) {
    let (runtime, id, model) = (model.runtime, environmentId, model)
    Task { @MainActor in
      do { try await runtime.updateServerSettings(environmentId: id, patch: patch) } catch { model.report("\(failure) \(Self.message(error))") }
    }
  }

  static func message(_ error: any Error) -> String { ProvidersController.message(error) }
}
