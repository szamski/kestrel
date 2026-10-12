import Foundation

/// Where a link or a notification click leads. A pure port of the iOS client's `PlatformDeepLinkParser` (pr-5178),
/// without its file, terminal and git destinations.
public enum AppRoute: Sendable, Equatable {
  /// `environmentId` is nil for links that only carry the thread id; the app resolves it.
  case thread(environmentId: String?, threadId: String)
  case project(environmentId: String?, projectId: String)
  /// A pairing link (`https://host/pair#token=...`) for `ClientRuntime.addEnvironment(pairingURL:)`.
  case pairing(url: String)
}

public enum AppRouteParser {
  /// The scheme Kestrel registers; `t3` and `t3code` are parsed too (links made for the other clients) but belong to them.
  public static let scheme = "kestrel"
  private static let customSchemes: Set<String> = [scheme, "t3", "t3code"]
  private static let trustedWebHosts: Set<String> = ["app.t3.codes", "t3.codes", "www.t3.codes"]

  public static func parse(_ value: String) -> AppRoute? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Agent thread links keep literal ids: parse them before Foundation can repair a malformed percent escape.
    if value.lowercased().hasPrefix("t3-thread:") { return threadLink(value) }
    guard let url = URL(string: value) else { return nil }
    return parse(url)
  }

  public static func parse(_ url: URL) -> AppRoute? {
    if url.scheme?.lowercased() == "t3-thread" { return threadLink(url.absoluteString) }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased() else { return nil }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] { if let value = item.value, !value.isEmpty { query[item.name.lowercased()] = value } }
    if customSchemes.contains(scheme) {
      var segments = pathSegments(components.percentEncodedPath)
      if let host = components.host, !host.isEmpty { segments.insert(host, at: 0) }
      if ["pair", "pairing", "connect"].contains(segments.first?.lowercased()) {
        return (query["pairingurl"] ?? query["pairing_url"] ?? query["url"]).flatMap(pairing)
      }
      return navigation(segments, query)
    }
    guard scheme == "http" || scheme == "https", let host = components.host?.lowercased(), trustedWebHosts.contains(host) else { return nil }
    let segments = pathSegments(components.percentEncodedPath)
    if segments.first?.lowercased() == "pair" { return pairing(url.absoluteString) }
    if ["thread", "threads", "project", "projects"].contains(segments.first?.lowercased()) || query["thread"] != nil { return navigation(segments, query) }
    // The web's own thread route is `/:environmentId/:threadId`.
    guard segments.count == 2, let environmentId = identifier(segments[0]), let threadId = identifier(segments[1]) else { return nil }
    return .thread(environmentId: environmentId, threadId: threadId)
  }

  /// The link a notification carries back to the app for `route` (thread and project only).
  public static func url(for route: AppRoute) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    switch route {
    case .thread(let environmentId, let threadId): components.host = "threads"; components.percentEncodedPath = "/" + [environmentId, threadId].compactMap { $0 }.map(encode).joined(separator: "/")
    case .project(let environmentId, let projectId): components.host = "projects"; components.percentEncodedPath = "/" + [environmentId, projectId].compactMap { $0 }.map(encode).joined(separator: "/")
    case .pairing: return nil
    }
    return components.url
  }

  // MARK: Internals

  private static func navigation(_ segments: [String], _ query: [String: String]) -> AppRoute? {
    let tail = Array(segments.dropFirst())
    let environment = query["environment"] ?? query["environmentid"] ?? query["env"]
    switch segments.first?.lowercased() {
    case "thread", "threads":
      guard let (environmentId, threadId) = pair(tail: tail, environment: environment, destination: query["thread"] ?? query["threadid"]) else { return nil }
      return .thread(environmentId: environmentId, threadId: threadId)
    case "project", "projects":
      guard let (environmentId, projectId) = pair(tail: tail, environment: environment, destination: query["project"] ?? query["projectid"]) else { return nil }
      return .project(environmentId: environmentId, projectId: projectId)
    default:
      return nil
    }
  }

  /// `/:environmentId/:id`, `/:id?environment=`, or `?environment=&id=`.
  private static func pair(tail: [String], environment: String?, destination: String?) -> (String?, String)? {
    if let destination {
      guard let id = identifier(destination) else { return nil }
      return (environment.flatMap(identifier), id)
    }
    if tail.count >= 2 {
      guard let environmentId = identifier(tail[0]), let id = identifier(tail[1]) else { return nil }
      return (environmentId, id)
    }
    guard let first = tail.first, let id = identifier(first) else { return nil }
    return (environment.flatMap(identifier), id)
  }

  /// `t3-thread://v1/<id>` or `t3-thread://v1/<environmentId>/<threadId>`.
  private static func threadLink(_ value: String) -> AppRoute? {
    let prefix = "t3-thread://v1/"
    guard value.lowercased().hasPrefix(prefix), !value.contains("?"), !value.contains("#") else { return nil }
    let segments = value.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    switch segments.count {
    case 1: return identifier(segments[0]).map { .thread(environmentId: nil, threadId: $0) }
    case 2:
      guard let environmentId = segments[0].removingPercentEncoding.flatMap(identifier), let threadId = segments[1].removingPercentEncoding.flatMap(identifier) else { return nil }
      return .thread(environmentId: environmentId, threadId: threadId)
    default: return nil
    }
  }

  private static func pairing(_ value: String) -> AppRoute? {
    guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
    return .pairing(url: value)
  }

  private static func pathSegments(_ percentEncodedPath: String) -> [String] {
    percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
  }

  private static func encode(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove("/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  /// Ids are opaque, so the only checks are the ones that keep a hostile link from reaching a lookup or a UI string.
  private static func identifier(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 1_024, value != ".", value != "..", value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return value
  }
}
