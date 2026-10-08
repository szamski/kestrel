import Foundation
import T3Contracts
import T3Protocol

public enum ConnectionAttemptProgress: Sendable {
  case preparing
  case opening(PreparedConnection)
  case synchronizing(PreparedConnection)
}

public struct ConnectionLease: Sendable {
  public let prepared: PreparedConnection
  public let session: any EnvironmentSession
  public init(prepared: PreparedConnection, session: any EnvironmentSession) {
    self.prepared = prepared
    self.session = session
  }
}

/// A single attempt: resolve the endpoint, open the socket, wait for the first server config.
/// Retry policy lives in the supervisor only; a driver never retries. Cancellation must leave
/// no open socket behind.
public protocol ConnectionDriving: Sendable {
  func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease
}

/// Bearer-token environments (pairing, Tailscale/LAN, direct): `/.well-known` descriptor check,
/// protocol compatibility, websocket ticket, then the RPC socket.
public struct BearerConnectionDriver: ConnectionDriving {
  private let credentials: any CredentialStore
  private let metadata: ClientMetadata
  private let session: URLSession

  public init(credentials: any CredentialStore, metadata: ClientMetadata, session: URLSession = URLSession(configuration: .ephemeral)) {
    self.credentials = credentials
    self.metadata = metadata
    self.session = session
  }

  static func map(_ error: EnvironmentHTTPError, label: String) -> ConnectionAttemptError {
    switch error {
    case .transport(let message): .transient(.network, detail: message)
    case .timeout: .transient(.timeout, detail: "\(label) did not respond during connection setup.")
    case .invalidJSON(let message): .transient(.remoteUnavailable, detail: message)
    case .server(let status, _, _, _, let traceId):
      switch status {
      case 401: .blocked(.authentication, detail: "The environment credential is invalid.", traceId: traceId)
      case 403: .blocked(.permission, detail: "The environment credential does not grant the required access.", traceId: traceId)
      case 400: .blocked(.configuration, detail: "The environment rejected the authentication request.", traceId: traceId)
      case 404: .blocked(.configuration, detail: "The environment endpoint could not be found.", traceId: traceId)
      default: .transient(.remoteUnavailable, detail: "The environment could not authorize the connection.", traceId: traceId)
      }
    }
  }

  public func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    progress(.preparing)
    guard let credential = try? credentials.load(environmentId: entry.environmentId.rawValue) else {
      throw ConnectionAttemptError.blocked(.authentication, detail: "Connection credential \(entry.environmentId.rawValue) is unavailable.")
    }
    let http = EnvironmentHTTPClient(baseURL: entry.httpBaseURL, session: session)
    do {
      let descriptor = try await http.descriptor()
      guard descriptor.environmentId == entry.environmentId.rawValue else {
        throw ConnectionAttemptError.blocked(.configuration, detail: "Connected environment \(descriptor.environmentId) does not match \(entry.environmentId.rawValue).")
      }
      if let incompatible = ProtocolCompatibility.check(descriptor) {
        throw ConnectionAttemptError.blocked(.unsupported, detail: incompatible.message(environmentLabel: descriptor.label))
      }
      let authorization = RequestAuthorization.bearer(credential.accessToken)
      let ticket = try await http.webSocketTicket(auth: authorization)
      let socketURL = WebSocketURL.make(wsBaseURL: entry.wsBaseURL, ticket: ticket.ticket, metadata: metadata, connectionMethod: .direct)
      let prepared = PreparedConnection(
        environmentId: entry.environmentId, label: descriptor.label, httpBaseURL: entry.httpBaseURL, socketURL: socketURL,
        authorization: authorization)
      progress(.opening(prepared))
      let transport = try await URLSessionWebSocketTransport.open(URLRequest(url: socketURL))
      progress(.synchronizing(prepared))
      let live = try await LiveEnvironmentSession.open(
        transport: transport, label: descriptor.label, expectedEnvironmentId: entry.environmentId, onConfigEvent: onConfigEvent)
      return ConnectionLease(prepared: prepared, session: live)
    } catch let error as EnvironmentHTTPError {
      throw Self.map(error, label: entry.label)
    } catch let error as WebSocketOpenError {
      switch error {
      case .timeout: throw ConnectionAttemptError.transient(.timeout, detail: "\(entry.label) did not respond during connection setup.")
      case .rejected(let status, let message):
        // A refused upgrade with 401/403 is an authorization problem, not a network one.
        if status == 401 || status == 403 { throw ConnectionAttemptError.blocked(.authentication, detail: "The environment rejected the connection credential.") }
        throw ConnectionAttemptError.transient(.transport, detail: "\(entry.label) could not establish a WebSocket connection: \(message)")
      }
    }
  }
}
