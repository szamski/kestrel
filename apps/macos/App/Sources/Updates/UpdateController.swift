import AppKit
import Observation
import Sparkle
import T3ClientRuntime

/// App updates through Sparkle 2: "Check for Updates…", the update channel and automatic checks of Settings › General, and the server-driven
/// update of a desktop-hosted server (apps/desktop/src/updates/DesktopRemoteUpdates.ts, docs/internals/server-updates.md).
///
/// The build ships no feed by default (`SUFeedURL` is empty, see App/Support/Updates.xcconfig): then there is no updater at all and
/// `state` says why. With a feed, Sparkle's own UI serves the person at the Mac, and `UpdateDriver` runs the same session without UI
/// when the server asks over the telemetry control channel.
@MainActor @Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
  static let shared = UpdateController()

  private(set) var state: DesktopUpdateState
  private(set) var automaticChecks: Bool
  /// The channel is the user's choice, kept per Mac. Nightly sees the appcast items tagged `<sparkle:channel>nightly</sparkle:channel>` as well as stable ones.
  var channel: DesktopUpdateChannel {
    didSet {
      guard channel != oldValue else { return }
      UserDefaults.standard.set(channel.rawValue, forKey: Self.channelKey)
      state.channel = channel
      publish()
    }
  }
  /// True once a feed is configured and Sparkle runs.
  var isAvailable: Bool { updater != nil }

  @ObservationIgnored private var updater: SPUUpdater?
  @ObservationIgnored private var driver: UpdateDriver?
  @ObservationIgnored fileprivate var remote: RemoteRun?
  @ObservationIgnored private var started = false
  private static let channelKey = "update.channel"

  /// A server-triggered run: its request id, what can cancel it, and the install reply held until the server commits.
  struct RemoteRun {
    var requestId: String
    var cancel: (() -> Void)?
    var installReply: ((SPUUserUpdateChoice) -> Void)?
    var preparedVersion: String?
    var committing = false
  }

  private override init() {
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let stored = UserDefaults.standard.string(forKey: Self.channelKey).flatMap(DesktopUpdateChannel.init(rawValue:))
    let initialChannel = stored ?? .defaultFor(version: version)
    channel = initialChannel
    let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    #if arch(arm64)
    let arch = "arm64"
    #elseif arch(x86_64)
    let arch = "x64"
    #else
    let arch = "other"
    #endif
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
    state = DesktopUpdateState(
      enabled: !feed.isEmpty, channel: initialChannel, currentVersion: version, hostArch: translated == 1 ? "arm64" : arch, appArch: arch,
      runningUnderArm64Translation: translated == 1, message: feed.isEmpty ? "This build has no update feed." : nil)
    automaticChecks = bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false
    super.init()
  }

  /// Starts Sparkle when a feed is configured, and publishes the updater state to the server. Call once at launch.
  func start() {
    guard !started else { return }
    started = true
    DesktopTelemetry.shared.onUpdateControl = { [weak self] message in Task { @MainActor in self?.handle(message) } }
    publish()
    guard state.enabled else { return }
    let driver = UpdateDriver(controller: self)
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    do {
      try updater.start()
      self.driver = driver
      self.updater = updater
      automaticChecks = updater.automaticallyChecksForUpdates
    } catch {
      state = DesktopUpdateState(
        enabled: false, channel: channel, currentVersion: state.currentVersion, hostArch: state.hostArch, appArch: state.appArch,
        runningUnderArm64Translation: state.runningUnderArm64Translation, message: "Updates are not available: \(error.localizedDescription)")
      publish()
    }
  }

  // MARK: User actions

  func checkForUpdates() { updater?.checkForUpdates() }

  func setAutomaticChecks(_ enabled: Bool) {
    automaticChecks = enabled
    updater?.automaticallyChecksForUpdates = enabled
  }

  // MARK: Updater state

  /// Records a step of the Sparkle session and tells the server.
  fileprivate func apply(_ event: DesktopUpdateState.Event) {
    state.apply(event)
    publish()
  }

  fileprivate func publish(outcome: DesktopUpdateReport.Outcome? = nil, reason: String? = nil, requestId: String? = nil) {
    DesktopTelemetry.shared.publish(DesktopUpdateReport(requestId: requestId ?? remote?.requestId, outcome: outcome, reason: reason, state: state))
  }

  /// The phase a Sparkle error belongs to, from where the session was.
  fileprivate var failureContext: DesktopUpdateState.ErrorContext {
    switch state.status {
    case .downloading: .download
    case .downloaded: .install
    default: .check
    }
  }

  // MARK: Server-triggered updates

  private func handle(_ message: DesktopTelemetryControl) {
    switch message {
    case .requestDesktopUpdate(let id): request(id)
    case .commitDesktopUpdate(let id): commit(id)
    case .cancelDesktopUpdate(let id): cancel(id)
    case .setDiagnosticsDemand, .setHostPowerIntervals: break
    }
  }

  private func fail(_ id: String, _ reason: String) {
    publish(outcome: .failed, reason: reason, requestId: id)
  }

  /// Check, download and stop at "ready to install": the server confirms with `commitDesktopUpdate` once its client has the token, so the
  /// install (which ends this app and the server it hosts) cannot lose the RPC result. A second request while one is prepared is refused.
  private func request(_ id: String) {
    guard let updater else { return fail(id, state.message ?? "Automatic updates are disabled on this machine.") }
    if remote != nil { return fail(id, "A prepared desktop update is already in progress.") }
    if updater.sessionInProgress { return fail(id, "Kestrel on this Mac is already working on an update. Finish or dismiss it there, then try again.") }
    remote = RemoteRun(requestId: id)
    updater.checkForUpdates()
  }

  private func cancel(_ id: String) {
    guard let run = remote, run.requestId == id, !run.committing else { return }
    remote = nil  // first: Sparkle ends the session synchronously, and a cancelled run needs no report
    if let reply = run.installReply { reply(.dismiss) } else { run.cancel?() }
  }

  private func commit(_ id: String) {
    guard var run = remote, run.requestId == id, let reply = run.installReply else {
      return fail(id, "This desktop update is no longer prepared.")
    }
    if run.committing { return }
    run.committing = true
    remote = run
    // The updater quits the app next; `willInstallUpdate` leaves the restart marker for the server before it stops.
    reply(.install)
  }

  /// `UpdateDriver` reports the end of a server-triggered run. The report carries the request id; the run's id is cleared after it.
  fileprivate func finishRemote(_ outcome: DesktopUpdateReport.Outcome, reason: String? = nil) {
    guard let run = remote else { return }
    publish(outcome: outcome, reason: reason, requestId: run.requestId)
    if outcome != .readyToInstall { remote = nil }
  }

  /// A prepared update waits at most five minutes for its commit (PREPARED_UPDATE_TTL in DesktopRemoteUpdates.ts).
  fileprivate func prepared(version: String, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard var run = remote else { return }
    run.installReply = reply
    run.preparedVersion = version
    remote = run
    let id = run.requestId
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(300))
      guard let self, let held = self.remote, held.requestId == id, !held.committing else { return }
      self.cancel(id)
    }
    finishRemote(.readyToInstall)
  }

  // MARK: SPUUpdaterDelegate

  func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel == .nightly ? ["nightly"] : [] }

  /// Installing stops this app and the server it hosts. The marker tells the server the next one starts at once, so it keeps its tunnel.
  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    let marker = desktopUpdateRestartMarker(t3Home: LocalServerLaunch.homeDirectory(dataDirectory: AppModel.dataDirectory))
    try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: marker.path, contents: Data())
  }

  /// A failed install brings no new server, so a later quit must release the tunnel.
  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    try? FileManager.default.removeItem(at: desktopUpdateRestartMarker(t3Home: LocalServerLaunch.homeDirectory(dataDirectory: AppModel.dataDirectory)))
  }
}

/// Sparkle's user driver: Sparkle's standard UI for the person at the Mac, none for a server-triggered run. Either way the session also
/// feeds `UpdateController.state`.
@MainActor
final class UpdateDriver: NSObject, SPUUserDriver {
  private let standard: SPUStandardUserDriver
  private unowned let controller: UpdateController
  private var expected: UInt64 = 0
  private var received: UInt64 = 0
  private var foundVersion = ""

  init(controller: UpdateController) {
    self.controller = controller
    standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
  }

  private var remote: Bool { controller.remote != nil }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
    standard.show(request, reply: reply)
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    controller.apply(.checkStarted)
    if remote { controller.remote?.cancel = cancellation } else { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
  }

  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    foundVersion = appcastItem.displayVersionString
    controller.apply(.found(version: foundVersion))
    if remote { reply(.install) } else { standard.showUpdateFound(with: appcastItem, state: state, reply: reply) }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { if !remote { standard.showUpdateReleaseNotes(with: downloadData) } }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { if !remote { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) } }

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    controller.apply(.notFound)
    if remote {
      acknowledgement()
      controller.finishRemote(.upToDate)
    } else {
      standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    controller.apply(.failed(error.localizedDescription, controller.failureContext))
    if remote {
      acknowledgement()
      controller.finishRemote(.failed, reason: error.localizedDescription)
    } else {
      standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expected = 0
    received = 0
    controller.apply(.downloadStarted)
    if remote { controller.remote?.cancel = cancellation } else { standard.showDownloadInitiated(cancellation: cancellation) }
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    expected = expectedContentLength
    if !remote { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    received += length
    if expected > 0 { controller.apply(.downloadProgress(Double(received) / Double(expected) * 100)) }
    if !remote { standard.showDownloadDidReceiveData(ofLength: length) }
  }

  func showDownloadDidStartExtractingUpdate() { if !remote { standard.showDownloadDidStartExtractingUpdate() } }

  func showExtractionReceivedProgress(_ progress: Double) { if !remote { standard.showExtractionReceivedProgress(progress) } }

  func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
    controller.apply(.downloaded(version: foundVersion))
    if remote { controller.prepared(version: foundVersion, reply: reply) } else { standard.showReady(toInstallAndRelaunch: reply) }
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
  }

  func showUpdateInFocus() { if !remote { standard.showUpdateInFocus() } }

  func dismissUpdateInstallation() {
    controller.apply(.sessionEnded)
    // A server-triggered run still open here was cancelled or died before it reported; the server must not wait for its timeout.
    if remote, controller.remote?.installReply == nil { controller.finishRemote(.failed, reason: "The update was cancelled.") }
    standard.dismissUpdateInstallation()
  }
}
