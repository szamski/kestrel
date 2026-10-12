import Foundation

/// How far the app-managed server reaches, like Electron's DesktopServerExposure: this Mac only (the default), every
/// network interface, and an optional Tailscale Serve mapping the server sets up itself at startup. Persisted on this
/// Mac; a change restarts the server because the bind address and Serve flags are fixed at launch.
struct LocalServerExposure: Equatable, Sendable {
  var networkAccessible = false
  var tailscaleServe = false
  var tailscalePort = 443

  /// What the server binds to: `0.0.0.0` makes it answer on the LAN and the tailnet, so pairing is the only gate.
  var bindHost: String { networkAccessible ? "0.0.0.0" : "127.0.0.1" }

  private static let networkKey = "localServer.networkAccessible"
  private static let tailscaleKey = "localServer.tailscaleServe"
  private static let tailscalePortKey = "localServer.tailscaleServePort"

  static func load(_ defaults: UserDefaults = .standard) -> LocalServerExposure {
    let port = defaults.integer(forKey: tailscalePortKey)
    return LocalServerExposure(
      networkAccessible: defaults.bool(forKey: networkKey), tailscaleServe: defaults.bool(forKey: tailscaleKey),
      tailscalePort: (1...65535).contains(port) ? port : 443)
  }

  func save(_ defaults: UserDefaults = .standard) {
    defaults.set(networkAccessible, forKey: Self.networkKey)
    defaults.set(tailscaleServe, forKey: Self.tailscaleKey)
    defaults.set(tailscalePort, forKey: Self.tailscalePortKey)
  }
}

/// The `tailscale` CLI, asked only when the user opens Tailscale HTTPS setup: on App Store builds each spawn of it
/// raises macOS's "Other apps" prompt, so nothing polls it.
enum TailscaleCLI {
  enum Reading: Equatable, Sendable {
    case notInstalled
    /// Installed but no answer (stopped, signed out, or no MagicDNS name yet).
    case unavailable
    case ready(magicDNSName: String)
  }

  /// The standalone and App Store app both ship the CLI as the app's own binary.
  static let appDirectory = "/Applications/Tailscale.app/Contents/MacOS"

  static func read() async -> Reading {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: readNow()) }
    }
  }

  /// `https://name` (default port) or `https://name:port`.
  static func httpsURL(magicDNSName: String, port: Int) -> URL? { URL(string: port == 443 ? "https://\(magicDNSName)" : "https://\(magicDNSName):\(port)") }

  /// `Self.DNSName` of `tailscale status --json`, without the trailing dot.
  static func parseMagicDNSName(_ json: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let me = root["Self"] as? [String: Any],
      let name = me["DNSName"] as? String
    else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func readNow() -> Reading {
    let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", appDirectory]
    guard let executable = directories.map({ "\($0)/tailscale" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .notInstalled }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["status", "--json"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return .unavailable }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    guard process.terminationStatus == 0, let name = parseMagicDNSName(data) else { return .unavailable }
    return .ready(magicDNSName: name)
  }
}
