import Foundation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// Opens managed (T3 Connect) environments for the connection layer, the way web's
/// `RemoteEnvironmentAuthorization.authorizeDpop` does:
///
/// 1. the relay vouches for the signed-in account and mints a one-time bootstrap credential bound to this device's proof key;
/// 2. the environment behind the relay's endpoint proves who it is (descriptor), then exchanges the credential, given a proof
///    signed by that key, for a DPoP access token (`client_device_type=desktop`);
/// 3. every later request carries `Authorization: DPoP` and a fresh proof for its method and URL.
///
/// Tokens stay in memory, keyed by environment and tied to the account and key that obtained them. A refused or expired
/// token is replaced by repeating steps 1 and 2, once per environment at a time. There is no bearer form: a DPoP failure is
/// an error, never a downgrade.
public actor ManagedEnvironmentAuthorizer: ManagedEnvironmentAuthorizing {
  /// Environment tokens live an hour; renew a minute early (`DPOP_ACCESS_TOKEN_REFRESH_SKEW_MS`).
  static let refreshSkew: TimeInterval = 60

  struct Endpoint: Sendable, Equatable {
    let http: URL
    let ws: URL
  }

  struct Token: Sendable {
    let environmentId: EnvironmentId
    let accountId: String
    let accessToken: String
    let expiresAt: Date
    let thumbprint: String
    let endpoint: Endpoint

    var id: String { DPoPSigner.accessTokenHash(accessToken) }
  }

  private let relay: RelayClient
  private let session: any CloudSession
  private let signer: DPoPSigner
  private let metadata: ClientMetadata
  private let urlSession: URLSession
  private let now: @Sendable () -> Date
  private var tokens: [EnvironmentId: Token] = [:]
  private var exchanges: [EnvironmentId: Task<Token, any Error>] = [:]
  /// Bumped on sign-out: an exchange that finishes afterwards belongs to nobody.
  private var generation = 0

  public init(
    relay: RelayClient, session: any CloudSession, signer: DPoPSigner, metadata: ClientMetadata,
    urlSession: URLSession = URLSession(configuration: .ephemeral), now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.relay = relay
    self.session = session
    self.signer = signer
    self.metadata = metadata
    self.urlSession = urlSession
    self.now = now
  }

  // MARK: ManagedEnvironmentAuthorizing

  public func authorize(_ environmentId: EnvironmentId, rejecting rejectedTokenId: String?) async throws(ConnectionAttemptError) -> ManagedConnectionGrant {
    do {
      let token = try await currentToken(for: environmentId, rejecting: rejectedTokenId)
      // The descriptor is read on every connect: the server's protocol version can change under a saved environment.
      let descriptor = try await EnvironmentHTTPClient(baseURL: token.endpoint.http, session: urlSession).descriptor()
      guard descriptor.environmentId == environmentId.rawValue else { throw ConnectionAttemptError.blocked(.configuration, detail: Self.mismatch(descriptor.environmentId, environmentId)) }
      return ManagedConnectionGrant(descriptor: descriptor, httpBaseURL: token.endpoint.http, wsBaseURL: token.endpoint.ws, authorization: authorizer(for: token))
    } catch {
      throw Self.classify(error)
    }
  }

  /// Sign-out or account switch: forget every token and the relay's.
  public func reset() async {
    generation += 1
    tokens = [:]
    exchanges.values.forEach { $0.cancel() }
    exchanges = [:]
    await relay.resetTokens()
  }

  // MARK: Tokens

  /// Signs requests for one environment with whichever token is current when the request is made, renewing it when it expired
  /// mid-session. It refuses any URL outside the environment's own endpoint: the token must never travel elsewhere.
  private func authorizer(for token: Token) -> DPoPAuthorizer {
    let environmentId = token.environmentId
    let endpoint = token.endpoint
    return DPoPAuthorizer(id: token.id) { [weak self] method, url in
      guard let self else { throw ConnectionAttemptError.blocked(.authentication, detail: "T3 Connect is not available.") }
      guard Self.sameOrigin(url, endpoint.http) else {
        throw ConnectionAttemptError.blocked(.configuration, detail: "A managed environment token was about to be sent to another host.")
      }
      let current = try await self.currentTokenForRequest(environmentId)
      let proof = try await self.signer.proof(method: method, url: url, accessToken: current.accessToken)
      return ["Authorization": "DPoP \(current.accessToken)", "DPoP": proof]
    }
  }

  private func currentTokenForRequest(_ environmentId: EnvironmentId) async throws -> Token {
    do { return try await currentToken(for: environmentId, rejecting: nil) } catch { throw Self.classify(error) }
  }

  func currentToken(for environmentId: EnvironmentId, rejecting rejectedTokenId: String?) async throws -> Token {
    guard let account = await session.account else { throw ConnectionAttemptError.blocked(.authentication, detail: Self.signedOutDetail) }
    let thumbprint = try await signer.thumbprint()
    if let cached = tokens[environmentId] {
      if cached.accountId == account.id, cached.thumbprint == thumbprint, cached.expiresAt.timeIntervalSince(now()) > Self.refreshSkew,
        cached.id != rejectedTokenId
      {
        return cached
      }
      // Never hand out a token again after the environment refused it, nor one an earlier account or key obtained.
      if cached.id == rejectedTokenId || cached.accountId != account.id || cached.thumbprint != thumbprint { tokens[environmentId] = nil }
    }
    if let running = exchanges[environmentId] { return try await running.value }
    let started = generation
    let task = Task { try await self.mint(environmentId, account: account, thumbprint: thumbprint) }
    exchanges[environmentId] = task
    defer { if started == generation { exchanges[environmentId] = nil } }
    let token = try await task.value
    // A sign-out or account change while the exchange ran: the token belongs to nobody now.
    guard started == generation, await session.account?.id == account.id else {
      throw ConnectionAttemptError.blocked(.authentication, detail: "Your cloud sign-in changed. Sign in again to authorize the environment.")
    }
    tokens[environmentId] = token
    return token
  }

  private func mint(_ environmentId: EnvironmentId, account: CloudAccount, thumbprint: String) async throws -> Token {
    let clerkToken = try await session.relayToken()
    let bootstrap = try await relay.connect(to: environmentId, clerkToken: clerkToken)
    guard bootstrap.environmentId == environmentId else { throw RelayError.environmentMismatch }
    let endpoint = try Self.validated(bootstrap.endpoint)
    let http = EnvironmentHTTPClient(baseURL: endpoint.http, session: urlSession)
    // The credential only goes to a host that has just proved it is this environment.
    let descriptor = try await http.descriptor()
    guard descriptor.environmentId == environmentId.rawValue else { throw ConnectionAttemptError.blocked(.configuration, detail: Self.mismatch(descriptor.environmentId, environmentId)) }
    let proof = try await signer.proof(method: "POST", url: http.endpointURL("/oauth/token"))
    let response = try await http.exchangeToken(credential: bootstrap.credential, scopes: nil, clientMetadata: metadata, dpopProof: proof)
    // A bearer token here would not be bound to this device; never accept one in place of DPoP.
    guard response.tokenType == "DPoP", !response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.expiresIn.isFinite, response.expiresIn > 0
    else { throw ConnectionAttemptError.blocked(.authentication, detail: "The environment did not issue a device-bound token.") }
    return Token(
      environmentId: environmentId, accountId: account.id, accessToken: response.accessToken, expiresAt: now().addingTimeInterval(response.expiresIn),
      thumbprint: thumbprint, endpoint: endpoint)
  }

  // MARK: Validation and errors

  /// A managed endpoint is a TLS origin: https for HTTP, wss for sockets, same host and port, no credentials.
  static func validated(_ endpoint: RelayManagedEndpoint) throws -> Endpoint {
    guard let http = URL(string: endpoint.httpBaseUrl), let ws = URL(string: endpoint.wsBaseUrl), http.scheme?.lowercased() == "https", ws.scheme?.lowercased() == "wss",
      let host = http.host?.lowercased(), !host.isEmpty, host == ws.host?.lowercased(), (http.port ?? 443) == (ws.port ?? 443),
      http.user == nil, http.password == nil, ws.user == nil, ws.password == nil
    else { throw RelayError.invalidConfiguration("The managed environment endpoint is invalid.") }
    return Endpoint(http: http, ws: ws)
  }

  static func sameOrigin(_ url: URL, _ endpoint: URL) -> Bool {
    url.scheme?.lowercased() == endpoint.scheme?.lowercased() && url.host?.lowercased() == endpoint.host?.lowercased()
      && (url.port ?? 443) == (endpoint.port ?? 443)
  }

  static let signedOutDetail = "Sign in to T3 Connect to open this environment."

  private static func mismatch(_ actual: String, _ expected: EnvironmentId) -> String { "Connected environment \(actual) does not match \(expected.rawValue)." }

  /// Everything thrown while authorizing, as a classified connection failure.
  static func classify(_ error: any Error) -> ConnectionAttemptError {
    switch error {
    case let error as ConnectionAttemptError: error
    case let error as RelayError: error.connectionAttemptError
    case let error as EnvironmentHTTPError: RelayConnectionDriver.map(error, label: "The environment")
    case let error as DPoPError: .blocked(.authentication, detail: error.errorDescription ?? "Could not load the device identity.")
    case let error as CloudSessionError: .blocked(.authentication, detail: error.errorDescription ?? signedOutDetail)
    case is CancellationError: .transient(.transport, detail: "The connection attempt was cancelled.")
    default: .transient(.relayUnavailable, detail: "T3 Connect failed: \(error.localizedDescription)")
    }
  }
}
