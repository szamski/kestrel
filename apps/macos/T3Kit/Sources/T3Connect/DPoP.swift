import CryptoKit
import Foundation

// DPoP (RFC 9449) proofs as packages/shared/src/dpop.ts verifies them: ES256 over `typ=dpop+jwt`, a
// header carrying only the public JWK, and a payload of htm/htu/jti/iat (+ ath for a bound token).

public struct DPoPPublicJWK: Codable, Equatable, Sendable {
  public let kty: String
  public let crv: String
  public let x: String
  public let y: String

  init(publicKey: P256.Signing.PublicKey) throws {
    let representation = publicKey.x963Representation
    guard representation.count == 65, representation.first == 0x04 else { throw DPoPError.invalidPublicKey }
    kty = "EC"
    crv = "P-256"
    x = Data(representation[1..<33]).base64URLEncodedString()
    y = Data(representation[33..<65]).base64URLEncodedString()
  }

  /// RFC 7638 input: required members only, in lexicographic order.
  public var canonicalThumbprintInput: String { "{\"crv\":\"\(crv)\",\"kty\":\"\(kty)\",\"x\":\"\(x)\",\"y\":\"\(y)\"}" }

  public var thumbprint: String { Data(SHA256.hash(data: Data(canonicalThumbprintInput.utf8))).base64URLEncodedString() }
}

public enum DPoPError: Error, Sendable, Equatable, LocalizedError {
  case invalidURL
  case invalidPrivateKey
  case invalidPublicKey
  case invalidStoredKey
  case keychain(OSStatus)
  case encoding

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "The DPoP proof URL is invalid."
    case .invalidPrivateKey: "The DPoP private key is invalid."
    case .invalidPublicKey: "The DPoP public key is invalid."
    case .invalidStoredKey: "The saved DPoP identity is invalid."
    case .keychain(let status): SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    case .encoding: "The DPoP proof could not be encoded."
    }
  }
}

/// Where the device's proof key lives. Rotating the key invalidates every token bound to its thumbprint.
public protocol DPoPKeyStore: Sendable {
  /// The raw P-256 private key, or nil when none was stored yet.
  func load() throws -> Data?
  /// Stores `key` unless another instance stored one first; returns whichever key is stored afterwards.
  func saveIfAbsent(_ key: Data) throws -> Data
}

/// The device's proof-of-possession identity, shared by relay and environment requests.
public actor DPoPSigner {
  private let store: (any DPoPKeyStore)?
  private var privateKey: P256.Signing.PrivateKey?
  /// The key never rotates, so its JWK and thumbprint are derived once.
  private var cachedJWK: DPoPPublicJWK?

  public init(store: any DPoPKeyStore) { self.store = store }

  /// A fixed in-memory identity for tests.
  public init(privateKeyRawRepresentation: Data) throws {
    do { privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRawRepresentation) } catch { throw DPoPError.invalidPrivateKey }
    store = nil
  }

  public func publicJWK() throws -> DPoPPublicJWK {
    if let cachedJWK { return cachedJWK }
    let jwk = try DPoPPublicJWK(publicKey: try loadPrivateKey().publicKey)
    cachedJWK = jwk
    return jwk
  }

  public func thumbprint() throws -> String { try publicJWK().thumbprint }

  /// A proof for one request. `accessToken` binds it to a DPoP token (`ath`). Never reuse a proof: servers accept each `jti` once.
  public func proof(method: String, url: URL, accessToken: String? = nil, issuedAt: Date = Date(), identifier: UUID = UUID()) throws -> String {
    guard let htu = Self.normalizedHTU(url) else { throw DPoPError.invalidURL }
    let key = try loadPrivateKey()
    let header = Header(typ: "dpop+jwt", alg: "ES256", jwk: try publicJWK())
    let payload = Payload(
      htm: method.uppercased(), htu: htu.absoluteString, jti: identifier.uuidString.lowercased(), iat: Int(issuedAt.timeIntervalSince1970.rounded(.down)),
      ath: accessToken.map(Self.accessTokenHash))
    guard let headerPart = try? Self.encoder.encode(header).base64URLEncodedString(), let payloadPart = try? Self.encoder.encode(payload).base64URLEncodedString()
    else { throw DPoPError.encoding }
    let signingInput = "\(headerPart).\(payloadPart)"
    let signature = try key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
  }

  /// `new URL(url)` with search and hash cleared, as `normalizeDpopHtu` does: lowercase scheme and host, default port
  /// dropped, an empty path becomes `/`. The server compares this string with the proof's `htu` byte for byte.
  public static func normalizedHTU(_ url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }
    components.scheme = scheme
    components.host = host
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    if components.path.isEmpty { components.path = "/" }
    switch (scheme, components.port) {
    case ("http", 80), ("https", 443), ("ws", 80), ("wss", 443): components.port = nil
    default: break
    }
    return components.url
  }

  public static func accessTokenHash(_ accessToken: String) -> String {
    Data(SHA256.hash(data: Data(accessToken.utf8))).base64URLEncodedString()
  }

  private func loadPrivateKey() throws -> P256.Signing.PrivateKey {
    if let privateKey { return privateKey }
    guard let store else { throw DPoPError.invalidStoredKey }
    let raw: Data
    if let existing = try store.load() {
      raw = existing
    } else {
      raw = try store.saveIfAbsent(P256.Signing.PrivateKey().rawRepresentation)
    }
    guard let restored = try? P256.Signing.PrivateKey(rawRepresentation: raw) else { throw DPoPError.invalidStoredKey }
    privateKey = restored
    return restored
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private struct Header: Encodable {
    let typ: String
    let alg: String
    let jwk: DPoPPublicJWK
  }

  private struct Payload: Encodable {
    let htm: String
    let htu: String
    let jti: String
    let iat: Int
    let ath: String?
  }
}

extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }
}
