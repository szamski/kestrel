import AppKit
import Foundation
import T3ClientRuntime
import T3Contracts

/// `t3 app <path>` for Kestrel: the activation socket plus what happens to a request once it arrives. The behavior follows
/// DesktopAppActivationBroker.ts (hold requests until the UI can take them, one at a time, 15 s, forget a request whose CLI hung up) and
/// apps/web/src/desktopAppActivation.ts (add the project to the Mac's own environment unless it is there, then open its new-thread draft).
@MainActor
final class DesktopActivation {
  static let shared = DesktopActivation()

  private var socket: ActivationSocket?
  private weak var app: AppModel?
  private var pending: [String: Pending] = [:]
  private var order: [String] = []
  private var draining = false

  private struct Pending {
    var request: DesktopAppActivation.Request
    var continuation: CheckedContinuation<Data, Never>
    var timeout: Task<Void, Never>
  }

  /// The address the CLI uses, for logs and the debug driver.
  var socketPath: String? { socket?.path }

  /// Binds the socket for the state directory of the local server (`<t3Home>/userdata`, the same rule `t3 app` applies to `--base-dir`).
  func start(app: AppModel) {
    guard socket == nil else { return }
    self.app = app
    let stateDir = LocalServerLaunch.homeDirectory(dataDirectory: AppModel.dataDirectory).appending(path: "userdata", directoryHint: .isDirectory).path
    let socket = ActivationSocket(
      stateDir: stateDir,
      handle: { request in await DesktopActivation.shared.submit(request) },
      cancel: { id in Task { @MainActor in DesktopActivation.shared.cancel(id) } })
    do {
      try socket.start()
      self.socket = socket
    } catch {
      NSLog("Kestrel: could not start the app control socket: %@", error.localizedDescription)
    }
  }

  func stop() {
    socket?.stop()
    socket = nil
    for id in order { settle(id, DesktopAppActivation.failure(requestId: id, .rendererUnavailable, "Kestrel is shutting down.")) }
  }

  // MARK: Broker

  /// Waits for its turn and the UI, then answers. Always returns a response line.
  fileprivate func submit(_ request: DesktopAppActivation.Request) async -> Data {
    if pending[request.requestId] != nil {
      return DesktopAppActivation.failure(requestId: request.requestId, .invalidRequest, "The request id is already in use.")
    }
    app?.showMainWindow()
    return await withCheckedContinuation { continuation in
      let id = request.requestId
      let timeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(DesktopAppActivation.requestTimeout))
        guard !Task.isCancelled else { return }
        self?.settle(id, DesktopAppActivation.failure(requestId: id, .requestTimeout, "Kestrel did not finish opening the project in time."))
      }
      pending[id] = Pending(request: request, continuation: continuation, timeout: timeout)
      order.append(id)
      if !draining {
        draining = true
        Task { await drain() }
      }
    }
  }

  fileprivate func cancel(_ id: String) {
    settle(id, DesktopAppActivation.failure(requestId: id, .rendererUnavailable, "The command closed before Kestrel was ready."))
  }

  private func settle(_ id: String, _ response: Data) {
    guard let entry = pending.removeValue(forKey: id) else { return }
    order.removeAll { $0 == id }
    entry.timeout.cancel()
    entry.continuation.resume(returning: response)
  }

  /// One request at a time, each once the local environment is connected; a request that cannot be served (no local server) fails at once.
  private func drain() async {
    defer { draining = false }
    while let id = order.first, let entry = pending[id] {
      guard let app else { return settle(id, DesktopAppActivation.failure(requestId: id, .rendererUnavailable, "Kestrel is shutting down.")) }
      switch app.activationTarget() {
      case .waiting:
        try? await Task.sleep(for: .milliseconds(100))
      case .unavailable(let message):
        settle(id, DesktopAppActivation.failure(requestId: id, .environmentUnavailable, message))
      case .ready(let environmentId):
        settle(id, await app.openWorkspace(entry.request, in: environmentId))
      }
    }
  }
}

extension AppModel {
  enum ActivationTarget {
    case waiting
    case unavailable(String)
    case ready(EnvironmentId)
  }

  /// The environment of the server this app runs, once it is connected and its shell has loaded (the desktop's "primary environment").
  func activationTarget() -> ActivationTarget {
    switch localServer.state {
    case .off: return .unavailable("The local server is turned off in Kestrel. Turn on Run local server in Settings › Connections.")
    case .failed(let reason): return .unavailable("The local server is not running: \(reason)")
    case .foreignOwner: return .unavailable("Another T3 Code server already owns this Mac's home, so Kestrel runs none of its own.")
    case .starting, .running, .stopping: break
    }
    guard let id = Self.storedLocalEnvironmentId,
      let entry = runtime.environments.first(where: { $0.environmentId == id }), entry.connection.phase == .connected,
      runtime.serverConfigs[id] != nil, runtime.shells[id]?.status == .live
    else { return .waiting }
    return .ready(id)
  }

  /// `handleDesktopAppActivationRequest`: the project at the path (created when new), then its draft thread, selected in the window.
  func openWorkspace(_ request: DesktopAppActivation.Request, in environmentId: EnvironmentId) async -> Data {
    func failure(_ code: DesktopAppActivation.ErrorCode, _ message: String) -> Data {
      DesktopAppActivation.failure(requestId: request.requestId, code, message)
    }
    guard request.platform == "darwin" else {
      let sent = request.platform == "win32" ? "windows" : request.platform
      return failure(.platformMismatch, "The command path is for \(sent), but Kestrel's local environment uses darwin. Cross-platform path mapping is not supported.")
    }
    let path = ProjectGrouping.normalizePath(request.workspaceRoot)
    func existing() -> EnvironmentProject? {
      runtime.projects.first { $0.environmentId == environmentId && ProjectGrouping.normalizePath($0.project.workspaceRoot) == path }
    }
    var project = existing()
    if project == nil {
      let projectId = ProjectId(rawValue: UUID().uuidString.lowercased())
      do {
        guard let environment = await runtime.runtime(for: environmentId) else { throw CommandError.notConnected(environment: environmentId.rawValue) }
        let meta = CommandMeta.fresh()
        try await environment.dispatch(
          .projectCreate(
            V1.ProjectCreateCommand(
              commandId: meta.commandId, projectId: projectId, title: URL(fileURLWithPath: path).lastPathComponent, workspaceRoot: path, createdAt: meta.createdAt)))
      } catch {
        return failure(.projectCreateFailed, Self.describe(error))
      }
      // The project reaches the shell through the event stream.
      for _ in 0..<100 where project == nil {
        project = runtime.projects.first { $0.environmentId == environmentId && $0.projectId == projectId }
        if project == nil { try? await Task.sleep(for: .milliseconds(50)) }
      }
      guard project != nil else { return failure(.projectCreateFailed, "The server did not report the new project.") }
    }
    guard let project else { return failure(.projectCreateFailed, "The project is not available.") }
    startNewThread(in: project, label: project.project.title)
    showMainWindow()
    guard let draft else { return failure(.threadOpenFailed, "Kestrel could not open a new thread for the project.") }
    return DesktopAppActivation.success(requestId: request.requestId, projectId: project.projectId.rawValue, threadId: draft.key.threadId.rawValue)
  }
}
