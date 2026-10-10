import Foundation
import Security
import Synchronization

/// Process-lifetime key for tests and previews.
public final class InMemoryDPoPKeyStore: DPoPKeyStore {
  private let key = Mutex<Data?>(nil)
  public init() {}
  public func load() throws -> Data? { key.withLock { $0 } }
  public func saveIfAbsent(_ new: Data) throws -> Data { key.withLock { $0 = $0 ?? new; return $0! } }
}

/// The device proof key as a generic-password item. It goes to the data-protection keychain, which
/// needs the app to be signed with an application identifier (`accessGroup` selects a shared group;
/// nil is the app's own). Builds without that entitlement answer `errSecMissingEntitlement`, and the
/// key then lives in the login keychain like the app's other credentials.
///
/// ponytail: the login-keychain fallback is readable by this app's code signature only, but a rebuilt
/// development binary asks the user again. A Secure Enclave key needs the same entitlement; upgrade to it
/// (non-exportable key) once release builds carry a provisioning profile.
public struct KeychainDPoPKeyStore: DPoPKeyStore {
  public static let defaultService = "codes.t3.macos.dpop"
  private let service: String
  private let account: String
  private let accessGroup: String?
  /// The file-based keychain can deadlock when two threads use it at once.
  private static let fileKeychainLock = NSLock()

  public init(service: String = KeychainDPoPKeyStore.defaultService, account: String = "device-proof-key", accessGroup: String? = nil) {
    self.service = service
    self.account = account
    self.accessGroup = accessGroup
  }

  private func query(dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
      if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    }
    return query
  }

  private func locked<T>(_ dataProtection: Bool, _ body: () -> T) -> T {
    if dataProtection { return body() }
    return Self.fileKeychainLock.withLock(body)
  }

  public func load() throws -> Data? {
    for dataProtection in [true, false] {
      var attributes = query(dataProtection: dataProtection)
      attributes[kSecReturnData as String] = true
      attributes[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = locked(dataProtection) { SecItemCopyMatching(attributes as CFDictionary, &item) }
      switch status {
      case errSecSuccess:
        guard let data = item as? Data else { throw DPoPError.invalidStoredKey }
        return data
      case errSecItemNotFound, errSecMissingEntitlement: continue
      default: throw DPoPError.keychain(status)
      }
    }
    return nil
  }

  public func saveIfAbsent(_ key: Data) throws -> Data {
    var status = OSStatus(errSecSuccess)
    for dataProtection in [true, false] {
      var attributes = query(dataProtection: dataProtection)
      attributes[kSecValueData as String] = key
      if dataProtection { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
      status = locked(dataProtection) { SecItemAdd(attributes as CFDictionary, nil) }
      if status == errSecMissingEntitlement { continue }
      break
    }
    switch status {
    case errSecSuccess: return key
    case errSecDuplicateItem:
      // Another signer won the first-launch race: keep its identity instead of rotating.
      guard let existing = try load() else { throw DPoPError.keychain(status) }
      return existing
    default: throw DPoPError.keychain(status)
    }
  }

  /// Removes the key from both keychains (tests; sign-out keeps it, since it is the device's identity, not the account's).
  public func remove() {
    for dataProtection in [true, false] { _ = locked(dataProtection) { SecItemDelete(query(dataProtection: dataProtection) as CFDictionary) } }
  }
}
