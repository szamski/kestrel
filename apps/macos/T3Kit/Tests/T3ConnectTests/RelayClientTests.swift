import Foundation
import Testing
import T3Contracts
@testable import T3Connect

@Suite(.timeLimit(.minutes(1))) @MainActor struct RelayClientTests {
  @Test func environmentListUsesTheAccountTokenAlone() async throws {
    let h = try await Harness()
    let environments = try await h.relay.listEnvironments(clerkToken: fakeClerkJWT(sub: "user_1"))
    #expect(environments.map(\.environmentId.rawValue) == ["env-1"])
    let request = try #require(FakeNetwork.requests(host: h.world.relayHost).first)
    #expect(request.header("Authorization")?.hasPrefix("Bearer ") == true)
    #expect(request.header("DPoP") == nil)
    #expect(h.world.relayRequests("/v1/client/dpop-token").isEmpty, "a list needs no DPoP exchange")
  }

  @Test func statusIsValidatedAgainstTheListedEnvironment() async throws {
    let h = try await Harness()
    let record = try #require(try await h.relay.listEnvironments(clerkToken: fakeClerkJWT(sub: "user_1")).first)
    // The fake relay has no status route (404): a missing route is a failure, not a pass.
    await #expect(throws: RelayError.self) { try await h.relay.status(of: record, clerkToken: fakeClerkJWT(sub: "user_1")) }
  }

  @Test func theRelayTokenIsCachedPerAccount() async throws {
    let h = try await Harness()
    let one = fakeClerkJWT(sub: "user_1")
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: one)
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_1"))
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 1, "the same account reuses its token even with a fresh Clerk JWT")
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_2"))
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2, "another account never receives the first account's token")
    let tokens = h.world.relayRequests("/v1/environments/env-1/connect").compactMap { $0.header("Authorization") }
    #expect(tokens == ["DPoP relay-token-1", "DPoP relay-token-1", "DPoP relay-token-2"])
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
  }

  @Test func theRelayTokenExpires() async throws {
    let h = try await Harness()
    let jwt = fakeClerkJWT(sub: "user_1")
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: jwt)
    h.clock.advance(296)
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: jwt)
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2, "within five seconds of expiry it is exchanged again")
  }

  @Test func concurrentCallersShareOneExchange() async throws {
    let h = try await Harness()
    let relay = h.relay, id = h.environmentId
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<6 { group.addTask { _ = try await relay.connect(to: id, clerkToken: fakeClerkJWT(sub: "user_1")) } }
      try await group.waitForAll()
    }
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 1)
  }

  @Test func aRejectedRelayTokenIsExchangedOnceMore() async throws {
    let h = try await Harness()
    h.world.edit { $0.connectStatuses = [401] }
    let response = try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_1"))
    #expect(response.credential.hasPrefix("boot+strap"))
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2)
    let tokens = h.world.relayRequests("/v1/environments/env-1/connect").compactMap { $0.header("Authorization") }
    #expect(tokens == ["DPoP relay-token-1", "DPoP relay-token-2"])

    // A second rejection is the relay's answer.
    h.world.edit { $0.connectStatuses = [401, 401] }
    await #expect(throws: RelayError.self) { try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_1")) }
  }

  @Test func signOutDropsCachedTokens() async throws {
    let h = try await Harness()
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_1"))
    await h.relay.resetTokens()
    _ = try await h.relay.connect(to: h.environmentId, clerkToken: fakeClerkJWT(sub: "user_1"))
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2)
  }

  @Test func theRelayMustGrantExactlyTheRequestedScopes() async throws {
    let host = uniqueHost("relay")
    FakeNetwork.serve(host: host) { request in
      request.url.path == "/v1/client/dpop-token"
        ? (200, #"{"access_token":"t","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":300,"scope":"environment:connect"}"#)
        : (404, "{}")
    }
    let relay = RelayClient(configuration: testConfiguration(relayHost: host), signer: try testSigner(), session: FakeNetwork.session())
    await #expect(throws: RelayError.unexpectedScopes(requested: RelayClient.scopes.sorted(), granted: "environment:connect")) {
      try await relay.connect(to: EnvironmentId(rawValue: "env-1"), clerkToken: fakeClerkJWT(sub: "u"))
    }
  }

  @Test func malformedAnswersAreRejected() async throws {
    let host = uniqueHost("relay")
    let token = #"{"access_token":"t","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"DPoP","expires_in":300,"scope":"environment:connect environment:status"}"#
    func serve(_ connect: String) {
      FakeNetwork.serve(host: host) { request in
        switch request.url.path {
        case "/v1/client/dpop-token": (200, token)
        case "/v1/environments/env-1/connect": (200, connect)
        case "/v1/client/environment-links/env-1": (200, #"{"ok":false}"#)
        default: (404, "{}")
        }
      }
    }
    let relay = RelayClient(configuration: testConfiguration(relayHost: host), signer: try testSigner(), session: FakeNetwork.session())
    let id = EnvironmentId(rawValue: "env-1")
    let endpoint = #""endpoint":{"httpBaseUrl":"https://e.test","wsBaseUrl":"wss://e.test","providerKind":"t3_relay"}"#
    serve(#"{"environmentId":"env-1",\#(endpoint),"credential":"   ","expiresAt":"2026-10-10T12:00:00Z"}"#)
    await #expect(throws: RelayError.invalidResponse) { try await relay.connect(to: id, clerkToken: fakeClerkJWT(sub: "u")) }
    serve(#"{"environmentId":"another",\#(endpoint),"credential":"c","expiresAt":"2026-10-10T12:00:00Z"}"#)
    await #expect(throws: RelayError.environmentMismatch) { try await relay.connect(to: id, clerkToken: fakeClerkJWT(sub: "u")) }
    serve("not json")
    await #expect(throws: RelayError.invalidResponse) { try await relay.connect(to: id, clerkToken: fakeClerkJWT(sub: "u")) }
    await #expect(throws: RelayError.invalidResponse) { try await relay.unlinkEnvironment(clerkToken: fakeClerkJWT(sub: "u"), environmentId: id) }
  }
}
