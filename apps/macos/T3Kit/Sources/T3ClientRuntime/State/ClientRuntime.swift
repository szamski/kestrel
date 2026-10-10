import Foundation
import Observation
import T3Contracts
import T3Protocol

/// The object the SwiftUI app binds to. Thin on purpose: every rule lives in the pure reducers
/// and the per-environment actors; this class mirrors their latest values onto the main actor
/// and exposes async command methods.
///
/// Reading: `environments`, `shells`, `serverConfigs`, `sidebar`, `projectGroups`, `openThread`.
/// Writing: the command methods in `ClientRuntime+Commands.swift`.
@MainActor @Observable
public final class ClientRuntime {
  // MARK: Observable state

  /// Saved environments with their live connection state.
  public private(set) var environments: [EnvironmentStatus] = []
  /// Shell per environment as the user should see it (optimistic updates included).
  public private(set) var shells: [EnvironmentId: EnvironmentShellState] = [:]
  public private(set) var serverConfigs: [EnvironmentId: ServerConfigProjection] = [:]
  /// Sidebar sections (Pinned / Active / Snoozed / Settled), rebuilt when shells, filters or visits change.
  public private(set) var sidebar = SidebarModel()
  public private(set) var projects: [EnvironmentProject] = []
  public private(set) var projectGroups: [ProjectGroup] = []
  /// When each thread was last visited (`environmentId:threadId`); unread and woke derive from it.
  public private(set) var lastVisitedAtById: [String: IsoDateTime] = [:]

  public var filter = SidebarFilter() {
    didSet {
      if filter.searchQuery != oldValue.searchQuery { searchChanged() }
      if filter != oldValue { scheduleRecompute() }
    }
  }
  public var projectGrouping = ProjectGroupingSettings() {
    didSet { if projectGrouping != oldValue { scheduleRecompute() } }
  }

  /// True once any environment has shell data (cached or live).
  public var hasShellData: Bool { shells.values.contains { $0.snapshot != nil } }

  // MARK: Internals

  @ObservationIgnored let registry: EnvironmentRegistry
  @ObservationIgnored let clientState: ClientStateStore
  @ObservationIgnored let clock: any RuntimeClock
  /// Background activity lease reporter (every 25 s while started).
  @ObservationIgnored public let activity: ActivityReporter
  @ObservationIgnored private let networkChanges: AsyncStream<NetworkStatus>?
  @ObservationIgnored private let wakeups: AsyncStream<ConnectionWakeup>?
  @ObservationIgnored private let reportsActivity: Bool
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var perEnvironment: [EnvironmentId: [Task<Void, Never>]] = [:]
  /// Which runtime `perEnvironment` observes: pairing an environment again replaces its runtime under the same id.
  @ObservationIgnored private var observedRuntime: [EnvironmentId: ObjectIdentifier] = [:]
  @ObservationIgnored private var connectionStates: [EnvironmentId: SupervisorConnectionState] = [:]
  @ObservationIgnored private var entries: [EnvironmentId: EnvironmentConnectionEntry] = [:]
  @ObservationIgnored private var order: [EnvironmentId] = []
  @ObservationIgnored private var recomputeScheduled = false
  @ObservationIgnored private var wakeTimer: Task<Void, Never>?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var matchedThreadKeys: Set<String> = []

  public init(
    registry: EnvironmentRegistry, clientState: ClientStateStore, clock: any RuntimeClock = SystemClock(),
    networkChanges: AsyncStream<NetworkStatus>? = nil, wakeups: AsyncStream<ConnectionWakeup>? = nil, reportsActivity: Bool = true
  ) {
    self.reportsActivity = reportsActivity
    self.registry = registry
    self.clientState = clientState
    self.clock = clock
    let runtimes = registry.runtimes
    activity = ActivityReporter(clock: clock, clientId: ActivityReporter.persistentClientId()) { runtimes.value }
    self.networkChanges = networkChanges
    self.wakeups = wakeups
  }

  /// Production wiring under `directory` (environments.json, client-state.json, snapshot-cache.sqlite),
  /// bearer credentials in the Keychain, `NWPathMonitor` and app-activation wakeups.
  public static func live(directory: URL, keychainService: String = KeychainCredentialStore.defaultService, appVersion: String? = nil) -> ClientRuntime {
    let clientState = ClientStateStore(directory: directory)
    let cache: any SnapshotCache = (try? SQLiteSnapshotCache(path: SQLiteSnapshotCache.defaultPath(in: directory))) ?? NoSnapshotCache()
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: KeychainCredentialStore(service: keychainService), cache: cache,
      clientState: clientState, metadata: ClientMetadata(label: EnvironmentRegistry.tokenExchangeLabel, appVersion: appVersion))
    return ClientRuntime(
      registry: registry, clientState: clientState, networkChanges: SystemSignals.networkChanges(), wakeups: SystemSignals.wakeups())
  }

  // MARK: Lifecycle

  /// Loads saved environments, starts their connections and begins mirroring state.
  public func start() async {
    guard tasks.isEmpty else { return }
    let runtimeChanges = registry.runtimes.changes()
    tasks.append(Task { [weak self] in
      for await runtimes in runtimeChanges { self?.observe(runtimes) }
    })
    let visited = clientState.state.changes()
    tasks.append(Task { [weak self] in
      for await state in visited {
        self?.lastVisitedAtById = state.threadLastVisitedAtById
        self?.scheduleRecompute()
      }
    })
    if let networkChanges {
      let registry = registry
      tasks.append(Task { for await status in networkChanges { await registry.networkChanged(status) } })
    }
    if let wakeups {
      let registry = registry
      tasks.append(Task { for await reason in wakeups { await registry.wake(reason) } })
    }
    await registry.start()
    if reportsActivity { await activity.start() }
  }

  public func stop() async {
    for task in tasks { task.cancel() }
    tasks = []
    for tasks in perEnvironment.values { tasks.forEach { $0.cancel() } }
    perEnvironment = [:]
    observedRuntime = [:]
    wakeTimer?.cancel()
    searchTask?.cancel()
    await activity.stop()
    await registry.stop()
    await clientState.flush()
  }

  /// Foreground / wake signal from the app (the live wiring already forwards the system ones).
  public func wake(_ reason: ConnectionWakeup = .applicationActive) async { await registry.wake(reason) }

  // MARK: Environments

  @discardableResult
  public func addEnvironment(pairingURL: String) async throws(AddEnvironmentError) -> EnvironmentConnectionEntry {
    try await registry.add(pairingURL: pairingURL)
  }

  @discardableResult
  public func addEnvironment(host: String, pairingCode: String) async throws(AddEnvironmentError) -> EnvironmentConnectionEntry {
    try await registry.add(host: host, pairingCode: pairingCode)
  }

  /// Registers (or re-registers, replacing its credential) the server the app runs itself.
  @discardableResult
  public func addLocalEnvironment(baseURL: URL, bootstrapToken: String, label: String, clientLabel: String) async throws(AddEnvironmentError)
    -> EnvironmentConnectionEntry
  {
    try await registry.addLocal(baseURL: baseURL, bootstrapToken: bootstrapToken, label: label, clientLabel: clientLabel)
  }

  /// Closes the connection and clears credentials, caches and client-owned state of the environment.
  public func removeEnvironment(_ environmentId: EnvironmentId) async { await registry.remove(environmentId) }
  public func setEnvironmentEnabled(_ environmentId: EnvironmentId, _ enabled: Bool) async { await registry.setEnabled(environmentId, enabled) }
  public func retryConnection(_ environmentId: EnvironmentId) async { await registry.retryNow(environmentId) }

  public func runtime(for environmentId: EnvironmentId) async -> EnvironmentRuntime? { await registry.runtime(for: environmentId) }

  /// The saved connection entry (endpoint included) of an environment, without awaiting its actor.
  public func connectionEntry(_ environmentId: EnvironmentId) -> EnvironmentConnectionEntry? { entries[environmentId] }

  // MARK: Observation

  private func observe(_ runtimes: [EnvironmentRuntime]) {
    let ids = runtimes.map { $0.entry.environmentId }
    order = ids
    for removed in perEnvironment.keys where !ids.contains(removed) {
      perEnvironment[removed]?.forEach { $0.cancel() }
      perEnvironment[removed] = nil
      observedRuntime[removed] = nil
      connectionStates[removed] = nil
      entries[removed] = nil
      shells[removed] = nil
      serverConfigs[removed] = nil
    }
    for runtime in runtimes where observedRuntime[runtime.entry.environmentId] != ObjectIdentifier(runtime) {
      let id = runtime.entry.environmentId
      perEnvironment[id]?.forEach { $0.cancel() }
      observedRuntime[id] = ObjectIdentifier(runtime)
      entries[id] = runtime.entry
      let connection = runtime.supervisor.state.changes()
      let shell = runtime.shell.changes()
      let config = runtime.config.projection.changes()
      perEnvironment[id] = [
        Task { [weak self] in
          for await state in connection {
            guard let self else { return }
            let wasConnected = connectionStates[id]?.phase == .connected
            connectionStates[id] = state
            publishEnvironments()
            if wasConnected != (state.phase == .connected) { scheduleRecompute() }  // the group representative follows who is connected
          }
        },
        Task { [weak self] in
          for await state in shell { self?.shells[id] = state; self?.scheduleRecompute() }
        },
        Task { [weak self] in
          for await projection in config { self?.serverConfigs[id] = projection; self?.scheduleRecompute() }
        },
      ]
    }
    publishEnvironments()
    scheduleRecompute()
  }

  private func publishEnvironments() {
    environments = order.compactMap { id in
      guard let entry = entries[id] else { return nil }
      return EnvironmentStatus(
        environmentId: id, label: entry.label, enabled: connectionStates[id]?.desired ?? entry.enabled,
        connection: connectionStates[id] ?? .available)
    }
  }

  // MARK: Derived state

  private func scheduleRecompute() {
    guard !recomputeScheduled else { return }
    recomputeScheduled = true
    Task { @MainActor in
      recomputeScheduled = false
      recompute()
    }
  }

  /// Rebuilds the sidebar against the current time. Call it when a clock-derived boundary may have
  /// passed (a minute tick in the UI); snooze wakes re-arm themselves.
  public func refreshNow() { recompute() }

  private var allThreads: [EnvironmentThreadShell] {
    order.flatMap { id in
      let pending = Set((shells[id]?.v2?.threads ?? []).filter { ShellPresentation.isPending($0.status) }.map(\.id))
      return (shells[id]?.snapshot?.threads ?? []).filter { $0.archivedAt == nil }.map {
        EnvironmentThreadShell(environmentId: id, shell: $0, startPending: pending.contains($0.id))
      }
    }
  }

  private func recompute() {
    let now = clock.nowISO()
    projects = order.flatMap { id in
      (shells[id]?.snapshot?.projects ?? []).map { EnvironmentProject(environmentId: id, project: $0) }
    }
    projectGroups = ProjectGrouping.buildGroups(
      projects: projects, settings: projectGrouping,
      connectedEnvironmentIds: Set(connectionStates.filter { $0.value.phase == .connected }.keys))
    sidebar = buildSidebar(now: now, filter: filter, projectRefs: filter.projectRefs)
    armSnoozeWake(sidebar.layout.nextSnoozeWakeAt, now: now)
  }

  /// A sidebar list for one project group (or all when nil), using the current filters.
  public func threadList(for group: ProjectGroup?) -> SidebarModel {
    var scoped = filter
    scoped.projectRefs = group?.memberProjectRefs ?? filter.projectRefs
    return buildSidebar(now: clock.nowISO(), filter: scoped, projectRefs: scoped.projectRefs)
  }

  private func buildSidebar(now: IsoDateTime, filter: SidebarFilter, projectRefs: [ScopedProjectRef]?) -> SidebarModel {
    // An environment whose config is not known yet counts as capable: servers only stamp what they support.
    func capable(_ keyPath: KeyPath<ExecutionEnvironmentCapabilities, Bool?>) -> Set<EnvironmentId> {
      Set(order.filter { id in serverConfigs[id].map { $0.config.environment.capabilities[keyPath: keyPath] == true } ?? true })
    }
    var input = ThreadListInput(
      threads: allThreads, environmentId: filter.environmentId, projectRefs: projectRefs, searchQuery: filter.searchQuery,
      matchedThreadKeys: matchedThreadKeys.isEmpty ? nil : matchedThreadKeys, settlementEnvironmentIds: capable(\.threadSettlement),
      snoozeEnvironmentIds: capable(\.threadSnooze), settledLimit: filter.settledLimit, now: now,
      snoozedShelfExpanded: filter.snoozedShelfExpanded, settledShelfExpanded: filter.settledShelfExpanded,
      selectedThreadKey: filter.selectedThread?.description)
    input.queuedThreadKeys = nil
    return SidebarModel.build(input: input, lastVisitedAtById: lastVisitedAtById)
  }

  /// One timer at the next snooze wake: no polling, the list re-partitions the moment a snooze expires.
  private func armSnoozeWake(_ wake: IsoDateTime?, now: IsoDateTime) {
    wakeTimer?.cancel()
    wakeTimer = nil
    guard let wake, let wakeMs = IsoTimestamp.parse(wake), let nowMs = IsoTimestamp.parse(now) else { return }
    let delay = max(0, wakeMs - nowMs) + 50
    let clock = clock
    wakeTimer = Task { [weak self] in
      do { try await clock.sleep(for: .milliseconds(Int64(min(delay, 2_147_483_647)))) } catch { return }
      self?.recompute()
    }
  }

  // MARK: Search

  /// Server-side content search across environments; title and pull-request search is local and immediate.
  private func searchChanged() {
    searchTask?.cancel()
    let query = filter.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      matchedThreadKeys = []
      return
    }
    let registry = registry, order = order
    searchTask = Task { [weak self] in
      var matches = Set<String>()
      for id in order {
        guard let runtime = await registry.runtime(for: id) else { continue }
        for match in await runtime.searchThreads(query: query) {
          matches.insert(ThreadList.matchKey(environmentId: id, threadId: match.threadId))
        }
      }
      if Task.isCancelled { return }
      self?.matchedThreadKeys = matches
      self?.scheduleRecompute()
    }
  }

  // MARK: Thread detail

  /// Opens a shared live subscription to one thread. Release it with `close()`.
  public func openThread(_ key: ScopedThreadKey) async -> ThreadDetailModel {
    let model = ThreadDetailModel(key: key)
    guard let runtime = await registry.runtime(for: key.environmentId) else { return model }
    let lease = await runtime.threads.acquire(key.threadId)
    let shellChanges = runtime.shell.changes()
    let threadId = key.threadId
    let shells = AsyncStream<V1.OrchestrationThreadShell?> { continuation in
      let task = Task {
        for await state in shellChanges { continuation.yield(state.snapshot?.threads.first { $0.id == threadId }) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    model.attach(lease: lease, shells: shells)
    return model
  }

  /// The thread shell for a key, from the displayed (optimistic) shell.
  public func threadShell(_ key: ScopedThreadKey) -> EnvironmentThreadShell? {
    shells[key.environmentId]?.snapshot?.threads.first { $0.id == key.threadId }.map {
      EnvironmentThreadShell(environmentId: key.environmentId, shell: $0)
    }
  }

  /// The protocol-2 record behind a thread row (queue state, goal, visited watermark, ...); nil on protocol 1.
  public func threadShellV2(_ key: ScopedThreadKey) -> OrchestrationV2ThreadShell? {
    shells[key.environmentId]?.v2?.threads.first { $0.id == key.threadId }
  }

  // MARK: Unread

  /// Reading a finished thread clears its unread badge: the visit is stamped at the completion
  /// time, so a later completion or wake still raises its own signal. `explicit` is the completion
  /// the reader is showing (the detail stream can be ahead of the shell); the later of it and the
  /// shell's wins. `markVisited` never moves the stamp backwards.
  public func markThreadRead(_ key: ScopedThreadKey, completedAt explicit: IsoDateTime? = nil) async {
    let shellCompletedAt = threadShell(key)?.shell.latestTurn?.completedAt
    let later = [explicit, shellCompletedAt].compactMap { $0 }.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    guard let completedAt = later else { return }
    await clientState.update { $0.markVisited(key.description, at: completedAt) }
  }

  public func markThreadUnread(_ key: ScopedThreadKey) async {
    let completedAt = threadShell(key)?.shell.latestTurn?.completedAt
    await clientState.update { $0.markUnread(key.description, latestTurnCompletedAt: completedAt) }
  }

  /// Clears the "woke" pill (the user re-engaged with the thread).
  public func acknowledgeWoke(_ key: ScopedThreadKey) async {
    guard let thread = threadShell(key), let wokeAt = ThreadSettled.threadWokeAt(thread.shell, now: clock.nowISO()) else { return }
    await clientState.update { $0.markVisited(key.description, at: wokeAt) }
  }
}
