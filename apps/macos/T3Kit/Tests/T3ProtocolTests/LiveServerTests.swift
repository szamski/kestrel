import Foundation
import Testing
import T3Contracts
@testable import T3Protocol

// Opt-in: T3_LIVE_SERVER=http://localhost:13773 T3_LIVE_TOKEN_FILE=<path to bootstrap credential>.
// Read-only RPCs against a server that holds a copy of real data. Never dispatch commands here.

private let liveEnabled = ProcessInfo.processInfo.environment["T3_LIVE_SERVER"] != nil

@Suite struct LiveServerTests {
  @Test(.enabled(if: liveEnabled))
  func unaryAndStreamAgainstLiveServer() async throws {
    let env = ProcessInfo.processInfo.environment
    let server = try #require(env["T3_LIVE_SERVER"])
    let tokenFile = try #require(env["T3_LIVE_TOKEN_FILE"])
    let baseURL = try #require(URL(string: server))
    let credential = try String(contentsOfFile: tokenFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let http = EnvironmentHTTPClient(baseURL: baseURL)
    let descriptor = try await http.descriptor()
    let negotiated = try ProtocolCompatibility.negotiate(descriptor).get()

    let metadata = ClientMetadata(label: "T3 Code macOS protocol tests", appVersion: "0.0.0-test")
    let token = try await http.exchangeToken(credential: credential, clientMetadata: metadata)
    let auth = RequestAuthorization.bearer(token.accessToken)
    #expect(try await http.authSession(auth: auth).authenticated)

    let shell: RawJSON = try await http.get("/api/orchestration/shell", auth: auth, orchestrationProtocol: negotiated)
    let afterSequence = try #require(shell["snapshotSequence"]?.numberValue)

    let ticket = try await http.webSocketTicket(auth: auth)
    let wsURL = WebSocketURL.make(wsBaseURL: wsBase(baseURL), ticket: ticket.ticket, metadata: metadata, orchestrationProtocol: negotiated)
    let transport = try await URLSessionWebSocketTransport.open(URLRequest(url: wsURL))

    // Readiness: the first subscribeServerConfig snapshot must be for the environment we paired with.
    let configSpec = RpcSpec<RawJSON, RawJSON, RpcUntypedFailure>(tag: "subscribeServerConfig", isStream: true)
    let expectedEnvironmentId = descriptor.environmentId
    let session = try await RpcSession.open(transport: transport) { session in
      for try await event in session.subscribe(configSpec, .object([:])) {
        guard event["type"]?.stringValue == "snapshot" else { continue }
        guard event["config"]?["environment"]?["environmentId"]?.stringValue == expectedEnvironmentId else {
          throw LiveError.environmentMismatch
        }
        return  // leaving the loop interrupts the subscription
      }
      throw LiveError.noSnapshot
    }

    let getConfig = RpcSpec<RawJSON, RawJSON, RpcUntypedFailure>(tag: "server.getConfig", isStream: false)
    let config = try await session.call(getConfig, .object([:]))
    #expect(config["environment"]?["environmentId"]?.stringValue == descriptor.environmentId)

    let subscribeShell = RpcSpec<RawJSON, RawJSON, RpcUntypedFailure>(tag: "orchestration.subscribeShell", isStream: true)
    let payload = RawJSON.object([
      "afterSequence": .number(afterSequence), "requestCompletionMarker": .bool(true),
    ])
    var sawSynchronized = false
    for try await item in session.subscribe(subscribeShell, payload) {
      if item["kind"]?.stringValue == "synchronized" {
        sawSynchronized = true
        break  // consumer ends -> Interrupt
      }
    }
    #expect(sawSynchronized)

    // A failing read-only request yields a real Exit failure the session maps to a typed case.
    let subscribeThread = RpcSpec<RawJSON, RawJSON, RpcUntypedFailure>(tag: "orchestration.subscribeThread", isStream: true)
    do {
      for try await _ in session.subscribe(subscribeThread, .object(["threadId": .string("t3-protocol-test-missing")])) {}
      Issue.record("expected the unknown thread to fail")
    } catch let error as RpcError<RpcUntypedFailure> {
      guard case .failure(let failure) = error else { Issue.record("expected typed failure, got \(error)"); return }
      #expect(failure.raw["_tag"]?.stringValue == "OrchestrationGetSnapshotError")
    }

    // The socket survives the interrupt and still answers.
    _ = try await session.call(getConfig, .object([:]))
    #expect(await session.isOpen)
    await session.close()
  }

  private enum LiveError: Error { case environmentMismatch, noSnapshot }

  private func wsBase(_ http: URL) -> URL {
    var components = URLComponents(url: http, resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    return components.url!
  }
}
