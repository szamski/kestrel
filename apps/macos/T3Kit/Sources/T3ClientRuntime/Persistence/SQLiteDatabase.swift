import Foundation
import SQLite3

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
  public let code: Int32
  public let message: String
  public var description: String { "SQLite error \(code): \(message)" }
}

/// Minimal wrapper over the system SQLite3 module. Not thread safe: owners confine it to one actor.
final class SQLiteDatabase {
  private var handle: OpaquePointer?
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// `path == nil` opens an in-memory database.
  init(path: String?) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path ?? ":memory:", &handle, flags, nil) == SQLITE_OK else {
      let error = SQLiteError(code: sqlite3_errcode(handle), message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
      sqlite3_close(handle)
      throw error
    }
    sqlite3_busy_timeout(handle, 2000)
  }

  deinit { sqlite3_close(handle) }

  private func error() -> SQLiteError { SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle))) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }

  enum Value {
    case int(Int64), text(String), blob(Data), null
  }

  /// Runs a statement, calling `row` for each result row. Returns the number of changed rows.
  @discardableResult
  func run(_ sql: String, _ bindings: [Value] = [], row: ((Statement) throws -> Void)? = nil) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
    defer { sqlite3_finalize(statement) }
    for (index, value) in bindings.enumerated() {
      let i = Int32(index + 1)
      switch value {
      case .int(let v): sqlite3_bind_int64(statement, i, v)
      case .text(let v): sqlite3_bind_text(statement, i, v, -1, Self.transient)
      case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), Self.transient) }
      case .null: sqlite3_bind_null(statement, i)
      }
    }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: try row?(Statement(handle: statement))
      case SQLITE_DONE: return Int(sqlite3_changes(handle))
      default: throw error()
      }
    }
  }

  struct Statement {
    let handle: OpaquePointer?
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(handle, column)) }
    func blob(_ column: Int32) -> Data {
      guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
  }

  var userVersion: Int {
    var version = 0
    _ = try? run("PRAGMA user_version") { version = Int($0.int(0)) }
    return version
  }

  func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }
}
