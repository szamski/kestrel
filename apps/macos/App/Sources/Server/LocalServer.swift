import AppKit
import Darwin
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
      // The server's telemetry and control channels: it learns the app's power state and process metrics, and the app learns its demand.
      var telemetryToken: Int?
      if let telemetryWrite = child.appEnds[ServerChannel.telemetry.childFd], let controlRead = child.appEnds[ServerChannel.telemetryControl.childFd] {
        telemetryToken = DesktopTelemetry.shared.attach(telemetryWrite: telemetryWrite, controlRead: controlRead)
      }

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
      if let telemetryToken { DesktopTelemetry.shared.detach(token: telemetryToken) }
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

/// A pipe the server inherits at `childFd` (in addition to stdio); the app keeps the other end (`ServerChild.appEnds`).
struct ServerChannel: Sendable {
  let childFd: Int32
  /// True when the app writes and the server reads; false when the server writes and the app reads.
  let toServer: Bool

  /// The desktop telemetry channel of packages/contracts/src/desktopBootstrap.ts: telemetry to the server on fd 4, its control messages on fd 5.
  static let telemetry = ServerChannel(childFd: 4, toServer: true)
  static let telemetryControl = ServerChannel(childFd: 5, toServer: false)
}

/// The spawned server process. Only the pid and `isRunning` are touched from other threads.
final class ServerChild: @unchecked Sendable {
  /// Pid of the server that is running now (0 when none), for `LocalServer.killSpawned`.
  static let livePid = OSAllocatedUnfairLock<Int32>(initialState: 0)

  let pid: Int32
  private let running = OSAllocatedUnfairLock<Bool>(initialState: true)
  var isRunning: Bool { running.withLock { $0 } }
  /// Exit status; any number of tasks may await it.
  let exit: Task<Int32, Never>
  /// The app's end of each channel, by the server's descriptor number. The caller owns and closes them.
  let appEnds: [Int32: Int32]

  private init(pid: Int32, exit: Task<Int32, Never>, appEnds: [Int32: Int32]) {
    self.pid = pid
    self.exit = exit
    self.appEnds = appEnds
  }

  /// `pipe()` with both ends above the descriptors the child is remapped onto (a source below them could be overwritten by an earlier
  /// `dup2` of the file actions) and close-on-exec, so nothing leaks into other children.
  private static func makePipe() throws -> (read: Int32, write: Int32) {
    var ends: [Int32] = [0, 0]
    guard pipe(&ends) == 0 else { throw LocalServerLaunch.Failure(errorDescription: "pipe: \(String(cString: strerror(errno)))") }
    let moved = ends.map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
    ends.forEach { Darwin.close($0) }
    guard moved.allSatisfy({ $0 >= 0 }) else {
      moved.filter { $0 >= 0 }.forEach { Darwin.close($0) }
      throw LocalServerLaunch.Failure(errorDescription: "fcntl: \(String(cString: strerror(errno)))")
    }
    return (moved[0], moved[1])
  }

  static func spawn(
    launch: LocalServerLaunch, environment: [String: String], port: Int, token: String, exposure: LocalServerExposure, log: URL,
    channels: [ServerChannel] = [.telemetry, .telemetryControl]
  ) throws -> ServerChild {
    let hasDesktopChannel = channels.contains { $0.childFd == ServerChannel.telemetry.childFd } && channels.contains { $0.childFd == ServerChannel.telemetryControl.childFd }
    let bootstrap = try LocalServerSupport.bootstrapJSON(
      port: port, home: launch.home, token: token, exposure: exposure,
      desktopFds: hasDesktopChannel ? (Int(ServerChannel.telemetry.childFd), Int(ServerChannel.telemetryControl.childFd)) : nil)
    let logHandle = try LocalServerSupport.openLog(log)
    defer { try? logHandle.close() }
    // Parent-death watchdog: the server has none of its own, so `/bin/sh` forks a watcher that polls the app's pid and
    // the server's, then `exec`s the server (same pid, so signals, `ps` and the pidfile all see the server itself).
    // When the app is gone the watcher SIGTERMs the server and SIGKILLs it after 5 s; when the server exits first the
    // watcher ends. The watcher drops the channel descriptors it inherited, so only the server holds them.
    // ponytail: polls once a second (up to 1 s late); kqueue/launchd would be exact but need a helper binary.
    let dropChannels = channels.map { "\($0.childFd)<&-" }.joined(separator: " ")
    let script = """
      app=$1; shift; srv=$$
      ( while kill -0 $app 2>/dev/null && kill -0 $srv 2>/dev/null; do sleep 1; done
        kill -0 $app 2>/dev/null && exit 0
        kill -TERM $srv 2>/dev/null
        for i in 1 2 3 4 5; do kill -0 $srv 2>/dev/null || exit 0; sleep 1; done
        kill -KILL $srv 2>/dev/null ) </dev/null >/dev/null 2>&1 \(dropChannels) &
      exec "$@"
      """
    let arguments = ["/bin/sh", "-c", script, "kestrel-server-watchdog", String(getpid()), launch.executable.path] + launch.arguments

    // One pipe for the bootstrap on stdin and one per channel; each has an end for the server and an end for the app.
    var serverEnds: [Int32] = []
    var appEnds: [Int32: Int32] = [:]
    var remap: [(from: Int32, to: Int32)] = []
    var spawned = false
    let stdin = try makePipe()
    defer {
      if !spawned {
        Darwin.close(stdin.write)
        (serverEnds + appEnds.values).forEach { Darwin.close($0) }
      }
    }
    serverEnds.append(stdin.read)
    // The log goes first: its descriptor number can be 4 or 5, which a later channel is mapped onto.
    remap += [(logHandle.fileDescriptor, 1), (logHandle.fileDescriptor, 2), (stdin.read, 0)]
    for channel in channels {
      let pipe = try makePipe()
      remap.append((channel.toServer ? pipe.read : pipe.write, channel.childFd))
      serverEnds.append(channel.toServer ? pipe.read : pipe.write)
      appEnds[channel.childFd] = channel.toServer ? pipe.write : pipe.read
    }

    // posix_spawn rather than Process: Process cannot hand the child descriptors beyond stdio. CLOEXEC_DEFAULT closes everything else.
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (from, to) in remap { posix_spawn_file_actions_adddup2(&actions, from, to) }
    posix_spawn_file_actions_addchdir_np(&actions, launch.workingDirectory.path)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultSignals = sigset_t(), noSignals = sigset_t()
    sigfillset(&defaultSignals)  // the app ignores SIGPIPE; the server starts with every signal at its default
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
    guard status == 0 else { throw LocalServerLaunch.Failure(errorDescription: "posix_spawn: \(String(cString: strerror(status)))") }
    spawned = true
    let childPid = pid
    livePid.withLock { $0 = childPid }
    serverEnds.forEach { Darwin.close($0) }

    // The envelope is written and the pipe closed at once: the server reads one line from fd 0, and an open
    // idle pipe makes its read fail with EAGAIN on macOS.
    var offset = 0
    while offset < bootstrap.count {
      let written = bootstrap[offset...].withUnsafeBytes { write(stdin.write, $0.baseAddress, $0.count) }
      if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
    }
    Darwin.close(stdin.write)

    let (statuses, continuation) = AsyncStream<Int32>.makeStream()
    let exit = Task<Int32, Never> {
      for await status in statuses { return status }
      return -1
    }
    let child = ServerChild(pid: childPid, exit: exit, appEnds: appEnds)
    // A thread of its own reaps the child: waitpid blocks until it exits.
    Thread.detachNewThread {
      var raw: Int32 = 0
      while waitpid(childPid, &raw, 0) < 0, errno == EINTR {}
      child.running.withLock { $0 = false }
      livePid.withLock { if $0 == childPid { $0 = 0 } }
      continuation.yield((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : raw & 0x7f)  // exit code, or the signal that ended it
      continuation.finish()
    }
    return child
  }

  /// SIGTERM now, SIGKILL after 5 s if it is still there. Only ever signals the pid this app spawned.
  func terminate() {
    guard isRunning else { return }
    kill(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in if isRunning { kill(pid, SIGKILL) } }
  }
}
