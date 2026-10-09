import Foundation
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// Scope resolution, patch planning and optimistic apply: the rules that decide which server gets which write.
@Suite struct SettingsPlannerTests {
  let envA = EnvironmentId("env-a"), envB = EnvironmentId("env-b")

  func target(_ id: EnvironmentId, connected: Bool = true, overrides: Bool = true, edit: (inout ServerSettings) -> Void = { _ in }) -> SettingsTargetEnvironment {
    var config = Fixtures.serverConfig()
    var settings = config.settings
    settings.projectSettingsOverrides = [:]
    edit(&settings)
    config.environment.capabilities.projectSettingsOverrides = overrides
    return SettingsTargetEnvironment(
      environmentId: id, label: id.rawValue, connected: connected, settings: settings, capabilities: config.environment.capabilities)
  }

  func status(_ id: EnvironmentId) -> EnvironmentStatus { EnvironmentStatus(environmentId: id, label: id.rawValue, enabled: true, connection: .available) }

  func group(root: String) -> (groups: [ProjectGroup], projectId: ProjectId) {
    var shell = Data2.shell().projects[0]
    shell.workspaceRoot = root
    let projects = [envA, envB].map { EnvironmentProject(environmentId: $0, project: shell) }
    return (ProjectGrouping.buildGroups(projects: projects, settings: ProjectGroupingSettings(mode: .separate)), shell.id)
  }

  @Test func aMissingTargetIsUnavailableAndNeverFallsBackToAnotherScope() {
    let environments = [status(envA), status(envB)]
    #expect(SettingsScope.resolve(SettingsScopeSearch(), groups: [], environments: environments).environmentIds == [envA, envB])
    let gone = SettingsScope.resolve(SettingsScopeSearch(machine: "env-gone"), groups: [], environments: environments)
    #expect(gone.kind == .unavailable && gone.environmentIds.isEmpty)
    #expect(SettingsScope.resolve(SettingsScopeSearch(checkout: "x"), groups: [], environments: environments).kind == .unavailable)
    #expect(SettingsScope.resolve(SettingsScopeSearch(project: "nope"), groups: [], environments: environments).kind == .unavailable)
    #expect(SettingsScope.resolve(SettingsScopeSearch(machine: "env-b"), groups: [], environments: environments).environmentIds == [envB])
  }

  @Test func environmentScopeWritesOnlyToConnectedSelectedEnvironments() {
    let environments = [target(envA), target(envB, connected: false)]
    let patch = ServerSettingsPatch(responseStreamingMode: .paragraph)
    let all = SettingsScope.resolve(SettingsScopeSearch(), groups: [], environments: [status(envA), status(envB)])
    #expect(SettingsPlanner.plan(patch, scope: all, environments: environments).writes.map(\.environmentId) == [envA])
    let offline = SettingsScope.resolve(SettingsScopeSearch(machine: "env-b"), groups: [], environments: [status(envA), status(envB)])
    let plan = SettingsPlanner.plan(patch, scope: offline, environments: environments)
    #expect(plan.writes.isEmpty && plan.unavailableReason != nil)
  }

  @Test func projectScopeWritesOverridesAndRejectsEnvironmentWideKeys() throws {
    let (groups, projectId) = group(root: "/ws/app")
    let scope = SettingsScope.resolve(SettingsScopeSearch(project: groups[0].key, machine: "env-a"), groups: groups, environments: [status(envA), status(envB)])
    #expect(scope.kind == .project)
    let environments = [target(envA), target(envB)]

    let blocked = SettingsPlanner.plan(ServerSettingsPatch(enableProviderUpdateChecks: false), scope: scope, environments: environments)
    #expect(blocked.writes.isEmpty && blocked.unavailableReason?.contains("environment-wide") == true)

    let plan = SettingsPlanner.plan(ServerSettingsPatch(defaultRuntimeMode: .fullAccess), scope: scope, environments: environments)
    #expect(plan.writes.map(\.environmentId) == [envA])
    let entry = try #require(plan.writes[0].patch.projectSettingsOverrides?[projectId.rawValue] ?? nil)
    #expect(entry.defaultRuntimeMode == .fullAccess)

    // The override is then the project's effective value and the environment keeps its own.
    var edited = environments[0].settings!
    edited.projectSettingsOverrides[projectId.rawValue] = try JSONDecoder().decode(
      ServerSettingsProjectSettingsOverridesValue.self, from: JSONEncoder().encode(entry))
    let effective = SettingsPlanner.effective(edited, projectId: projectId)
    #expect(effective.settings.defaultRuntimeMode == .fullAccess && effective.overridden == ["defaultRuntimeMode"])
    #expect(edited.defaultRuntimeMode == environments[0].settings!.defaultRuntimeMode)
  }

  @Test func inheritingDropsAnOverrideExceptWhereNullIsAStoredValue() throws {
    let (groups, projectId) = group(root: "/ws/app")
    let scope = SettingsScope.resolve(SettingsScopeSearch(project: groups[0].key, machine: "env-a"), groups: groups, environments: [status(envA)])
    let withOverride = target(envA) {
      $0.projectSettingsOverrides[projectId.rawValue] = try! JSONDecoder().decode(
        ServerSettingsProjectSettingsOverridesValue.self, from: Data(#"{"defaultRuntimeMode":"auto","sidebarAutoSettleAfterDays":5}"#.utf8))
    }
    // null for `defaultRuntimeMode` is not a value: the override goes away.
    var inherit = ServerSettingsPatch()
    inherit.worktreeSubmodules = .some(nil)
    let dropped = SettingsPlanner.plan(inherit, scope: scope, environments: [withOverride])
    #expect(dropped.writes.count == 1)
    // null for `sidebarAutoSettleAfterDays` is "never settle": it is stored.
    let never = SettingsPlanner.plan(ServerSettingsPatch(sidebarAutoSettleAfterDays: .some(nil)), scope: scope, environments: [withOverride])
    let entry = try #require(never.writes[0].patch.projectSettingsOverrides?[projectId.rawValue] ?? nil)
    #expect(entry.sidebarAutoSettleAfterDays == .some(nil) && entry.defaultRuntimeMode == .auto)

    let cleared = SettingsPlanner.clearOverrides(keys: ["defaultRuntimeMode"], scope: scope, environments: [withOverride])
    let remaining = try #require(cleared.writes[0].patch.projectSettingsOverrides?[projectId.rawValue] ?? nil)
    #expect(remaining.defaultRuntimeMode == nil && remaining.sidebarAutoSettleAfterDays == .some(5))
    #expect(SettingsPlanner.plan(ServerSettingsPatch(defaultRuntimeMode: .auto), scope: scope, environments: [target(envA, overrides: false)]).writes.isEmpty)
  }

  @Test func anOptimisticEditMergesLikeTheServerDoes() throws {
    var settings = target(envA).settings!
    settings.sidebarAutoSettleAfterDays = 3
    settings.backgroundActivity = try JSONDecoder().decode(
      BackgroundActivitySettings.self, from: Data(#"{"schemaVersion":1,"profile":"custom","baseProfile":"balanced","overrides":{"automaticGitFetchInterval":30}}"#.utf8))

    var patch = ServerSettingsPatch(responseStreamingMode: .token, sidebarAutoSettleAfterDays: .some(nil))
    patch.backgroundActivity = ServerSettingsPatchBackgroundActivity(schemaVersion: 1, profile: .batterySaver, overrides: ServerSettingsPatchBackgroundActivityOverrides())
    let next = try #require(SettingsPlanner.applying(patch, to: settings))
    #expect(next.responseStreamingMode == .token)
    #expect(next.sidebarAutoSettleAfterDays == nil)
    #expect(next.backgroundActivity.profile == .batterySaver && next.backgroundActivity.overrides.automaticGitFetchInterval == nil, "the policy is replaced, not merged")
    #expect(next.addProjectBaseDirectory == settings.addProjectBaseDirectory)

    var entry = ServerSettingsPatch()
    entry.projectSettingsOverrides = ["p1": .some(ProjectSettingsOverrides(defaultRuntimeMode: .auto))]
    let withEntry = try #require(SettingsPlanner.applying(entry, to: settings))
    #expect(withEntry.projectSettingsOverrides["p1"]?.defaultRuntimeMode == .auto)
    var removal = ServerSettingsPatch()
    removal.projectSettingsOverrides = ["p1": nil]
    #expect(SettingsPlanner.applying(removal, to: withEntry)?.projectSettingsOverrides["p1"] == nil)
  }

  @Test func theBackgroundPolicyResolvesPresetsAndOverrides() {
    var settings = target(envA).settings!
    #expect(BackgroundActivityPolicy.matchingProfile(settings) == .balanced && BackgroundActivityPolicy.isDefault(settings))
    let preset = SettingsPlanner.applying(BackgroundActivityPolicy.profilePatch(.batterySaver), to: settings)!
    #expect(BackgroundActivityPolicy.matchingProfile(preset) == .batterySaver)
    settings = SettingsPlanner.applying(
      BackgroundActivityPolicy.overridePatch(settings) { $0.automaticGitFetchInterval = 45_000 }, to: settings)!
    #expect(BackgroundActivityPolicy.matchingProfile(settings) == nil, "an interval off the preset is Advanced")
    #expect(BackgroundActivityPolicy.resolved(settings).automaticGitFetchInterval == 45_000)
    let shared = SettingsPlanner.applying(BackgroundActivityPolicy.sharedPolicyPatch(settings, profile: .performance), to: settings)!
    #expect(BackgroundActivityPolicy.resolved(shared).profile == .performance && BackgroundActivityPolicy.resolved(shared).automaticGitFetchInterval == 45_000)
  }

  @Test func sharedPreferencesFanOutToCapableEnvironmentsAndOtherKeysStayLocal() {
    let capable = { (id: EnvironmentId, restart: Bool) -> SettingsTargetEnvironment in
      var environment = self.target(id)
      environment.capabilities?.threadAutoSettlement = true
      environment.capabilities?.threadRestartContinuation = restart
      return environment
    }
    var legacy = target(envB)
    legacy.capabilities?.threadAutoSettlement = false
    let patch = ServerSettingsPatch(
      enableProviderUpdateChecks: false, continueThreadsAfterServerUpdate: true, sidebarAutoSettleOnMerge: false)
    let plan = SettingsPlanner.fanOut(patch, from: envA, environments: [capable(envA, true), capable(EnvironmentId("env-c"), false), legacy])
    #expect(plan.writes.map(\.environmentId.rawValue) == ["env-a", "env-c"])
    #expect(SettingsPlanner.keys(of: plan.writes[0].patch) == ["continueThreadsAfterServerUpdate", "enableProviderUpdateChecks", "sidebarAutoSettleOnMerge"])
    #expect(SettingsPlanner.keys(of: plan.writes[1].patch) == ["sidebarAutoSettleOnMerge"], "no restart continuation there, and the local key stays on the source")
  }
}

/// The runtime shows a server-settings edit at once and undoes it when the server refuses.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ServerSettingsUpdateTests {
  func makeRuntime(server: FakeServer) async throws -> ClientRuntime {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-settings-\(UUID().uuidString)")
    let config = Fixtures.serverConfig()
    try EnvironmentCatalogFile(directory: directory).save([
      EnvironmentConnectionEntry(environmentId: config.environment.environmentId, label: "Box", httpBaseURL: URL(string: "http://localhost:1")!, wsBaseURL: URL(string: "ws://localhost:1")!)
    ])
    let clientState = ClientStateStore(directory: directory)
    let driver = FakeServerDriver([server])
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: InMemoryCredentialStore(), cache: try SQLiteSnapshotCache(path: nil),
      clientState: clientState, loader: FakeLoader(shell: Data2.shell()), clock: ManualClock(), keepRunningThreadsMounted: false,
      makeDriver: { _, _ in driver })
    let runtime = ClientRuntime(registry: registry, clientState: clientState, clock: ManualClock())
    await runtime.start()
    return runtime
  }

  func until(_ condition: @MainActor () -> Bool) async { while !condition() { await Task.yield() } }

  @Test func anEditShowsAtOnceKeepsTheServersAnswerAndRollsBackWhenRefused() async throws {
    let server = FakeServer()
    let runtime = try await makeRuntime(server: server)
    let id = Fixtures.serverConfig().environment.environmentId
    await until { runtime.serverConfigs[id] != nil && runtime.environments.first?.connection.phase == .connected }
    let original = try #require(runtime.serverConfigs[id]?.config.settings)
    let changed: ServerSettingsResponseStreamingMode = original.responseStreamingMode == .token ? .turn : .token
    func shown() -> ServerSettingsResponseStreamingMode? { runtime.serverConfigs[id]?.config.settings.responseStreamingMode }

    let saving = Task { try await runtime.updateServerSettings(environmentId: id, patch: ServerSettingsPatch(responseStreamingMode: changed)) }
    let accepted = await server.waitForRequest("server.updateSettings")
    await until { shown() == changed }
    var answer = original
    answer.responseStreamingMode = changed
    server.succeed(accepted, try toAny(answer))
    try await saving.value
    #expect(shown() == changed)

    let refused = Task { try await runtime.updateServerSettings(environmentId: id, patch: ServerSettingsPatch(responseStreamingMode: original.responseStreamingMode)) }
    let rejected = await server.waitForRequest("server.updateSettings", count: 2)
    await until { shown() == original.responseStreamingMode }
    server.fail(rejected, error: ["_tag": "ServerSettingsError", "settingsPath": "/x", "operation": "write", "cause": "nope"])
    let reread = await server.waitForRequest("server.getSettings")
    server.succeed(reread, try toAny(answer))
    do { try await refused.value; Issue.record("expected a rejection") } catch { #expect(error is CommandError) }
    await until { shown() == changed }
    await runtime.stop()
  }
}
