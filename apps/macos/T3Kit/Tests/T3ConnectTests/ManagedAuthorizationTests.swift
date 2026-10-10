import Foundation
import Testing
import T3ClientRuntime
import T3Contracts
import T3Protocol
@testable import T3Connect

@Suite(.timeLimit(.minutes(1))) @MainActor struct ManagedAuthorizationTests {
  private func kind(_ error: ConnectionAttemptError) -> String {
    switch error {
    case .blocked(let reason, _, _): "blocked.\(reason.rawValue)"
    case .transient(let reason, _, _): "transient.\(reason.rawValue)"
    }
  }

  private func authorize(_ harness: Harness, rejecting: String? = nil) async -> Result<ManagedConnectionGrant, ConnectionAttemptError> {
    do { return .success(try await harness.authorizer.authorize(harness.environmentId, rejecting: rejecting)) } catch { return .failure(error) }
  }

  @Test func fullFlowBootstrapsADeviceBoundToken() async throws {
    let h = try await Harness()
    let grant = try await authorize(h).get()

    #expect(grant.descriptor.environmentId == "env-1")
    #expect(grant.httpBaseURL.host == h.world.envHost)
    #expect(grant.wsBaseURL.scheme == "wss")
    // Account sign-in → relay DPoP token → bootstrap → environment DPoP token: one of each.
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 1)
    #expect(h.world.relayRequests("/v1/environments/env-1/connect").count == 1)
    #expect(h.world.envRequests("/oauth/token").count == 1)
    #expect(h.cloud.tokenCalls == 1)
    // The bootstrap credential only went to the environment's own token endpoint, never to the relay's host as an environment token.
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
    // The environment exchange carries the client identity the server shows in its client list.
    let form = try #require(h.world.envRequests("/oauth/token").first).form
    #expect(form["client_label"] == "T3 Code macOS")

    // The grant signs any request to that endpoint with a fresh proof bound to the token, over the URL without its query.
    let url = URL(string: "https://\(h.world.envHost)/api/orchestration/shell?turnLimit=5")!
    let first = try await grant.authorization.headers(method: "GET", url: url)
    let second = try await grant.authorization.headers(method: "GET", url: url)
    #expect(first["Authorization"] == "DPoP env-token-1")
    #expect(first["DPoP"] != second["DPoP"], "a proof is never reused")
    let verified = try verifyDPoP(first["DPoP"], method: "GET", url: url, accessToken: "env-token-1", expectedThumbprint: h.world.thumbprint)
    #expect(verified.thumbprint == h.world.thumbprint)
  }

  @Test func theWebSocketTicketIsRequestedOverDPoP() async throws {
    let h = try await Harness()
    let grant = try await authorize(h).get()
    let ticket = try await EnvironmentHTTPClient(baseURL: grant.httpBaseURL, session: h.world.session).webSocketTicket(auth: .dpop(grant.authorization))
    #expect(ticket.ticket == "tk-1")
    let request = try #require(h.world.envRequests("/api/auth/websocket-ticket").first)
    #expect(request.header("Authorization") == "DPoP env-token-1")
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
  }

  @Test func aCachedTokenIsReusedWithoutTouchingTheRelay() async throws {
    let h = try await Harness()
    _ = try await authorize(h).get()
    _ = try await authorize(h).get()
    #expect(h.world.relayRequests("/v1/environments/env-1/connect").count == 1)
    #expect(h.world.envRequests("/oauth/token").count == 1)
    // The descriptor is still read on every connect: the protocol version can change under a saved environment.
    #expect(h.world.envRequests("/.well-known/t3/environment").count == 3)
  }

  @Test func expiryRefreshIsSingleFlight() async throws {
    let h = try await Harness()
    _ = try await authorize(h).get()
    h.clock.advance(3600 - 30)  // inside the one-minute renewal margin
    let tasks = (0..<8).map { _ in
      Task { @MainActor () -> String in
        switch await self.authorize(h) {
        case .success(let grant): grant.authorization.id
        case .failure(let error): "failed: \(error)"
        }
      }
    }
    var results: [String] = []
    for task in tasks { results.append(await task.value) }
    #expect(Set(results).count == 1, "\(results)")
    #expect(h.world.relayRequests("/v1/environments/env-1/connect").count == 2, "eight callers share one renewal")
    #expect(h.world.envRequests("/oauth/token").count == 2)
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
  }

  @Test func aRejectedTokenIsNeverHandedOutAgain() async throws {
    let h = try await Harness()
    let first = try await authorize(h).get()
    let replacement = try await authorize(h, rejecting: first.authorization.id).get()
    #expect(replacement.authorization.id != first.authorization.id)
    #expect(h.world.envRequests("/oauth/token").count == 2)
    let url = URL(string: "https://\(h.world.envHost)/api/x")!
    #expect(try await replacement.authorization.headers(method: "GET", url: url)["Authorization"] == "DPoP env-token-2")
  }

  @Test func theRequestSignerRenewsAnExpiredTokenMidSession() async throws {
    let h = try await Harness()
    let grant = try await authorize(h).get()
    h.clock.advance(3600)
    let url = URL(string: "https://\(h.world.envHost)/api/orchestration/shell")!
    let headers = try await grant.authorization.headers(method: "GET", url: url)
    #expect(headers["Authorization"] == "DPoP env-token-2", "an HTTP load an hour into a session uses a fresh token")
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
  }

  // MARK: Never a bearer

  @Test func aBearerTokenIsRefusedInsteadOfDPoP() async throws {
    let h = try await Harness()
    h.world.edit { $0.envTokenType = "Bearer" }
    guard case .failure(let error) = await authorize(h) else { Issue.record("a bearer token must not be accepted for a managed environment"); return }
    #expect(kind(error) == "blocked.authentication")
    #expect(h.world.envRequests("/api/auth/websocket-ticket").isEmpty, "nothing was authorized with the token")
  }

  @Test func theEnvironmentNeverSeesABearerHeader() async throws {
    let h = try await Harness()
    let grant = try await authorize(h).get()
    // The environment refuses the token twice: both the first ticket and the retry, as the driver does. Every request stays DPoP.
    h.world.edit { $0.ticketStatuses = [401, 401] }
    let http = EnvironmentHTTPClient(baseURL: grant.httpBaseURL, session: h.world.session)
    await #expect(throws: EnvironmentHTTPError.self) { try await http.webSocketTicket(auth: .dpop(grant.authorization)) }
    let replacement = try await authorize(h, rejecting: grant.authorization.id).get()
    await #expect(throws: EnvironmentHTTPError.self) { try await http.webSocketTicket(auth: .dpop(replacement.authorization)) }
    for request in FakeNetwork.requests(host: h.world.envHost) {
      let authorization = request.header("Authorization")
      #expect(authorization == nil || authorization?.hasPrefix("DPoP ") == true, "\(request.url.path) sent \(authorization ?? "")")
    }
    #expect(h.world.violations.isEmpty, "\(h.world.violations)")
  }

  // MARK: Trust boundaries

  @Test func theTokenIsNeverSignedForAnotherHost() async throws {
    let h = try await Harness()
    let grant = try await authorize(h).get()
    await #expect(throws: ConnectionAttemptError.self) { try await grant.authorization.headers(method: "GET", url: URL(string: "https://evil.example/api/x")!) }
    await #expect(throws: ConnectionAttemptError.self) { try await grant.authorization.headers(method: "GET", url: URL(string: "http://\(h.world.envHost)/api/x")!) }
  }

  @Test func anInsecureOrMismatchedEndpointNeverReceivesTheBootstrapCredential() async throws {
    for endpoint in [("http://insecure.test", "ws://insecure.test"), ("https://a.test", "wss://b.test"), ("https://user:pw@a.test", "wss://user:pw@a.test"), ("https://a.test:8443", "wss://a.test")] {
      let h = try await Harness()
      h.world.edit { $0.connectEndpoint = endpoint }
      guard case .failure(let error) = await authorize(h) else { Issue.record("\(endpoint) must be refused"); return }
      #expect(kind(error) == "blocked.configuration", "\(endpoint)")
      #expect(h.world.envRequests("/oauth/token").isEmpty)
    }
  }

  @Test func aDifferentEnvironmentBehindTheEndpointNeverReceivesTheBootstrapCredential() async throws {
    let h = try await Harness()
    h.world.edit { $0.descriptorEnvironmentId = "somebody-else" }
    guard case .failure(let error) = await authorize(h) else { Issue.record("a descriptor for another environment must be refused"); return }
    #expect(kind(error) == "blocked.configuration")
    #expect(h.world.envRequests("/oauth/token").isEmpty, "the credential only goes to a host that proved it is this environment")
  }

  // MARK: Account changes

  @Test func signedOutBlocksWithoutNetwork() async throws {
    let h = try await Harness(account: nil)
    guard case .failure(let error) = await authorize(h) else { Issue.record("signed out must not connect"); return }
    #expect(kind(error) == "blocked.authentication")
    #expect(FakeNetwork.requests(host: h.world.relayHost).isEmpty)
  }

  @Test func aTokenNeverOutlivesItsAccount() async throws {
    let h = try await Harness()
    let first = try await authorize(h).get()
    h.cloud.account = CloudAccount(id: "user_2", email: "b@example.com")
    let second = try await authorize(h).get()
    #expect(second.authorization.id != first.authorization.id, "another account mints its own token")
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2, "the relay token is partitioned by account too")

    h.cloud.account = nil
    guard case .failure(let error) = await authorize(h) else { Issue.record("signed out must not reuse a cached token"); return }
    #expect(kind(error) == "blocked.authentication")
    // The grant obtained earlier stops signing after sign-out.
    await #expect(throws: ConnectionAttemptError.self) { try await second.authorization.headers(method: "GET", url: URL(string: "https://\(h.world.envHost)/api/x")!) }
  }

  @Test func resetForgetsEveryToken() async throws {
    let h = try await Harness()
    _ = try await authorize(h).get()
    await h.authorizer.reset()
    _ = try await authorize(h).get()
    #expect(h.world.envRequests("/oauth/token").count == 2)
    #expect(h.world.relayRequests("/v1/client/dpop-token").count == 2)
  }

  // MARK: Failure classification

  @Test func relayFailuresAreClassified() async throws {
    let h = try await Harness()
    h.world.edit { $0.connectStatuses = [403] }
    guard case .failure(let denied) = await authorize(h) else { Issue.record("403 must fail"); return }
    #expect(kind(denied) == "blocked.authentication")  // auth_invalid body → authentication
    h.world.edit { $0.relayTokenStatuses = [] }
    h.cloud.tokenFailure = URLError(.notConnectedToInternet)
    guard case .failure(let offline) = await authorize(h) else { Issue.record("a failing Clerk token must fail"); return }
    #expect(kind(offline) == "transient.relay-unavailable")
  }
}
