import Foundation

/// What an address bar does with typed text; a port of `resolveAddressBarInput` / `normalizePreviewUrl`
/// (packages/shared/src/preview.ts).
public enum PreviewAddress {
  public enum Failure: Error, Equatable { case empty, parse, unsupportedProtocol(String) }

  /// What JavaScript's `encodeURIComponent` leaves alone.
  private static let componentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
  private static let searchURL = "https://duckduckgo.com/?q="
  private static let nonWebSchemes: Set<String> = [
    "about:", "blob:", "chrome:", "data:", "file:", "ftp:", "javascript:", "mailto:", "sms:", "ssh:", "tel:", "view-source:", "ws:", "wss:",
  ]

  /// An address as written, or else a web search for the text. Throws only for empty input or an explicit unsupported scheme.
  public static func resolve(_ input: String) throws -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefixRegex("^[a-z][a-z\\d+.-]*://") { return try normalize(trimmed) }
    if !trimmed.contains(where: \.isWhitespace) {
      let scheme = protocolOf(trimmed)
      if let scheme, nonWebSchemes.contains(scheme) || !trimmed.hasPrefixRegex("^[^/?#:@]+:\\d+(?:[/?#]|$)") {
        if scheme != "http:" && scheme != "https:" { throw Failure.unsupportedProtocol(scheme) }
        return try normalize(trimmed)
      }
      let authority = String(trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { "/?#".contains($0) })[0])
      let withoutUser = authority.replacingOccurrences(of: "^[^@]*@", with: "", options: .regularExpression)
      let host = withoutUser.replacingOccurrences(of: ":\\d+$", with: "", options: .regularExpression)
      let hasPort = host.count < withoutUser.count
      if hasPort || host.matches("^(?:localhost|\\d{1,3}(?:\\.\\d{1,3}){3}|\\[[\\da-f:.]+\\])$") || host.matches("^[^.]+(?:\\.[^.]+)+\\.?$") {
        if let url = try? normalize(trimmed) { return url }
      }
    }
    return searchURL + (trimmed.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? trimmed)
  }

  /// A fully qualified `http(s)://` URL: bare loopback hosts become `http://`, other bare hosts `https://`.
  public static func normalize(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw Failure.empty }
    let loopback = trimmed.hasPrefixRegex("^(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1?\\])(?::|/|$)")
    let candidate = trimmed.contains("://") ? trimmed : "\(loopback ? "http" : "https")://\(trimmed)"
    guard var components = URLComponents(string: candidate), let host = components.host, !host.isEmpty else { throw Failure.parse }
    let scheme = (components.scheme ?? "").lowercased()
    guard scheme == "http" || scheme == "https" else { throw Failure.unsupportedProtocol(scheme + ":") }
    components.scheme = scheme
    if components.path.isEmpty { components.path = "/" }
    guard let url = components.url else { throw Failure.parse }
    return url.absoluteString
  }

  private static func protocolOf(_ text: String) -> String? {
    guard let range = text.range(of: "^[A-Za-z][A-Za-z\\d+.-]*:", options: .regularExpression) else { return nil }
    return text[range].lowercased()
  }
}

extension String {
  fileprivate func hasPrefixRegex(_ pattern: String) -> Bool { range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
  fileprivate func matches(_ pattern: String) -> Bool { range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
}
