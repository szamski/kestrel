import Foundation
import T3Contracts
import T3Protocol

/// Everything the client keeps for one environment: its supervisor (the only retry owner),
/// server config, shell sync, shared thread subscriptions and the command path.
public actor EnvironmentRuntime {
  public nonisolated let entry: EnvironmentConnectionEntry
  public nonisolated let supervisor: EnvironmentSupervisor
  public nonisolated let config: ServerConfigSync
  public nonisolated let shellSync: ShellSync
  public nonisolated let threads: ThreadSyncRegistry
  /// The shell as the user should see it: synchronised data with pending optimistic updates layered on.
  public nonisolated let shell = ValueHub<EnvironmentShellState>(.empty)
  /// Foreground events, fanned out to the supervisor and to the subscriptions that resume on the same session.
  public nonisolated let wakeups = EventHub<ConnectionWakeup>()

  private let clock: any RuntimeClock
  private let keepRunningThreadsMounted: Bool
  private let configEvents: AsyncStream<ServerConfigStreamEvent>
  private let serial = KeyedSerialExecutor()
  private let urlSession: URLSession
  private var overlay = OptimisticOverlay()
  private var settingsInFlight = 0
  private var tasks: [Task<Void, Never>] = []

  public init(
    entry: EnvironmentConnectionEntry, driver: any ConnectionDriving, cache: any SnapshotCache, loader: any SnapshotLoading,
    clock: any RuntimeClock = SystemClock(), network: NetworkStatus = .unknown, keepRunningThreadsMounted: Bool = true,
    urlSession: URLSession = URLSession(configuration: .ephemeral)
  ) {
    self.entry = entry
    self.clock = clock
    self.keepRunningThreadsMounted = keepRunningThreadsMounted
    self.urlSession = urlSession
    let (events, continuation) = AsyncStream<ServerConfigStreamEvent>.makeStream()
    configEvents = events
    let supervisor = EnvironmentSupervisor(
      entry: entry, driver: driver, clock: clock, network: network, initiallyDesired: entry.enabled,
      onConfigEvent: { continuation.yield($0) })
    self.supervisor = supervisor
    config = ServerConfigSync(environmentId: entry.environmentId, cache: cache, clock: clock)
    shellSync = ShellSync(environmentId: entry.environmentId, supervisor: supervisor, cache: cache, loader: loader, clock: clock)
    let wakeups = wakeups
    threads = ThreadSyncRegistry(
      environmentId: entry.environmentId, supervisor: supervisor, cache: cache, loader: loader, clock: clock, wakeups: wakeups)
  }

  public var environmentId: EnvironmentId { entry.environmentId }

  // MARK: Lifecycle

  public func start() async {
    guard tasks.isEmpty else { return }
    await config.start(events: configEvents)
    await shellSync.start(wakeups: wakeups)
    let shellChanges = shellSync.state.changes()
    tasks.append(Task {
      for await synced in shellChanges { await self.shellChanged(synced) }
    })
    if keepRunningThreadsMounted {
      let keepAliveChanges = shellSync.state.changes()
      tasks.append(Task {
        var previous: Set<ThreadId>?
        for await synced in keepAliveChanges {
          let running = Set((synced.snapshot?.threads ?? []).filter { $0.session?.isStartingOrRunning ?? false }.map(\.id))
          if running == previous { continue }
          previous = running
          await self.threads.reconcileKeepAlive(running: running)
        }
      })
    }
    await supervisor.start()
  }

  public func stop() async {
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    tasks = []
    await supervisor.shutdown()
    await threads.shutdown()
    await shellSync.stop()
    await config.stop()
  }

  public func connect() async { await supervisor.connect() }
  public func disconnect() async { await supervisor.disconnect() }
  public func retryNow() async { await supervisor.retryNow() }
  public func networkChanged(_ status: NetworkStatus) async { await supervisor.networkChanged(status) }
  public func wake(_ reason: ConnectionWakeup) async {
    wakeups.emit(reason)
    await supervisor.wake(reason)
  }

  // MARK: Optimistic shell

  private func shellChanged(_ synced: EnvironmentShellState) {
    overlay.reconcile(with: synced.snapshot)
    shell.set(display(synced))
  }

  private func recomputeDisplay() { shell.set(display(shellSync.state.value)) }

  private func display(_ synced: EnvironmentShellState) -> EnvironmentShellState {
    guard var snapshot = synced.snapshot, !overlay.isEmpty else { return synced }
    snapshot = overlay.apply(to: snapshot)
    var shown = synced
    shown.snapshot = snapshot
    return shown
  }

  // MARK: Commands

  /// Dispatches one orchestration command. Commands for one thread run one at a time. With `optimistic`,
  /// the shell shows the lifecycle change at once and rolls it back if the dispatch fails.
  @discardableResult
  public func dispatch(
    _ command: ClientOrchestrationCommand, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> DispatchResult {
    let key = "\(entry.environmentId.rawValue):\(thread?.rawValue ?? "*")"
    let outcome = await serial.run(key: key) { await self.performDispatch(command, thread: thread, optimistic: optimistic) }
    return try outcome.get()
  }

  private func performDispatch(
    _ command: ClientOrchestrationCommand, thread: ThreadId?, optimistic: OptimisticAction?
  ) async -> Result<DispatchResult, CommandError> {
    guard let session = supervisor.session.value else { return .failure(.notConnected(environment: entry.label)) }
    var updateId: Int?
    if let thread, let optimistic {
      updateId = overlay.add(threadId: thread, action: optimistic, now: clock.nowISO())
      recomputeDisplay()
    }
    do {
      let result = try await session.call(Rpc.orchestrationDispatchCommand, command)
      if let updateId {
        overlay.accept(updateId, sequence: result.sequence)
        overlay.reconcile(with: shellSync.state.value.snapshot)
        recomputeDisplay()
      }
      return .success(result)
    } catch {
      if let updateId {
        overlay.remove(updateId)
        recomputeDisplay()
      }
      return .failure(CommandError.map(error))
    }
  }

  // MARK: Settings

  /// `server.updateSettings` with the edit shown at once. Concurrent edits stack; the last answer is authoritative, and a
  /// rejected edit is undone by re-reading the server's settings (or restoring the previous ones when it cannot be reached).
  public func updateSettings(_ patch: ServerSettingsPatch) async throws(CommandError) {
    guard let session = supervisor.session.value else { throw .notConnected(environment: entry.label) }
    let previous = config.projection.value?.config.settings
    var shown: ServerSettings?
    if let previous, let next = SettingsPlanner.applying(patch, to: previous) {
      shown = next
      await config.replaceSettings(next)
    }
    settingsInFlight += 1
    do {
      let result = try await session.call(Rpc.serverUpdateSettings, ServerUpdateSettingsPayload(patch: patch))
      settingsInFlight -= 1
      if settingsInFlight == 0 { await config.replaceSettings(result) }
    } catch {
      settingsInFlight -= 1
      if settingsInFlight == 0 {
        if let fresh = try? await session.call(Rpc.serverGetSettings, EmptyObject()) {
          await config.replaceSettings(fresh)
        } else if let previous, config.projection.value?.config.settings == shown {
          await config.replaceSettings(previous)
        }
      }
      switch error {
      case .failure(.serverSettingsError): throw .rejected(message: "The server could not save the setting.")
      case .failure(.environmentAuthorizationError(let e)): throw .unauthorized(message: "\(e)")
      case .failure(.unknown): throw .rejected(message: "The server refused the setting.")
      case .transportClosed(let reason): throw .transport(message: "The connection closed before the setting was saved (\(reason)).")
      case .defect, .interrupted: throw .transport(message: "The setting could not be saved.")
      }
    }
  }

  // MARK: Attachments

  /// Uploads bytes for a later `thread.turn.start`. Cancelling the task deletes the pending upload it created.
  public func uploadAttachment(data: Data, name: String, mimeType: String) async throws(AttachmentUploadError) -> UploadedAttachment {
    guard let session = supervisor.session.value else { throw .notConnected }
    return try await AttachmentUploader.upload(
      session: session, httpBaseURL: entry.httpBaseURL, data: data, name: name, mimeType: mimeType, urlSession: urlSession)
  }

  public func deletePendingAttachment(_ attachmentId: String) async {
    guard let session = supervisor.session.value else { return }
    await AttachmentUploader.delete(session, attachmentId)
  }

  // MARK: Background activity

  /// `server.reportClientActivity`: keeps the server's background work (provider status, VCS refresh)
  /// alive while this client looks at it. Failures are ignored; the next report renews the lease.
  public func reportClientActivity(_ input: ClientActivityReportInput) async {
    guard let session = supervisor.session.value else { return }
    _ = try? await session.call(Rpc.serverReportClientActivity, input)
  }

  // MARK: Queries used by the facade

  public func searchThreads(query: String) async -> [OrchestrationThreadSearchMatch] {
    guard let session = supervisor.session.value, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    do {
      return try await session.call(Rpc.orchestrationSearchThreads, OrchestrationSearchThreadsInput(query: query)).matches
    } catch {
      return []  // search failures contribute no content matches; local title search stays the fallback
    }
  }
}
