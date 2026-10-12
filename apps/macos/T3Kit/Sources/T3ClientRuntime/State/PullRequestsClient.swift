import Foundation
import T3Contracts
import T3Protocol

/// What a failed pull request call says, in words for the user.
public struct PullRequestsFailure: Error, LocalizedError, Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case notConnected
    /// The host tooling cannot serve pull requests here (no `gh`, not signed in, unsupported provider).
    case unavailable(PullRequestUnavailableReason)
    case notFound
    case interrupted
    case other
  }

  public var kind: Kind
  public var message: String
  public var errorDescription: String? { message }

  public init(kind: Kind, message: String) {
    self.kind = kind
    self.message = message
  }

  /// The host's own sentence when it said something, else nothing: callers fall back to a hint (`readableFailure`).
  public var host: String {
    let stripped = message.replacingOccurrences(of: "^Pull request operation \\w+ failed:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let noise = [#"^(github|gitlab|bitbucket|azure devops)?\s*(cli|api)?\s*(command\s*)?failed\.?$"#, #"^exited? with (code|status) \d+\.?$"#, #"^unknown error\.?$"#]
    if stripped.isEmpty || noise.contains(where: { stripped.captures($0, caseInsensitive: true) != nil }) { return "" }
    return stripped.count <= 320 ? stripped : String(stripped.prefix(319)) + "\u{2026}"
  }

  /// `readableFailure`: what to put under a failed action.
  public func readable(hint: String) -> String { host.isEmpty ? hint : host }
}

/// Calls of the `pullRequests.*` RPCs on one environment, with their failures mapped to `PullRequestsFailure`. The
/// environment that owns the project answers; GitHub accounts are not routed across environments (the web's router also
/// asks other connected environments signed in to the same account).
public struct PullRequestsClient: Sendable {
  public let runtime: ClientRuntime

  public init(runtime: ClientRuntime) { self.runtime = runtime }

  private func session(_ environmentId: EnvironmentId) async throws -> any EnvironmentSession {
    guard let environment = await runtime.runtime(for: environmentId), let session = environment.supervisor.session.value else {
      throw PullRequestsFailure(kind: .notConnected, message: "The environment is not connected.")
    }
    return session
  }

  public func call<Payload: Sendable, Success: Sendable, Failure: Error & Sendable & Encodable>(
    _ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload, in environmentId: EnvironmentId
  ) async throws -> Success {
    let session = try await session(environmentId)
    do {
      return try await session.call(spec, payload)
    } catch {
      throw Self.failure(error)
    }
  }

  /// The server's live signal that pull request data may have changed (a turn finished, a checkpoint was taken).
  public func refreshes(in environmentId: EnvironmentId) async throws -> AsyncThrowingStream<Int, any Error> {
    try await session(environmentId).subscribe(Rpc.pullRequestsSubscribeRefreshes, EmptyObject())
  }

  /// `POST /api/pull-requests/diff` pages joined: the diff is not an RPC. Follows `nextCursor` up to `pages` pages.
  public func diff(_ input: PullRequestDiffInput, in environmentId: EnvironmentId, pages: Int = 10) async throws -> PullRequestDiffResult {
    guard let environment = await runtime.runtime(for: environmentId), let prepared = environment.supervisor.prepared.value else {
      throw PullRequestsFailure(kind: .notConnected, message: "The environment is not connected.")
    }
    let http = EnvironmentHTTPClient(baseURL: prepared.httpBaseURL, timeout: 60)
    var request = input
    var patches: [String] = []
    var omitted: [PullRequestOmittedFileStat] = []
    var truncated = false
    var next: String?
    for _ in 0..<pages {
      let page: PullRequestDiffResult
      do {
        page = try await http.post(Http.pullRequestsDiff.path, body: request, auth: prepared.authorization)
      } catch let error as EnvironmentHTTPError {
        throw Self.failure(error)
      }
      patches.append(page.patch)
      omitted += page.omittedFileStats ?? []
      truncated = page.truncated
      next = page.nextCursor
      guard let cursor = page.nextCursor, cursor != request.cursor else { next = nil; break }
      request.cursor = cursor
    }
    return PullRequestDiffResult(
      patch: patches.joined(separator: patches.last?.hasSuffix("\n") == true ? "" : "\n"), truncated: truncated || next != nil, nextCursor: next,
      omittedFileStats: omitted.isEmpty ? nil : omitted)
  }

  // MARK: Failures

  public static func failure(_ error: any Error) -> PullRequestsFailure {
    switch error {
    case let error as PullRequestsFailure: return error
    case is CancellationError: return PullRequestsFailure(kind: .interrupted, message: "The request was interrupted.")
    case let error as EnvironmentHTTPError:
      switch error {
      case .server(let status, _, let reason, _, _):
        return PullRequestsFailure(kind: status == 503 ? .unavailable(.unknown("")) : .other, message: reason ?? "The server answered \(status).")
      case .timeout: return PullRequestsFailure(kind: .other, message: "The server did not answer in time.")
      case .transport(let detail), .invalidJSON(let detail): return PullRequestsFailure(kind: .other, message: detail)
      }
    case let error as RpcError<PullRequestsListFailure>: return describe(error)
    case let error as RpcError<PullRequestsSubscribeRefreshesFailure>: return describe(error)
    default: return PullRequestsFailure(kind: .other, message: error.localizedDescription)
    }
  }

  private static func describe<Failure: Error & Sendable & Encodable>(_ error: RpcError<Failure>) -> PullRequestsFailure {
    switch error {
    case .interrupted: return PullRequestsFailure(kind: .interrupted, message: "The request was interrupted.")
    case .transportClosed: return PullRequestsFailure(kind: .notConnected, message: "The connection closed before the request completed.")
    case .defect: return PullRequestsFailure(kind: .other, message: "The server could not complete the request.")
    case .failure(let failure):
      guard let data = try? JSONEncoder().encode(failure), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return PullRequestsFailure(kind: .other, message: "The server refused the request.")
      }
      switch object["_tag"] as? String {
      case "PullRequestUnavailableError":
        let reason = PullRequestUnavailableReason(rawValue: object["reason"] as? String ?? "")
        return PullRequestsFailure(kind: .unavailable(reason), message: unavailableMessage(reason))
      case "PullRequestOperationError":
        let detail = object["detail"] as? String ?? "The server refused the request."
        return PullRequestsFailure(kind: object["reason"] as? String == "not-found" ? .notFound : .other, message: detail)
      default:
        for key in ["message", "detail"] { if let text = object[key] as? String, !text.isEmpty { return PullRequestsFailure(kind: .other, message: text) } }
        return PullRequestsFailure(kind: .other, message: object["_tag"] as? String ?? "The server refused the request.")
      }
    }
  }

  static func unavailableMessage(_ reason: PullRequestUnavailableReason) -> String {
    switch reason {
    case .cliMissing: "The host's command line tool (for GitHub, gh) is not installed on this environment."
    case .cliUnauthenticated: "The host's command line tool is not signed in on this environment. Run `gh auth login` there."
    case .providerUnsupported: "This project's source control provider has no pull request support."
    case .unknown: "Pull requests are not available on this environment."
    }
  }
}
