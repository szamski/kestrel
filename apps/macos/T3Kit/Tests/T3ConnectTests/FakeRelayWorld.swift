import Foundation
import Synchronization
import T3ClientRuntime
import T3Connect
import T3Contracts
import T3Protocol

/// A relay and one environment behind it, served in-process. Both check every DPoP proof the way the real servers do and record
/// anything they would have refused in `violations`, so a test asserts the whole conversation was well formed.
final class FakeRelayWorld: Sendable {
  struct State: Sendable {
    var violations: [String] = []
    var relayTokenSerial = 0
    var envTokenSerial = 0
    var bootstrapSerial = 0
    // Behaviour switches.
    var envTokenType = "DPoP"
    var envTokenLifetime = 3600
    var descriptorEnvironmentId: String?
    var connectEndpoint: (http: String, ws: String)?
    var ticketStatuses: [Int] = []
    var relayTokenStatuses: [Int] = []
    var connectStatuses: [Int] = []
  }

  let relayHost = uniqueHost("relay")
  let envHost = uniqueHost("env")
  let environmentId = "env-1"
  let thumbprint: String
  let state = Mutex(State())
  let session = FakeNetwork.session()

  init(thumbprint: String) {
    self.thumbprint = thumbprint
    FakeNetwork.serve(host: relayHost) { [self] in relay($0) }
    FakeNetwork.serve(host: envHost) { [self] in environment($0) }
  }

  var configuration: T3ConnectConfiguration { testConfiguration(relayHost: relayHost) }
  var violations: [String] { state.withLock { $0.violations } }
  func relayRequests(_ path: String) -> [FakeNetwork.Request] { FakeNetwork.requests(host: relayHost).filter { $0.url.path == path } }
  func envRequests(_ path: String) -> [FakeNetwork.Request] { FakeNetwork.requests(host: envHost).filter { $0.url.path == path } }
  func edit(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

  private func violation(_ text: String) { state.withLock { $0.violations.append(text) } }

  private func check(_ request: FakeNetwork.Request, token: String?, label: String) {
    do {
      _ = try verifyDPoP(request.header("DPoP"), method: request.method, url: request.url, accessToken: token, expectedThumbprint: thumbprint)
    } catch {
      violation("\(label): \(error)")
    }
  }

  private static func json(_ object: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }

  // MARK: Relay

  private func relay(_ request: FakeNetwork.Request) -> (status: Int, body: String) {
    switch (request.method, request.url.path) {
    case ("POST", "/v1/client/dpop-token"):
      if let status = state.withLock({ $0.relayTokenStatuses.isEmpty ? nil : $0.relayTokenStatuses.removeFirst() }), status != 200 {
        return (status, Self.json(["code": "auth_invalid", "reason": "invalid_bearer", "traceId": "relay-token"]))
      }
      check(request, token: nil, label: "relay token exchange")
      let form = request.form
      if form["client_id"] != "t3-web" || form["scope"] != "environment:connect environment:status" || form["resource"] != "https://\(relayHost)"
        || form["subject_token_type"] != "urn:ietf:params:oauth:token-type:jwt" || form["subject_token"]?.split(separator: ".").count != 3
      {
        violation("relay token exchange form: \(form)")
      }
      let serial = state.withLock { $0.relayTokenSerial += 1; return $0.relayTokenSerial }
      return (
        200,
        Self.json([
          "access_token": "relay-token-\(serial)", "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "token_type": "DPoP", "expires_in": 300,
          "scope": "environment:connect environment:status",
        ]))
    case ("POST", "/v1/environments/\(environmentId)/connect"):
      if let status = state.withLock({ $0.connectStatuses.isEmpty ? nil : $0.connectStatuses.removeFirst() }), status != 200 {
        return (status, Self.json(["code": "auth_invalid", "reason": "invalid_bearer", "traceId": "relay-connect"]))
      }
      let token = request.header("Authorization").flatMap { $0.hasPrefix("DPoP ") ? String($0.dropFirst(5)) : nil }
      if token == nil || !(token ?? "").hasPrefix("relay-token-") { violation("relay connect: Authorization \(request.header("Authorization") ?? "nil")") }
      check(request, token: token, label: "relay connect")
      let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
      if body?["clientProofKeyThumbprint"] as? String != thumbprint { violation("relay connect: thumbprint \(String(describing: body))") }
      let endpoint = state.withLock { $0.connectEndpoint } ?? ("https://\(envHost)", "wss://\(envHost)")
      let serial = state.withLock { $0.bootstrapSerial += 1; return $0.bootstrapSerial }
      return (
        200,
        Self.json([
          "environmentId": environmentId, "endpoint": ["httpBaseUrl": endpoint.http, "wsBaseUrl": endpoint.ws, "providerKind": "t3_relay"],
          "credential": "boot+strap-\(serial)", "expiresAt": "2026-10-10T12:00:00.000Z",
        ]))
    case ("GET", "/v1/environments"):
      guard request.header("Authorization")?.hasPrefix("Bearer ") == true, request.header("DPoP") == nil else {
        violation("list environments auth")
        return (401, Self.json(["code": "auth_invalid", "reason": "missing_bearer", "traceId": "t"]))
      }
      return (
        200,
        Self.json([
          "environments": [
            [
              "environmentId": environmentId, "label": "Studio",
              "endpoint": ["httpBaseUrl": "https://\(envHost)", "wsBaseUrl": "wss://\(envHost)", "providerKind": "t3_relay"], "linkedAt": "2026-08-01T12:00:00.000Z",
            ]
          ]
        ]))
    default:
      return (404, Self.json(["code": "not_found"]))
    }
  }

  // MARK: Environment

  private func environment(_ request: FakeNetwork.Request) -> (status: Int, body: String) {
    switch (request.method, request.url.path) {
    case ("GET", "/.well-known/t3/environment"):
      let id = state.withLock { $0.descriptorEnvironmentId } ?? environmentId
      return (200, Self.json(["environmentId": id, "label": "Studio", "serverVersion": "1.0.0", "orchestrationProtocolVersion": 2]))
    case ("POST", "/oauth/token"):
      check(request, token: nil, label: "environment token exchange")
      let form = request.form
      let serial = state.withLock { $0.bootstrapSerial }
      // The bootstrap credential arrives byte for byte: `+` must not turn into a space.
      if form["subject_token"] != "boot+strap-\(serial)" || form["subject_token_type"] != "urn:t3:params:oauth:token-type:environment-bootstrap"
        || form["client_device_type"] != "desktop" || form["client_os"] != "macOS" || form["grant_type"] != "urn:ietf:params:oauth:grant-type:token-exchange"
      {
        violation("environment token exchange form: \(form)")
      }
      let (type, lifetime, token) = state.withLock { state -> (String, Int, String) in
        state.envTokenSerial += 1
        return (state.envTokenType, state.envTokenLifetime, "env-token-\(state.envTokenSerial)")
      }
      return (
        200,
        Self.json([
          "access_token": token, "issued_token_type": "urn:ietf:params:oauth:token-type:access_token", "token_type": type, "expires_in": lifetime,
          "scope": "orchestration:read orchestration:operate",
        ]))
    default:
      // Every other environment request is authenticated: DPoP, bound to the current token, with a proof for this very request.
      let current = state.withLock { "env-token-\($0.envTokenSerial)" }
      guard let authorization = request.header("Authorization"), authorization.hasPrefix("DPoP ") else {
        violation("\(request.url.path): Authorization \(request.header("Authorization") ?? "nil")")
        return (401, Self.json(["code": "auth_invalid", "reason": "invalid_credential", "traceId": "env"]))
      }
      let token = String(authorization.dropFirst(5))
      if token != current { return (401, Self.json(["code": "auth_invalid", "reason": "invalid_credential", "traceId": "env"])) }
      check(request, token: token, label: request.url.path)
      if request.url.path == "/api/auth/websocket-ticket", let status = state.withLock({ $0.ticketStatuses.isEmpty ? nil : $0.ticketStatuses.removeFirst() }), status != 200 {
        return (status, Self.json(["code": "auth_invalid", "reason": "invalid_credential", "traceId": "env-ticket"]))
      }
      return (200, request.url.path == "/api/auth/websocket-ticket" ? Self.json(["ticket": "tk-1", "expiresAt": "2026-10-10T12:05:00.000Z"]) : "{}")
    }
  }
}

/// Everything wired against one `FakeRelayWorld`.
@MainActor
struct Harness {
  let world: FakeRelayWorld
  let cloud: FakeCloudSession
  let clock: TestClock
  let signer: DPoPSigner
  let relay: RelayClient
  let authorizer: ManagedEnvironmentAuthorizer
  let environmentId = EnvironmentId(rawValue: "env-1")

  init(account: CloudAccount? = CloudAccount(id: "user_1", email: "a@example.com")) async throws {
    let signer = try testSigner()
    let world = FakeRelayWorld(thumbprint: try await signer.thumbprint())
    let clock = TestClock()
    let cloud = FakeCloudSession(account: account)
    let relay = RelayClient(configuration: world.configuration, signer: signer, session: world.session, now: { clock.now })
    self.world = world
    self.cloud = cloud
    self.clock = clock
    self.signer = signer
    self.relay = relay
    authorizer = ManagedEnvironmentAuthorizer(
      relay: relay, session: cloud, signer: signer, metadata: ClientMetadata(label: "T3 Code macOS", appVersion: "1.0"), urlSession: world.session, now: { clock.now })
  }
}
