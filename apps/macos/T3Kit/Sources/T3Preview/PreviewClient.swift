import Foundation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// What a failed preview call says, in words for the user.
public struct PreviewFailure: Error, LocalizedError, Sendable, Equatable {
  public var message: String
  public var errorDescription: String? { message }
  public init(_ message: String) { self.message = message }
}

/// Where the stream's HTTP and socket requests go and the ticket that authenticates them. A ticket lives five minutes and
/// covers everything a panel opens at once; callers mint a fresh one each time they (re)connect.
public struct PreviewStreamAccess: Sendable, Equatable {
  public var httpBase: URL
  public var ticket: String
}

/// The `preview.*` RPCs and the stream's access on one environment (the mobile app's `state/preview.ts`).
public struct PreviewClient: Sendable {
  public let runtime: ClientRuntime

  public init(runtime: ClientRuntime) { self.runtime = runtime }

  private func session(_ environmentId: EnvironmentId) async throws -> any EnvironmentSession {
    guard let environment = await runtime.runtime(for: environmentId), let session = environment.supervisor.session.value else {
      throw PreviewFailure("The environment is not connected.")
    }
    return session
  }

  public func call<Payload: Sendable, Success: Sendable, Failure: Error & Sendable & Encodable>(
    _ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload, in environmentId: EnvironmentId
  ) async throws -> Success {
    let session = try await session(environmentId)
    do { return try await session.call(spec, payload) } catch { throw Self.failure(error) }
  }

  public func list(_ threadId: ThreadId, in environmentId: EnvironmentId) async throws -> PreviewListResult {
    try await call(Rpc.previewList, PreviewListInput(threadId: threadId), in: environmentId)
  }

  /// Every thread's tab events of the environment.
  public func events(in environmentId: EnvironmentId) async throws -> AsyncThrowingStream<PreviewEvent, any Error> {
    try await session(environmentId).subscribe(Rpc.subscribePreviewEvents, EmptyObject())
  }

  /// Local servers the environment's port scanner found, refreshed as they come and go.
  public func discoveredServers(in environmentId: EnvironmentId) async throws -> AsyncThrowingStream<DiscoveredLocalServerList, any Error> {
    try await session(environmentId).subscribe(Rpc.subscribeDiscoveredLocalServers, SubscribeDiscoveredLocalServersPayload())
  }

  /// A new server tab (the environment's own headless browser), optionally on `url`.
  @discardableResult
  public func open(_ threadId: ThreadId, url: String?, viewport: PreviewViewportSetting? = nil, in environmentId: EnvironmentId) async throws -> PreviewSessionSnapshot {
    try await call(Rpc.previewOpen, PreviewOpenInput(threadId: threadId, url: url, viewport: viewport, runtime: .server), in: environmentId)
  }

  public func resize(_ threadId: ThreadId, tab: String, to viewport: PreviewViewportSetting, in environmentId: EnvironmentId) async throws {
    _ = try await call(Rpc.previewResize, PreviewResizeInput(threadId: threadId, tabId: tab, viewport: viewport), in: environmentId)
  }

  /// Appearance, zoom, hard reload and site data: changes for any client, with no need to control the tab.
  public func adjust(_ input: PreviewAdjustInput, in environmentId: EnvironmentId) async throws {
    _ = try await call(Rpc.previewAdjust, input, in: environmentId)
  }

  public func close(_ threadId: ThreadId, tab: String, in environmentId: EnvironmentId) async throws {
    _ = try await call(Rpc.previewClose, PreviewCloseInput(threadId: threadId, tabId: tab), in: environmentId)
  }

  /// Mints a ticket for the stream's socket and its download and upload routes.
  public func access(in environmentId: EnvironmentId) async throws -> PreviewStreamAccess {
    guard let environment = await runtime.runtime(for: environmentId), let prepared = environment.supervisor.prepared.value else {
      throw PreviewFailure("The environment is not connected.")
    }
    do {
      let ticket = try await EnvironmentHTTPClient(baseURL: prepared.httpBaseURL).webSocketTicket(auth: prepared.authorization)
      return PreviewStreamAccess(httpBase: prepared.httpBaseURL, ticket: ticket.ticket)
    } catch { throw Self.failure(error) }
  }

  // MARK: Failures

  public static func failure(_ error: any Error) -> PreviewFailure {
    switch error {
    case let error as PreviewFailure: return error
    case is CancellationError: return PreviewFailure("The request was interrupted.")
    case let error as EnvironmentHTTPError:
      switch error {
      case .server(let status, _, let reason, _, _): return PreviewFailure(reason ?? "The server answered \(status).")
      case .timeout: return PreviewFailure("The server did not answer in time.")
      case .transport(let detail), .invalidJSON(let detail): return PreviewFailure(detail)
      }
    case let error as RpcError<PreviewOpenFailure>: return describe(error)
    case let error as RpcError<PreviewListFailure>: return describe(error)
    default: return PreviewFailure(error.localizedDescription)
    }
  }

  private static func describe<Failure: Error & Sendable & Encodable>(_ error: RpcError<Failure>) -> PreviewFailure {
    switch error {
    case .interrupted: return PreviewFailure("The request was interrupted.")
    case .transportClosed: return PreviewFailure("The connection closed before the request completed.")
    case .defect: return PreviewFailure("The server could not complete the request.")
    case .failure(let failure):
      guard let data = try? JSONEncoder().encode(failure), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return PreviewFailure("The server refused the request.")
      }
      switch object["_tag"] as? String {
      case "PreviewInvalidUrlError": return PreviewFailure("Enter an http or https address.")
      case "PreviewSessionLookupError": return PreviewFailure("This tab no longer exists.")
      case "PreviewControlRequiredError": return PreviewFailure("Take control of the browser first.")
      default:
        for key in ["message", "detail"] { if let text = object[key] as? String, !text.isEmpty { return PreviewFailure(text) } }
        return PreviewFailure("The server refused the request.")
      }
    }
  }
}
