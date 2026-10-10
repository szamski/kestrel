import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3Connect

@Suite(.timeLimit(.minutes(1))) @MainActor struct LinkerTests {
  /// A relay (challenge, link, unlink) and the local server's connect routes, with request order recorded.
  final class World: Sendable {
    let relayHost = uniqueHost("relay")
    let localHost = uniqueHost("local")
    let order = Mutex<[String]>([])
    let linkEnvironmentId = Mutex("env-1")
    let linkProviderKind = Mutex("cloudflare_tunnel")
    let linkUser = Mutex("user_1")

    init() {
      FakeNetwork.serve(host: relayHost) { [self] request in
        order.withLock { $0.append("relay \(request.method) \(request.url.path)") }
        switch (request.method, request.url.path) {
        case ("POST", "/v1/client/environment-link-challenges"): return (200, #"{"challenge":"challenge-1","expiresAt":"2026-10-10T12:05:00Z"}"#)
        case ("POST", "/v1/client/environment-links"):
          return (
            200,
            """
            {"ok":true,"cloudUserId":"\(linkUser.withLock { $0 })","environmentId":"\(linkEnvironmentId.withLock { $0 })","endpoint":{"httpBaseUrl":"https://tunnel.example","wsBaseUrl":"wss://tunnel.example","providerKind":"\(linkProviderKind.withLock { $0 })"},"endpointRuntime":null,"relayIssuer":"https://\(relayHost)","environmentCredential":"env-credential","cloudMintPublicKey":"mint-key"}
            """)
        case ("DELETE", "/v1/client/environment-links/env-1"): return (200, #"{"ok":true}"#)
        default: return (404, "{}")
        }
      }
      FakeNetwork.serve(host: localHost) { [self] request in
        order.withLock { $0.append("local \(request.method) \(request.url.path)") }
        switch request.url.path {
        case "/api/connect/link-proof": return (200, "\"signed-proof\"")
        case "/api/connect/relay-config": return (200, #"{"ok":true,"endpointRuntimeStatus":{"status":"running"}}"#)
        case "/api/connect/unlink": return (200, #"{"ok":true,"endpointRuntimeStatus":{"status":"stopped"}}"#)
        case "/api/connect/link-state": return (200, #"{"linked":true,"cloudUserId":"user_1","publishAgentActivity":true}"#)
        default: return (404, "{}")
        }
      }
    }
  }

  private func make(_ world: World) async throws -> (LocalEnvironmentLinker, LinkTarget) {
    let relay = RelayClient(configuration: testConfiguration(relayHost: world.relayHost), signer: try testSigner(), session: FakeNetwork.session())
    let linker = LocalEnvironmentLinker(relay: relay, relayURL: URL(string: "https://\(world.relayHost)")!, urlSession: FakeNetwork.session())
    // The local server is plain http on loopback; the fake network answers by host name.
    let target = LinkTarget(environmentId: EnvironmentId(rawValue: "env-1"), httpBaseURL: URL(string: "http://\(world.localHost):13773/")!, authorization: .bearer("local-bearer"))
    return (linker, target)
  }

  @Test func linkRunsTheFourStepsInOrderAndKeepsCredentialsApart() async throws {
    let world = World()
    let (linker, target) = try await make(world)
    try await linker.link(target, clerkToken: fakeClerkJWT(sub: "user_1"), accountId: "user_1", accountStillCurrent: { true })
    #expect(
      world.order.withLock { $0 } == [
        "relay POST /v1/client/environment-link-challenges", "local POST /api/connect/link-proof", "relay POST /v1/client/environment-links",
        "local POST /api/connect/relay-config",
      ])
    // The server's bearer goes to the server only; the account token goes to the relay only.
    for request in FakeNetwork.requests(host: world.localHost) { #expect(request.header("Authorization") == "Bearer local-bearer") }
    for request in FakeNetwork.requests(host: world.relayHost) { #expect(request.header("Authorization")?.hasPrefix("Bearer local-bearer") != true) }

    let challenge = try #require(try JSONSerialization.jsonObject(with: FakeNetwork.requests(host: world.relayHost)[0].body) as? [String: Any])
    #expect(challenge["managedTunnelsEnabled"] as? Bool == true)
    let proofRequest = try #require(try JSONSerialization.jsonObject(with: FakeNetwork.requests(host: world.localHost)[0].body) as? [String: Any])
    #expect(proofRequest["challenge"] as? String == "challenge-1")
    #expect(proofRequest["relayIssuer"] as? String == "https://\(world.relayHost)")
    #expect((proofRequest["origin"] as? [String: Any])?["localHttpHost"] as? String == "127.0.0.1")
    #expect((proofRequest["origin"] as? [String: Any])?["localHttpPort"] as? Int == 13773)
    #expect((proofRequest["endpoint"] as? [String: Any])?["providerKind"] as? String == "cloudflare_tunnel")
    let linkRequest = try #require(try JSONSerialization.jsonObject(with: FakeNetwork.requests(host: world.relayHost)[1].body) as? [String: Any])
    #expect(linkRequest["proof"] as? String == "signed-proof")
    let config = try #require(try JSONSerialization.jsonObject(with: FakeNetwork.requests(host: world.localHost)[1].body) as? [String: Any])
    #expect(config["environmentCredential"] as? String == "env-credential")
    #expect(config["cloudMintPublicKey"] as? String == "mint-key")
    #expect(config["endpointRuntime"] is NSNull, "the host schema requires endpointRuntime, null included")
  }

  @Test func anAccountChangeStopsTheLinkBeforeTheNextStep() async throws {
    let world = World()
    let (linker, target) = try await make(world)
    let checks = Mutex(0)
    await #expect(throws: LinkError.accountChanged) {
      try await linker.link(target, clerkToken: fakeClerkJWT(sub: "user_1"), accountId: "user_1", accountStillCurrent: { checks.withLock { $0 += 1; return $0 < 3 } })
    }
    let order = world.order.withLock { $0 }
    #expect(order == ["relay POST /v1/client/environment-link-challenges", "local POST /api/connect/link-proof"], "no relay link is created for an account that signed out")
  }

  @Test func aLinkForAnotherEnvironmentOrAccountIsNotStored() async throws {
    for change in [("env-2", "cloudflare_tunnel", "user_1"), ("env-1", "manual", "user_1"), ("env-1", "cloudflare_tunnel", "user_2")] {
      let world = World()
      world.linkEnvironmentId.withLock { $0 = change.0 }
      world.linkProviderKind.withLock { $0 = change.1 }
      world.linkUser.withLock { $0 = change.2 }
      let (linker, target) = try await make(world)
      await #expect(throws: LinkError.self) { try await linker.link(target, clerkToken: fakeClerkJWT(sub: "user_1"), accountId: "user_1", accountStillCurrent: { true }) }
      #expect(!world.order.withLock { $0 }.contains("local POST /api/connect/relay-config"), "\(change)")
    }
  }

  @Test func unlinkRemovesTheServerLinkBeforeTheAccountLink() async throws {
    let world = World()
    let (linker, target) = try await make(world)
    try await linker.unlink(target, clerkToken: fakeClerkJWT(sub: "user_1"))
    #expect(world.order.withLock { $0 } == ["local POST /api/connect/unlink", "relay DELETE /v1/client/environment-links/env-1"])
    let unlink = try #require(FakeNetwork.requests(host: world.localHost).first)
    #expect(unlink.body.isEmpty, "the declared endpoint has no payload")
  }

  @Test func linkStateIsDecodedFromTheGeneratedType() async throws {
    let world = World()
    let (linker, target) = try await make(world)
    let state = try await linker.linkState(target)
    #expect(state.linked)
    #expect(state.cloudUserId == "user_1")
  }

  @Test func serverErrorsKeepTheirMessage() async throws {
    let host = uniqueHost("local")
    FakeNetwork.serve(host: host) { _ in (409, #"{"_tag":"EnvironmentHttpConflictError","message":"This environment is linked to another account."}"#) }
    let relay = RelayClient(configuration: testConfiguration(relayHost: uniqueHost("relay")), signer: try testSigner(), session: FakeNetwork.session())
    let linker = LocalEnvironmentLinker(relay: relay, relayURL: URL(string: "https://relay.test")!, urlSession: FakeNetwork.session())
    let target = LinkTarget(environmentId: EnvironmentId(rawValue: "env-1"), httpBaseURL: URL(string: "http://\(host):1/")!, authorization: .bearer("b"))
    await #expect(throws: LinkError.server("This environment is linked to another account.")) { try await linker.linkState(target) }
  }
}
