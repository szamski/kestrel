import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// Answers URLSession requests in-process, keyed by host so concurrent tests do not interfere.
final class StubProtocol: URLProtocol {
  struct Recorded: Sendable { let url: URL; let method: String; let headers: [String: String]; let body: Data }
  typealias Handler = @Sendable (Recorded) -> (status: Int, body: Data)
  private static let state = Mutex(([String: Handler](), [String: [Recorded]]()))

  static func install(host: String, _ handler: @escaping Handler) { state.withLock { $0.0[host] = handler; $0.1[host] = [] } }
  static func requests(host: String) -> [Recorded] { state.withLock { $0.1[host] ?? [] } }
  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        body.append(buffer, count: read)
      }
      stream.close()
    }
    let url = request.url!
    let recorded = Recorded(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
    let host = url.host ?? ""
    let handler = Self.state.withLock { state -> Handler? in
      state.1[host, default: []].append(recorded)
      return state.0[host]
    }
    let (status, data) = handler?(recorded) ?? (404, Data())
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1))) struct RegistryTests {
  let environmentId = Fixtures.serverConfig().environment.environmentId

  func directory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("t3-registry-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func descriptor(protocolVersion: Int? = 1) -> Data {
    var json: [String: Any] = ["environmentId": environmentId.rawValue, "label": "Work Mac", "serverVersion": "9.9.9"]
    if let protocolVersion { json["orchestrationProtocolVersion"] = protocolVersion }
    return try! JSONSerialization.data(withJSONObject: json)
  }

  func installServer(host: String, protocolVersion: Int? = 1, tokenStatus: Int = 200) {
    let descriptor = descriptor(protocolVersion: protocolVersion)
    StubProtocol.install(host: host) { request in
      switch request.url.path {
      case "/.well-known/t3/environment": (200, descriptor)
      case "/oauth/token":
        tokenStatus == 200
          ? (200, Data(#"{"access_token":"bearer-secret","token_type":"Bearer","expires_in":3600,"scope":"orchestration:read"}"#.utf8))
          : (tokenStatus, Data(#"{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"Pairing code expired"}"#.utf8))
      default: (404, Data())
      }
    }
  }

  func makeRegistry(
    directory: URL, credentials: InMemoryCredentialStore = InMemoryCredentialStore(), servers: [FakeServer] = [], cache: SQLiteSnapshotCache? = nil
  ) throws -> (EnvironmentRegistry, InMemoryCredentialStore, SQLiteSnapshotCache, ClientStateStore) {
    let cache = try cache ?? SQLiteSnapshotCache(path: nil)
    let state = ClientStateStore(directory: directory)
    let driver = FakeServerDriver(servers)
    let registry = EnvironmentRegistry(
      catalog: EnvironmentCatalogFile(directory: directory), credentials: credentials, cache: cache, clientState: state,
      loader: FakeLoader(shell: Data2.shell()), clock: ManualClock(), keepRunningThreadsMounted: false, httpSession: StubProtocol.session(),
      makeDriver: { _, _ in driver })
    return (registry, credentials, cache, state)
  }

  @Test func pairingExchangesTheCodeStoresTheTokenOnlyInTheKeychainAndConnects() async throws {
    installServer(host: "pair-ok.test")
    let dir = directory()
    let server = FakeServer()
    let (registry, credentials, _, _) = try makeRegistry(directory: dir, servers: [server])
    let entry = try await registry.add(pairingURL: "http://pair-ok.test:3773/pair#token=ABC123")
    #expect(entry.environmentId == environmentId && entry.label == "Work Mac")

    let exchange = try #require(StubProtocol.requests(host: "pair-ok.test").first { $0.url.path == "/oauth/token" })
    let form = String(decoding: exchange.body, as: UTF8.self)
    #expect(form.contains("subject_token=ABC123"))
    #expect(form.contains("client_label=T3%20Code%20macOS"), "the token exchange identifies this client")
    #expect(form.contains("client_os=macOS"))

    let stored = try #require(try credentials.load(environmentId: environmentId.rawValue))
    #expect(stored.accessToken == "bearer-secret" && stored.httpBaseURL.absoluteString == "http://pair-ok.test:3773/")
    let catalogText = try String(contentsOf: EnvironmentCatalogFile(directory: dir).url, encoding: .utf8)
    #expect(!catalogText.contains("bearer-secret"), "the token never touches the catalog file")

    let runtime = try #require(await registry.runtime(for: environmentId))
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected }
    await registry.stop()
  }

  @Test func hostAndCodeAssumeHttpsAndRejectBadInputWithReadableErrors() async throws {
    installServer(host: "manual.test")
    let (registry, _, _, _) = try makeRegistry(directory: directory(), servers: [FakeServer()])
    _ = try await registry.add(host: "manual.test:8443", pairingCode: "123456")
    #expect(StubProtocol.requests(host: "manual.test").first?.url.scheme == "https")
    await registry.stop()

    let (other, _, _, _) = try makeRegistry(directory: directory())
    do { _ = try await other.add(pairingURL: "http://nowhere.test/pair"); Issue.record("missing token must fail") } catch { #expect(error.message == "The pairing link or code is missing.") }
    do { _ = try await other.add(host: "", pairingCode: "1"); Issue.record("empty host must fail") } catch { #expect(error == .invalidPairing("Enter the address of the T3 Code server.")) }
  }

  @Test func rejectedCodesAndIncompatibleServersAreNotSaved() async throws {
    installServer(host: "expired.test", tokenStatus: 401)
    installServer(host: "old-server.test", protocolVersion: 0)
    installServer(host: "future-server.test", protocolVersion: 2)
    let dir = directory()
    let (registry, credentials, _, _) = try makeRegistry(directory: dir)
    do { _ = try await registry.add(pairingURL: "http://expired.test/pair#token=x"); Issue.record("expected rejection") } catch {
      #expect(error == .pairingRejected("Pairing code expired"))
    }
    for host in ["old-server.test", "future-server.test"] {
      do { _ = try await registry.add(pairingURL: "http://\(host)/pair#token=x"); Issue.record("expected incompatibility") } catch {
        guard case .incompatible = error else { Issue.record("unexpected \(error)"); continue }
      }
    }
    #expect(try credentials.load(environmentId: environmentId.rawValue) == nil)
    #expect(EnvironmentCatalogFile(directory: dir).load().isEmpty)
    #expect(registry.runtimes.value.isEmpty)
  }

  @Test func savedEnvironmentsComeBackAfterARestartWithTheirCredentials() async throws {
    installServer(host: "restart.test")
    let dir = directory()
    let credentials = InMemoryCredentialStore()
    let (first, _, _, _) = try makeRegistry(directory: dir, credentials: credentials, servers: [FakeServer()])
    _ = try await first.add(pairingURL: "http://restart.test/pair#token=t")
    await first.stop()

    let second = FakeServer()
    let (restarted, _, _, _) = try makeRegistry(directory: dir, credentials: credentials, servers: [second])
    await restarted.start()
    let runtime = try #require(await restarted.runtime(for: environmentId))
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected }
    #expect(runtime.entry.label == "Work Mac")
    await restarted.stop()
  }

  @Test func disablingStopsConnectingWithoutForgettingAnything() async throws {
    installServer(host: "toggle.test")
    let dir = directory()
    let first = FakeServer(), second = FakeServer()
    let (registry, credentials, _, _) = try makeRegistry(directory: dir, servers: [first, second])
    _ = try await registry.add(pairingURL: "http://toggle.test/pair#token=t")
    let runtime = try #require(await registry.runtime(for: environmentId))
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected }
    await registry.setEnabled(environmentId, false)
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .available }
    #expect(EnvironmentCatalogFile(directory: dir).load().first?.enabled == false)
    #expect(try credentials.load(environmentId: environmentId.rawValue) != nil)
    await registry.setEnabled(environmentId, true)
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    await registry.stop()
  }

  @Test func removingAnEnvironmentClosesItAndClearsCredentialsCachesAndClientState() async throws {
    installServer(host: "remove.test")
    let dir = directory()
    let server = FakeServer()
    let (registry, credentials, cache, clientState) = try makeRegistry(directory: dir, servers: [server])
    _ = try await registry.add(pairingURL: "http://remove.test/pair#token=t")
    let runtime = try #require(await registry.runtime(for: environmentId))
    _ = await waitFor(runtime.supervisor.state) { $0.phase == .connected }
    await cache.saveShell(environmentId, Data2.shell())
    await cache.saveServerConfig(environmentId, Fixtures.serverConfig())
    await clientState.update {
      $0.markVisited("\(environmentId.rawValue):t1", at: "2026-10-08T12:00:00.000Z")
      $0.markVisited("other-env:t1", at: "2026-10-08T12:00:00.000Z")
    }

    await registry.remove(environmentId)
    #expect(server.isClosed, "the scope's socket is closed")
    #expect(try credentials.load(environmentId: environmentId.rawValue) == nil)
    let shell = await cache.loadShell(environmentId), config = await cache.loadServerConfig(environmentId)
    #expect(shell == nil && config == nil)
    #expect(Array(clientState.state.value.threadLastVisitedAtById.keys) == ["other-env:t1"])
    #expect(EnvironmentCatalogFile(directory: dir).load().isEmpty)
    #expect(registry.runtimes.value.isEmpty)
    #expect(await registry.runtime(for: environmentId) == nil)
  }
}

@Suite(.timeLimit(.minutes(1)), .serialized) struct ActivityAndAttachmentTests {  // serialized: the stubbed HTTP host is shared
  @Test func theActivityLeaseIsReportedEveryTwentyFiveSecondsAndWhenPresenceChanges() async throws {
    let server = FakeServer()
    let h = try await SyncTests.Harness.make(servers: [server])
    _ = await waitFor(h.runtime.supervisor.state) { $0.phase == .connected }
    // Answer every report like the server does; the reporter awaits each reply.
    let replies = Task { for n in 1... { server.succeed(await server.waitForRequest("server.reportClientActivity", count: n), NSNull()) } }
    let runtime = h.runtime
    let reporter = ActivityReporter(clock: h.clock, clientId: "client-1") { [runtime] }
    await reporter.start()

    // The first report goes out as soon as the reporter starts.
    let first = await server.waitForRequest("server.reportClientActivity")
    #expect(first.payload["clientId"] as? String == "client-1")
    #expect(first.payload["clientKind"] as? String == "desktop-renderer")
    #expect(first.payload["environmentId"] as? String == h.environmentId.rawValue)
    #expect(first.payload["visible"] as? Bool == true && first.payload["recentlyInteracted"] as? Bool == true)
    #expect(first.payload["ttlMs"] as? Double == 45_000)
    #expect((first.payload["scopes"] as? [[String: Any]])?.first?["type"] as? String == "provider-status")

    // The reporter's timer may not be registered yet: keep moving time until the next report arrives.
    while server.requests("server.reportClientActivity").count < 2 {
      await h.clock.advance(by: .seconds(25), waitForSleeper: false)
      await Task.yield()
    }

    await reporter.update(visible: false, focused: false)  // presence change: reported after a 250 ms debounce
    while server.requests("server.reportClientActivity").count < 3 {
      await h.clock.advance(by: .milliseconds(250), waitForSleeper: false)
      await Task.yield()
    }
    let third = await server.waitForRequest("server.reportClientActivity", count: 3)
    #expect(third.payload["visible"] as? Bool == false && third.payload["appState"] as? String == "background")
    replies.cancel()
    await reporter.stop()
    await h.runtime.stop()
  }

  @Test func uploadsMintASignedUrlThenPostTheBytesWithoutCredentials() async throws {
    let server = FakeServer()
    let h = try await SyncTests.Harness.make(servers: [server], uploadSession: StubProtocol.session())
    _ = await waitFor(h.runtime.supervisor.state) { $0.phase == .connected }
    StubProtocol.install(host: "localhost") { _ in (204, Data()) }

    async let uploaded = h.runtime.uploadAttachment(data: Data([1, 2, 3, 4]), name: "shot.png", mimeType: "image/png")
    let mint = await server.waitForRequest("attachments.createUploadUrl")
    #expect(mint.payload["name"] as? String == "shot.png" && mint.payload["mimeType"] as? String == "image/png" && mint.payload["sizeBytes"] as? Int == 4)
    server.succeed(mint, ["attachmentId": "att-1", "relativeUrl": "/api/attachments/att-1/upload?sig=abc", "expiresAt": 1.0])
    let attachment = try await uploaded
    #expect(attachment.attachmentId == "att-1" && attachment.kind == .image)
    guard case .chatImageAttachment(let reference) = attachment.messageAttachment else { Issue.record("expected an image reference"); return }
    #expect(reference.id == "att-1" && reference.sizeBytes == 4)

    let post = try #require(StubProtocol.requests(host: "localhost").last)
    #expect(post.method == "POST" && post.url.absoluteString == "http://localhost:1/api/attachments/att-1/upload?sig=abc")
    #expect(post.headers["Content-Type"] == "image/png" && post.headers["Authorization"] == nil, "the signed URL is the credential")
    #expect(post.body == Data([1, 2, 3, 4]))
    await h.runtime.stop()
  }

  @Test func aRejectedUploadDeletesThePendingUploadItMinted() async throws {
    let server = FakeServer()
    let h = try await SyncTests.Harness.make(servers: [server], uploadSession: StubProtocol.session())
    _ = await waitFor(h.runtime.supervisor.state) { $0.phase == .connected }
    StubProtocol.install(host: "localhost") { _ in (500, Data()) }
    async let uploaded = h.runtime.uploadAttachment(data: Data("hello".utf8), name: "notes.txt", mimeType: "text/plain")
    let mint = await server.waitForRequest("attachments.createUploadUrl")
    #expect(mint.payload["type"] as? String == "file", "non-image types upload as files")
    server.succeed(mint, ["attachmentId": "att-2", "relativeUrl": "/up/att-2", "expiresAt": 1.0])
    let cleanup = await server.waitForRequest("attachments.delete")
    #expect(cleanup.payload["attachmentId"] as? String == "att-2")
    server.succeed(cleanup, NSNull())
    do { _ = try await uploaded; Issue.record("expected failure") } catch { #expect((error as? AttachmentUploadError) == .uploadFailed(status: 500)) }
    await h.runtime.stop()
  }
}
