import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// A scripted `ManagedEnvironmentAuthorizing`: hands out the grants in order and records what each call rejected.
private final class ScriptedAuthorizer: ManagedEnvironmentAuthorizing {
  let grants: Mutex<[Result<ManagedConnectionGrant, ConnectionAttemptError>]>
  let rejected = Mutex<[String?]>([])
  init(_ grants: [Result<ManagedConnectionGrant, ConnectionAttemptError>]) { self.grants = Mutex(grants) }

  func authorize(_ environmentId: EnvironmentId, rejecting rejectedTokenId: String?) async throws(ConnectionAttemptError) -> ManagedConnectionGrant {
    rejected.withLock { $0.append(rejectedTokenId) }
    let next = grants.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    guard let next else { throw .transient(.relayUnavailable, detail: "no more grants") }
    return try next.get()
  }
}

@Suite(.timeLimit(.minutes(1))) struct RelayRouteTests {
  let environmentId = EnvironmentId(rawValue: "env-1")

  private func entry(route: ConnectionRoute, host: String = "relay-entry.test") -> EnvironmentConnectionEntry {
    EnvironmentConnectionEntry(
      environmentId: environmentId, label: "Studio", httpBaseURL: URL(string: "https://\(host)/")!, wsBaseURL: URL(string: "wss://\(host)/")!, route: route)
  }

  private func directory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t3-relay-route-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func grant(host: String, id: String, descriptorId: String = "env-1") -> ManagedConnectionGrant {
    let descriptor = try! JSONDecoder().decode(
      EnvironmentDescriptorInfo.self,
      from: Data(#"{"environmentId":"\#(descriptorId)","label":"Studio","serverVersion":"1","orchestrationProtocolVersion":2}"#.utf8))
    return ManagedConnectionGrant(
      descriptor: descriptor, httpBaseURL: URL(string: "https://\(host)")!, wsBaseURL: URL(string: "wss://\(host)")!,
      authorization: DPoPAuthorizer(id: id) { _, _ in ["Authorization": "DPoP \(id)", "DPoP": "proof"] })
  }

  // MARK: Catalog

  @Test func catalogsWrittenBeforeRoutesStayDirect() throws {
    let legacy = #"{"environmentId":"env-1","label":"Old","httpBaseURL":"http://h:1/","wsBaseURL":"ws://h:1/"}"#
    let decoded = try JSONDecoder().decode(EnvironmentConnectionEntry.self, from: Data(legacy.utf8))
    #expect(decoded.route == .direct && decoded.enabled)
    let relay = try JSONDecoder().decode(EnvironmentConnectionEntry.self, from: try JSONEncoder().encode(entry(route: .relay)))
    #expect(relay.route == .relay)
  }

  // MARK: Registry

  private func registry(_ directory: URL, credentials: InMemoryCredentialStore = InMemoryCredentialStore()) throws -> EnvironmentRegistry {
    EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: credentials, cache: try SQLiteSnapshotCache(path: nil),
      loader: FakeLoader(shell: Data2.shell()), clock: ManualClock(), keepRunningThreadsMounted: false, httpSession: StubProtocol.session(),
      makeDriver: { _, _ in FakeServerDriver([FakeServer()]) })
  }

  @Test func aManagedEnvironmentIsSavedWithoutAnyCredential() async throws {
    let dir = directory()
    let credentials = InMemoryCredentialStore()
    let registry = try registry(dir, credentials: credentials)
    let saved = try await registry.addManaged(
      environmentId: environmentId, label: "Studio", httpBaseURL: URL(string: "https://studio.test")!, wsBaseURL: URL(string: "wss://studio.test")!)
    #expect(saved.route == .relay)
    #expect(try credentials.load(environmentId: "env-1") == nil, "a managed token is minted on demand, never stored")
    #expect(await registry.directAuthorization(for: environmentId) == nil, "a relay environment has no bearer to hand out")
    #expect(EnvironmentCatalogFile(directory: dir).load().first?.route == .relay)
    await registry.stop()
  }

  @Test func aManagedEnvironmentNeverReplacesADirectOne() async throws {
    let dir = directory()
    try EnvironmentCatalogFile(directory: dir).save([entry(route: .direct, host: "direct.test")])
    let credentials = InMemoryCredentialStore()
    try credentials.save(
      EnvironmentCredential(environmentId: "env-1", label: "L", httpBaseURL: URL(string: "http://direct.test/")!, wsBaseURL: URL(string: "ws://direct.test/")!, accessToken: "bearer-secret"))
    let registry = try registry(dir, credentials: credentials)
    await #expect(throws: AddEnvironmentError.self) {
      try await registry.addManaged(environmentId: environmentId, label: "Studio", httpBaseURL: URL(string: "https://studio.test")!, wsBaseURL: URL(string: "wss://studio.test")!)
    }
    #expect(EnvironmentCatalogFile(directory: dir).load().first?.route == .direct)
    #expect(try credentials.load(environmentId: "env-1")?.accessToken == "bearer-secret")
    #expect(await registry.directAuthorization(for: environmentId) != nil)
    await registry.stop()
  }

  @Test func savingTheSameManagedEnvironmentAgainOnlyRefreshesIt() async throws {
    let registry = try registry(directory())
    let url = URL(string: "https://studio.test")!, ws = URL(string: "wss://studio.test")!
    _ = try await registry.addManaged(environmentId: environmentId, label: "Studio", httpBaseURL: url, wsBaseURL: ws)
    let runtime = try #require(await registry.runtime(for: environmentId))
    let again = try await registry.addManaged(environmentId: environmentId, label: "Studio", httpBaseURL: url, wsBaseURL: ws)
    #expect(again.route == .relay)
    #expect(await registry.runtime(for: environmentId) === runtime, "an unchanged entry keeps its running connection")
    _ = try await registry.addManaged(environmentId: environmentId, label: "Renamed", httpBaseURL: url, wsBaseURL: ws)
    #expect(try #require(await registry.runtime(for: environmentId)).entry.label == "Renamed")
    await registry.stop()
  }

  // MARK: Drivers

  @Test func routingPicksTheDriverByRoute() async throws {
    let direct = FakeServerDriver([FakeServer()])
    let driver = RoutingConnectionDriver(direct: direct, relay: nil)
    do {
      _ = try await driver.connect(entry(route: .relay), progress: { _ in }, onConfigEvent: { _ in })
      Issue.record("a relay environment must not connect in a build without T3 Connect")
    } catch let error as ConnectionAttemptError {
      #expect(error.isBlocked, "blocked until a relay driver exists; retrying cannot help")
    }
    var directEntry = entry(route: .direct)
    directEntry.environmentId = Fixtures.serverConfig().environment.environmentId  // what the fake server announces
    let lease = try await driver.connect(directEntry, progress: { _ in }, onConfigEvent: { _ in })
    await lease.session.close()
  }

  @Test func aRefusedTicketIsRetriedOnceWithAnotherTokenAndStaysDPoP() async throws {
    let host = "relay-driver-\(UUID().uuidString.prefix(8).lowercased()).test"
    StubProtocol.install(host: host) { request in
      request.url.path == "/api/auth/websocket-ticket"
        ? (401, Data(#"{"code":"auth_invalid","reason":"invalid_credential","traceId":"t-1"}"#.utf8)) : (404, Data())
    }
    let authorizer = ScriptedAuthorizer([.success(grant(host: host, id: "token-a")), .success(grant(host: host, id: "token-b"))])
    let driver = RelayConnectionDriver(authorizer: authorizer, metadata: ClientMetadata(label: "Kestrel"), session: StubProtocol.session())
    do {
      _ = try await driver.connect(entry(route: .relay), progress: { _ in }, onConfigEvent: { _ in })
      Issue.record("a twice-refused token must fail the attempt")
    } catch let error as ConnectionAttemptError {
      guard case .blocked(.authentication, let detail, "t-1") = error else { Issue.record("expected blocked authentication, got \(error)"); return }
      #expect(detail.contains("automatic date and time"), "a rejected proof may be clock skew")
    }
    #expect(authorizer.rejected.withLock { $0 } == [nil, "token-a"], "the second grant is asked to replace the refused token")
    let requests = StubProtocol.requests(host: host)
    #expect(requests.map(\.url.path) == ["/api/auth/websocket-ticket", "/api/auth/websocket-ticket"])
    #expect(requests.allSatisfy { $0.headers["Authorization"]?.hasPrefix("DPoP ") == true }, "never a bearer fallback")
    #expect(requests.map { $0.headers["Authorization"] } == ["DPoP token-a", "DPoP token-b"])
  }

  @Test func aDescriptorForAnotherEnvironmentBlocksBeforeAnyTicket() async throws {
    let host = "relay-driver-\(UUID().uuidString.prefix(8).lowercased()).test"
    StubProtocol.install(host: host) { _ in (500, Data()) }
    let authorizer = ScriptedAuthorizer([.success(grant(host: host, id: "token-a", descriptorId: "somebody-else"))])
    let driver = RelayConnectionDriver(authorizer: authorizer, metadata: ClientMetadata(), session: StubProtocol.session())
    do {
      _ = try await driver.connect(entry(route: .relay), progress: { _ in }, onConfigEvent: { _ in })
      Issue.record("a mismatched descriptor must fail")
    } catch let error as ConnectionAttemptError {
      #expect(error.isBlocked)
    }
    #expect(StubProtocol.requests(host: host).isEmpty)
  }

  @Test func anAuthorizerFailureIsReportedAsIs() async throws {
    let authorizer = ScriptedAuthorizer([.failure(.blocked(.authentication, detail: "Sign in to T3 Connect to open this environment."))])
    let driver = RelayConnectionDriver(authorizer: authorizer, metadata: ClientMetadata(), session: StubProtocol.session())
    do {
      _ = try await driver.connect(entry(route: .relay), progress: { _ in }, onConfigEvent: { _ in })
      Issue.record("signed out must not connect")
    } catch let error as ConnectionAttemptError {
      #expect(error == .blocked(.authentication, detail: "Sign in to T3 Connect to open this environment."))
    }
  }
}
