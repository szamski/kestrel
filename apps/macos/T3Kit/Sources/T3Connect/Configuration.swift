import Foundation

/// The public identifiers T3 Connect needs, as web and desktop get them from `T3CODE_CLERK_PUBLISHABLE_KEY`,
/// `T3CODE_CLERK_JWT_TEMPLATE` and `T3CODE_RELAY_URL` (docs/operations/connect-setup.md). This app reads the same
/// values from Info.plist keys that App/Support/Connect.xcconfig fills in. None of them is a secret.
public struct T3ConnectConfiguration: Equatable, Sendable {
  public let clerkPublishableKey: String
  public let clerkJWTTemplate: String
  /// A secure origin (`https://relay.t3.codes`), no path.
  public let relayURL: URL

  public init(clerkPublishableKey: String, clerkJWTTemplate: String, relayURL: URL) {
    self.clerkPublishableKey = clerkPublishableKey
    self.clerkJWTTemplate = clerkJWTTemplate
    self.relayURL = relayURL
  }

  public enum Resolution: Equatable, Sendable {
    case available(T3ConnectConfiguration)
    /// T3 Connect is off in this build; `reason` is for the settings page.
    case unavailable(reason: String)

    public var configuration: T3ConnectConfiguration? {
      if case .available(let configuration) = self { configuration } else { nil }
    }
  }

  public static func resolve(bundle: Bundle = .main) -> Resolution { resolve(infoDictionary: bundle.infoDictionary ?? [:]) }

  public static func resolve(infoDictionary: [String: Any]) -> Resolution {
    let key = value(infoDictionary["T3ConnectClerkPublishableKey"])
    let template = value(infoDictionary["T3ConnectClerkJWTTemplate"])
    let host = value(infoDictionary["T3ConnectRelayHost"])
    var missing: [String] = []
    if key == nil { missing.append("Clerk publishable key") }
    if template == nil { missing.append("Clerk JWT template") }
    if host == nil { missing.append("relay host") }
    guard missing.isEmpty, let key, let template, let host else { return .unavailable(reason: "This build is missing the \(missing.joined(separator: ", ")).") }
    guard clerkFrontendAPIHost(publishableKey: key) != nil else { return .unavailable(reason: "The Clerk publishable key of this build is not valid.") }
    guard let relayURL = secureOrigin("https://\(host)") else { return .unavailable(reason: "The relay host of this build is not valid.") }
    return .available(T3ConnectConfiguration(clerkPublishableKey: key, clerkJWTTemplate: template, relayURL: relayURL))
  }

  /// The Frontend API host encoded in a publishable key (`clerkFrontendApiHostnameFromPublishableKey`); nil when the key is malformed.
  public static func clerkFrontendAPIHost(publishableKey: String) -> String? {
    guard publishableKey.hasPrefix("pk_test_") || publishableKey.hasPrefix("pk_live_") else { return nil }
    let encoded = publishableKey.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false).dropFirst(2).joined(separator: "_")
    guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)), var host = String(data: data, encoding: .utf8)
    else { return nil }
    if host.hasSuffix("$") { host.removeLast() }
    guard !host.isEmpty, !host.contains("/"), URL(string: "https://\(host)")?.host != nil else { return nil }
    return host
  }

  /// `normalizeSecureRelayUrl`: https, no credentials, query, fragment or path.
  public static func secureOrigin(_ value: String) -> URL? {
    guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path.allSatisfy({ $0 == "/" })
    else { return nil }
    var origin = URLComponents()
    origin.scheme = "https"
    origin.host = host.lowercased()
    origin.port = components.port == 443 ? nil : components.port
    return origin.url
  }

  /// An unresolved `$(VARIABLE)` means the xcconfig did not define it.
  private static func value(_ raw: Any?) -> String? {
    guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains("$(") else { return nil }
    return text
  }
}
