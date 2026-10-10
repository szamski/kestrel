import Foundation
import Testing
@testable import T3Protocol

@Suite struct PairingTests {
  @Test func directPairingURL() throws {
    let target = try PairingTarget.parse(pairingURL: " http://localhost:3773/pair#token=abc123 ")
    #expect(target.credential == "abc123")
    #expect(target.httpBaseURL.absoluteString == "http://localhost:3773/")
    #expect(target.wsBaseURL.absoluteString == "ws://localhost:3773/")
    #expect(target.label == nil)
  }

  @Test func httpsMapsToWss() throws {
    let target = try PairingTarget.parse(pairingURL: "https://box.tail1234.ts.net/pair#token=t")
    #expect(target.httpBaseURL.absoluteString == "https://box.tail1234.ts.net/")
    #expect(target.wsBaseURL.absoluteString == "wss://box.tail1234.ts.net/")
  }

  @Test func hostedPairingURL() throws {
    let target = try PairingTarget.parse(
      pairingURL: "https://app.t3.codes/pair?host=192.168.1.20%3A3773&label=My+Laptop#token=s3cr%2Bet")
    #expect(target.credential == "s3cr+et")
    #expect(target.label == "My Laptop")
    // Host without scheme defaults to https, like normalizeRemoteBaseUrl.
    #expect(target.httpBaseURL.absoluteString == "https://192.168.1.20:3773/")
    #expect(target.wsBaseURL.absoluteString == "wss://192.168.1.20:3773/")
  }

  @Test func hostedHostKeepsExplicitScheme() throws {
    let target = try PairingTarget.parse(
      pairingURL: "https://app.t3.codes/pair?host=http%3A%2F%2F10.0.0.5%3A3773%2Fignored#token=t")
    #expect(target.httpBaseURL.absoluteString == "http://10.0.0.5:3773/")
    #expect(target.wsBaseURL.absoluteString == "ws://10.0.0.5:3773/")
  }

  @Test func tokenInQueryIsAccepted() throws {
    #expect(try PairingTarget.parse(pairingURL: "http://h:1/pair?token=q").credential == "q")
  }

  @Test func rejectsBadInput() {
    #expect(throws: PairingError.missingToken(host: "h")) { try PairingTarget.parse(pairingURL: "http://h:1/pair") }
    #expect(throws: PairingError.invalidPairingURL(scheme: "ftp")) { try PairingTarget.parse(pairingURL: "ftp://h/pair#token=x") }
    #expect(throws: PairingError.invalidPairingURL(scheme: nil)) { try PairingTarget.parse(pairingURL: "not a url") }
    #expect(throws: PairingError.invalidBackendURL(scheme: "ftp")) {
      try PairingTarget.parse(pairingURL: "https://app.t3.codes/pair?host=ftp%3A%2F%2Fh#token=x")
    }
  }

  @Test func manualHostAndCode() throws {
    let target = try PairingTarget.resolve(host: "localhost:3773", pairingCode: " 123456 ")
    #expect(target.credential == "123456")
    #expect(target.httpBaseURL.absoluteString == "https://localhost:3773/")
    #expect(throws: PairingError.missingCode(host: "h")) { try PairingTarget.resolve(host: "h", pairingCode: " ") }
    #expect(throws: PairingError.missingBackendURL) { try PairingTarget.resolve(host: "", pairingCode: "1") }
  }
}

@Suite struct EnvironmentURLTests {
  @Test func webSocketURLCarriesTicketAndClientIdentity() {
    let url = WebSocketURL.make(
      wsBaseURL: URL(string: "ws://localhost:13773/")!,
      ticket: "tk-1_x",
      metadata: ClientMetadata(label: "Mac", appVersion: "1.2+3"),
      orchestrationProtocol: .v1)
    #expect(url.path == "/ws")
    #expect(
      url.absoluteString == "ws://localhost:13773/ws?wsTicket=tk-1_x&clientSurface=desktop"
        + "&clientAppVersion=1.2%2B3&clientDeviceType=desktop&clientOs=macOS"
        + "&connectionMethod=direct&orchestrationProtocol=1")
  }

  @Test func tokenExchangeFormIsFormUrlEncoded() {
    let form = EnvironmentHTTPClient.tokenExchangeForm(
      credential: "a b&c", scopes: ["orchestration:read", "terminal:operate"],
      clientMetadata: ClientMetadata(label: "T3 Code for Mac"))
    #expect(
      form == "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange"
        + "&subject_token=a%20b%26c"
        + "&subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap"
        + "&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token"
        + "&scope=orchestration%3Aread%20terminal%3Aoperate"
        + "&client_label=T3%20Code%20for%20Mac&client_device_type=desktop&client_os=macOS")
  }

  @Test func dpopSeamBuildsHeaders() {
    #expect(RequestAuthorization.bearer("t").headers == ["Authorization": "Bearer t"])
    #expect(RequestAuthorization.dpop(accessToken: "t", proof: "p").headers == ["Authorization": "DPoP t", "DPoP": "p"])
  }

  @Test func protocolCompatibility() throws {
    func descriptor(_ version: Int?) throws -> EnvironmentDescriptorInfo {
      let field = version.map { #","orchestrationProtocolVersion":\#($0)"# } ?? ""
      return try JSONDecoder().decode(
        EnvironmentDescriptorInfo.self,
        from: Data(#"{"environmentId":"e","label":"L","serverVersion":"1"\#(field),"capabilities":{}}"#.utf8))
    }
    // Servers without negotiation speak protocol 1; 1 and 2 are both supported, anything newer is refused.
    #expect(try ProtocolCompatibility.negotiate(descriptor(nil)) == .success(.v1))
    #expect(try ProtocolCompatibility.negotiate(descriptor(1)) == .success(.v1))
    #expect(try ProtocolCompatibility.negotiate(descriptor(2)) == .success(.v2))
    #expect(try ProtocolCompatibility.negotiate(descriptor(3)) == .failure(.clientTooOld(serverVersion: 3)))
    #expect(try ProtocolCompatibility.negotiate(descriptor(0)) == .failure(.serverTooOld(serverVersion: 0)))
    #expect(ProtocolCompatibility.check(try descriptor(2)) == nil)
    #expect(ProtocolCompatibility.check(try descriptor(3))?.message(environmentLabel: "Box") == "This client is not supported by this server. Update your app or use a compatible release to connect to Box.")
    #expect(ProtocolCompatibility.check(try descriptor(0))?.message(environmentLabel: "Box") == "This client requires a newer server. Update T3 Code on Box to connect.")
  }

  @Test func negotiatedProtocolIsSentOnTheSocketAndOrchestrationRequests() {
    let url = WebSocketURL.make(
      wsBaseURL: URL(string: "ws://localhost:13773/ws")!, ticket: "t", metadata: ClientMetadata(), orchestrationProtocol: .v2)
    #expect(url.query?.hasSuffix("&orchestrationProtocol=2") == true)
    var headers: [String: String] = [:]
    EnvironmentHTTPClient.addOrchestrationProtocol(.v1, to: &headers)
    EnvironmentHTTPClient.addOrchestrationProtocol(nil, to: &headers)
    #expect(headers.isEmpty, "protocol-1 servers predate the header")
    EnvironmentHTTPClient.addOrchestrationProtocol(.v2, to: &headers)
    #expect(headers == ["x-t3-orchestration-protocol": "2"])
  }
}

@Suite struct CredentialStoreTests {
  private func credential(_ id: String, token: String) -> EnvironmentCredential {
    EnvironmentCredential(
      environmentId: id, label: "L", httpBaseURL: URL(string: "http://localhost:1/")!,
      wsBaseURL: URL(string: "ws://localhost:1/")!, accessToken: token)
  }

  private func roundTrip(_ store: some CredentialStore, id: String) throws {
    #expect(try store.load(environmentId: id) == nil)
    try store.save(credential(id, token: "one"))
    #expect(try store.load(environmentId: id)?.accessToken == "one")
    try store.save(credential(id, token: "two"))
    #expect(try store.load(environmentId: id)?.accessToken == "two")
    try store.remove(environmentId: id)
    #expect(try store.load(environmentId: id) == nil)
    try store.remove(environmentId: id)
  }

  @Test func inMemory() throws {
    try roundTrip(InMemoryCredentialStore(), id: "env-1")
  }

  @Test func keychain() throws {
    // Own service so the real `codes.t3.macos` items are never touched.
    try roundTrip(KeychainCredentialStore(service: "codes.t3.macos.tests"), id: "env-\(UUID().uuidString)")
  }
}
