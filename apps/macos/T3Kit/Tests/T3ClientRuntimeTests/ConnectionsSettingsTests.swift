import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct AuthAccessTests {
  func link(_ id: String, at created: String, scopes: [AuthEnvironmentScope] = [.orchestrationRead], permissions: [AuthEnvironmentScope]? = nil) -> AuthPairingLink {
    AuthPairingLink(id: id, scopes: scopes, permissions: permissions, subject: "one-time-token", label: nil, createdAt: IsoDateTime(created), expiresAt: IsoDateTime("2030-01-01T00:00:00.000Z"))
  }

  func client(_ id: String, issued: String, current: Bool = false, connected: Bool = false) -> AuthClientSession {
    AuthClientSession(
      sessionId: AuthSessionId(id), subject: "s", scopes: [.orchestrationRead], method: .bearerAccessToken,
      client: AuthClientMetadata(label: id, deviceType: .desktop), issuedAt: IsoDateTime(issued), expiresAt: IsoDateTime("2030-01-01T00:00:00.000Z"),
      connected: connected, current: current)
  }

  @Test func streamEventsUpsertAndRemoveByIdentity() {
    var access = AuthAccess.empty
    let first = link("a", at: "2026-01-01T00:00:00.000Z")
    access = AuthAccess.apply(.pairingLinkUpserted(.init(revision: 1, payload: first)), to: access)
    access = AuthAccess.apply(.clientUpserted(.init(revision: 2, payload: client("c1", issued: "2026-01-01T00:00:00.000Z"))), to: access)
    // The same link upserted again replaces it rather than listing it twice.
    access = AuthAccess.apply(.pairingLinkUpserted(.init(revision: 3, payload: link("a", at: "2026-01-01T00:00:00.000Z", scopes: []))), to: access)
    #expect(access.pairingLinks.count == 1 && access.pairingLinks[0].scopes.isEmpty)
    access = AuthAccess.apply(.pairingLinkRemoved(.init(revision: 4, payload: .init(id: "a"))), to: access)
    access = AuthAccess.apply(.clientRemoved(.init(revision: 5, payload: .init(sessionId: AuthSessionId("c1")))), to: access)
    #expect(access.pairingLinks.isEmpty && access.clientSessions.isEmpty)
    // A snapshot replaces the whole list.
    let snapshot = AuthAccessSnapshot(pairingLinks: [first], clientSessions: [])
    #expect(AuthAccess.apply(.snapshot(.init(revision: 6, payload: snapshot)), to: access) == snapshot)
  }

  @Test func listsSortLikeTheWebPage() {
    let links = AuthAccess.sorted([link("old", at: "2026-01-01T00:00:00.000Z"), link("new", at: "2026-03-01T00:00:00.000Z")])
    #expect(links.map(\.id) == ["new", "old"])
    let sessions = AuthAccess.sorted([
      client("newer", issued: "2026-03-01T00:00:00.000Z"),
      client("connected", issued: "2026-01-01T00:00:00.000Z", connected: true),
      client("me", issued: "2025-01-01T00:00:00.000Z", current: true),
    ])
    #expect(sessions.map(\.sessionId.rawValue) == ["me", "connected", "newer"])
  }

  @Test func exactPermissionsOutrankWireScopesEvenWhenEmpty() {
    #expect(AuthAccess.scopes(of: link("a", at: "2026-01-01T00:00:00.000Z", scopes: [.orchestrationRead], permissions: [])) == [])
    #expect(AuthAccess.scopes(of: link("a", at: "2026-01-01T00:00:00.000Z", scopes: [.orchestrationRead])) == [.orchestrationRead])
    let state = AuthSessionState(authenticated: true, auth: Self.descriptor, scopes: [.accessWrite], permissions: [.accessRead])
    #expect(AuthAccess.grants(.accessRead, in: state) && !AuthAccess.grants(.accessWrite, in: state))
  }

  static let descriptor = ServerAuthDescriptor(policy: .loopbackBrowser, bootstrapMethods: [], sessionMethods: [], sessionCookieName: "c")

  @Test func revokeOthersNeedsAnotherClientUnlessTheListIsUnknown() {
    #expect(AuthAccess.canRevokeOthers(nil))
    #expect(!AuthAccess.canRevokeOthers([client("me", issued: "2026-01-01T00:00:00.000Z", current: true)]))
    #expect(AuthAccess.canRevokeOthers([client("me", issued: "2026-01-01T00:00:00.000Z", current: true), client("x", issued: "2026-01-01T00:00:00.000Z")]))
  }

  @Test func pairingScopesKeepTerminalsListable() {
    #expect(PairingScopes.toggled([.orchestrationRead], .terminalOperate, on: true).contains(.terminalRead))
    #expect(!PairingScopes.toggled([.terminalRead, .terminalOperate], .terminalRead, on: false).contains(.terminalOperate))
    // A holder can only delegate what it holds.
    let held: [AuthEnvironmentScope] = [.orchestrationRead, .accessRead]
    #expect(PairingScopes.delegatable(PairingScopes.administrative, by: held) == [.orchestrationRead, .accessRead])
    #expect(PairingScopes.administrative.count == PairingScopes.standard.count + 3)
  }

  @Test func pairingEndpointsNeverOfferLoopbackToAScanner() throws {
    let direct = [
      ServerConfigDirectEndpointsItem(kind: .lan, httpBaseUrl: "http://192.168.1.20:3773/"),
      ServerConfigDirectEndpointsItem(kind: .tailnet, httpBaseUrl: "https://mac.tail1234.ts.net/"),
    ]
    let endpoints = PairingEndpoint.endpoints(loopbackPort: 3773, direct: direct)
    #expect(endpoints.map(\.label) == ["This Mac", "Local network", "Tailscale HTTPS"])
    #expect(PairingEndpoint.preferred(endpoints)?.reach == .lan)
    #expect(PairingEndpoint.preferred(PairingEndpoint.endpoints(loopbackPort: 3773, direct: []))?.reach == .loopback)
    let url = try #require(endpoints[1].pairingURL(credential: "ab+/c"))
    #expect(url.absoluteString == "http://192.168.1.20:3773/pair#token=ab%2B%2Fc")
  }
}

@Suite struct LoadBalancingTests {
  let now = 1_000_000

  func machine(_ id: String, cpu: Double? = 0.5, count: Int = 8, free: Int = 50, age: Int = 1_000, weight: Double = 50) -> LoadBalancing.Candidate {
    LoadBalancing.Candidate(
      environmentId: EnvironmentId(rawValue: id),
      resources: HostResourcesSnapshot(sampledAt: now - age, cpuUtilization: cpu, cpuCount: count, availableMemoryBytes: free, totalMemoryBytes: 100),
      weight: weight)
  }

  @Test func theMostFreeCapacityWinsAndWeightTipsTheScale() {
    #expect(LoadBalancing.choose([machine("busy", cpu: 0.9), machine("idle", cpu: 0.1)], now: now)?.rawValue == "idle")
    // Same capacity: the preferred machine wins; double the weight beats a modest capacity lead.
    #expect(LoadBalancing.choose([machine("a"), machine("b", weight: 100)], now: now)?.rawValue == "b")
    #expect(LoadBalancing.choose([machine("a", cpu: 0.4), machine("b", cpu: 0.5, weight: 100)], now: now)?.rawValue == "b")
  }

  @Test func machinesThatCannotTakeWorkAreSkipped() {
    #expect(LoadBalancing.choose([machine("manual", weight: 0)], now: now) == nil)
    #expect(LoadBalancing.choose([machine("hot", cpu: 0.95), machine("unknown", cpu: nil)], now: now) == nil)
    #expect(LoadBalancing.choose([machine("full", free: 5)], now: now) == nil)
    #expect(LoadBalancing.choose([machine("stale", age: 15_001)], now: now) == nil)
    #expect(LoadBalancing.choose([machine("future", age: -5_001)], now: now) == nil)
    #expect(LoadBalancing.choose([machine("nan", weight: .nan), machine("ok", cpu: 0.9)], now: now)?.rawValue == "ok")
    #expect(LoadBalancing.choose([], now: now) == nil)
  }

  @Test func receiptTimeBeatsTheHostsClock() {
    var skewed = machine("skewed", age: 3_600_000)
    skewed.receivedAt = now - 500
    #expect(LoadBalancing.choose([skewed], now: now)?.rawValue == "skewed")
  }

  @Test func savedWeightsSnapToTheFourPreferences() {
    #expect(LoadBalancing.Preference(weight: nil) == .normal)
    #expect(LoadBalancing.Preference(weight: 0) == .manualOnly)
    #expect(LoadBalancing.Preference(weight: 30) == .lessOften)
    #expect(LoadBalancing.Preference(weight: 80) == .prefer)
    #expect(LoadBalancing.summary([("a", "Mac"), ("b", "Studio")], weights: ["b": 0]) == "Studio manual only")
    #expect(LoadBalancing.summary([("a", "Mac")], weights: [:]) == nil)
  }
}
