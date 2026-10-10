import Foundation
import T3Contracts
import T3Protocol
import os

/// HTTP snapshot loads (`shellSnapshotHttp.ts`, `threadSnapshotHttp.ts`). A failure returns nil and the
/// caller falls back to the snapshot the socket subscription sends, so a proxy that blocks /api
/// but not /ws still works. The deadline is long on purpose: on timeout the socket asks the same
/// server for the same snapshot, so a short deadline only throws the first build away.
public protocol SnapshotLoading: Sendable {
  func loadShell(_ prepared: PreparedConnection) async -> V1.OrchestrationShellSnapshot?
  func loadThread(
    _ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool
  ) async -> V1.OrchestrationThreadDetailSnapshot?
  /// Protocol 2: the shell, a thread's recent window, and one older page of its history.
  func loadShellV2(_ prepared: PreparedConnection) async -> OrchestrationV2ShellSnapshot?
  func loadThreadV2(_ prepared: PreparedConnection, threadId: ThreadId) async -> ThreadSnapshotLoadResult
  func loadHistoryPage(_ prepared: PreparedConnection, threadId: ThreadId, cursor: String) async -> Result<OrchestrationV2ThreadHistoryPage, HistoryLoadFailure>
}

/// A loader that only speaks protocol 1 (tests, servers that never negotiated 2) answers "nothing": the socket snapshot is used.
extension SnapshotLoading {
  public func loadShellV2(_ prepared: PreparedConnection) async -> OrchestrationV2ShellSnapshot? { nil }
  public func loadThreadV2(_ prepared: PreparedConnection, threadId: ThreadId) async -> ThreadSnapshotLoadResult { .unavailable }
  public func loadHistoryPage(_ prepared: PreparedConnection, threadId: ThreadId, cursor: String) async -> Result<OrchestrationV2ThreadHistoryPage, HistoryLoadFailure> {
    .failure(HistoryLoadFailure("Earlier activity is not available."))
  }
}

/// Outcome of a protocol-2 thread snapshot load: `missing` is a definitive 404 (the thread does not exist),
/// `unavailable` any other failure (the socket snapshot is the fallback).
public enum ThreadSnapshotLoadResult: Sendable, Equatable {
  /// `history` is set when the server sent a bounded window: its cursor and watermark ride along.
  case present(OrchestrationV2ThreadDetailSnapshot, history: ThreadHistoryMeta?)
  case missing
  case unavailable
}

public struct HistoryLoadFailure: Error, Sendable, Equatable {
  public var message: String
  public init(_ message: String) { self.message = message }
}

/// Optional turn window of a thread snapshot; only sent to servers that advertise `threadSnapshotPagination`.
public struct ThreadSnapshotWindow: Sendable, Equatable {
  public var turnLimit: Int
  public var beforeCursor: String?
  public init(turnLimit: Int, beforeCursor: String? = nil) {
    self.turnLimit = turnLimit
    self.beforeCursor = beforeCursor
  }
}

public struct HTTPSnapshotLoader: SnapshotLoading {
  public static let timeout: TimeInterval = 20
  /// Older pages are interactive: a short deadline lets the reader retry instead of waiting out a hung request.
  public static let historyTimeout: TimeInterval = 6
  private let session: URLSession
  private static let log = Logger(subsystem: "codes.t3.macos", category: "snapshots")

  public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

  public func loadShell(_ prepared: PreparedConnection) async -> V1.OrchestrationShellSnapshot? {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    do {
      return try await http.get("/api/orchestration/shell", auth: prepared.authorization, orchestrationProtocol: prepared.orchestrationProtocol)
    } catch {
      Self.log.warning("Could not load the environment shell snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  public func loadThread(
    _ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool
  ) async -> V1.OrchestrationThreadDetailSnapshot? {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    var query: [URLQueryItem] = []
    if reasoningMessages { query.append(URLQueryItem(name: "reasoningMessages", value: "true")) }
    if let window {
      query.append(URLQueryItem(name: "turnLimit", value: String(window.turnLimit)))
      if let cursor = window.beforeCursor { query.append(URLQueryItem(name: "beforeCursor", value: cursor)) }
    }
    do {
      return try await http.get("/api/orchestration/threads/\(threadId.rawValue)", query: query, auth: prepared.authorization, orchestrationProtocol: prepared.orchestrationProtocol)
    } catch let error as EnvironmentHTTPError {
      // A genuinely missing thread is expected: the socket subscription is the source of truth for existence.
      if case .server(404, _, _, _, _) = error { return nil }
      Self.log.warning("Could not load the thread snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
      return nil
    } catch {
      return nil
    }
  }

  // MARK: Protocol 2

  public func loadShellV2(_ prepared: PreparedConnection) async -> OrchestrationV2ShellSnapshot? {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    do {
      return try await http.get("/api/orchestration/shell", auth: prepared.authorization, orchestrationProtocol: .v2)
    } catch {
      Self.log.warning("Could not load the environment shell snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Seeds from the bounded recent window; an older server without that route gets the full snapshot.
  public func loadThreadV2(_ prepared: PreparedConnection, threadId: ThreadId) async -> ThreadSnapshotLoadResult {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    let path = "/api/orchestration/threads/\(threadId.rawValue)"
    do {
      let bounded: OrchestrationV2ThreadBoundedSnapshot = try await http.get(
        path + "/bounded", query: [URLQueryItem(name: "compactTurnItems", value: "1")], auth: prepared.authorization, orchestrationProtocol: .v2)
      return .present(Self.detail(bounded), history: ThreadHistoryMeta.of(bounded))
    } catch let error as EnvironmentHTTPError {
      switch error {
      case .server(404, let code, _, _, _) where code != nil: return .missing
      case .server(404, _, _, _, _), .invalidJSON: break  // no bounded route (older protocol-2 server): ask for the full snapshot
      default:
        Self.log.warning("Could not load the bounded thread snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
        return .unavailable
      }
    } catch {
      return .unavailable
    }
    do {
      let full: OrchestrationV2ThreadDetailSnapshot = try await http.get(path, auth: prepared.authorization, orchestrationProtocol: .v2)
      return .present(full, history: nil)
    } catch let error as EnvironmentHTTPError {
      if case .server(404, let code, _, _, _) = error, code != nil { return .missing }
      return .unavailable
    } catch {
      return .unavailable
    }
  }

  public func loadHistoryPage(_ prepared: PreparedConnection, threadId: ThreadId, cursor: String) async -> Result<OrchestrationV2ThreadHistoryPage, HistoryLoadFailure> {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.historyTimeout)
    do {
      let page: OrchestrationV2ThreadHistoryPage = try await http.get(
        "/api/orchestration/threads/\(threadId.rawValue)/history", query: [URLQueryItem(name: "cursor", value: cursor)],
        auth: prepared.authorization, orchestrationProtocol: .v2)
      return .success(page)
    } catch {
      return .failure(HistoryLoadFailure("Could not load earlier activity."))
    }
  }

  /// A bounded snapshot as the detail snapshot the thread state works with (compact turn items restored).
  static func detail(_ bounded: OrchestrationV2ThreadBoundedSnapshot) -> OrchestrationV2ThreadDetailSnapshot {
    let projection = bounded.turnItemsOmitLocalVisible == true ? ThreadHistory.restoreLocalVisibleTurnItems(bounded.projection) : bounded.projection
    return OrchestrationV2ThreadDetailSnapshot(
      snapshotSequence: bounded.snapshotSequence, projection: projection, historyCursor: .some(bounded.historyCursor),
      hasMoreHistory: bounded.hasMoreHistory, latestLocalTurnOrdinal: .some(bounded.latestLocalTurnOrdinal))
  }
}

extension ThreadHistoryMeta {
  static func of(_ bounded: OrchestrationV2ThreadBoundedSnapshot) -> ThreadHistoryMeta {
    ThreadHistoryMeta(
      historyCursor: bounded.historyCursor, hasMoreHistory: bounded.hasMoreHistory, loading: false, error: nil, expanded: false,
      latestLocalTurnOrdinal: bounded.latestLocalTurnOrdinal)
  }
}
