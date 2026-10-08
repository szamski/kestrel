import Foundation
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

// Opt-in, read-only: T3_LIVE_SERVER=http://localhost:13773 T3_LIVE_TOKEN_FILE=<path to bootstrap credential>.
// The server holds a copy of real data: this test pairs, syncs and reads. It never dispatches a command
// and never reports activity. The credential lives in memory only (no Keychain item is created).
private let liveEnabled = ProcessInfo.processInfo.environment["T3_LIVE_SERVER"] != nil

@Suite(.timeLimit(.minutes(2))) @MainActor struct LiveServerRuntimeTests {
  @Test(.enabled(if: liveEnabled))
  func pairSyncShellAndOpenOneThread() async throws {
    let env = ProcessInfo.processInfo.environment
    let server = try #require(env["T3_LIVE_SERVER"])
    let tokenFile = try #require(env["T3_LIVE_TOKEN_FILE"])
    let credential = try String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-live-\(UUID().uuidString)")
    let clientState = ClientStateStore(directory: directory)
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: InMemoryCredentialStore(),
      cache: try SQLiteSnapshotCache(path: SQLiteSnapshotCache.defaultPath(in: directory)), clientState: clientState)
    let runtime = ClientRuntime(registry: registry, clientState: clientState, reportsActivity: false)
    await runtime.start()

    let entry = try await runtime.addEnvironment(host: server, pairingCode: credential)
    while runtime.environments.first?.connection.phase != .connected { await Task.yield() }
    #expect(runtime.environments.first?.environmentId == entry.environmentId)

    // Shell: HTTP snapshot, subscribeShell with a completion marker, replay, synchronized.
    while runtime.shells[entry.environmentId]?.status != .live { await Task.yield() }
    let shell = try #require(runtime.shells[entry.environmentId]?.snapshot)
    #expect(!shell.threads.isEmpty && !shell.projects.isEmpty)
    #expect(runtime.serverConfigs[entry.environmentId] != nil)

    // Sidebar sections derive from the live shell.
    runtime.refreshNow()
    while runtime.sidebar.rows.isEmpty { await Task.yield() }
    let counts = [runtime.sidebar.pinned.count, runtime.sidebar.active.count, runtime.sidebar.snoozed.count, runtime.sidebar.settled.count]
    #expect(counts.reduce(0, +) == runtime.sidebar.rows.count && !runtime.sidebar.isEmpty)
    #expect(!runtime.projectGroups.isEmpty)

    // Thread detail: windowed HTTP snapshot, subscribeThread, synchronized.
    let row = try #require(runtime.sidebar.rows.first)
    let detail = await runtime.openThread(row.thread.key)
    while detail.state.status != .live { await Task.yield() }
    #expect(detail.thread?.id == row.thread.shell.id)
    #expect(detail.thread?.messages.isEmpty == false || detail.thread?.activities.isEmpty == false || detail.state.data != nil)
    await detail.close()
    await runtime.stop()
  }
}
