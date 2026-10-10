import CryptoKit
import Foundation
import Synchronization
import T3Connect

// MARK: Fake network

/// Answers URLSession requests in-process, keyed by host, so concurrent tests never share a "server".
final class FakeNetwork: URLProtocol {
  struct Request: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    /// `application/x-www-form-urlencoded` fields as a server decodes them: `+` is a space, `%2B` a plus.
    var form: [String: String] {
      func decode(_ part: Substring) -> String {
        let spaced = part.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
      }
      var fields: [String: String] = [:]
      for pair in bodyText.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        fields[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
      }
      return fields
    }
  }

  typealias Handler = @Sendable (Request) -> (status: Int, body: String)
  private static let state = Mutex(([String: Handler](), [String: [Request]]()))

  static func serve(host: String, _ handler: @escaping Handler) { state.withLock { $0.0[host] = handler; $0.1[host] = [] } }
  static func requests(host: String) -> [Request] { state.withLock { $0.1[host] ?? [] } }
  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FakeNetwork.self]
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
    let recorded = Request(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
    let host = url.host ?? ""
    let handler = Self.state.withLock { state -> Handler? in
      state.1[host, default: []].append(recorded)
      return state.0[host]
    }
    let (status, text) = handler?(recorded) ?? (404, "{}")
    client?.urlProtocol(
      self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(text.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

func uniqueHost(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased()).test" }

// MARK: DPoP verification (what packages/shared/src/dpop.ts `verifyDpopProof` checks)

struct VerifiedProof: Equatable {
  var thumbprint: String
  var jti: String
}

struct ProofRejected: Error, CustomStringConvertible {
  var description: String
}

/// Independent of the signer: parses the compact JWT and checks it as the server would. Throws the reason it would refuse.
func verifyDPoP(_ proof: String?, method: String, url: URL, accessToken: String? = nil, now: Date = Date(), expectedThumbprint: String? = nil) throws -> VerifiedProof {
  func fail(_ reason: String) -> ProofRejected { ProofRejected(description: reason) }
  guard let proof, !proof.isEmpty else { throw fail("missing_proof") }
  let parts = proof.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
  guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { throw fail("malformed_proof") }
  guard let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]), let signatureData = Data(base64URL: parts[2]),
    let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
    let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
  else { throw fail("malformed_proof") }
  guard header["typ"] as? String == "dpop+jwt", header["alg"] as? String == "ES256", let jwk = header["jwk"] as? [String: Any], jwk["d"] == nil,
    jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256", let x = jwk["x"] as? String, let y = jwk["y"] as? String,
    let xData = Data(base64URL: x), let yData = Data(base64URL: y), xData.count == 32, yData.count == 32
  else { throw fail("malformed_proof") }
  let thumbprintInput = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(x)\",\"y\":\"\(y)\"}"
  let thumbprint = Data(SHA256.hash(data: Data(thumbprintInput.utf8))).base64URL
  if let expectedThumbprint, thumbprint != expectedThumbprint { throw fail("key_mismatch") }
  guard let htm = payload["htm"] as? String, htm.uppercased() == method.uppercased() else { throw fail("method_mismatch") }
  guard let htu = payload["htu"] as? String, htu == expectedHTU(url) else { throw fail("url_mismatch") }
  if let accessToken {
    guard payload["ath"] as? String == Data(SHA256.hash(data: Data(accessToken.utf8))).base64URL else { throw fail("access_token_hash_mismatch") }
  } else if payload["ath"] != nil {
    throw fail("unexpected ath")
  }
  guard let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + xData + yData),
    let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
    publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8))
  else { throw fail("invalid_signature") }
  guard let jti = payload["jti"] as? String, !jti.isEmpty, let iat = payload["iat"] as? Int else { throw fail("malformed_proof") }
  let age = Int(now.timeIntervalSince1970) - iat
  guard age >= -5, age <= 300 else { throw fail("time_window") }
  return VerifiedProof(thumbprint: thumbprint, jti: jti)
}

/// The server's `normalizeDpopHtu`: no search or hash; URLs here are already lowercase with explicit default ports removed.
private func expectedHTU(_ url: URL) -> String {
  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
  components.query = nil
  components.fragment = nil
  return components.url!.absoluteString
}

extension Data {
  init?(base64URL value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }

  var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

/// An unsigned JWT-shaped token: only its `sub` claim is read (cache partition), never trusted.
func fakeClerkJWT(sub: String, jti: String = UUID().uuidString) -> String {
  func part(_ object: [String: Any]) -> String { try! JSONSerialization.data(withJSONObject: object).base64URL }
  return "\(part(["alg": "none"])).\(part(["sub": sub, "jti": jti])).sig"
}

// MARK: Test doubles

final class TestClock: Sendable {
  private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
  var now: Date { current.withLock { $0 } }
  func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
final class FakeCloudSession: CloudSession {
  var account: CloudAccount?
  var tokenCalls = 0
  var tokenFailure: (any Error)?
  let accountChanges = AsyncStream<CloudAccount?> { _ in }

  init(account: CloudAccount? = CloudAccount(id: "user_1", email: "a@example.com")) { self.account = account }

  func refresh() async {}
  func relayToken() async throws -> String {
    tokenCalls += 1
    if let tokenFailure { throw tokenFailure }
    guard let account else { throw CloudSessionError.signedOut }
    return fakeClerkJWT(sub: account.id)
  }
  func signIn(with provider: CloudSignInProvider) async throws {}
  func startEmailCode(email: String) async throws {}
  func verifyEmailCode(_ code: String) async throws {}
  func signOut() async throws { account = nil }
}

func testSigner() throws -> DPoPSigner {
  var scalar = Data(repeating: 0, count: 32)
  scalar[31] = 1
  return try DPoPSigner(privateKeyRawRepresentation: scalar)
}

func testConfiguration(relayHost: String) -> T3ConnectConfiguration {
  T3ConnectConfiguration(clerkPublishableKey: "pk_live_Y2xlcmsudDMuY29kZXMk", clerkJWTTemplate: "t3-relay", relayURL: URL(string: "https://\(relayHost)")!)
}
