import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct PersistenceTests {
  func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t3-runtime-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  let env = EnvironmentId(rawValue: "env-1")

  @Test func aCacheWriteNeverReplacesNewerData() async throws {
    let cache = try SQLiteSnapshotCache(path: nil)
    var shell = Data2.shell()
    shell.snapshotSequence = 10
    await cache.saveShell(env, shell)
    shell.snapshotSequence = 5
    shell.threads = []
    await cache.saveShell(env, shell)
    #expect(await cache.loadShell(env)?.snapshotSequence == 10)
    #expect(await cache.loadShell(env)?.threads.isEmpty == false)
    shell.snapshotSequence = 11
    await cache.saveShell(env, shell)
    #expect(await cache.loadShell(env)?.snapshotSequence == 11)

    var thread = Data2.threadDetail()
    let id = thread.thread.id
    thread.snapshotSequence = 20
    await cache.saveThread(env, thread)
    thread.snapshotSequence = 3
    await cache.saveThread(env, thread)
    #expect(await cache.loadThread(env, id)?.snapshotSequence == 20)
    await cache.removeThread(env, id)
    #expect(await cache.loadThread(env, id) == nil)
  }

  @Test func aSchemaVersionMismatchStartsCold() async throws {
    let path = tempDirectory().appendingPathComponent("cache.sqlite").path
    do {
      let cache = try SQLiteSnapshotCache(path: path)
      await cache.saveShell(env, Data2.shell())
      #expect(await cache.loadShell(env) != nil)
    }
    let db = try SQLiteDatabase(path: path)
    try db.setUserVersion(SQLiteSnapshotCache.schemaVersion + 1)
    let reopened = try SQLiteSnapshotCache(path: path)
    #expect(await reopened.loadShell(env) == nil, "an incompatible cache is dropped, not misread")
    await reopened.saveShell(env, Data2.shell())
    #expect(await reopened.loadShell(env) != nil)
  }

  @Test func theCacheSurvivesReopeningAndIsKeyedByEnvironment() async throws {
    let path = tempDirectory().appendingPathComponent("cache.sqlite").path
    do {
      let cache = try SQLiteSnapshotCache(path: path)
      await cache.saveShell(env, Data2.shell())
      await cache.saveServerConfig(env, Fixtures.serverConfig())
    }
    let cache = try SQLiteSnapshotCache(path: path)
    #expect(await cache.loadShell(env)?.threads.count == 25)
    #expect(await cache.loadShell(EnvironmentId(rawValue: "other")) == nil)
    #expect(await cache.loadServerConfig(env)?.environment.environmentId == Fixtures.serverConfig().environment.environmentId)
    await cache.clearEnvironment(env)
    let shellAfter = await cache.loadShell(env), configAfter = await cache.loadServerConfig(env)
    #expect(shellAfter == nil && configAfter == nil)
  }

  @Test func publishedThemesAreNeverCached() async throws {
    var config = Fixtures.serverConfig()
    config.environmentThemes = [EnvironmentTheme(id: "t", name: "T", appearance: EnvironmentThemeAppearance(rawValue: "dark"))]
    let cache = try SQLiteSnapshotCache(path: nil)
    await cache.saveServerConfig(env, config)
    #expect(await cache.loadServerConfig(env)?.environmentThemes == nil)
  }

  @Test func theEnvironmentCatalogRoundTripsWithoutCredentials() throws {
    let file = EnvironmentCatalogFile(directory: tempDirectory())
    #expect(file.load().isEmpty)
    let entry = EnvironmentConnectionEntry(environmentId: env, label: "Box", httpBaseURL: URL(string: "https://box.local:3773/")!, wsBaseURL: URL(string: "wss://box.local:3773/")!, enabled: false)
    try file.save([entry])
    #expect(file.load() == [entry])
    let text = try String(contentsOf: file.url, encoding: .utf8)
    #expect(!text.lowercased().contains("token") && !text.contains("accessToken"), "only the Keychain holds bearer credentials")
  }

  @Test func clientStateIsWrittenDebouncedAndReloaded() async throws {
    let directory = tempDirectory()
    let clock = ManualClock()
    let store = ClientStateStore(directory: directory, clock: clock)
    await store.update { $0.markVisited("env-1:t", at: "2026-10-08T12:00:00.000Z") }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("client-state.json").path), "nothing is written before the debounce")
    await store.flush()
    let reloaded = ClientStateStore(directory: directory, clock: clock)
    #expect(reloaded.state.value.threadLastVisitedAtById["env-1:t"]?.rawValue == "2026-10-08T12:00:00.000Z")
  }
}
