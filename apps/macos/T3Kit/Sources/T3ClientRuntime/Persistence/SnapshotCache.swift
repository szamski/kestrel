import Foundation
import T3Contracts
import T3Protocol

/// Per-environment cache of synchronised data (`EnvironmentCacheStore` in client-runtime).
/// The cache is read once when a state machine is created and written from live data only; a
/// write never replaces a row that is already ahead of it.
public protocol SnapshotCache: Sendable {
  func loadShell(_ environmentId: EnvironmentId) async -> V1.OrchestrationShellSnapshot?
  func saveShell(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationShellSnapshot) async
  func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> V1.OrchestrationThreadDetailSnapshot?
  func saveThread(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationThreadDetailSnapshot) async
  func removeThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async
  func loadServerConfig(_ environmentId: EnvironmentId) async -> ServerConfig?
  func saveServerConfig(_ environmentId: EnvironmentId, _ config: ServerConfig) async
  /// Removes everything cached for the environment (explicit removal).
  func clearEnvironment(_ environmentId: EnvironmentId) async

  // Protocol 2 payloads. Shell and thread rows of one environment all belong to one protocol, the one
  // `adoptProtocol` last recorded; the V1 loads return nil while protocol 2 data is stored, and vice versa.
  func loadShellV2(_ environmentId: EnvironmentId) async -> OrchestrationV2ShellSnapshot?
  func saveShellV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ShellSnapshot) async
  func loadThreadV2(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> OrchestrationV2ThreadDetailSnapshot?
  func saveThreadV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ThreadDetailSnapshot) async
  /// The protocol of the cached shell and thread rows; nil when none were stored.
  func cachedProtocol(_ environmentId: EnvironmentId) async -> OrchestrationProtocol?
  /// Records the protocol the environment now speaks. When it differs from the stored one, the shell and
  /// thread rows (another contract shape and another sequence space) are dropped; returns whether they were.
  @discardableResult
  func adoptProtocol(_ environmentId: EnvironmentId, _ version: OrchestrationProtocol) async -> Bool
}

/// Discards everything; used when the cache cannot be opened and in tests that want a cold start.
public struct NoSnapshotCache: SnapshotCache {
  public init() {}
  public func loadShell(_ environmentId: EnvironmentId) async -> V1.OrchestrationShellSnapshot? { nil }
  public func saveShell(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationShellSnapshot) async {}
  public func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> V1.OrchestrationThreadDetailSnapshot? { nil }
  public func saveThread(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationThreadDetailSnapshot) async {}
  public func removeThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async {}
  public func loadServerConfig(_ environmentId: EnvironmentId) async -> ServerConfig? { nil }
  public func saveServerConfig(_ environmentId: EnvironmentId, _ config: ServerConfig) async {}
  public func clearEnvironment(_ environmentId: EnvironmentId) async {}
  public func loadShellV2(_ environmentId: EnvironmentId) async -> OrchestrationV2ShellSnapshot? { nil }
  public func saveShellV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ShellSnapshot) async {}
  public func loadThreadV2(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> OrchestrationV2ThreadDetailSnapshot? { nil }
  public func saveThreadV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ThreadDetailSnapshot) async {}
  public func cachedProtocol(_ environmentId: EnvironmentId) async -> OrchestrationProtocol? { nil }
  public func adoptProtocol(_ environmentId: EnvironmentId, _ version: OrchestrationProtocol) async -> Bool { false }
}

/// SQLite-backed cache (system `SQLite3`, no ORM). The schema is versioned: a mismatch drops the
/// tables and starts cold, since every cached value can be re-fetched.
public actor SQLiteSnapshotCache: SnapshotCache {
  /// Bump when a stored payload or table changes shape, including generated contract types.
  public static let schemaVersion = 2
  private let db: SQLiteDatabase
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  /// `path == nil` keeps the cache in memory.
  public init(path: String?) throws {
    if let path { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
    db = try SQLiteDatabase(path: path)
    if db.userVersion != Self.schemaVersion {
      for table in ["shell", "thread", "server_config", "environment_protocol"] { try db.execute("DROP TABLE IF EXISTS \(table)") }
      try db.setUserVersion(Self.schemaVersion)
    }
    try db.execute("PRAGMA journal_mode = WAL")
    try db.execute("CREATE TABLE IF NOT EXISTS shell(environment_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL, payload BLOB NOT NULL)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS thread(environment_id TEXT NOT NULL, thread_id TEXT NOT NULL, sequence INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(environment_id, thread_id))")
    try db.execute("CREATE TABLE IF NOT EXISTS server_config(environment_id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    try db.execute("CREATE TABLE IF NOT EXISTS environment_protocol(environment_id TEXT PRIMARY KEY, protocol INTEGER NOT NULL)")
  }

  public static func defaultPath(in directory: URL) -> String { directory.appendingPathComponent("snapshot-cache.sqlite").path }

  private func load<T: Decodable>(_ sql: String, _ bindings: [SQLiteDatabase.Value], as type: T.Type) -> T? {
    var data: Data?
    _ = try? db.run(sql, bindings) { data = $0.blob(0) }
    guard let data else { return nil }
    // An undecodable row (older contract shape) is a cold start, not an error.
    return try? decoder.decode(T.self, from: data)
  }

  /// A save for another protocol than the one stored is a late write from a replaced connection: dropped.
  private func accepts(_ environmentId: EnvironmentId, _ version: OrchestrationProtocol) -> Bool {
    switch storedProtocol(environmentId) {
    case nil:
      _ = try? db.run(
        "INSERT OR REPLACE INTO environment_protocol(environment_id, protocol) VALUES(?, ?)", [.text(environmentId.rawValue), .int(Int64(version.rawValue))])
      return true
    case let stored?: return stored == version
    }
  }

  private func storedProtocol(_ environmentId: EnvironmentId) -> OrchestrationProtocol? {
    var raw: Int64?
    _ = try? db.run("SELECT protocol FROM environment_protocol WHERE environment_id = ?", [.text(environmentId.rawValue)]) { raw = $0.int(0) }
    return raw.flatMap { OrchestrationProtocol(rawValue: Int($0)) }
  }

  public func cachedProtocol(_ environmentId: EnvironmentId) -> OrchestrationProtocol? { storedProtocol(environmentId) }

  @discardableResult
  public func adoptProtocol(_ environmentId: EnvironmentId, _ version: OrchestrationProtocol) -> Bool {
    let stored = storedProtocol(environmentId)
    if stored == version { return false }
    if stored != nil {
      for table in ["shell", "thread"] { _ = try? db.run("DELETE FROM \(table) WHERE environment_id = ?", [.text(environmentId.rawValue)]) }
    }
    _ = try? db.run(
      "INSERT OR REPLACE INTO environment_protocol(environment_id, protocol) VALUES(?, ?)", [.text(environmentId.rawValue), .int(Int64(version.rawValue))])
    return stored != nil
  }

  public func loadShellV2(_ environmentId: EnvironmentId) -> OrchestrationV2ShellSnapshot? {
    guard storedProtocol(environmentId) == .v2 else { return nil }
    return load("SELECT payload FROM shell WHERE environment_id = ?", [.text(environmentId.rawValue)], as: OrchestrationV2ShellSnapshot.self)
  }

  public func saveShellV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ShellSnapshot) {
    guard accepts(environmentId, .v2), let payload = try? encoder.encode(snapshot) else { return }
    _ = try? db.run(
      """
      INSERT INTO shell(environment_id, sequence, payload) VALUES(?, ?, ?)
      ON CONFLICT(environment_id) DO UPDATE SET sequence = excluded.sequence, payload = excluded.payload
      WHERE excluded.sequence >= shell.sequence
      """, [.text(environmentId.rawValue), .int(Int64(snapshot.snapshotSequence)), .blob(payload)])
  }

  public func loadThreadV2(_ environmentId: EnvironmentId, _ threadId: ThreadId) -> OrchestrationV2ThreadDetailSnapshot? {
    guard storedProtocol(environmentId) == .v2 else { return nil }
    return load(
      "SELECT payload FROM thread WHERE environment_id = ? AND thread_id = ?", [.text(environmentId.rawValue), .text(threadId.rawValue)],
      as: OrchestrationV2ThreadDetailSnapshot.self)
  }

  public func saveThreadV2(_ environmentId: EnvironmentId, _ snapshot: OrchestrationV2ThreadDetailSnapshot) {
    guard accepts(environmentId, .v2), let payload = try? encoder.encode(snapshot) else { return }
    _ = try? db.run(
      """
      INSERT INTO thread(environment_id, thread_id, sequence, payload) VALUES(?, ?, ?, ?)
      ON CONFLICT(environment_id, thread_id) DO UPDATE SET sequence = excluded.sequence, payload = excluded.payload
      WHERE excluded.sequence >= thread.sequence
      """,
      [.text(environmentId.rawValue), .text(snapshot.projection.thread.id.rawValue), .int(Int64(snapshot.snapshotSequence)), .blob(payload)])
  }

  public func loadShell(_ environmentId: EnvironmentId) -> V1.OrchestrationShellSnapshot? {
    guard storedProtocol(environmentId) != .v2 else { return nil }
    return load("SELECT payload FROM shell WHERE environment_id = ?", [.text(environmentId.rawValue)], as: V1.OrchestrationShellSnapshot.self)
  }

  public func saveShell(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationShellSnapshot) {
    guard accepts(environmentId, .v1), let payload = try? encoder.encode(snapshot) else { return }
    _ = try? db.run(
      """
      INSERT INTO shell(environment_id, sequence, payload) VALUES(?, ?, ?)
      ON CONFLICT(environment_id) DO UPDATE SET sequence = excluded.sequence, payload = excluded.payload
      WHERE excluded.sequence >= shell.sequence
      """, [.text(environmentId.rawValue), .int(Int64(snapshot.snapshotSequence)), .blob(payload)])
  }

  public func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) -> V1.OrchestrationThreadDetailSnapshot? {
    guard storedProtocol(environmentId) != .v2 else { return nil }
    return load("SELECT payload FROM thread WHERE environment_id = ? AND thread_id = ?", [.text(environmentId.rawValue), .text(threadId.rawValue)], as: V1.OrchestrationThreadDetailSnapshot.self)
  }

  public func saveThread(_ environmentId: EnvironmentId, _ snapshot: V1.OrchestrationThreadDetailSnapshot) {
    guard accepts(environmentId, .v1), let payload = try? encoder.encode(snapshot) else { return }
    _ = try? db.run(
      """
      INSERT INTO thread(environment_id, thread_id, sequence, payload) VALUES(?, ?, ?, ?)
      ON CONFLICT(environment_id, thread_id) DO UPDATE SET sequence = excluded.sequence, payload = excluded.payload
      WHERE excluded.sequence >= thread.sequence
      """, [.text(environmentId.rawValue), .text(snapshot.thread.id.rawValue), .int(Int64(snapshot.snapshotSequence)), .blob(payload)])
  }

  public func removeThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) {
    _ = try? db.run("DELETE FROM thread WHERE environment_id = ? AND thread_id = ?", [.text(environmentId.rawValue), .text(threadId.rawValue)])
  }

  public func loadServerConfig(_ environmentId: EnvironmentId) -> ServerConfig? {
    load("SELECT payload FROM server_config WHERE environment_id = ?", [.text(environmentId.rawValue)], as: ServerConfig.self)
  }

  public func saveServerConfig(_ environmentId: EnvironmentId, _ config: ServerConfig) {
    guard let payload = try? encoder.encode(ServerConfigProjection.withoutEnvironmentThemes(config)) else { return }
    _ = try? db.run(
      "INSERT INTO server_config(environment_id, payload) VALUES(?, ?) ON CONFLICT(environment_id) DO UPDATE SET payload = excluded.payload",
      [.text(environmentId.rawValue), .blob(payload)])
  }

  public func clearEnvironment(_ environmentId: EnvironmentId) {
    for table in ["shell", "thread", "server_config", "environment_protocol"] {
      _ = try? db.run("DELETE FROM \(table) WHERE environment_id = ?", [.text(environmentId.rawValue)])
    }
  }
}
