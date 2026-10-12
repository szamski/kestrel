import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// The UI-facing runtime end to end over a fake server: sidebar sections, optimistic commands, thread detail, unread.
@Suite(.timeLimit(.minutes(1))) @MainActor struct ClientRuntimeTests {
  func makeRuntime(server: FakeServer, shell: V1.OrchestrationShellSnapshot = Data2.shell(), thread: V1.OrchestrationThreadDetailSnapshot? = nil) async throws -> ClientRuntime {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-client-\(UUID().uuidString)")
    let config = Fixtures.serverConfig()
    try EnvironmentCatalogFile(directory: directory).save([
      EnvironmentConnectionEntry(environmentId: config.environment.environmentId, label: "Box", httpBaseURL: URL(string: "http://localhost:1")!, wsBaseURL: URL(string: "ws://localhost:1")!)
    ])
    let clientState = ClientStateStore(directory: directory)
    let driver = FakeServerDriver([server])
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: InMemoryCredentialStore(), cache: try SQLiteSnapshotCache(path: nil),
      clientState: clientState, loader: FakeLoader(shell: shell, thread: thread), clock: ManualClock(), keepRunningThreadsMounted: false,
      makeDriver: { _, _ in driver })
    let runtime = ClientRuntime(registry: registry, clientState: clientState, clock: ManualClock())
    await runtime.start()
    return runtime
  }

  func until(_ condition: @MainActor () -> Bool) async { while !condition() { await Task.yield() } }

  @Test func sidebarSectionsFillFromTheShellAndSettleMovesARowAtOnce() async throws {
    let server = FakeServer()
    var shell = Data2.shell()
    // Make the first thread a clean active one so it can be settled.
    shell.threads[0].settledOverride = nil
    shell.threads[0].session = nil
    shell.threads[0].hasPendingApprovals = false
    shell.threads[0].hasPendingUserInput = false
    shell.threads[0].latestUserMessageAt = nil
    shell.threads[0].pinnedAt = .some(nil)
    shell.threads[0].snoozedUntil = .some(nil)
    shell.threads[0].archivedAt = nil
    let runtime = try await makeRuntime(server: server, shell: shell)
    let subscribe = await server.waitForRequest("orchestration.subscribeShell")
    try server.chunk(subscribe, items: [V1.OrchestrationShellStreamItem.synchronized])

    await until { runtime.sidebar.rows.count > 0 && runtime.environments.first?.connection.phase == .connected }
    #expect(runtime.environments.first?.label == "Box")
    #expect(!runtime.sidebar.settled.isEmpty && runtime.sidebar.active.contains { $0.thread.shell.id == shell.threads[0].id })
    #expect(!runtime.projectGroups.isEmpty)
    let key = ScopedThreadKey(environmentId: runtime.environments[0].environmentId, threadId: shell.threads[0].id)

    // Settling shows immediately, before the server answers; a rejection rolls it back.
    let settling = Task { try await runtime.settleThread(key) }
    let request = await server.waitForRequest("orchestration.dispatchCommand")
    await until { runtime.sidebar.settled.contains { $0.thread.shell.id == key.threadId } }
    #expect(!runtime.sidebar.active.contains { $0.thread.shell.id == key.threadId })
    server.fail(request, error: ["_tag": "OrchestrationDispatchCommandError", "message": "nope"])
    do { try await settling.value; Issue.record("expected a rejection") } catch { #expect((error as? CommandError) == .rejected(message: "nope")) }
    await until { runtime.sidebar.active.contains { $0.thread.shell.id == key.threadId } }
    await runtime.stop()
  }

  @Test func unreadAndWokeFlagsComeFromClientOwnedVisitsAndClearWhenRead() async throws {
    let server = FakeServer()
    var shell = Data2.shell()
    shell.threads[0].settledOverride = nil
    shell.threads[0].latestTurn = V1.OrchestrationLatestTurn(
      turnId: "t", state: .completed, requestedAt: "2026-10-08T11:00:00.000Z", completedAt: "2026-10-08T12:00:00.000Z")
    let runtime = try await makeRuntime(server: server, shell: shell)
    let subscribe = await server.waitForRequest("orchestration.subscribeShell")
    try server.chunk(subscribe, items: [V1.OrchestrationShellStreamItem.synchronized])
    await until { runtime.sidebar.rows.count > 0 }
    let key = ScopedThreadKey(environmentId: runtime.environments[0].environmentId, threadId: shell.threads[0].id)
    func row() -> SidebarRow? { runtime.sidebar.rows.first { $0.thread.shell.id == key.threadId } }

    #expect(row()?.isUnread == false, "never visited counts as read")
    await runtime.markThreadUnread(key)
    await until { row()?.isUnread == true }
    await runtime.markThreadRead(key)
    await until { row()?.isUnread == false }
    #expect(runtime.lastVisitedAtById[key.description]?.rawValue == "2026-10-08T12:00:00.000Z")
    await runtime.stop()
  }

  @Test func openThreadSharesTheLiveStreamAndMergesTheShellMetadata() async throws {
    let server = FakeServer()
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    let snapshot = try decode(V1.OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!)
    var shell = Data2.shell()
    var threadShell = shell.threads[0]
    threadShell.id = snapshot.thread.id
    threadShell.title = "Shell title wins"
    shell.threads[0] = threadShell
    let runtime = try await makeRuntime(server: server, shell: shell, thread: snapshot)
    let key = ScopedThreadKey(environmentId: Fixtures.serverConfig().environment.environmentId, threadId: snapshot.thread.id)
    let detail = await runtime.openThread(key)
    let request = await server.waitForRequest("orchestration.subscribeThread")
    try server.chunk(request, items: [V1.OrchestrationThreadStreamItem.synchronized])
    await until { detail.state.status == .live && detail.thread?.title == "Shell title wins" }
    #expect(detail.thread?.messages.isEmpty == false, "messages come from the detail, metadata from the shell")
    await detail.close()
    await runtime.stop()
  }

  @Test func removingAnEnvironmentDropsItsStateFromTheModel() async throws {
    let server = FakeServer()
    let runtime = try await makeRuntime(server: server)
    let subscribe = await server.waitForRequest("orchestration.subscribeShell")
    try server.chunk(subscribe, items: [V1.OrchestrationShellStreamItem.synchronized])
    await until { runtime.hasShellData }
    let id = runtime.environments[0].environmentId
    await runtime.removeEnvironment(id)
    await until { runtime.environments.isEmpty && runtime.shells.isEmpty && runtime.sidebar.rows.isEmpty }
    await runtime.stop()
  }

  /// The app starts the saved local environment before its server is up, then registers the same environment
  /// again; the model has to follow the replacement runtime, not the stopped one (it stayed in backoff forever).
  /// A thread opened meanwhile (the restored selection) follows too: on the stopped runtime it stayed `cached` and
  /// every "load earlier" failed with "Environment is not connected".
  @Test func registeringAnEnvironmentAgainMakesTheModelFollowTheReplacementRuntime() async throws {
    let config = Fixtures.serverConfig()
    let descriptor = try JSONSerialization.data(withJSONObject: [
      "environmentId": config.environment.environmentId.rawValue, "label": "Box", "serverVersion": "9.9.9", "orchestrationProtocolVersion": 1,
    ])
    let token = Data(#"{"access_token":"bearer","token_type":"Bearer","expires_in":3600,"scope":"orchestration:read"}"#.utf8)
    StubProtocol.install(host: "replaced.test") { request in (200, request.url.path == "/oauth/token" ? token : descriptor) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-client-\(UUID().uuidString)")
    let base = URL(string: "http://replaced.test:1")!
    try EnvironmentCatalogFile(directory: directory).save([
      EnvironmentConnectionEntry(environmentId: config.environment.environmentId, label: "Box", httpBaseURL: base, wsBaseURL: URL(string: "ws://replaced.test:1")!)
    ])
    let clientState = ClientStateStore(directory: directory)
    let server = FakeServer()
    let launches = Mutex(0)
    let scenario = try Oracle.load(Oracle.directory(raw: false), "scenarios", "thread-synthetic-live")
    let snapshot = try decode(V1.OrchestrationThreadDetailSnapshot.self, scenario["snapshot"]!)
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: InMemoryCredentialStore(), cache: try SQLiteSnapshotCache(path: nil),
      clientState: clientState, loader: FakeLoader(shell: Data2.shell(), thread: snapshot), clock: ManualClock(), keepRunningThreadsMounted: false,
      httpSession: StubProtocol.session(),
      makeDriver: { _, _ in launches.withLock { $0 += 1; return $0 } == 1 ? FakeServerDriver([]) : FakeServerDriver([server]) })
    let runtime = ClientRuntime(registry: registry, clientState: clientState, clock: ManualClock(), reportsActivity: false)
    await runtime.start()
    await until { runtime.environments.first?.connection.phase == .backoff }
    let detail = await runtime.openThread(ScopedThreadKey(environmentId: config.environment.environmentId, threadId: snapshot.thread.id))

    try await runtime.addLocalEnvironment(baseURL: base, bootstrapToken: "boot", label: "This Mac", clientLabel: "Kestrel")
    await until { runtime.environments.first?.connection.phase == .connected }
    #expect(runtime.environments.count == 1 && runtime.environments[0].label == "This Mac")
    let request = await server.waitForRequest("orchestration.subscribeThread")
    try server.chunk(request, items: [V1.OrchestrationThreadStreamItem.synchronized])
    await until { detail.state.status == .live }
    await detail.close()
    await runtime.stop()
  }
}
