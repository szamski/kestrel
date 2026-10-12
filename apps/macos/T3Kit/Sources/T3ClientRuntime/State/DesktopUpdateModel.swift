import Foundation
import T3Contracts

/// `DesktopUpdateChannel` of packages/contracts/src/ipc.ts: which release train the app follows.
public enum DesktopUpdateChannel: String, Sendable, CaseIterable, Identifiable {
  case latest
  case nightly

  public var id: String { rawValue }
  public var title: String { self == .latest ? "Stable" : "Nightly" }

  /// `resolveDefaultDesktopUpdateChannel` (apps/desktop/src/updates/updateChannels.ts): a nightly build follows nightly.
  public static func defaultFor(version: String) -> DesktopUpdateChannel {
    version.range(of: #"^[^-+]+-nightly\.\d{8}\.\d+$"#, options: .regularExpression) != nil ? .nightly : .latest
  }
}

/// `DesktopUpdateState` (DesktopUpdateStateSchema in packages/contracts/src/ipc.ts): what the server mirrors of the app's updater.
/// Nullable fields are sent as explicit nulls, as the schema requires.
public struct DesktopUpdateState: Sendable, Equatable, Encodable {
  public enum Status: String, Sendable { case disabled, idle, checking, upToDate = "up-to-date", available, downloading, downloaded, error }
  public enum ErrorContext: String, Sendable { case check, download, install }

  public var enabled: Bool
  public var status: Status
  public var channel: DesktopUpdateChannel
  public var currentVersion: String
  public var hostArch: String
  public var appArch: String
  public var runningUnderArm64Translation: Bool
  public var availableVersion: String?
  public var downloadedVersion: String?
  public var downloadPercent: Double?
  public var checkedAt: String?
  public var message: String?
  public var errorContext: ErrorContext?
  public var canRetry: Bool

  public init(
    enabled: Bool, status: Status = .idle, channel: DesktopUpdateChannel, currentVersion: String, hostArch: String = "other", appArch: String = "other",
    runningUnderArm64Translation: Bool = false, message: String? = nil
  ) {
    self.enabled = enabled
    self.status = enabled ? status : .disabled
    self.channel = channel
    self.currentVersion = currentVersion
    self.hostArch = hostArch
    self.appArch = appArch
    self.runningUnderArm64Translation = runningUnderArm64Translation
    self.message = message
    canRetry = false
  }

  /// A step of the Sparkle session, already reduced to what the state cares about.
  public enum Event: Sendable, Equatable {
    case checkStarted
    case found(version: String)
    case notFound
    case downloadStarted
    case downloadProgress(Double)
    case downloaded(version: String)
    case failed(String, ErrorContext)
    /// The Sparkle session ended; a check that never reported back (cancelled) is no longer running.
    case sessionEnded
  }

  /// `now` is stamped as `checkedAt` when a check ends.
  public mutating func apply(_ event: Event, now: Date = .now) {
    guard enabled else { return }
    switch event {
    case .checkStarted:
      status = .checking
      message = nil
      errorContext = nil
      canRetry = false
    case .found(let version):
      status = .available
      availableVersion = version
      downloadPercent = nil
      checkedAt = IsoDateTime(date: now).rawValue
      message = nil
      errorContext = nil
    case .notFound:
      status = .upToDate
      availableVersion = nil
      checkedAt = IsoDateTime(date: now).rawValue
      message = nil
      errorContext = nil
      canRetry = false
    case .downloadStarted:
      status = .downloading
      downloadPercent = 0
      message = nil
      errorContext = nil
    case .downloadProgress(let percent):
      status = .downloading
      downloadPercent = min(100, max(0, percent))
    case .downloaded(let version):
      status = .downloaded
      downloadedVersion = version
      downloadPercent = 100
      message = nil
      errorContext = nil
    case .sessionEnded:
      if status == .checking { status = .idle }
    case .failed(let text, let context):
      status = .error
      message = text
      errorContext = context
      canRetry = context != .install
    }
  }

  /// One line for Settings.
  public var summary: String {
    switch status {
    case .disabled: message ?? "Updates are turned off."
    case .idle: "Version \(currentVersion)"
    case .checking: "Checking for updates…"
    case .upToDate: "Kestrel is up to date."
    case .available: "Version \(availableVersion ?? "") is available."
    case .downloading: "Downloading version \(availableVersion ?? "")" + (downloadPercent.map { " (\(Int($0.rounded()))%)" } ?? "…")
    case .downloaded: "Version \(downloadedVersion ?? "") is ready to install."
    case .error: message ?? "The update failed."
    }
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, status, channel, currentVersion, hostArch, appArch, runningUnderArm64Translation, availableVersion, downloadedVersion
    case releaseNotes, omittedReleaseCount, downloadPercent, checkedAt, message, errorContext, canRetry
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(enabled, forKey: .enabled)
    try c.encode(status.rawValue, forKey: .status)
    try c.encode(channel.rawValue, forKey: .channel)
    try c.encode(currentVersion, forKey: .currentVersion)
    try c.encode(hostArch, forKey: .hostArch)
    try c.encode(appArch, forKey: .appArch)
    try c.encode(runningUnderArm64Translation, forKey: .runningUnderArm64Translation)
    try c.encode(availableVersion, forKey: .availableVersion)
    try c.encode(downloadedVersion, forKey: .downloadedVersion)
    // ponytail: Sparkle shows its own release notes; the mirrored list stays empty. Fill it if a remote client should show them.
    try c.encode([String](), forKey: .releaseNotes)
    try c.encode(0, forKey: .omittedReleaseCount)
    try c.encode(downloadPercent, forKey: .downloadPercent)
    try c.encode(checkedAt, forKey: .checkedAt)
    try c.encode(message, forKey: .message)
    try c.encode(errorContext?.rawValue, forKey: .errorContext)
    try c.encode(canRetry, forKey: .canRetry)
  }
}

/// `normalizeRemoteUpdateReason` (remoteUpdateFlow.ts): the wire `reason` is a non-empty trimmed string, so a blank message is dropped
/// rather than failing the encoding of the terminal report.
public func normalizedUpdateReason(_ reason: String?) -> String? {
  let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return trimmed.isEmpty ? nil : trimmed
}

/// The path the desktop app drops just before it stops the server to install an update (DESKTOP_UPDATE_RESTART_MARKER_FILE):
/// `<t3Home>/runtime/desktop-update-restart`. A server that finds it fresh at shutdown keeps its managed tunnel for the next one.
public func desktopUpdateRestartMarker(t3Home: URL) -> URL {
  t3Home.appending(path: "runtime", directoryHint: .isDirectory).appending(path: "desktop-update-restart")
}
