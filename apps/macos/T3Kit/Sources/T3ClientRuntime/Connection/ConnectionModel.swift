import Foundation
import T3Contracts
import T3Protocol

// Port of packages/client-runtime/src/connection/model.ts (direct and T3 Connect relay routes;
// SSH targets belong to a later stage).

public enum NetworkStatus: String, Sendable { case unknown, offline, online }

public enum ConnectionTransientReason: String, Sendable {
  case network, timeout, transport
  case endpointUnavailable = "endpoint-unavailable"
  case relayUnavailable = "relay-unavailable"
  case remoteUnavailable = "remote-unavailable"
}

public enum ConnectionBlockedReason: String, Sendable { case authentication, configuration, permission, unsupported }

/// Why an attempt or an established connection failed. Transient failures retry with backoff;
/// blocked ones wait for an explicit wakeup because retrying cannot change the outcome.
public enum ConnectionAttemptError: Error, Sendable, Equatable {
  case transient(ConnectionTransientReason, detail: String, traceId: String? = nil)
  case blocked(ConnectionBlockedReason, detail: String, traceId: String? = nil)

  public var detail: String {
    switch self {
    case .transient(_, let detail, _), .blocked(_, let detail, _): detail
    }
  }
  public var isBlocked: Bool { if case .blocked = self { true } else { false } }
}

public enum ConnectionPhase: String, Sendable { case available, offline, connecting, backoff, connected, blocked }
public enum ConnectionStage: String, Sendable { case preparing, opening, synchronizing }

public struct SupervisorConnectionState: Sendable, Equatable {
  public var desired: Bool
  public var network: NetworkStatus
  public var phase: ConnectionPhase
  public var stage: ConnectionStage?
  public var attempt: Int
  public var generation: Int
  public var lastFailure: ConnectionAttemptError?
  /// Epoch milliseconds of the next automatic attempt while in `backoff`.
  public var retryAt: Int64?

  public static let available = SupervisorConnectionState(
    desired: false, network: .unknown, phase: .available, stage: nil, attempt: 0, generation: 0, lastFailure: nil, retryAt: nil)
}

public enum ConnectionProjectionPhase: Sendable { case disconnected, synchronizing, ready }

extension SupervisorConnectionState {
  /// What data layers care about: a connecting transport is "synchronizing", a backoff is "disconnected".
  public var projectionPhase: ConnectionProjectionPhase {
    switch phase {
    case .connecting: .synchronizing
    case .connected: .ready
    case .available, .offline, .backoff, .blocked: .disconnected
    }
  }
}

public enum ConnectionWakeup: String, Sendable {
  case applicationActive = "application-active"
  case applicationActiveProbe = "application-active-probe"
  case applicationActiveReconnect = "application-active-reconnect"
  case credentialsChanged = "credentials-changed"

  public var isApplicationActive: Bool { self != .credentialsChanged }
  /// Foreground resubscriptions on the same live session resume from the in-memory cursor.
  public var shouldResubscribe: Bool { self == .applicationActive || self == .applicationActiveProbe }
}

/// How an environment is reached. Only the driver for the route ever sees its credential.
public enum ConnectionRoute: String, Sendable, Codable {
  /// A bearer token saved at pairing time (pairing link, LAN, Tailscale, the local server).
  case direct
  /// T3 Connect: the relay vouches for the account, the environment issues a DPoP-bound token for this device.
  /// Nothing is saved but the entry; the token is minted on demand and never replaced by a bearer.
  case relay
}

/// A saved environment as the connection layer needs it.
public struct EnvironmentConnectionEntry: Sendable, Equatable, Codable, Identifiable {
  public var environmentId: EnvironmentId
  public var label: String
  /// For a relay entry: the managed endpoint the relay last reported. The driver takes the endpoint from the relay on every connect.
  public var httpBaseURL: URL
  public var wsBaseURL: URL
  /// False when the user switched the environment off: saved, but never connects.
  public var enabled: Bool = true
  public var route: ConnectionRoute = .direct
  public var id: EnvironmentId { environmentId }

  public init(environmentId: EnvironmentId, label: String, httpBaseURL: URL, wsBaseURL: URL, enabled: Bool = true, route: ConnectionRoute = .direct) {
    self.environmentId = environmentId
    self.label = label
    self.httpBaseURL = httpBaseURL
    self.wsBaseURL = wsBaseURL
    self.enabled = enabled
    self.route = route
  }

  private enum CodingKeys: String, CodingKey { case environmentId, label, httpBaseURL, wsBaseURL, enabled, route }

  /// Catalogs written before `route` existed hold direct environments only.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    environmentId = try c.decode(EnvironmentId.self, forKey: .environmentId)
    label = try c.decode(String.self, forKey: .label)
    httpBaseURL = try c.decode(URL.self, forKey: .httpBaseURL)
    wsBaseURL = try c.decode(URL.self, forKey: .wsBaseURL)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    route = try c.decodeIfPresent(ConnectionRoute.self, forKey: .route) ?? .direct
  }
}

/// Output of preparing a connection: everything an HTTP request or the socket needs.
public struct PreparedConnection: Sendable, Equatable {
  public var environmentId: EnvironmentId
  public var label: String
  public var httpBaseURL: URL
  public var socketURL: URL
  public var authorization: RequestAuthorization
  /// What the descriptor negotiated; the socket URL and orchestration HTTP calls speak it.
  public var orchestrationProtocol: OrchestrationProtocol = .v1
}
