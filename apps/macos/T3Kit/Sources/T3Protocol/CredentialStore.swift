import Foundation
import Security
import Synchronization

/// Long-lived access token for one paired environment.
public struct EnvironmentCredential: Codable, Sendable, Equatable {
  public var environmentId: String
  public var label: String
  public var httpBaseURL: URL
  public var wsBaseURL: URL
  public var accessToken: String
  /// "Bearer" today; "DPoP" tokens need a proof key as well (T3 Connect, later).
  public var tokenType: String

  public init(
    environmentId: String, label: String, httpBaseURL: URL, wsBaseURL: URL,
    accessToken: String, tokenType: String = "Bearer"
  ) {
    self.environmentId = environmentId
    self.label = label
    self.httpBaseURL = httpBaseURL
    self.wsBaseURL = wsBaseURL
    self.accessToken = accessToken
    self.tokenType = tokenType
  }
}

public protocol CredentialStore: Sendable {
  func load(environmentId: String) throws -> EnvironmentCredential?
  func save(_ credential: EnvironmentCredential) throws
  func remove(environmentId: String) throws
}

public final class InMemoryCredentialStore: CredentialStore {
  private let credentials = Mutex<[String: EnvironmentCredential]>([:])

  public init() {}

  public func load(environmentId: String) throws -> EnvironmentCredential? {
    credentials.withLock { $0[environmentId] }
  }

  public func save(_ credential: EnvironmentCredential) throws {
    credentials.withLock { $0[credential.environmentId] = credential }
  }

  public func remove(environmentId: String) throws {
    credentials.withLock { _ = $0.removeValue(forKey: environmentId) }
  }
}

public struct KeychainError: Error, Sendable, Equatable {
  public let status: OSStatus
}

/// Generic-password items, service `codes.t3.macos`, account = environmentId, value = JSON.
/// Uses the default (file-based login) keychain, which needs no entitlements; the item is
/// readable by the app that stored it.
public struct KeychainCredentialStore: CredentialStore {
  public static let defaultService = "codes.t3.macos"
  private let service: String

  public init(service: String = KeychainCredentialStore.defaultService) {
    self.service = service
  }

  private func query(_ environmentId: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: environmentId]
  }

  public func load(environmentId: String) throws -> EnvironmentCredential? {
    var attributes = query(environmentId)
    attributes[kSecReturnData] = true
    attributes[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
    return try JSONDecoder().decode(EnvironmentCredential.self, from: data)
  }

  public func save(_ credential: EnvironmentCredential) throws {
    let data = try JSONEncoder().encode(credential)
    var attributes = query(credential.environmentId)
    attributes[kSecValueData] = data
    var status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      status = SecItemUpdate(
        query(credential.environmentId) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func remove(environmentId: String) throws {
    let status = SecItemDelete(query(environmentId) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }
}
