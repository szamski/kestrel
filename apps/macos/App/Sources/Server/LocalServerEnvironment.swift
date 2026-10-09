import Foundation

/// The environment the server is started with, built like Electron's DesktopShellEnvironment +
/// DesktopBackendConfiguration: a GUI app inherits a minimal environment, so the login shell is asked for
/// the variables the server and the provider CLIs it spawns rely on (PATH above all).
enum LocalServerEnvironment {
  /// Same list as apps/desktop/src/shell/DesktopShellEnvironment.ts (LOGIN_SHELL_ENV_NAMES).
  private static let shellNames = [
    "PATH", "DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK", "HOMEBREW_PREFIX", "HOMEBREW_CELLAR",
    "HOMEBREW_REPOSITORY", "XDG_CONFIG_HOME", "XDG_CURRENT_DESKTOP", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "XDG_SESSION_DESKTOP",
    "XDG_SESSION_TYPE", "WAYLAND_DISPLAY",
  ]
  /// Stripped like DESKTOP_BACKEND_ENV_NAMES: they outrank the bootstrap envelope in the server's config. T3CODE_HOME,
  /// T3CODE_BOOTSTRAP_FD and VITE_DEV_SERVER_URL are stripped as well so the home and the transport are only ever what we pass.
  private static let stripped: Set<String> = [
    "T3CODE_PORT", "T3CODE_MODE", "T3CODE_NO_BROWSER", "T3CODE_HOST", "T3CODE_DESKTOP_WS_URL", "T3CODE_DESKTOP_LAN_ACCESS",
    "T3CODE_DESKTOP_LAN_HOST", "T3CODE_DESKTOP_HTTPS_ENDPOINTS", "T3CODE_TAILSCALE_SERVE", "T3CODE_TAILSCALE_SERVE_PORT", "T3CODE_HOME",
    "T3CODE_BOOTSTRAP_FD", "VITE_DEV_SERVER_URL", "ELECTRON_RUN_AS_NODE",
  ]

  static func build() async -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let shell = await captureLoginShell()
    // PATH: the login shell's first, then what the app was given.
    let path = ((shell["PATH"] ?? "").split(separator: ":") + (env["PATH"] ?? "").split(separator: ":")).map(String.init)
    var seen = Set<String>()
    env["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    for (name, value) in shell where name != "PATH" && (env[name] ?? "").isEmpty { env[name] = value }
    for name in stripped { env[name] = nil }
    return env
  }

  private static func captureLoginShell(timeout: TimeInterval = 5) async -> [String: String] {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = shellNames.map { "printf '%s\\n' '<<\($0)'; printenv \($0) || true; printf '%s\\n' '>>\($0)'" }.joined(separator: "; ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return continuation.resume(returning: [:]) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        continuation.resume(returning: parse(String(decoding: data, as: UTF8.self)))
      }
    }
  }

  static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for name in shellNames {
      guard let start = text.range(of: "<<\(name)\n"), let end = text.range(of: ">>\(name)", range: start.upperBound..<text.endIndex) else { continue }
      var value = String(text[start.upperBound..<end.lowerBound])
      if value.hasSuffix("\n") { value.removeLast() }
      if !value.isEmpty { result[name] = value }
    }
    return result
  }
}
