import Foundation
import T3Contracts
import T3Protocol

/// What the relay and the environment agreed on for one connect: a verified descriptor, the endpoint
/// the relay named, and a DPoP authorizer. The authorizer is typed as DPoP on purpose: a managed
/// environment has no bearer form, so a failure can never degrade to a bearer request.
public struct ManagedConnectionGrant: Sendable {
  public var descriptor: EnvironmentDescriptorInfo
  public var httpBaseURL: URL
  public var wsBaseURL: URL
  public var authorization: DPoPAuthorizer

  public init(descriptor: EnvironmentDescriptorInfo, httpBaseURL: URL, wsBaseURL: URL, authorization: DPoPAuthorizer) {
    self.descriptor = descriptor
    self.httpBaseURL = httpBaseURL
    self.wsBaseURL = wsBaseURL
    self.authorization = authorization
  }
}

/// T3 Connect's side of a connection (T3Connect implements it): account sign-in, relay bootstrap and the
/// environment's DPoP token exchange. Failures are already classified: `blocked` waits for a wakeup
/// (signed out, not authorized), `transient` retries with backoff.
public protocol ManagedEnvironmentAuthorizing: Sendable {
  /// `rejectedTokenId` is the `DPoPAuthorizer.id` of a token the environment just refused; it is never handed out again.
  func authorize(_ environmentId: EnvironmentId, rejecting rejectedTokenId: String?) async throws(ConnectionAttemptError) -> ManagedConnectionGrant
}

/// Relay (T3 Connect) environments: authorize through the account, check the descriptor, ticket over
/// DPoP, then the same RPC socket as any other environment (`connectionMethod=relay`).
public struct RelayConnectionDriver: ConnectionDriving {
  private let authorizer: any ManagedEnvironmentAuthorizing
  private let metadata: ClientMetadata
  private let session: URLSession

  public init(authorizer: any ManagedEnvironmentAuthorizing, metadata: ClientMetadata, session: URLSession = URLSession(configuration: .ephemeral)) {
    self.authorizer = authorizer
    self.metadata = metadata
    self.session = session
  }

  /// The bearer mapping plus the DPoP clock hint web shows for a rejected proof.
  public static func map(_ error: EnvironmentHTTPError, label: String) -> ConnectionAttemptError {
    if case .server(401, let code, let reason, _, let traceId) = error, code == "auth_invalid", reason == nil || reason == "invalid_credential" {
      return .blocked(
        .authentication,
        detail: "The environment credential is invalid. Try again. If it still fails, check that automatic date and time is enabled on this Mac.",
        traceId: traceId)
    }
    return BearerConnectionDriver.map(error, label: label)
  }

  public func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    progress(.preparing)
    var grant = try await authorizer.authorize(entry.environmentId, rejecting: nil)
    var ticket: WebSocketTicket?
    // A refused token is replaced once; a second refusal is the environment's answer.
    for attempt in 0..<2 {
      guard grant.descriptor.environmentId == entry.environmentId.rawValue else {
        throw ConnectionAttemptError.blocked(.configuration, detail: "Connected environment \(grant.descriptor.environmentId) does not match \(entry.environmentId.rawValue).")
      }
      do {
        ticket = try await EnvironmentHTTPClient(baseURL: grant.httpBaseURL, session: session).webSocketTicket(auth: .dpop(grant.authorization))
        break
      } catch let error as EnvironmentHTTPError {
        guard attempt == 0, error.isAuthInvalid else { throw Self.map(error, label: entry.label) }
        grant = try await authorizer.authorize(entry.environmentId, rejecting: grant.authorization.id)
      }
    }
    guard let ticket else { throw ConnectionAttemptError.transient(.remoteUnavailable, detail: "The environment did not issue a connection ticket.") }
    let negotiated: OrchestrationProtocol
    switch ProtocolCompatibility.negotiate(grant.descriptor) {
    case .success(let version): negotiated = version
    case .failure(let incompatible):
      throw ConnectionAttemptError.blocked(.unsupported, detail: incompatible.message(environmentLabel: grant.descriptor.label))
    }
    let socketURL = WebSocketURL.make(
      wsBaseURL: grant.wsBaseURL, ticket: ticket.ticket, metadata: metadata, connectionMethod: .relay, orchestrationProtocol: negotiated)
    let prepared = PreparedConnection(
      environmentId: entry.environmentId, label: grant.descriptor.label, httpBaseURL: grant.httpBaseURL, socketURL: socketURL,
      authorization: .dpop(grant.authorization), orchestrationProtocol: negotiated)
    return try await ConnectionLease.open(
      prepared, entryLabel: entry.label, label: grant.descriptor.label, expectedEnvironmentId: entry.environmentId, progress: progress,
      onConfigEvent: onConfigEvent)
  }
}

/// Picks the driver by the entry's route. A build without T3 Connect blocks relay entries instead of guessing a route.
public struct RoutingConnectionDriver: ConnectionDriving {
  private let direct: any ConnectionDriving
  private let relay: (any ConnectionDriving)?

  public init(direct: any ConnectionDriving, relay: (any ConnectionDriving)?) {
    self.direct = direct
    self.relay = relay
  }

  public func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    switch entry.route {
    case .direct:
      return try await direct.connect(entry, progress: progress, onConfigEvent: onConfigEvent)
    case .relay:
      guard let relay else { throw ConnectionAttemptError.blocked(.configuration, detail: "T3 Connect is not available in this build.") }
      return try await relay.connect(entry, progress: progress, onConfigEvent: onConfigEvent)
    }
  }
}
