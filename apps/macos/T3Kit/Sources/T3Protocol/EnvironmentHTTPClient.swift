import Foundation

// HTTP side of an environment, as used by packages/client-runtime
// (authorization/remote.ts, rpc/http.ts). Response types are minimal on purpose:
// they carry only what this module needs; richer models come from T3Contracts.

public struct EnvironmentDescriptorInfo: Decodable, Sendable, Equatable {
  public let environmentId: String
  public let label: String
  public let serverVersion: String
  /// Missing means protocol 1 (servers older than version negotiation).
  public let orchestrationProtocolVersion: Int?
}

public struct AccessTokenResponse: Decodable, Sendable, Equatable {
  public let accessToken: String
  /// "Bearer", or "DPoP" once T3 Connect lands.
  public let tokenType: String
  public let expiresIn: Double
  public let scope: String

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in", scope
  }
}

public struct WebSocketTicket: Decodable, Sendable, Equatable {
  public let ticket: String
  public let expiresAt: String
}

public struct AuthSessionInfo: Decodable, Sendable, Equatable {
  public let authenticated: Bool
  public let scopes: [String]?
  public let sessionMethod: String?
  public let expiresAt: String?
}

/// How an authenticated request proves itself. DPoP only builds the headers; minting
/// the proof is the (later) T3 Connect work.
public enum RequestAuthorization: Sendable, Equatable {
  case bearer(String)
  case dpop(accessToken: String, proof: String)

  var headers: [String: String] {
    switch self {
    case .bearer(let token): ["Authorization": "Bearer \(token)"]
    case .dpop(let token, let proof): ["Authorization": "DPoP \(token)", "DPoP": proof]
    }
  }
}

/// Client identity announced on token exchange and on the /ws URL.
public struct ClientMetadata: Sendable, Equatable {
  public var label: String?
  public var appVersion: String?
  public var surface = "desktop"
  public var deviceType = "desktop"
  /// Must be "macOS": the server validates against contracts' ClientOs literals.
  public var os = "macOS"

  public init(label: String? = nil, appVersion: String? = nil) {
    self.label = label
    self.appVersion = appVersion
  }
}

public enum ConnectionMethod: String, Sendable {
  case direct, ssh, relay, unknown
}

public enum EnvironmentHTTPError: Error, Sendable, Equatable {
  case transport(String)
  case timeout(URL)
  /// A declared environment error body (`code` is e.g. `auth_invalid`, `insufficient_scope`).
  case server(status: Int, code: String?, reason: String?, requiredScope: String?, traceId: String?)
  case invalidJSON(String)

  public var isAuthInvalid: Bool {
    if case .server(401, _, _, _, _) = self { return true }
    return false
  }
}

public struct EnvironmentHTTPClient: Sendable {
  public static let tokenExchangeGrantType = "urn:ietf:params:oauth:grant-type:token-exchange"
  public static let accessTokenType = "urn:ietf:params:oauth:token-type:access_token"
  public static let bootstrapTokenType = "urn:t3:params:oauth:token-type:environment-bootstrap"

  public let baseURL: URL
  private let session: URLSession
  private let timeout: TimeInterval

  /// URLSession negotiates and decodes gzip transparently.
  public init(baseURL: URL, session: URLSession = URLSession(configuration: .ephemeral), timeout: TimeInterval = 10) {
    self.baseURL = baseURL
    self.session = session
    self.timeout = timeout
  }

  // MARK: Endpoints

  public func descriptor() async throws -> EnvironmentDescriptorInfo {
    try await get("/.well-known/t3/environment")
  }

  /// Exchanges a pairing/bootstrap credential for an access token (`POST /oauth/token`).
  public func exchangeToken(
    credential: String,
    scopes: [String]? = nil,
    clientMetadata: ClientMetadata? = nil,
    dpopProof: String? = nil
  ) async throws -> AccessTokenResponse {
    var headers = ["Content-Type": "application/x-www-form-urlencoded"]
    headers["DPoP"] = dpopProof
    let form = Self.tokenExchangeForm(credential: credential, scopes: scopes, clientMetadata: clientMetadata)
    return try await send(method: "POST", path: "/oauth/token", headers: headers, body: Data(form.utf8))
  }

  public func authSession(auth: RequestAuthorization?) async throws -> AuthSessionInfo {
    try await get("/api/auth/session", auth: auth)
  }

  public func webSocketTicket(auth: RequestAuthorization) async throws -> WebSocketTicket {
    try await send(method: "POST", path: "/api/auth/websocket-ticket", headers: auth.headers, body: nil)
  }

  // MARK: Authorized JSON helpers

  /// `orchestrationProtocol` marks an orchestration endpoint call: protocol-2 servers require
  /// the `x-t3-orchestration-protocol` header there; protocol-1 servers predate it, so it is not sent.
  public func get<Response: Decodable & Sendable>(
    _ path: String, query: [URLQueryItem] = [], auth: RequestAuthorization? = nil,
    orchestrationProtocol: OrchestrationProtocol? = nil
  ) async throws -> Response {
    var headers = auth?.headers ?? [:]
    Self.addOrchestrationProtocol(orchestrationProtocol, to: &headers)
    return try await send(method: "GET", path: path, query: query, headers: headers, body: nil)
  }

  public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
    _ path: String, body: Body, auth: RequestAuthorization? = nil,
    orchestrationProtocol: OrchestrationProtocol? = nil
  ) async throws -> Response {
    var headers = auth?.headers ?? [:]
    Self.addOrchestrationProtocol(orchestrationProtocol, to: &headers)
    headers["Content-Type"] = "application/json"
    return try await send(method: "POST", path: path, headers: headers, body: try JSONEncoder().encode(body))
  }

  // MARK: Internals

  static func addOrchestrationProtocol(_ version: OrchestrationProtocol?, to headers: inout [String: String]) {
    if let version, version >= .v2 { headers[OrchestrationProtocol.headerName] = String(version.rawValue) }
  }

  static func tokenExchangeForm(credential: String, scopes: [String]?, clientMetadata: ClientMetadata?) -> String {
    var fields = [
      ("grant_type", tokenExchangeGrantType),
      ("subject_token", credential),
      ("subject_token_type", bootstrapTokenType),
      ("requested_token_type", accessTokenType),
    ]
    if let scopes { fields.append(("scope", scopes.joined(separator: " "))) }
    if let label = clientMetadata?.label { fields.append(("client_label", label)) }
    if let deviceType = clientMetadata?.deviceType { fields.append(("client_device_type", deviceType)) }
    if let os = clientMetadata?.os { fields.append(("client_os", os)) }
    return fields.map { "\($0.0)=\(formEscape($0.1))" }.joined(separator: "&")
  }

  private func send<Response: Decodable & Sendable>(
    method: String, path: String, query: [URLQueryItem] = [], headers: [String: String], body: Data?
  ) async throws -> Response {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.path = path
    components.fragment = nil
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw EnvironmentHTTPError.timeout(request.url!)
    } catch {
      throw EnvironmentHTTPError.transport(error.localizedDescription)
    }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw EnvironmentHTTPError.transport("Non-HTTP response from \(request.url!)")
    }
    guard (200..<300).contains(status) else {
      let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
      throw EnvironmentHTTPError.server(
        status: status, code: body?.code, reason: body?.reason,
        requiredScope: body?.requiredScope, traceId: body?.traceId)
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw EnvironmentHTTPError.invalidJSON("\(error)")
    }
  }

  private struct ErrorBody: Decodable {
    let code: String?
    let reason: String?
    let requiredScope: String?
    let traceId: String?
  }
}

/// RFC 3986 unreserved characters only, so `+`, `&`, `=` and spaces never leak through.
func formEscape(_ value: String) -> String {
  value.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? value
}

extension CharacterSet {
  static let urlUnreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
