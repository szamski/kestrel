import Darwin
import Foundation
import Security
import SQLite3

/// Small, separately testable pieces of the local-server lifecycle.
enum LocalServerSupport {
  // MARK: Bootstrap

  /// The envelope the server reads from `--bootstrap-fd 0`: packages/contracts/src/desktopBootstrap.ts
  /// (DesktopBackendBootstrap). Telemetry fds and OTLP endpoints are omitted, Tailscale Serve is off.
  static func bootstrapJSON(port: Int, home: URL, token: String) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: [
        "mode": "desktop", "noBrowser": true, "port": port, "t3Home": home.path, "host": "127.0.0.1", "desktopBootstrapToken": token,
        "tailscaleServeEnabled": false, "tailscaleServePort": 443,
      ] as [String: Any], options: [.sortedKeys])
    data.append(0x0A)
    return data
  }

  static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Ports

  /// First port from `first` upward that nothing is listening on (strict bind, so a wildcard listener counts too).
  static func firstFreePort(from first: Int) -> Int? {
    (first..<min(first + 200, 65536)).first(where: isFree)
  }

  static func isFree(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
  }

  // MARK: Readiness

  /// `GET /.well-known/t3/environment` answers 200 once the server serves HTTP (the readiness probe Electron uses).
  static func isReady(origin: URL) async -> Bool {
    var request = URLRequest(url: origin.appending(path: ".well-known/t3/environment"), timeoutInterval: 1)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }

  /// Polls until ready, the task is cancelled, the process is gone (`alive` false) or `timeout` passes.
  static func waitUntilReady(origin: URL, timeout: Duration = .seconds(60), while alive: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !Task.isCancelled, alive(), ContinuousClock.now < deadline {
      if await isReady(origin: origin) { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  // MARK: Home guard

  private struct RuntimeState: Decodable {
    var pid: Int32
    var origin: String
  }

  /// Another live server on this home. The server has no lock file: a running one writes
  /// `<home>/userdata/server-runtime.json` (pid, origin) after it listens and removes it on shutdown, which is what
  /// `t3 pair` and the CLI use to find it. A server counts as owning the home when that pid is alive and its origin
  /// answers the readiness probe. ponytail: a hung server (alive, not answering) is not detected; add a pid-based check if needed.
  static func foreignOwner(runtimeState: URL) async -> URL? {
    guard let data = try? Data(contentsOf: runtimeState), let state = try? JSONDecoder().decode(RuntimeState.self, from: data),
      isAlive(state.pid), let origin = URL(string: state.origin), await isReady(origin: origin)
    else { return nil }
    return origin
  }

  static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

  // MARK: Stale process of a previous run

  /// The server we spawned last time, remembered so a crash or force quit of the app (the server has no
  /// parent-death detection) does not leave it running forever.
  struct Pidfile: Codable, Equatable {
    var pid: Int32
    var marker: String
    var home: String

    static func read(_ url: URL) -> Pidfile? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Pidfile.self, from: $0) } }
    func write(_ url: URL) { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(self).write(to: url, options: .atomic) }
    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
  }

  /// Stops the server recorded in the pidfile when that pid is still alive AND its command line still holds our
  /// server entry (so a recycled pid is left alone) AND the home matches. Always clears the pidfile.
  static func reclaimStale(pidfile url: URL, home: URL) async {
    defer { Pidfile.remove(url) }
    guard let record = Pidfile.read(url), record.home == home.path, isAlive(record.pid),
      commandLine(of: record.pid)?.contains(record.marker) == true
    else { return }
    kill(record.pid, SIGTERM)
    for _ in 0..<50 where isAlive(record.pid) { try? await Task.sleep(for: .milliseconds(100)) }
    if isAlive(record.pid) { kill(record.pid, SIGKILL) }
  }

  private static func commandLine(of pid: Int32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "command="]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Log

  /// Opens the log for appending; a log over 5 MB moves to `server.log.1` first (one generation is enough).
  static func openLog(_ url: URL) throws -> FileHandle {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 5_000_000 {
      let old = url.appendingPathExtension("1")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: url, to: old)
    }
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    return handle
  }

  // MARK: Debug seed

  #if DEBUG
  /// `-KestrelSeedFromLive YES`: gives an empty dev home a snapshot of the live database for browsing real threads.
  /// The source is opened READ-ONLY and only ever read (`VACUUM INTO` writes the new file, never the source); nothing
  /// is symlinked and nothing flows back (AGENTS.md "Test data"). Only runs when the dev home has no database yet.
  static func seedFromLiveIfRequested(into stateDirectory: URL) {
    guard UserDefaults.standard.bool(forKey: "KestrelSeedFromLive") else { return }
    let fm = FileManager.default
    let destination = stateDirectory.appending(path: "state.sqlite")
    let source = fm.homeDirectoryForCurrentUser.appending(path: ".t3/userdata/state.sqlite")
    guard !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path) else { return }
    try? fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    let quoted = destination.path.replacingOccurrences(of: "'", with: "''")
    if sqlite3_exec(db, "VACUUM INTO '\(quoted)'", nil, nil, nil) != SQLITE_OK { try? fm.removeItem(at: destination) }
  }
  #endif
}
