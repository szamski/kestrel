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

  /// The protocol of the live connection; nil while not connected.
  public nonisolated var orchestrationProtocol: OrchestrationProtocol? { supervisor.session.value?.orchestrationProtocol }

  /// Dispatches one orchestration command. Commands for one thread run one at a time. With `optimistic`,
  /// the shell shows the lifecycle change at once and rolls it back if the dispatch fails. On a protocol-2
  /// connection the V1-shaped command is translated into the calls that do the same (`CommandTranslation`).
  @discardableResult
  public func dispatch(
    _ command: V1.ClientOrchestrationCommand, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> V1.DispatchResult {
    V1.DispatchResult(sequence: try await dispatch(.translated(command), thread: thread, optimistic: optimistic))
  }

  /// Dispatches one protocol-2 command (steer, queue edits, rollback by checkpoint, ...). The sequence is the
  /// event the server committed; a protocol-1 connection refuses.
  @discardableResult
  public func dispatch(
    _ command: OrchestrationV2Command, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> Int {
    try await dispatch(.native(command), thread: thread, optimistic: optimistic)
  }

  private enum Work: Sendable {
    case translated(V1.ClientOrchestrationCommand)
    case native(OrchestrationV2Command)
  }

  private func dispatch(_ work: Work, thread: ThreadId?, optimistic: OptimisticAction?) async throws(CommandError) -> Int {
    let key = "\(entry.environmentId.rawValue):\(thread?.rawValue ?? "*")"
    let outcome = await serial.run(key: key) { await self.performDispatch(work, thread: thread, optimistic: optimistic) }
    return try outcome.get()
  }

  private func performDispatch(_ work: Work, thread: ThreadId?, optimistic: OptimisticAction?) async -> Result<Int, CommandError> {
    guard let session = supervisor.session.value else { return .failure(.notConnected(environment: entry.label)) }
    var updateId: Int?
    if let thread, let optimistic {
      updateId = overlay.add(threadId: thread, action: optimistic, now: clock.nowISO())
      recomputeDisplay()
    }
    do {
      let sequence = try await execute(work, session)
      if let updateId {
        overlay.accept(updateId, sequence: sequence)
        overlay.reconcile(with: shellSync.state.value.snapshot)
        recomputeDisplay()
      }
      return .success(sequence)
    } catch {
      if let updateId {
        overlay.remove(updateId)
        recomputeDisplay()
      }
      return .failure(error)
    }
  }

  private func execute(_ work: Work, _ session: any EnvironmentSession) async throws(CommandError) -> Int {
    switch work {
    case .translated(let command):
      if session.orchestrationProtocol == .v2 { return try await run(try CommandTranslation.plan(for: command), session: session) }
      do { return try await session.call(V1.Rpc.orchestrationDispatchCommand, command).sequence } catch { throw CommandError.map(error) }
    case .native(let command):
      guard session.orchestrationProtocol == .v2 else { throw .rejected(message: "\(entry.label) needs a newer T3 Code for this action.") }
      return try await run([.command(command)], session: session)
    }
  }

  // MARK: Protocol-2 plans

  /// Runs the steps in order and returns the sequence of the last committed command (0 when none reports one).
  private func run(_ steps: [V2Step], session: any EnvironmentSession) async throws(CommandError) -> Int {
    var sequence = 0
    for step in steps {
      switch step {
      case .command(let command):
        sequence = try await send(command, session)
      case .launch(let input):
        do { _ = try await session.call(Rpc.orchestrationLaunchThread, input) } catch { throw CommandError.map(error) }
      case .project(let mutation):
        do { _ = try await session.call(Rpc.projectsMutate, mutation) } catch { throw CommandError.map(error) }
      case .interrupt(let threadId, let runId, let meta):
        guard let target = runId ?? interruptTarget(threadId) else { continue }
        sequence = try await send(ThreadCommandV2.interrupt(threadId, runId: target, meta: meta), session)
      case .rollback(let threadId, let turnCount, let restoreFiles, let meta):
        let projection = try await projection(threadId, session)
        // The checkpoint taken after run ordinal `turnCount` (0: the state before any run).
        let checkpoint = projection.checkpoints.last { candidate in
          turnCount == 0 ? candidate.ordinalWithinScope == 0 && candidate.appRunOrdinal == nil : candidate.appRunOrdinal == turnCount
        }
        guard let checkpoint, checkpoint.status == .ready else { throw .rejected(message: "That checkpoint is no longer available.") }
        sequence = try await send(
          ThreadCommandV2.rollback(threadId, scopeId: checkpoint.scopeId, checkpointId: checkpoint.id, restoreFiles: restoreFiles, meta: meta), session)
      case .detachSessions(let threadId, let meta):
        for providerSession in try await projection(threadId, session).providerSessions {
          let id = CommandId(rawValue: "\(meta.commandId.rawValue):detach:\(providerSession.id.rawValue)")
          sequence = try await send(
            ThreadCommandV2.detachProviderSession(threadId, sessionId: providerSession.id, meta: CommandMeta(commandId: id, createdAt: meta.createdAt)), session)
        }
      }
    }
    return sequence
  }

  private func send(_ command: OrchestrationV2Command, _ session: any EnvironmentSession) async throws(CommandError) -> Int {
    do { return try await session.call(Rpc.orchestrationDispatchCommand, command).sequence } catch { throw CommandError.map(error) }
  }

  private func projection(_ threadId: ThreadId, _ session: any EnvironmentSession) async throws(CommandError) -> OrchestrationV2ThreadProjection {
    do { return try await session.call(Rpc.orchestrationGetThreadProjection, OrchestrationV2GetThreadProjectionInput(threadId: threadId)) } catch { throw CommandError.map(error) }
  }

  /// Stop's target: the active run, or the latest run while its background work (a subagent, a monitor) still runs.
  private func interruptTarget(_ threadId: ThreadId) -> RunId? {
    guard let thread = shellSync.state.value.v2?.threads.first(where: { $0.id == threadId }) else { return nil }
    if let active = thread.activeRunId { return active }
    return ShellPresentation.backgroundWorkHoldsCompletion(thread.pendingBackgroundTasks) ? thread.latestRunId : nil
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
      return try await session.call(V1.Rpc.orchestrationSearchThreads, OrchestrationSearchThreadsInput(query: query)).matches
    } catch {
      return []  // search failures contribute no content matches; local title search stays the fallback
    }
  }
}
