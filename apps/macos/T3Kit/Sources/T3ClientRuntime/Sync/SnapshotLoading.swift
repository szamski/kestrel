import Foundation
import T3Contracts
import T3Protocol
import os

/// HTTP snapshot loads (`shellSnapshotHttp.ts`, `threadSnapshotHttp.ts`). A failure returns nil and the
/// caller falls back to the snapshot the socket subscription sends, so a proxy that blocks /api
/// but not /ws still works. The deadline is long on purpose: on timeout the socket asks the same
/// server for the same snapshot, so a short deadline only throws the first build away.
public protocol SnapshotLoading: Sendable {
  func loadShell(_ prepared: PreparedConnection) async -> OrchestrationShellSnapshot?
  func loadThread(
    _ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool
  ) async -> OrchestrationThreadDetailSnapshot?
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
  private let session: URLSession
  private static let log = Logger(subsystem: "codes.t3.macos", category: "snapshots")

  public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

  public func loadShell(_ prepared: PreparedConnection) async -> OrchestrationShellSnapshot? {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    do {
      return try await http.get("/api/orchestration/shell", auth: prepared.authorization)
    } catch {
      Self.log.warning("Could not load the environment shell snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  public func loadThread(
    _ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool
  ) async -> OrchestrationThreadDetailSnapshot? {
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, session: session, timeout: Self.timeout)
    var query: [URLQueryItem] = []
    if reasoningMessages { query.append(URLQueryItem(name: "reasoningMessages", value: "true")) }
    if let window {
      query.append(URLQueryItem(name: "turnLimit", value: String(window.turnLimit)))
      if let cursor = window.beforeCursor { query.append(URLQueryItem(name: "beforeCursor", value: cursor)) }
    }
    do {
      return try await http.get("/api/orchestration/threads/\(threadId.rawValue)", query: query, auth: prepared.authorization)
    } catch let error as EnvironmentHTTPError {
      // A genuinely missing thread is expected: the socket subscription is the source of truth for existence.
      if case .server(404, _, _, _, _) = error { return nil }
      Self.log.warning("Could not load the thread snapshot over HTTP; using the socket snapshot instead: \(String(describing: error), privacy: .public)")
      return nil
    } catch {
      return nil
    }
  }
}
