import Foundation
import Testing
import T3ClientRuntime
import T3Contracts
@testable import T3Connect

/// Payloads in the shape `infra/relay` answers with (packages/contracts/src/relay.ts), decoded by the generated contract types.
@Suite struct RelayDecodingTests {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }

  @Test func environmentListAndStatus() throws {
    let list = try decode(
      RelayListEnvironmentsResponse.self,
      #"{"environments":[{"environmentId":"env-1","label":"Studio","endpoint":{"httpBaseUrl":"https://studio.example","wsBaseUrl":"wss://studio.example","providerKind":"cloudflare_tunnel"},"linkedAt":"2026-08-01T12:00:00.000Z"}]}"#)
    #expect(list.environments.first?.environmentId.rawValue == "env-1")
    #expect(list.environments.first?.endpoint.providerKind == .cloudflare_tunnel)

    let offline = try decode(
      RelayEnvironmentStatusResponse.self,
      #"{"environmentId":"env-1","endpoint":{"httpBaseUrl":"https://studio.example","wsBaseUrl":"wss://studio.example","providerKind":"t3_relay"},"status":"offline","checkedAt":"2026-10-07T12:00:00Z","offlineReason":"tunnel_released","error":"connector unavailable","traceId":"trace-1"}"#)
    #expect(offline.status == .offline)
    #expect(offline.offlineReason == "tunnel_released")
    #expect(offline.traceId == "trace-1")
    // A reason this build does not know stays readable.
    let future = try decode(
      RelayEnvironmentStatusResponse.self,
      #"{"environmentId":"env-1","endpoint":{"httpBaseUrl":"https://s.example","wsBaseUrl":"wss://s.example","providerKind":"future_kind"},"status":"offline","checkedAt":"2026-10-07T12:00:00Z","offlineReason":"future_reason"}"#)
    #expect(future.offlineReason == "future_reason")
    #expect(future.endpoint.providerKind == .unknown("future_kind"))
  }

  @Test func dpopTokenResponseIsStrict() throws {
    let token = try decode(
      RelayDpopAccessTokenResponse.self,
      #"{"access_token":"relay-token","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":300,"scope":"environment:status environment:connect"}"#)
    #expect(token.access_token == "relay-token")
    #expect(token.expires_in == 300)
    // A bearer-typed or wrongly typed token is not a DPoP token: decoding refuses it.
    #expect(throws: (any Error).self) {
      try decode(RelayDpopAccessTokenResponse.self, #"{"access_token":"t","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":300,"scope":"s"}"#)
    }
    #expect(throws: (any Error).self) { try decode(RelayDpopAccessTokenResponse.self, #"{"access_token":"t","token_type":"DPoP","expires_in":300,"scope":"s"}"#) }
  }

  @Test func connectAndLinkResponses() throws {
    let connect = try decode(
      RelayEnvironmentConnectResponse.self,
      #"{"environmentId":"env-1","endpoint":{"httpBaseUrl":"https://env.example","wsBaseUrl":"wss://env.example","providerKind":"t3_relay"},"credential":"one-time","expiresAt":"2026-10-10T12:00:00.000Z"}"#)
    #expect(connect.credential == "one-time")

    let link = try decode(
      RelayEnvironmentLinkResponse.self,
      #"{"ok":true,"cloudUserId":"user-1","environmentId":"env-1","endpoint":{"httpBaseUrl":"https://env.example","wsBaseUrl":"wss://env.example","providerKind":"cloudflare_tunnel"},"endpointRuntime":null,"relayIssuer":"https://relay.example","environmentCredential":"credential","cloudMintPublicKey":"key"}"#)
    #expect(link.ok)
    #expect(link.endpointRuntime == nil)

    // The host schema requires `endpointRuntime` even when null.
    let config = try JSONEncoder().encode(
      RelayEnvironmentConfigRequest(relayUrl: "https://relay.example", relayIssuer: link.relayIssuer, cloudUserId: link.cloudUserId, environmentCredential: link.environmentCredential, cloudMintPublicKey: link.cloudMintPublicKey, endpointRuntime: nil))
    #expect(String(decoding: config, as: UTF8.self).contains(#""endpointRuntime":null"#))
  }

  @Test func connectRequestCarriesTheProofKeyThumbprint() throws {
    let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RelayEnvironmentConnectRequest(deviceId: nil, clientKeyThumbprint: "jkt", clientProofKeyThumbprint: "jkt"))) as? [String: Any]
    #expect(body?["clientProofKeyThumbprint"] as? String == "jkt")
    #expect(body?["clientKeyThumbprint"] as? String == "jkt")
    #expect(body?["deviceId"] == nil)
  }

  // MARK: Error presentation

  private func failure(_ json: String) throws -> RelayFailure { try decode(RelayFailure.self, json) }

  @Test func dpopFailuresGetTheRightAdvice() throws {
    let clock = try failure(#"{"code":"auth_invalid","reason":"invalid_dpop","dpopFailureReason":"time_window","traceId":"t"}"#)
    #expect(clock.presentation(requestUsesDPoP: true) == "Relay rejected the DPoP proof. \(RelayFailure.clockHint)")
    // Older relays omit the category: skew is only possible.
    let old = try failure(#"{"code":"auth_invalid","reason":"invalid_dpop","traceId":"t"}"#)
    #expect(old.presentation(requestUsesDPoP: true) == "Relay rejected the DPoP proof. \(RelayFailure.unknownHint)")
    for reason in ["key_mismatch", "request_mismatch", "token_mismatch", "replay", "invalid_proof", "future_reason"] {
      let neutral = try failure(#"{"code":"auth_invalid","reason":"invalid_dpop","dpopFailureReason":"\#(reason)","traceId":"t"}"#)
      #expect(neutral.presentation(requestUsesDPoP: true) == "Relay rejected the DPoP proof. \(RelayFailure.retryHint)")
    }
    // A request that sent no proof never gets clock advice.
    let bearer = try failure(#"{"code":"auth_invalid","reason":"invalid_dpop","dpopFailureReason":"time_window","message":"The session was rejected.","traceId":"t"}"#)
    #expect(bearer.presentation(requestUsesDPoP: false) == "The session was rejected.")
  }

  @Test func specificMessages() throws {
    #expect(
      try failure(#"{"code":"environment_connect_not_authorized","reason":"environment_link_not_found","traceId":"t"}"#).presentation(requestUsesDPoP: true)
        == "Relay has no active link for this environment. The environment server may not have re-established its link yet.")
    #expect(
      try failure(#"{"code":"environment_link_limit_exceeded","maxTunnels":3,"traceId":"t"}"#).presentation(requestUsesDPoP: true)
        == "Relay refused the link: this account already has its maximum of 3 managed tunnels. Unlink an environment to free one up.")
    #expect(try failure(#"{"code":"something_new","traceId":"t"}"#).presentation(requestUsesDPoP: true) == "something_new")
    let error = RelayError.failure(status: 504, try failure(#"{"code":"environment_endpoint_timed_out","traceId":"trace-timeout"}"#))
    #expect(error.errorDescription == "Relay timed out while contacting the environment endpoint. (trace trace-timeout)")
  }

  private func kind(_ error: ConnectionAttemptError) -> String {
    switch error {
    case .blocked(let reason, _, _): "blocked.\(reason.rawValue)"
    case .transient(let reason, _, _): "transient.\(reason.rawValue)"
    }
  }

  @Test func classification() throws {
    func attempt(_ status: Int, _ json: String) throws -> String { kind(RelayError.failure(status: status, try failure(json)).connectionAttemptError) }
    // Waiting for the user: authentication and permission. Retrying cannot fix them.
    #expect(try attempt(401, #"{"code":"auth_invalid","reason":"invalid_bearer","traceId":"t"}"#) == "blocked.authentication")
    #expect(try attempt(403, #"{"code":"environment_connect_not_authorized","traceId":"t"}"#) == "blocked.permission")
    #expect(try attempt(429, #"{"code":"environment_link_limit_exceeded","maxTunnels":1,"traceId":"t"}"#) == "blocked.permission")
    // Outages retry.
    #expect(try attempt(504, #"{"code":"environment_endpoint_timed_out","traceId":"t"}"#) == "transient.timeout")
    #expect(try attempt(502, #"{"code":"environment_endpoint_unavailable","reason":"tunnel_down","traceId":"t"}"#) == "transient.endpoint-unavailable")
    #expect(try attempt(500, #"{"code":"internal_error","reason":"database_unavailable","traceId":"t"}"#) == "transient.relay-unavailable")
    // An unknown code falls back to its status.
    #expect(try attempt(401, #"{"code":"brand_new"}"#) == "blocked.authentication")
    #expect(try attempt(503, #"{}"#) == "transient.relay-unavailable")
    #expect(kind(RelayError.transport("offline").connectionAttemptError) == "transient.network")
    #expect(kind(RelayError.timeout.connectionAttemptError) == "transient.timeout")
    #expect(kind(RelayError.environmentMismatch.connectionAttemptError) == "blocked.configuration")
    guard case .transient(_, _, let trace) = RelayError.failure(status: 500, try failure(#"{"code":"internal_error","traceId":"tr"}"#)).connectionAttemptError else { return }
    #expect(trace == "tr")
  }
}
