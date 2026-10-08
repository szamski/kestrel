import Foundation

// Pairing URL parsing (packages/shared/src/remote.ts), /ws URL building
// (client-runtime authorization/remote.ts) and protocol compatibility
// (client-runtime connection/compatibility.ts).

// MARK: - Pairing

public struct PairingTarget: Sendable, Equatable {
  public let credential: String
  public let httpBaseURL: URL
  public let wsBaseURL: URL
  /// `label` query param of a hosted pairing link.
  public let label: String?
}

public enum PairingError: Error, Sendable, Equatable {
  case missingBackendURL
  case invalidPairingURL(scheme: String?)
  case invalidBackendURL(scheme: String?)
  case missingToken(host: String)
  case missingCode(host: String)
}

extension PairingTarget {
  private static let supportedSchemes: Set<String> = ["http", "https", "ws", "wss"]

  /// Accepts `http(s)://host[:port]/pair#token=…` and the hosted form
  /// `…/pair?host=…&label=…#token=…` (token also accepted in the query).
  public static func parse(pairingURL: String) throws(PairingError) -> PairingTarget {
    guard let url = URLComponents(string: pairingURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme != nil, url.host != nil
    else { throw .invalidPairingURL(scheme: nil) }
    let scheme = url.scheme!.lowercased()
    guard supportedSchemes.contains(scheme) else { throw .invalidPairingURL(scheme: scheme) }

    let query = formParams(url.percentEncodedQuery)
    let token = (formParams(url.percentEncodedFragment)["token"] ?? query["token"])?
      .trimmingCharacters(in: .whitespaces) ?? ""
    let hostedHost = query["host"]?.trimmingCharacters(in: .whitespaces) ?? ""
    if !hostedHost.isEmpty, !token.isEmpty {
      let base = try normalizedBase(hostedHost)
      return PairingTarget(
        credential: token, httpBaseURL: httpURL(base), wsBaseURL: wsURL(base),
        label: query["label"]?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
    }
    guard !token.isEmpty else { throw .missingToken(host: url.host!) }
    let base = rootURL(url)
    return PairingTarget(credential: token, httpBaseURL: httpURL(base), wsBaseURL: wsURL(base), label: nil)
  }

  /// Manual entry: backend host (scheme optional, https assumed) plus a pairing code.
  public static func resolve(host: String, pairingCode: String) throws(PairingError) -> PairingTarget {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty { throw .missingBackendURL }
    let base = try normalizedBase(host)
    if code.isEmpty { throw .missingCode(host: base.host!) }
    return PairingTarget(credential: code, httpBaseURL: httpURL(base), wsBaseURL: wsURL(base), label: nil)
  }

  private static func normalizedBase(_ raw: String) throws(PairingError) -> URLComponents {
    var trimmed = Substring(raw)
    while trimmed.first == "/" { trimmed = trimmed.dropFirst() }
    let hasScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+-]*://"#, options: .regularExpression) != nil
    guard let url = URLComponents(string: hasScheme ? String(trimmed) : "https://\(trimmed)"),
      url.host != nil
    else { throw .invalidBackendURL(scheme: nil) }
    guard supportedSchemes.contains(url.scheme!.lowercased()) else {
      throw .invalidBackendURL(scheme: url.scheme!.lowercased())
    }
    return rootURL(url)
  }

  private static func rootURL(_ url: URLComponents) -> URLComponents {
    var root = url
    root.path = "/"
    root.query = nil
    root.fragment = nil
    return root
  }

  private static func httpURL(_ base: URLComponents) -> URL {
    var url = base
    url.scheme = url.scheme!.lowercased() == "ws" ? "http" : url.scheme!.lowercased() == "wss" ? "https" : url.scheme!.lowercased()
    return url.url!
  }

  private static func wsURL(_ base: URLComponents) -> URL {
    var url = base
    url.scheme = url.scheme!.lowercased() == "http" ? "ws" : url.scheme!.lowercased() == "https" ? "wss" : url.scheme!.lowercased()
    return url.url!
  }
}

/// `URLSearchParams` semantics: `+` is a space, values are percent-decoded, first key wins.
private func formParams(_ raw: String?) -> [String: String] {
  var params: [String: String] = [:]
  for pair in (raw ?? "").split(separator: "&") {
    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    func decode(_ part: Substring) -> String {
      let spaced = part.replacingOccurrences(of: "+", with: " ")
      return spaced.removingPercentEncoding ?? spaced
    }
    let key = decode(parts[0])
    if params[key] == nil { params[key] = parts.count > 1 ? decode(parts[1]) : "" }
  }
  return params
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - WebSocket URL

public enum WebSocketURL {
  public static let orchestrationProtocolQueryParam = "orchestrationProtocol"

  /// `/ws?wsTicket=…&clientSurface=…&clientAppVersion=…&clientDeviceType=…&clientOs=…
  /// [&connectionMethod=…]&orchestrationProtocol=1`. The server reads these in
  /// apps/server/src/ws.ts (`readClientAnalyticsProps`); unknown or malformed values are dropped.
  public static func make(
    wsBaseURL: URL,
    ticket: String,
    metadata: ClientMetadata,
    connectionMethod: ConnectionMethod? = .direct
  ) -> URL {
    var url = URLComponents(url: wsBaseURL, resolvingAgainstBaseURL: false)!
    if url.path.isEmpty || url.path == "/" { url.path = "/ws" }
    var items = [("wsTicket", ticket), ("clientSurface", metadata.surface)]
    if let version = metadata.appVersion { items.append(("clientAppVersion", version)) }
    items.append(("clientDeviceType", metadata.deviceType))
    items.append(("clientOs", metadata.os))
    if let connectionMethod { items.append(("connectionMethod", connectionMethod.rawValue)) }
    items.append((orchestrationProtocolQueryParam, String(ProtocolCompatibility.clientVersion)))
    // Percent-encoded by hand: URLComponents would leave `+` raw and the server reads it as a space.
    url.percentEncodedQuery = items.map { "\($0.0)=\(formEscape($0.1))" }.joined(separator: "&")
    return url.url!
  }
}

// MARK: - Compatibility

public enum ProtocolCompatibility: Error, Sendable, Equatable {
  /// The server speaks a newer protocol than this client.
  case clientTooOld(serverVersion: Int)
  /// The server speaks an older protocol than this client.
  case serverTooOld(serverVersion: Int)

  /// ORCHESTRATION_PROTOCOL_VERSION in packages/contracts/src/environment.ts.
  public static let clientVersion = 1

  /// nil when compatible. A missing version means protocol 1.
  public static func check(_ descriptor: EnvironmentDescriptorInfo) -> ProtocolCompatibility? {
    let server = descriptor.orchestrationProtocolVersion ?? 1
    if server == clientVersion { return nil }
    return server > clientVersion ? .clientTooOld(serverVersion: server) : .serverTooOld(serverVersion: server)
  }

  public func message(environmentLabel: String) -> String {
    switch self {
    case .clientTooOld:
      "This client is not supported by this server. Update your app or use a compatible release to connect to \(environmentLabel)."
    case .serverTooOld:
      "This client requires a newer server. Update T3 Code on \(environmentLabel) to connect."
    }
  }
}
