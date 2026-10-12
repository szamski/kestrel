import AppKit
import Foundation
import Observation
import os

/// The T3 server this app starts and supervises itself, so it works without any external server (what the
/// Electron shell does with DesktopBackendManager). One supervision task owns the whole lifecycle: reclaim a
/// stale server of an earlier run, refuse to share a home with another live server, spawn, wait for readiness,
/// register the environment, restart with backoff on unexpected exit, SIGTERM then SIGKILL on stop. The server is
/// started through a watchdog (see `ServerChild.spawn`) so it also ends when the app dies without running any of this.
@MainActor @Observable
final class LocalServer {
  enum State: Equatable {
    case off
    case starting(attempt: Int)
    case running(port: Int)
    case stopping
    case failed(String)
    /// Another server already owns the home; this app does not start a second one.
    case foreignOwner(origin: URL)
  }

  private(set) var state: State = .off
  /// Bind address and Tailscale Serve of the next launch; `setExposure` restarts a running server.
  private(set) var exposure = LocalServerExposure.load()

  /// Called once the server answers: exchange the bootstrap token and register the environment. Set by `AppModel`.
  @ObservationIgnored var register: (@MainActor (_ baseURL: URL, _ bootstrapToken: String) async throws -> Void)?
  /// Called when no server runs because of a failure or a foreign owner, so the stale environment stops reconnecting.
  @ObservationIgnored var unavailable: (@MainActor () async -> Void)?

  @ObservationIgnored private let dataDirectory: URL
  @ObservationIgnored private var supervisor: Task<Void, Never>?
  /// Held while a server of this data directory may run; released when supervision ends.
  @ObservationIgnored private var instanceLock: LocalServerSupport.InstanceLock?
  @ObservationIgnored private static let maxRestartAttempts = 5

  var logURL: URL { dataDirectory.appending(path: "logs/server.log") }
  private var pidfileURL: URL { dataDirectory.appending(path: "local-server.json") }
  private var lockURL: URL { dataDirectory.appending(path: "local-server.lock") }

  init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

  // MARK: Control

  func start() {
    guard supervisor == nil else { return }
    signal(SIGPIPE, SIG_IGN)  // a server that dies while its bootstrap is written must not take the app down
    state = .starting(attempt: 0)
    supervisor = Task { [weak self] in await self?.supervise() }
  }

  /// Stops the server and returns once it has exited (SIGTERM, SIGKILL after 5 s).
  func stop() async {
    guard let supervisor else {
      if case .failed = state { state = .off } else if case .foreignOwner = state { state = .off }
      return
    }
    if case .running = state { state = .stopping } else if case .starting = state { state = .stopping }
    supervisor.cancel()
    await supervisor.value
    self.supervisor = nil
    instanceLock = nil
    state = .off
  }

  /// SIGKILL for the server this process spawned, callable from any thread: the last resort of the quit deadline.
  nonisolated static func killSpawned() {
    let pid = ServerChild.livePid.withLock { $0 }
    if pid > 0 { kill(pid, SIGKILL) }
  }

  func restart() {
    Task {
      await stop()
      start()
    }
  }

  /// Saves how far the server reaches and relaunches it when it runs (or has failed) so the change takes effect.
  func setExposure(_ next: LocalServerExposure) {
    guard next != exposure else { return }
    exposure = next
    next.save()
    if supervisor != nil { restart() }
  }

  func showLog() {
    if FileManager.default.fileExists(atPath: logURL.path) { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } else {
      NSWorkspace.shared.open(logURL.deletingLastPathComponent())
    }
  }

  // MARK: Supervision

  private func supervise() async {
    let environment = await LocalServerEnvironment.build()
    let launch: LocalServerLaunch
    do { launch = try LocalServerLaunch.resolve(environment: environment, dataDirectory: dataDirectory) } catch {
      return await finish(.failed(error.localizedDescription))
    }
    let pidfileURL = pidfileURL
    guard let lock = await LocalServerSupport.InstanceLock.acquire(lockURL) else {
      return await finish(.failed("Another instance of the app is managing the local server. Quit it and try again."))
    }
    instanceLock = lock
    await LocalServerSupport.reclaimStale(pidfile: pidfileURL, launch: launch)
    if let origin = await LocalServerSupport.foreignOwner(runtimeState: launch.runtimeStateURL) { return await finish(.foreignOwner(origin: origin)) }
    #if DEBUG
    let stateDirectory = launch.stateDirectory
    await Task.detached { LocalServerSupport.seedFromLiveIfRequested(into: stateDirectory) }.value
    #endif

    var attempt = 0
    while !Task.isCancelled {
      state = .starting(attempt: attempt)
      guard let port = LocalServerSupport.firstFreePort(from: launch.firstPort) else {
        return await finish(.failed("No free port from \(launch.firstPort) upward."))
      }
      let token = LocalServerSupport.randomToken()
      let child: ServerChild
      do {
        child = try ServerChild.spawn(launch: launch, environment: environment, port: port, token: token, exposure: exposure, log: logURL)
      } catch {
        return await finish(.failed("Could not start the server: \(error.localizedDescription)"))
      }
      LocalServerSupport.Pidfile(pid: child.pid, marker: launch.marker, home: launch.home.path).write(pidfileURL)

      let origin = URL(string: "http://127.0.0.1:\(port)")!
      let ready = await LocalServerSupport.waitUntilReady(origin: origin, while: { child.isRunning })
      var status: Int32?
      if ready, !Task.isCancelled {
        state = .running(port: port)
        attempt = 0
        do { try await register?(origin, token) } catch { state = .failed("The local server runs, but connecting to it failed: \(error.localizedDescription)") }
        status = await withTaskCancellationHandler { await child.exit.value } onCancel: { child.terminate() }
      } else {
        child.terminate()  // cancelled, or never became ready
        status = await child.exit.value
      }
      LocalServerSupport.Pidfile.remove(pidfileURL)
      if Task.isCancelled { return }

      attempt += 1
      if attempt > Self.maxRestartAttempts {
        return await finish(.failed("The server stopped unexpectedly (exit \(status ?? -1)) and did not recover. See the log."))
      }
      state = .starting(attempt: attempt)
      try? await Task.sleep(for: .milliseconds(min(500 << attempt, 10_000)))
    }
  }

  /// Ends supervision with a terminal state; `supervisor` stays set until `stop()`, so Restart goes through it.
  private func finish(_ terminal: State) async {
    guard !Task.isCancelled else { return }
    state = terminal
    await unavailable?()
  }
}

/// The spawned server process. Only the pid and `isRunning` are touched from other threads.
final class ServerChild: @unchecked Sendable {
  /// Pid of the server that is running now (0 when none), for `LocalServer.killSpawned`.
  static let livePid = OSAllocatedUnfairLock<Int32>(initialState: 0)

  let pid: Int32
  private let process: Process
  var isRunning: Bool { process.isRunning }
  /// Exit status; any number of tasks may await it.
  let exit: Task<Int32, Never>

  private init(process: Process, exit: Task<Int32, Never>) {
    self.process = process
    self.exit = exit
    pid = process.processIdentifier
  }

  static func spawn(
    launch: LocalServerLaunch, environment: [String: String], port: Int, token: String, exposure: LocalServerExposure, log: URL
  ) throws -> ServerChild {
    let bootstrap = try LocalServerSupport.bootstrapJSON(port: port, home: launch.home, token: token, exposure: exposure)
    let logHandle = try LocalServerSupport.openLog(log)
    defer { try? logHandle.close() }
    let process = Process()
    // Parent-death watchdog: the server has none of its own, so `/bin/sh` forks a watcher that polls the app's pid and
    // the server's, then `exec`s the server (same pid, so signals, `ps` and the pidfile all see the server itself).
    // When the app is gone the watcher SIGTERMs the server and SIGKILLs it after 5 s; when the server exits first the
    // watcher ends. ponytail: polls once a second (up to 1 s late); kqueue/launchd would be exact but need a helper binary.
    let script = """
      app=$1; shift; srv=$$
      ( while kill -0 $app 2>/dev/null && kill -0 $srv 2>/dev/null; do sleep 1; done
        kill -0 $app 2>/dev/null && exit 0
        kill -TERM $srv 2>/dev/null
        for i in 1 2 3 4 5; do kill -0 $srv 2>/dev/null || exit 0; sleep 1; done
        kill -KILL $srv 2>/dev/null ) </dev/null >/dev/null 2>&1 &
      exec "$@"
      """
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "kestrel-server-watchdog", String(getpid()), launch.executable.path] + launch.arguments
    process.currentDirectoryURL = launch.workingDirectory
    process.environment = environment
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = logHandle
    process.standardError = logHandle
    let (statuses, continuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { finished in
      livePid.withLock { if $0 == finished.processIdentifier { $0 = 0 } }
      continuation.yield(finished.terminationStatus)
      continuation.finish()
    }
    try process.run()
    livePid.withLock { $0 = process.processIdentifier }
    // The envelope is written and the pipe closed at once: the server reads one line from fd 0, and an open
    // idle pipe makes its read fail with EAGAIN on macOS.
    try? stdin.fileHandleForWriting.write(contentsOf: bootstrap)
    try? stdin.fileHandleForWriting.close()
    let exit = Task<Int32, Never> {
      for await status in statuses { return status }
      return -1
    }
    return ServerChild(process: process, exit: exit)
  }

  /// SIGTERM now, SIGKILL after 5 s if it is still there. Only ever signals the pid this app spawned.
  func terminate() {
    guard process.isRunning else { return }
    kill(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in if process.isRunning { kill(pid, SIGKILL) } }
  }
}
