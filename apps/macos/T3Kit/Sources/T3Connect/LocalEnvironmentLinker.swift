import Foundation
import T3Contracts
import T3Protocol

/// The server this Mac runs (or any directly paired server): where its `/api/connect/*` routes are and the bearer that may call them
/// (`relay:read` / `relay:write`).
public struct LinkTarget: Sendable {
  public var environmentId: EnvironmentId
  public var httpBaseURL: URL
  public var authorization: RequestAuthorization

  public init(environmentId: EnvironmentId, httpBaseURL: URL, authorization: RequestAuthorization) {
    self.environmentId = environmentId
    self.httpBaseURL = httpBaseURL
    self.authorization = authorization
  }
}

public enum LinkError: Error, Sendable, Equatable, LocalizedError {
  case accountChanged
  /// The relay or the server answered with something other than the environment and account being linked.
  case mismatch(String)
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .accountChanged: "Your cloud sign-in changed while linking. Try again."
    case .mismatch(let message), .server(let message): message
    }
  }
}

/// Links a server to the signed-in account, as web's `linkPrimaryEnvironmentToCloud` does. Four steps, each checked:
/// the relay issues a challenge, the server signs a proof of it with its own key (over `/api/connect/link-proof`, from
/// loopback only), the relay verifies that proof and links, and the server stores the resulting relay credential. The
/// server's bearer only ever goes to that server; relay credentials never replace it.
public struct LocalEnvironmentLinker: Sendable {
  private let relay: RelayClient
  private let relayURL: URL
  private let urlSession: URLSession

  public init(relay: RelayClient, relayURL: URL, urlSession: URLSession = URLSession(configuration: .ephemeral)) {
    self.relay = relay
    self.relayURL = relayURL
    self.urlSession = urlSession
  }

  public func linkState(_ target: LinkTarget) async throws -> EnvironmentCloudLinkStateResult {
    try await server(target) { try await $0.get(Http.connectLinkState.path, auth: target.authorization) }
  }

  /// `accountStillCurrent` is checked between the steps so a sign-out or account switch cannot complete someone else's link.
  public func link(_ target: LinkTarget, clerkToken: String, accountId: String, accountStillCurrent: @Sendable () async -> Bool) async throws {
    func check() async throws { if await !accountStillCurrent() { throw LinkError.accountChanged } }
    try await check()
    let challenge = try await relay.createLinkChallenge(
      clerkToken: clerkToken,
      RelayEnvironmentLinkChallengeRequest(notificationsEnabled: true, liveActivitiesEnabled: true, managedTunnelsEnabled: true))
    try await check()
    let origin = Self.localOrigin(target.httpBaseURL)
    let proof: String = try await server(target) {
      try await $0.post(
        Http.connectLinkProof.path,
        body: RelayLinkProofRequest(
          challenge: challenge.challenge, relayIssuer: relayURL.absoluteString,
          endpoint: RelayManagedEndpoint(httpBaseUrl: origin.http, wsBaseUrl: origin.ws, providerKind: .cloudflare_tunnel),
          origin: RelayManagedEndpointOrigin(localHttpHost: "127.0.0.1", localHttpPort: origin.port)),
        auth: target.authorization)
    }
    try await check()
    let link = try await relay.linkEnvironment(
      clerkToken: clerkToken,
      RelayEnvironmentLinkRequest(deviceId: nil, proof: proof, notificationsEnabled: true, liveActivitiesEnabled: true, managedTunnelsEnabled: true))
    try await check()
    guard link.ok, link.environmentId == target.environmentId, link.cloudUserId == accountId, link.endpoint.providerKind == .cloudflare_tunnel else {
      throw LinkError.mismatch("Relay returned credentials for a different environment, account or endpoint.")
    }
    let configured: EnvironmentCloudRelayConfigResult = try await server(target) {
      try await $0.post(
        Http.connectRelayConfig.path,
        body: RelayEnvironmentConfigRequest(
          relayUrl: relayURL.absoluteString, relayIssuer: link.relayIssuer, cloudUserId: link.cloudUserId, environmentCredential: link.environmentCredential,
          cloudMintPublicKey: link.cloudMintPublicKey, endpointRuntime: link.endpointRuntime),
        auth: target.authorization)
    }
    guard configured.ok else { throw LinkError.server("The environment did not accept the relay configuration.") }
  }

  /// Unlinks on the server first (as web does), then removes the link from the account; a relay failure after that is returned
  /// to the caller but the server is already unlinked.
  public func unlink(_ target: LinkTarget, clerkToken: String?) async throws {
    let _: EnvironmentCloudRelayConfigResult = try await server(target) { try await $0.postWithoutBody(Http.connectUnlink.path, auth: target.authorization) }
    if let clerkToken { try await relay.unlinkEnvironment(clerkToken: clerkToken, environmentId: target.environmentId) }
  }

  private func server<T: Sendable>(_ target: LinkTarget, _ call: (EnvironmentHTTPClient) async throws -> T) async throws -> T {
    do {
      return try await call(EnvironmentHTTPClient(baseURL: target.httpBaseURL, session: urlSession, timeout: 30))
    } catch let error as EnvironmentHTTPError {
      switch error {
      case .server(let status, _, let reason, let requiredScope, let traceId):
        let detail = reason ?? requiredScope.map { "This session needs the \($0) permission." } ?? "The server answered with status \(status)."
        throw LinkError.server(traceId.map { "\(detail) (trace \($0))" } ?? detail)
      case .transport(let message), .invalidJSON(let message): throw LinkError.server(message)
      case .timeout: throw LinkError.server("The server did not respond.")
      }
    }
  }

  /// `http://127.0.0.1:13773/` as the origin strings and port a link proof names (`new URL(url).origin`).
  static func localOrigin(_ url: URL) -> (http: String, ws: String, port: Int) {
    let secure = url.scheme?.lowercased() == "https"
    let port = url.port ?? (secure ? 443 : 80)
    let host = url.host(percentEncoded: false) ?? "127.0.0.1"
    let authority = url.port.map { "\(host):\($0)" } ?? host
    return ("\(secure ? "https" : "http")://\(authority)", "\(secure ? "wss" : "ws")://\(authority)", port)
  }
}
