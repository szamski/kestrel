import Foundation
import T3Contracts

/// Per-environment cache of synchronised data (`EnvironmentCacheStore` in client-runtime).
/// The cache is read once when a state machine is created and written from live data only; a
/// write never replaces a row that is already ahead of it.
public protocol SnapshotCache: Sendable {
  func loadShell(_ environmentId: EnvironmentId) async -> OrchestrationShellSnapshot?
  func saveShell(_ environmentId: EnvironmentId, _ snapshot: OrchestrationShellSnapshot) async
  func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> OrchestrationThreadDetailSnapshot?
  func saveThread(_ environmentId: EnvironmentId, _ snapshot: OrchestrationThreadDetailSnapshot) async
  func removeThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async
  func loadServerConfig(_ environmentId: EnvironmentId) async -> ServerConfig?
  func saveServerConfig(_ environmentId: EnvironmentId, _ config: ServerConfig) async
  /// Removes everything cached for the environment (explicit removal).
  func clearEnvironment(_ environmentId: EnvironmentId) async
}

/// Discards everything; used when the cache cannot be opened and in tests that want a cold start.
public struct NoSnapshotCache: SnapshotCache {
  public init() {}
  public func loadShell(_ environmentId: EnvironmentId) async -> OrchestrationShellSnapshot? { nil }
  public func saveShell(_ environmentId: EnvironmentId, _ snapshot: OrchestrationShellSnapshot) async {}
  public func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async -> OrchestrationThreadDetailSnapshot? { nil }
  public func saveThread(_ environmentId: EnvironmentId, _ snapshot: OrchestrationThreadDetailSnapshot) async {}
  public func removeThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) async {}
  public func loadServerConfig(_ environmentId: EnvironmentId) async -> ServerConfig? { nil }
  public func saveServerConfig(_ environmentId: EnvironmentId, _ config: ServerConfig) async {}
  public func clearEnvironment(_ environmentId: EnvironmentId) async {}
}

/// SQLite-backed cache (system `SQLite3`, no ORM). The schema is versioned: a mismatch drops the
/// tables and starts cold, since every cached value can be re-fetched.
public actor SQLiteSnapshotCache: SnapshotCache {
  /// Bump when a stored payload or table changes shape, including generated contract types.
  public static let schemaVersion = 1
  private let db: SQLiteDatabase
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  /// `path == nil` keeps the cache in memory.
  public init(path: String?) throws {
    if let path { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
    db = try SQLiteDatabase(path: path)
    if db.userVersion != Self.schemaVersion {
      for table in ["shell", "thread", "server_config"] { try db.execute("DROP TABLE IF EXISTS \(table)") }
      try db.setUserVersion(Self.schemaVersion)
    }
    try db.execute("PRAGMA journal_mode = WAL")
    try db.execute("CREATE TABLE IF NOT EXISTS shell(environment_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL, payload BLOB NOT NULL)")
    try db.execute(
      "CREATE TABLE IF NOT EXISTS thread(environment_id TEXT NOT NULL, thread_id TEXT NOT NULL, sequence INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(environment_id, thread_id))")
    try db.execute("CREATE TABLE IF NOT EXISTS server_config(environment_id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
  }

  public static func defaultPath(in directory: URL) -> String { directory.appendingPathComponent("snapshot-cache.sqlite").path }

  private func load<T: Decodable>(_ sql: String, _ bindings: [SQLiteDatabase.Value], as type: T.Type) -> T? {
    var data: Data?
    _ = try? db.run(sql, bindings) { data = $0.blob(0) }
    guard let data else { return nil }
    // An undecodable row (older contract shape) is a cold start, not an error.
    return try? decoder.decode(T.self, from: data)
  }

  public func loadShell(_ environmentId: EnvironmentId) -> OrchestrationShellSnapshot? {
    load("SELECT payload FROM shell WHERE environment_id = ?", [.text(environmentId.rawValue)], as: OrchestrationShellSnapshot.self)
  }

  public func saveShell(_ environmentId: EnvironmentId, _ snapshot: OrchestrationShellSnapshot) {
    guard let payload = try? encoder.encode(snapshot) else { return }
    _ = try? db.run(
      """
      INSERT INTO shell(environment_id, sequence, payload) VALUES(?, ?, ?)
      ON CONFLICT(environment_id) DO UPDATE SET sequence = excluded.sequence, payload = excluded.payload
      WHERE excluded.sequence >= shell.sequence
      """, [.text(environmentId.rawValue), .int(Int64(snapshot.snapshotSequence)), .blob(payload)])
  }

  public func loadThread(_ environmentId: EnvironmentId, _ threadId: ThreadId) -> OrchestrationThreadDetailSnapshot? {
    load("SELECT payload FROM thread WHERE environment_id = ? AND thread_id = ?", [.text(environmentId.rawValue), .text(threadId.rawValue)], as: OrchestrationThreadDetailSnapshot.self)
  }

  public func saveThread(_ environmentId: EnvironmentId, _ snapshot: OrchestrationThreadDetailSnapshot) {
    guard let payload = try? encoder.encode(snapshot) else { return }
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
    for table in ["shell", "thread", "server_config"] {
      _ = try? db.run("DELETE FROM \(table) WHERE environment_id = ?", [.text(environmentId.rawValue)])
    }
  }
}
