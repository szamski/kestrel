import Foundation
import T3ClientRuntime
import T3Contracts

// The relay HTTP API a signed-in client calls (packages/client-runtime/src/relay/managedRelay.ts).
// Bodies and responses are the generated T3Contracts relay types. Environment lists and link calls
// authenticate with the Clerk token; status and connect use a DPoP access token the relay issues
// for the device's proof key in exchange for that Clerk token.

public enum RelayError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  case transport(String)
  case timeout
  case invalidResponse
  case failure(status: Int, RelayFailure)
  case unexpectedScopes(requested: [String], granted: String)
  case environmentMismatch
}

/// A declared relay error body (`RelayProtectedError`). Decoded by `code` rather than the `_tag`
/// union so older relays, which omit optional fields, and codes added later both stay readable.
public struct RelayFailure: Decodable, Sendable, Equatable {
  public var code: String?
  public var reason: String?
  public var message: String?
  public var dpopFailureReason: String?
  public var maxTunnels: Int?
  public var traceId: String?

  public init(code: String? = nil, reason: String? = nil, message: String? = nil, dpopFailureReason: String? = nil, maxTunnels: Int? = nil, traceId: String? = nil) {
    self.code = code
    self.reason = reason
    self.message = message
    self.dpopFailureReason = dpopFailureReason
    self.maxTunnels = maxTunnels
    self.traceId = traceId
  }

  static let clockHint = "Hint: Check that automatic date and time is enabled on this Mac, then try again."
  static let unknownHint = "Hint: Try again. If it still fails, clock skew may be the cause; check that automatic date and time is enabled on this Mac."
  static let retryHint = "Hint: Try again. If the problem continues, copy the trace ID."

  /// `relayProtectedErrorMessage`. A request that sent no DPoP proof never gets DPoP advice.
  func presentation(requestUsesDPoP: Bool) -> String {
    switch code {
    case "auth_invalid":
      switch reason {
      case "missing_bearer", "invalid_bearer": return "Relay rejected the cloud session token."
      case "invalid_dpop" where requestUsesDPoP:
        let hint = dpopFailureReason == nil ? Self.unknownHint : dpopFailureReason == "time_window" ? Self.clockHint : Self.retryHint
        return "Relay rejected the DPoP proof. \(hint)"
      case "not_authorized": return "Relay rejected the authenticated request."
      default: break
      }
    case "environment_link_proof_expired": return "Relay rejected an expired environment link proof."
    case "environment_link_proof_invalid":
      if let reason { return "Relay rejected the environment link proof (\(reason))." }
    case "environment_connect_not_authorized":
      // "Not authorized" covers non-auth causes too; a missing link must not read as a credential problem.
      if reason == "environment_link_not_found" {
        return "Relay has no active link for this environment. The environment server may not have re-established its link yet."
      }
      return reason.map { "Relay rejected the environment connection request (\($0))." } ?? "Relay rejected the environment connection request."
    case "environment_endpoint_unavailable":
      if let reason { return "Relay could not reach the environment endpoint (\(reason))." }
    case "environment_endpoint_timed_out": return "Relay timed out while contacting the environment endpoint."
    case "environment_link_failed":
      if let reason { return "Relay could not link the environment (\(reason))." }
    case "environment_link_unavailable":
      if let reason { return "Relay cannot provision the managed endpoint (\(reason))." }
    case "environment_link_limit_exceeded":
      if let maxTunnels {
        return "Relay refused the link: this account already has its maximum of \(maxTunnels) managed tunnels. Unlink an environment to free one up."
      }
      return "Relay refused the link because this account has reached its managed tunnel limit. Unlink an environment to free one up."
    case "internal_error":
      if let reason { return "Relay encountered an internal error (\(reason))." }
    default: break
    }
    return message ?? reason ?? code ?? "T3 Connect request failed."
  }
}

extension RelayError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message): message
    case .transport(let message): "\(message) \(Self.networkHint)"
    case .timeout: "T3 Connect timed out. \(Self.networkHint)"
    case .invalidResponse: "T3 Connect returned an invalid response."
    case .failure(let status, let failure):
      // The DPoP flag only picks advice text; a decoded body with a trace id is what the user can report.
      failure.presentation(requestUsesDPoP: true) + (failure.traceId.map { " (trace \($0))" } ?? " (HTTP \(status))")
    case .unexpectedScopes(let requested, let granted): "T3 Connect granted \(granted) instead of \(requested.joined(separator: " "))."
    case .environmentMismatch: "T3 Connect returned credentials for a different environment."
    }
  }

  static let networkHint = "Your DNS or firewall may be blocking T3 Connect. Try another network, such as a phone hotspot."

  /// How a failed relay call affects a connection (`mapManagedRelayError`): authentication and permission wait for the
  /// user; outages retry.
  public var connectionAttemptError: ConnectionAttemptError {
    switch self {
    case .invalidConfiguration, .environmentMismatch:
      return .blocked(.configuration, detail: errorDescription ?? "T3 Connect is not configured correctly.")
    case .unexpectedScopes: return .blocked(.permission, detail: errorDescription ?? "Relay granted unexpected access.")
    case .transport: return .transient(.network, detail: errorDescription ?? "Could not reach T3 Connect.")
    case .timeout: return .transient(.timeout, detail: errorDescription ?? "T3 Connect timed out.")
    case .invalidResponse: return .transient(.relayUnavailable, detail: errorDescription ?? "T3 Connect returned an invalid response.")
    case .failure(let status, let failure):
      let detail = failure.presentation(requestUsesDPoP: true)
      let trace = failure.traceId
      switch failure.code {
      case "auth_invalid", "environment_link_proof_expired", "agent_activity_publish_proof_expired", "agent_activity_publish_proof_invalid":
        return .blocked(.authentication, detail: detail, traceId: trace)
      case "environment_connect_not_authorized", "environment_link_proof_invalid", "environment_link_limit_exceeded":
        return .blocked(.permission, detail: detail, traceId: trace)
      case "environment_endpoint_timed_out": return .transient(.timeout, detail: detail, traceId: trace)
      case "environment_endpoint_unavailable", "environment_link_unavailable": return .transient(.endpointUnavailable, detail: detail, traceId: trace)
      case "environment_link_failed", "internal_error": return .transient(.relayUnavailable, detail: detail, traceId: trace)
      default:
        if status == 401 { return .blocked(.authentication, detail: detail, traceId: trace) }
        if status == 403 { return .blocked(.permission, detail: detail, traceId: trace) }
        return .transient(.relayUnavailable, detail: detail, traceId: trace)
      }
    }
  }
}

public actor RelayClient {
  /// The relay issues DPoP tokens to `t3-web` and `t3-mobile` only (RelayPublicClientId). The desktop app is the web client in
  /// a shell, so a native macOS client identifies as `t3-web`; `t3-web` cannot request `mobile:registration`, which nothing here needs.
  public static let clientId = "t3-web"
  /// One token serves status and connect; the relay must grant exactly this set.
  public static let scopes = ["environment:connect", "environment:status"]
  public static let requestTimeout: TimeInterval = 10

  private struct CachedToken: Sendable {
    let accessToken: String
    let expiresAt: Date
    let thumbprint: String
  }

  private let configuration: T3ConnectConfiguration
  private let signer: DPoPSigner
  private let session: URLSession
  private let now: @Sendable () -> Date
  private var tokens: [String: CachedToken] = [:]
  /// Bumped by `resetTokens`: an exchange that finishes after a sign-out must not repopulate the cache.
  private var generation = 0
  private var exchanges: [String: Task<CachedToken, any Error>] = [:]

  public init(
    configuration: T3ConnectConfiguration, signer: DPoPSigner, session: URLSession = URLSession(configuration: .ephemeral),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.signer = signer
    self.session = session
    self.now = now
  }

  // MARK: Clerk-token calls

  public func listEnvironments(clerkToken: String) async throws -> [RelayClientEnvironmentRecord] {
    let response: RelayListEnvironmentsResponse = try await send(request(["v1", "environments"], "GET", bearer: clerkToken))
    return response.environments
  }

  public func createLinkChallenge(clerkToken: String, _ payload: RelayEnvironmentLinkChallengeRequest) async throws -> RelayEnvironmentLinkChallengeResponse {
    try await send(try request(["v1", "client", "environment-link-challenges"], "POST", bearer: clerkToken, json: payload))
  }

  public func linkEnvironment(clerkToken: String, _ payload: RelayEnvironmentLinkRequest) async throws -> RelayEnvironmentLinkResponse {
    try await send(try request(["v1", "client", "environment-links"], "POST", bearer: clerkToken, json: payload))
  }

  public func unlinkEnvironment(clerkToken: String, environmentId: EnvironmentId) async throws {
    let response: RelayOkResponse = try await send(request(["v1", "client", "environment-links", environmentId.rawValue], "DELETE", bearer: clerkToken))
    guard response.ok else { throw RelayError.invalidResponse }
  }

  // MARK: DPoP calls

  public func status(of environment: RelayClientEnvironmentRecord, clerkToken: String) async throws -> RelayEnvironmentStatusResponse {
    let response: RelayEnvironmentStatusResponse = try await sendDPoP(["v1", "environments", environment.environmentId.rawValue, "status"], body: nil, clerkToken: clerkToken)
    guard response.environmentId == environment.environmentId, response.endpoint == environment.endpoint,
      response.descriptor == nil || response.descriptor?.environmentId == environment.environmentId
    else { throw RelayError.environmentMismatch }
    return response
  }

  /// A one-time bootstrap credential the environment exchanges for a DPoP token bound to this device's key.
  public func connect(to environmentId: EnvironmentId, clerkToken: String, deviceId: String? = nil) async throws -> RelayEnvironmentConnectResponse {
    let thumbprint = try await signer.thumbprint()
    // Both names carry the same value: older relays read the alias, newer ones the explicit name.
    let body = try JSONEncoder().encode(
      RelayEnvironmentConnectRequest(deviceId: deviceId, clientKeyThumbprint: thumbprint, clientProofKeyThumbprint: thumbprint))
    let response: RelayEnvironmentConnectResponse = try await sendDPoP(
      ["v1", "environments", environmentId.rawValue, "connect"], body: body, clerkToken: clerkToken)
    guard response.environmentId == environmentId else { throw RelayError.environmentMismatch }
    guard !response.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !response.expiresAt.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw RelayError.invalidResponse }
    return response
  }

  /// Sign-out and account changes: tokens belong to the account that asked for them.
  public func resetTokens() {
    generation += 1
    tokens = [:]
    exchanges.values.forEach { $0.cancel() }
    exchanges = [:]
  }

  // MARK: DPoP token

  private func sendDPoP<Response: Decodable & Sendable>(_ path: [String], body: Data?, clerkToken: String) async throws -> Response {
    var refreshRejectedToken = true
    while true {
      let token = try await accessToken(clerkToken: clerkToken)
      let url = endpoint(path)
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.httpBody = body
      if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
      request.setValue("DPoP \(token.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(try await signer.proof(method: "POST", url: url, accessToken: token.accessToken), forHTTPHeaderField: "DPoP")
      do {
        return try await send(request)
      } catch RelayError.failure(let status, let failure) where status == 401 && failure.code == "auth_invalid" && failure.reason == "invalid_bearer" && refreshRejectedToken {
        // The relay refused a cached access token (revoked or expired early): exchange once more, then give up.
        refreshRejectedToken = false
        tokens = tokens.filter { $0.value.accessToken != token.accessToken }
      }
    }
  }

  private func accessToken(clerkToken: String) async throws -> CachedToken {
    let thumbprint = try await signer.thumbprint()
    // The JWT subject only partitions the cache by account; it authenticates nothing.
    let account = Self.subject(of: clerkToken)
    let key = account.map { "\($0)|\(thumbprint)" }
    if let key, let cached = tokens[key], cached.thumbprint == thumbprint, cached.expiresAt.timeIntervalSince(now()) > 5 { return cached }
    guard let key else { return try await exchange(clerkToken: clerkToken, thumbprint: thumbprint) }
    // Concurrent callers share one exchange; one caller's cancellation must not cancel the others'.
    if let running = exchanges[key] { return try await running.value }
    let started = generation
    let task = Task { try await self.exchange(clerkToken: clerkToken, thumbprint: thumbprint) }
    exchanges[key] = task
    defer { if started == generation { exchanges[key] = nil } }
    let token = try await task.value
    if started == generation { tokens[key] = token }
    return token
  }

  private func exchange(clerkToken: String, thumbprint: String) async throws -> CachedToken {
    let url = endpoint(["v1", "client", "dpop-token"])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(try await signer.proof(method: "POST", url: url), forHTTPHeaderField: "DPoP")
    let scopes = Self.scopes.sorted()
    request.httpBody = Data(
      Self.form([
        ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
        ("subject_token", clerkToken),
        ("subject_token_type", "urn:ietf:params:oauth:token-type:jwt"),
        ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
        ("resource", configuration.relayURL.absoluteString),
        ("scope", scopes.joined(separator: " ")),
        ("client_id", Self.clientId),
      ]).utf8)
    // The generated decoder already requires `token_type == DPoP` and the access-token `issued_token_type`.
    let response: RelayDpopAccessTokenResponse = try await send(request)
    guard Set(response.scope.split(separator: " ").map(String.init)) == Set(scopes) else {
      throw RelayError.unexpectedScopes(requested: scopes, granted: response.scope)
    }
    guard !response.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, response.expires_in > 0 else { throw RelayError.invalidResponse }
    return CachedToken(accessToken: response.access_token, expiresAt: now().addingTimeInterval(TimeInterval(response.expires_in)), thumbprint: thumbprint)
  }

  // MARK: Transport

  private func endpoint(_ path: [String]) -> URL {
    var segments = CharacterSet.urlPathAllowed
    segments.remove("/")
    let encoded = path.map { $0.addingPercentEncoding(withAllowedCharacters: segments) ?? $0 }
    return URL(string: configuration.relayURL.absoluteString + "/" + encoded.joined(separator: "/"))!
  }

  private func request(_ path: [String], _ method: String, bearer: String) -> URLRequest {
    var request = URLRequest(url: endpoint(path))
    request.httpMethod = method
    request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func request<Body: Encodable>(_ path: [String], _ method: String, bearer: String, json: Body) throws -> URLRequest {
    var request = request(path, method, bearer: bearer)
    request.httpBody = try JSONEncoder().encode(json)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func send<Response: Decodable & Sendable>(_ request: URLRequest) async throws -> Response {
    var request = request
    request.timeoutInterval = Self.requestTimeout
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw RelayError.timeout
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw RelayError.transport(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw RelayError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw RelayError.failure(status: http.statusCode, (try? JSONDecoder().decode(RelayFailure.self, from: data)) ?? RelayFailure())
    }
    do { return try JSONDecoder().decode(Response.self, from: data) } catch { throw RelayError.invalidResponse }
  }

  // MARK: Helpers

  static func form(_ fields: [(String, String)]) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
    return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
  }

  static func subject(of jwt: String) -> String? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let data = Data(base64URLEncoded: String(parts[1])),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let sub = claims["sub"] as? String, !sub.isEmpty
    else { return nil }
    return sub
  }
}
