import CryptoKit
import Foundation
import Testing
@testable import T3Connect

private struct Malformed: Error {}

private func jsonObject(_ part: String) throws -> [String: Any] {
  guard let data = Data(base64URL: part), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Malformed() }
  return object
}

private func bytes(_ part: String) throws -> Data {
  guard let data = Data(base64URL: part) else { throw Malformed() }
  return data
}

@Suite struct DPoPTests {
  @Test func thumbprintAndProofMatchTheServerContract() async throws {
    let signer = try testSigner()
    let jwk = try await signer.publicJWK()
    // RFC 7638 thumbprint of the P-256 key with private scalar 1 (the generator point).
    #expect(
      jwk.canonicalThumbprintInput
        == #"{"crv":"P-256","kty":"EC","x":"axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpY","y":"T-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"}"#)
    #expect(jwk.thumbprint == "xx0BcA-wMohw8atYDJOe6peGModklG2wRHBlXHMvl0M")

    let url = URL(string: "https://relay.example/v1/connect?ignored=yes#fragment")!
    let issued = Date(timeIntervalSince1970: 1_800_000_000)
    let proof = try await signer.proof(
      method: "post", url: url, accessToken: "access-token", issuedAt: issued, identifier: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
    let parts = proof.split(separator: ".").map(String.init)
    #expect(parts.count == 3)

    let header = try jsonObject(parts[0])
    #expect(header["typ"] as? String == "dpop+jwt")
    #expect(header["alg"] as? String == "ES256")
    #expect((header["jwk"] as? [String: Any])?["d"] == nil, "the private scalar never leaves the signer")
    let payload = try jsonObject(parts[1])
    #expect(payload["htm"] as? String == "POST")
    #expect(payload["htu"] as? String == "https://relay.example/v1/connect")
    #expect(payload["iat"] as? Int == 1_800_000_000)
    #expect(payload["jti"] as? String == "12345678-1234-1234-1234-1234567890ab")
    #expect(payload["ath"] as? String == DPoPSigner.accessTokenHash("access-token"))

    // Signature: ES256 over `header.payload`, raw r||s, verified with the public JWK alone.
    let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + (try bytes(jwk.x)) + (try bytes(jwk.y)))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: try bytes(parts[2]))
    #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    // …and the independent verifier accepts it for the right request and nothing else.
    let verified = try verifyDPoP(proof, method: "POST", url: url, accessToken: "access-token", now: issued, expectedThumbprint: jwk.thumbprint)
    #expect(verified.thumbprint == jwk.thumbprint)
    #expect(throws: ProofRejected.self) { try verifyDPoP(proof, method: "GET", url: url, accessToken: "access-token", now: issued) }
    #expect(throws: ProofRejected.self) { try verifyDPoP(proof, method: "POST", url: URL(string: "https://relay.example/v1/other")!, accessToken: "access-token", now: issued) }
    #expect(throws: ProofRejected.self) { try verifyDPoP(proof, method: "POST", url: url, accessToken: "another-token", now: issued) }
    #expect(throws: ProofRejected.self) { try verifyDPoP(proof, method: "POST", url: url, accessToken: "access-token", now: issued.addingTimeInterval(301)) }
    #expect(throws: ProofRejected.self) { try verifyDPoP(proof + "x", method: "POST", url: url, accessToken: "access-token", now: issued) }
  }

  @Test func proofsWithoutATokenCarryNoAccessTokenHash() async throws {
    let proof = try await testSigner().proof(method: "POST", url: URL(string: "https://env.example/oauth/token")!)
    let payload = try jsonObject(String(proof.split(separator: ".")[1]))
    #expect(payload["ath"] == nil)
  }

  @Test func everyProofHasItsOwnIdentifier() async throws {
    let signer = try testSigner()
    let url = URL(string: "https://env.example/api/x")!
    let first = try verifyDPoP(try await signer.proof(method: "GET", url: url), method: "GET", url: url)
    let second = try verifyDPoP(try await signer.proof(method: "GET", url: url), method: "GET", url: url)
    #expect(first.jti != second.jti, "the server accepts each jti once")
    #expect(first.thumbprint == second.thumbprint)
  }

  @Test func htuNormalization() {
    func htu(_ url: String) -> String? { DPoPSigner.normalizedHTU(URL(string: url)!)?.absoluteString }
    #expect(htu("https://relay.example:443/path?query=one#fragment") == "https://relay.example/path")
    #expect(htu("https://relay.example:8443/path") == "https://relay.example:8443/path")
    #expect(htu("http://relay.example:80/a") == "http://relay.example/a")
    #expect(htu("wss://relay.example:443/ws?wsTicket=x") == "wss://relay.example/ws")
    #expect(htu("HTTPS://Relay.Example/Path") == "https://relay.example/Path", "scheme and host fold, the path does not")
    #expect(htu("https://relay.example") == "https://relay.example/", "an empty path is `/` like `new URL(...)`")
    #expect(DPoPSigner.normalizedHTU(URL(string: "/relative/only")!) == nil)
  }

  @Test func invalidURLIsRejected() async throws {
    await #expect(throws: DPoPError.invalidURL) { try await testSigner().proof(method: "GET", url: URL(string: "/relative")!) }
  }

  @Test func generatesAndReusesTheStoredKey() async throws {
    let store = InMemoryDPoPKeyStore()
    let first = try await DPoPSigner(store: store).thumbprint()
    let second = try await DPoPSigner(store: store).thumbprint()
    #expect(first == second, "a new launch must keep the device identity")
    #expect(try await DPoPSigner(store: InMemoryDPoPKeyStore()).thumbprint() != first)
  }

  @Test func corruptStoredKeyIsAnErrorNotARotation() async throws {
    let store = InMemoryDPoPKeyStore()
    _ = try store.saveIfAbsent(Data([1, 2, 3]))
    await #expect(throws: DPoPError.invalidStoredKey) { try await DPoPSigner(store: store).thumbprint() }
  }

  @Test func keychainRoundTrip() async throws {
    // Own service so the app's real items are never touched. Unsigned test hosts have no application identifier, so this runs through the
    // login-keychain fallback; a signed app uses the data-protection keychain with the same calls.
    let store = KeychainDPoPKeyStore(service: "codes.t3.macos.tests.dpop.\(UUID().uuidString)")
    defer { store.remove() }
    #expect(try store.load() == nil)
    let first = Data(P256.Signing.PrivateKey().rawRepresentation)
    #expect(try store.saveIfAbsent(first) == first)
    // A second writer loses the race and receives the stored key instead of rotating it.
    #expect(try store.saveIfAbsent(Data(P256.Signing.PrivateKey().rawRepresentation)) == first)
    #expect(try store.load() == first)

    let signed = try await DPoPSigner(store: store).thumbprint()
    #expect(signed == (try await DPoPSigner(store: store).thumbprint()), "two signer instances share one identity")
    let expected = try P256.Signing.PrivateKey(rawRepresentation: first).publicKey
    #expect(signed == (try DPoPPublicJWK(publicKey: expected)).thumbprint)
  }
}
