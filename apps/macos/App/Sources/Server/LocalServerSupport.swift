import Darwin
import Foundation
import Security
import SQLite3

/// Small, separately testable pieces of the local-server lifecycle.
enum LocalServerSupport {
  // MARK: Bootstrap

  /// The envelope the server reads from `--bootstrap-fd 0`: packages/contracts/src/desktopBootstrap.ts
  /// (DesktopBackendBootstrap). `desktopFds` names the descriptors of the telemetry channel (see `ServerChild.spawn`); OTLP endpoints
  /// are omitted; the bind host and Tailscale Serve follow `exposure`.
  static func bootstrapJSON(
    port: Int, home: URL, token: String, exposure: LocalServerExposure = LocalServerExposure(), desktopFds: (telemetry: Int, control: Int)? = nil
  ) throws -> Data {
    var envelope: [String: Any] = [
      "mode": "desktop", "noBrowser": true, "port": port, "t3Home": home.path, "host": exposure.bindHost, "desktopBootstrapToken": token,
      "tailscaleServeEnabled": exposure.tailscaleServe, "tailscaleServePort": exposure.tailscalePort,
    ]
    if let desktopFds {
      envelope["desktopTelemetryFd"] = desktopFds.telemetry
      envelope["desktopTelemetryControlFd"] = desktopFds.control
    }
    var data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
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

  /// Stops every server of ours left over from an earlier run: the one in the pidfile, plus any process whose command
  /// line is our server (`executable`, our entry `marker`, `--bootstrap-fd`) that is not this app's child. The scan is
  /// what catches a server whose pidfile was overwritten or never written (a crash, a second launch, `exit(0)`), and one
  /// that is still starting, which has no `server-runtime.json` yet. Callers hold `InstanceLock`, so nothing found here
  /// can belong to a live instance. A process holding another home's database open is left alone. Always clears the pidfile.
  static func reclaimStale(pidfile url: URL, launch: LocalServerLaunch) async {
    defer { Pidfile.remove(url) }
    var pids = Set(staleServers(executable: launch.executable.path, marker: launch.marker, home: launch.home))
    if let record = Pidfile.read(url), record.home == launch.home.path, isAlive(record.pid),
      commandLine(of: record.pid)?.contains(record.marker) == true
    {
      pids.insert(record.pid)
    }
    guard !pids.isEmpty else { return }
    pids.forEach { kill($0, SIGTERM) }
    for _ in 0..<50 where pids.contains(where: isAlive) { try? await Task.sleep(for: .milliseconds(100)) }
    pids.filter(isAlive).forEach { kill($0, SIGKILL) }
  }

  static func staleServers(executable: String, marker: String, home: URL) -> [Int32] {
    let listing = run("/bin/ps", ["-axo", "pid=,ppid=,command="]) ?? ""
    let me = getpid()
    return listing.split(separator: "\n").compactMap { line -> Int32? in
      let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), pid != me, parent != me else { return nil }
      let command = String(fields[2])
      guard command.hasPrefix(executable), command.contains(marker), command.contains("--bootstrap-fd"), !holdsOtherHome(pid, home: home) else { return nil }
      return pid
    }
  }

  /// True when `pid` has a server database (`userdata/state.sqlite` for orchestration V1,
  /// `userdata/statev2.sqlite` for V2) open that is not under `home` (lsof lists open files by `n<path>`).
  private static func holdsOtherHome(_ pid: Int32, home: URL) -> Bool {
    (run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"]) ?? "").split(separator: "\n").contains { line in
      line.hasPrefix("n")
        && (line.hasSuffix("/userdata/state.sqlite") || line.hasSuffix("/userdata/statev2.sqlite"))
        && !line.dropFirst().hasPrefix(home.path + "/")
    }
  }

  private static func commandLine(of pid: Int32) -> String? { run("/bin/ps", ["-p", String(pid), "-o", "command="]) }

  /// Runs a tool and returns its stdout; nil when it cannot start.
  private static func run(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Instance lock

  /// One app instance supervises a server per data directory. A kernel `flock` on a file next to the pidfile: it needs
  /// no cleanup (the kernel drops it when the process dies, however it dies) and serializes a relaunch behind an instance
  /// that is still shutting its server down, which is how two servers ended up on one home.
  final class InstanceLock: @unchecked Sendable {
    private let fd: Int32

    /// Waits up to `timeout` for the previous holder; nil when it never lets go.
    static func acquire(_ url: URL, timeout: Duration = .seconds(15)) async -> InstanceLock? {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard fd >= 0 else { return nil }
      let deadline = ContinuousClock.now + timeout
      while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { close(fd); return nil }
        try? await Task.sleep(for: .milliseconds(200))
      }
      return InstanceLock(fd: fd)
    }

    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }  // closing releases the flock
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
  /// After a successful snapshot, `attachments/` is copied as real files so seeded image threads still load.
  /// Prefers the orchestration V2 `statev2.sqlite` when the live home has one; otherwise falls back to V1 `state.sqlite`.
  static func seedFromLiveIfRequested(into stateDirectory: URL) {
    guard UserDefaults.standard.bool(forKey: "KestrelSeedFromLive") else { return }
    let fm = FileManager.default
    let liveUserdata = fm.homeDirectoryForCurrentUser.appending(path: ".t3/userdata")
    let destinations = ["statev2.sqlite", "state.sqlite"].map { stateDirectory.appending(path: $0) }
    guard !destinations.contains(where: { fm.fileExists(atPath: $0.path) }) else { return }
    let useV2 = fm.fileExists(atPath: liveUserdata.appending(path: "statev2.sqlite").path)
    let source = liveUserdata.appending(path: useV2 ? "statev2.sqlite" : "state.sqlite")
    let destination = useV2 ? destinations[0] : destinations[1]
    guard fm.fileExists(atPath: source.path) else { return }
    try? fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    let quoted = destination.path.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_exec(db, "VACUUM INTO '\(quoted)'", nil, nil, nil) == SQLITE_OK else {
      try? fm.removeItem(at: destination)
      return
    }
    seedAttachmentsFromLive(liveUserdata.appending(path: "attachments", directoryHint: .isDirectory),
                            into: stateDirectory.appending(path: "attachments", directoryHint: .isDirectory))
  }

  /// Real copies of the live attachments so seeded threads can load their images; existing files are kept and a
  /// file that fails to copy is logged, not fatal. A missing source directory is a no-op.
  private static func seedAttachmentsFromLive(_ source: URL, into destination: URL) {
    let fm = FileManager.default
    guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
    let prefix = source.pathComponents.count
    for case let file as URL in files {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
      let target = destination.appending(path: file.pathComponents.dropFirst(prefix).joined(separator: "/"))
      guard !fm.fileExists(atPath: target.path) else { continue }
      do {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: target)
      } catch {
        NSLog("Kestrel seed: could not copy attachment %@: %@", file.lastPathComponent, error.localizedDescription)
      }
    }
  }
  #endif
}
