import Foundation

// Link classification for rendered Markdown. Port of
// packages/client-runtime/src/{markdownLinks,markdownImages}.ts so the native client
// reads the same hrefs as the web renderer. This module only *resolves*; the UI routes.

/// A file reference. `path` is absolute when `baseDirectory` was known, otherwise as authored.
public struct MarkdownFileTarget: Hashable, Sendable {
  public var path: String
  public var line: Int?
  public var column: Int?
  /// End of a `#L12-L20` range.
  public var endLine: Int?

  public init(path: String, line: Int? = nil, column: Int? = nil, endLine: Int? = nil) {
    self.path = path
    self.line = line
    self.column = column
    self.endLine = endLine
  }

  public var basename: String { MarkdownPaths.basename(path) }

  /// `path:line:column`, the editor-friendly spelling.
  public var pathWithPosition: String {
    guard let line else { return path }
    return "\(path):\(line)\(column.map { ":\($0)" } ?? "")"
  }
}

/// `t3-citation://v1/<env>/<thread>/<message>?text=…` (packages/shared/src/assistantCitations.ts).
public struct MarkdownCitation: Hashable, Sendable {
  public var environmentId: String
  public var threadId: String
  public var messageId: String
  public var text: String
  public var comment: String?
  /// UTF-16 offsets into the *rendered* text of the source message.
  public var start: Int
  public var end: Int
  public var prefix: String
  public var suffix: String
}

/// Where an image's bytes must come from. Filesystem paths belong to the environment host:
/// the UI turns `.workspaceFile` into a signed asset request, never a direct file read.
public enum MarkdownImageSource: Hashable, Sendable {
  case direct(String)
  case workspaceFile(String)
  case blocked
}

public enum MarkdownLink: Hashable, Sendable {
  /// http(s), mailto, xmpp, irc(s): the sanitizer's href allow-list.
  case web(URL)
  case file(MarkdownFileTarget)
  case citation(MarkdownCitation)
  /// `t3-context://v1/<kind>/<contextId>`.
  case context(kind: String, id: String)
  /// Same-document `#fragment` (without the `#`).
  case anchor(String)
  /// "Use template" action of an artifact card.
  case artifactTemplate(MarkdownArtifactTemplate)
  /// Activation of an image (placeholder or loaded): the UI may expand or open it.
  case image(MarkdownImage)
}

public enum MarkdownPaths {
  static func isWindowsDrive(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count >= 3 && isASCIILetter(u[0]) && u[1] == 0x3A && (u[2] == 0x2F || u[2] == 0x5C)
  }
  static func isWindowsAbsolute(_ s: String) -> Bool { s.hasPrefix("\\\\") || isWindowsDrive(s) }

  static func isASCIILetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }

  static func safeDecode(_ s: String) -> String { s.removingPercentEncoding ?? s }

  static func normalizeDestination(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.hasPrefix("<") && t.hasSuffix(">") && t.count >= 2 ? String(t.dropFirst().dropLast()) : t
  }

  /// Browser URL parsers write `C:/foo` as `/C:/foo` for file URLs.
  static func stripSlashPrefixedDrive(_ p: String) -> String {
    let u = Array(p.utf8)
    if u.count >= 4, u[0] == 0x2F, isASCIILetter(u[1]), u[2] == 0x3A, u[3] == 0x2F || u[3] == 0x5C {
      return String(p.dropFirst())
    }
    return p
  }

  static func splitSearchAndHash(_ v: String) -> (path: String, hash: String) {
    var pathPart = Substring(v)
    var hash = ""
    if let i = v.firstIndex(of: "#") {
      pathPart = v[..<i]
      hash = String(v[i...])
    }
    if let q = pathPart.firstIndex(of: "?") { pathPart = pathPart[..<q] }
    return (String(pathPart), hash)
  }

  /// `file:` URL → host path, still percent-encoded (callers decode once). A
  /// non-localhost authority becomes a UNC share.
  static func parseFileURL(_ href: String) -> (path: String, hash: String)? {
    guard href.lowercased().hasPrefix("file:") else { return nil }
    var rest = Substring(href.dropFirst(5))
    var hash = ""
    if let i = rest.firstIndex(of: "#") {
      hash = String(rest[i...])
      rest = rest[..<i]
    }
    if let q = rest.firstIndex(of: "?") { rest = rest[..<q] }
    var host = ""
    if rest.hasPrefix("//") {
      rest = rest.dropFirst(2)
      let slash = rest.firstIndex(of: "/") ?? rest.endIndex
      host = String(rest[..<slash])
      rest = rest[slash...]
    }
    var path = String(rest)
    if host.lowercased() == "localhost" { host = "" }
    if !host.isEmpty { path = "\\\\\(host)" + path.replacingOccurrences(of: "/", with: "\\") }
    if path.isEmpty { return nil }
    return (stripSlashPrefixedDrive(path), hash)
  }

  static func splitPosition(_ path: String, hash: String = "") -> MarkdownFileTarget {
    if let m = positionSuffix.firstMatch(in: path) {
      let line = Int(m[1] ?? "")
      let col = m[2].flatMap { Int($0) }
      let cut = path.index(path.endIndex, offsetBy: -(m[0]?.count ?? 0))
      return MarkdownFileTarget(
        path: String(path[..<cut]), line: (line ?? 0) > 0 ? line : nil, column: (col ?? 0) > 0 ? col : nil)
    }
    if let m = positionHash.firstMatch(in: hash) {
      let line = Int(m[1] ?? "")
      let col = m[2].flatMap { Int($0) }
      let end = m[3].flatMap { Int($0) }
      return MarkdownFileTarget(
        path: path, line: (line ?? 0) > 0 ? line : nil, column: (col ?? 0) > 0 ? col : nil,
        endLine: (end ?? 0) > 0 ? end : nil)
    }
    return MarkdownFileTarget(path: path)
  }

  static func isRelativePath(_ p: String) -> Bool {
    relativePrefix.matches(p) || (!p.hasPrefix("/") && !isWindowsAbsolute(p))
  }

  public static func basename(_ path: String) -> String {
    var t = Substring(path)
    while let l = t.last, l == "/" || l == "\\" { t = t.dropLast() }
    if t.isEmpty { return path }
    if let i = t.lastIndex(where: { $0 == "/" || $0 == "\\" }) { return String(t[t.index(after: i)...]) }
    return String(t)
  }

  /// Joins a relative path onto `base`, collapsing `.`/`..`. `~/…` stays unresolved.
  static func join(base: String, relative: String) -> String {
    if relative.hasPrefix("~/") { return relative }
    let windows = isWindowsAbsolute(base)
    let sep = windows ? "\\" : "/"
    let baseNorm = base.replacingOccurrences(of: "\\", with: "/")
    var prefix = ""
    var rest = Substring(baseNorm)
    if windows {
      if rest.hasPrefix("//") {
        prefix = "//"
        rest = rest.dropFirst(2)
      } else if let c = rest.firstIndex(of: ":") {
        prefix = String(rest[...c]) + "/"
        rest = rest[rest.index(after: c)...].drop(while: { $0 == "/" })
      }
    } else if rest.hasPrefix("/") {
      prefix = "/"
      rest = rest.dropFirst()
    }
    var segs = rest.split(separator: "/").map(String.init)
    for seg in relative.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
      if seg == "." { continue }
      if seg == ".." {
        if !segs.isEmpty { segs.removeLast() }
        continue
      }
      segs.append(String(seg))
    }
    let joined = prefix + segs.joined(separator: "/")
    return windows ? joined.replacingOccurrences(of: "/", with: sep) : joined
  }
}

// MARK: - Patterns

/// Thin Sendable wrapper over NSRegularExpression (immutable, thread-safe after init).
struct Rx: @unchecked Sendable {
  let re: NSRegularExpression
  init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
    // Patterns are compile-time constants in this file; a failure is a programmer error.
    re = try! NSRegularExpression(pattern: pattern, options: options)
  }
  func matches(_ s: String) -> Bool {
    re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
  }
  /// Capture groups as strings; index 0 is the whole match.
  func firstMatch(in s: String) -> [String?]? {
    guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
      Range(m.range(at: i), in: s).map { String(s[$0]) }
    }
  }
}

private let positionSuffix = Rx(#":(\d+)(?::(\d+))?$"#)
private let positionHash = Rx(#"^#L(\d+)(?:C(\d+))?(?:-L?(\d+)(?:C\d+)?)?$"#, .caseInsensitive)
private let positionSuffixAny = Rx(#":\d+(?::\d+)?$"#)
private let relativePrefix = Rx(#"^(~/|\.{1,2}/)"#)
private let relativeFilePath = Rx(
  #"^(?:[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*/)+[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*(?::\d+){0,2}$"#)
private let relativeFileName = Rx(#"^[A-Za-z0-9._-]+(?: +[A-Za-z0-9._-]+)*\.[A-Za-z0-9_-]+(?::\d+){0,2}$"#)
private let externalScheme = Rx(#"^([A-Za-z][A-Za-z0-9+.-]*):(.*)$"#, .dotMatchesLineSeparators)
private let uriScheme = Rx(#"^[A-Za-z][A-Za-z0-9+.-]*:"#)
private let positionOnly = Rx(#"^\d+(?::\d+)?$"#)
private let inlineDisqualifier = Rx(#"[\s`]"#)
private let pathSeparator = Rx(#"[\\/]"#)
private let fileExtension = Rx(#"\.[A-Za-z0-9_-]+$"#)
private let numericDotted = Rx(#"^\d+(?:\.\d+)+$"#)

// Standard OS and dev-container roots; deliberately excludes app-route-ish prefixes
// like /app/ or /chat/ so SPA routes never read as files.
private let posixRoots = [
  "/Users/", "/home/", "/tmp/", "/var/", "/etc/", "/opt/", "/mnt/", "/Volumes/", "/private/", "/root/",
  "/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/srv/", "/dev/", "/proc/", "/sys/", "/run/", "/boot/",
  "/media/", "/workspace/", "/workspaces/",
]
private let extensionlessNames: Set<String> = [
  "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile", "justfile", "Rakefile",
  "Gemfile", "Procfile", "Brewfile", "Caddyfile", "Vagrantfile", "Jenkinsfile", "Podfile", "Fastfile",
  "BUILD", "WORKSPACE", "LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS", "CONTRIBUTORS", "CHANGELOG",
  "README", "CODEOWNERS",
]
private let genericTLDs: Set<String> = [
  "com", "net", "org", "io", "dev", "app", "ai", "co", "edu", "gov", "mil", "info", "biz", "xyz", "me", "tv",
  "cc", "gg", "chat", "cloud", "site", "online", "tech", "store", "link",
]
// Country codes also name file extensions; a :line suffix makes `.pl`/`.pt` files likelier.
private let countryTLDs: Set<String> = [
  "uk", "de", "fr", "nl", "se", "no", "fi", "dk", "pl", "ch", "at", "be", "es", "it", "pt", "eu", "us", "ca",
  "au", "nz", "jp", "kr", "cn", "br", "ru", "mx", "ie", "cz", "tr", "sg", "hk",
]

private func looksLikeHostname(_ segment: String, hasPosition: Bool) -> Bool {
  if segment.hasPrefix(".") { return false }
  let lowered = segment.lowercased()
  if lowered == "localhost" { return true }
  if numericDotted.matches(segment) { return true }
  let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
  guard labels.count >= 2, let last = labels.last.map(String.init) else { return false }
  if genericTLDs.contains(last) { return true }
  return !hasPosition && countryTLDs.contains(last)
}

private func looksLikePosixFilesystemPath(_ path: String) -> Bool {
  guard path.hasPrefix("/") else { return false }
  if posixRoots.contains(where: { path.hasPrefix($0) }) { return true }
  if positionSuffixAny.matches(path) { return true }
  let base = String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...])
  return extensionlessNames.contains(base) || fileExtension.matches(base)
}

/// Whether a decoded link destination is a file path rather than a route or prose. Only a
/// `:line` suffix the author wrote counts as evidence; a `#L` anchor never turns
/// `/chat/settings` into a file.
private func looksLikeFilePath(_ path: String, authored: String) -> Bool {
  if MarkdownPaths.isWindowsAbsolute(path) || relativePrefix.matches(path) { return true }
  if path.hasPrefix("/") { return looksLikePosixFilesystemPath(authored) }
  if extensionlessNames.contains(path) { return true }
  return relativeFilePath.matches(authored) || relativeFileName.matches(path)
}

private func hasExternalScheme(_ path: String) -> Bool {
  if MarkdownPaths.isWindowsAbsolute(path) { return false }
  guard let m = externalScheme.firstMatch(in: path) else { return false }
  let rest = m[2] ?? ""
  if rest.hasPrefix("//") { return true }
  return !positionOnly.matches(rest)
}

// MARK: - Public resolvers

extension MarkdownLink {
  /// Classifies a Markdown link destination. Returns nil for destinations the sanitizer
  /// would strip (script/data/unknown schemes); callers render the label as plain text.
  public static func resolve(destination: String, baseDirectory: String? = nil) -> MarkdownLink? {
    let href = MarkdownPaths.normalizeDestination(destination)
    guard !href.isEmpty else { return nil }
    if href.hasPrefix("#") { return href.count > 1 ? .anchor(String(href.dropFirst())) : nil }
    if let citation = MarkdownCitationParser.parse(href: href) { return .citation(citation) }
    if let ctx = MarkdownCitationParser.parseContext(href: href) { return .context(kind: ctx.kind, id: ctx.id) }
    if let target = fileTarget(href: href, baseDirectory: baseDirectory) { return .file(target) }
    return webURL(href).map { .web($0) }
  }

  static func webURL(_ href: String) -> URL? {
    var candidate = href
    if candidate.hasPrefix("//") { candidate = "https:" + candidate }
    guard let m = externalScheme.firstMatch(in: candidate), let scheme = m[1]?.lowercased() else { return nil }
    guard ["http", "https", "mailto", "xmpp", "irc", "ircs"].contains(scheme) else { return nil }
    return URL(string: candidate)
  }

  /// `parseMarkdownFileLink` + `resolveMarkdownFileLinkTarget`: nil when `href` is not a file.
  public static func fileTarget(href: String, baseDirectory: String? = nil) -> MarkdownFileTarget? {
    let normalized = MarkdownPaths.normalizeDestination(href)
    if normalized.isEmpty || normalized.hasPrefix("#") || normalized.hasPrefix("//") { return nil }
    let source: (path: String, hash: String) =
      (normalized.lowercased().hasPrefix("file:") ? MarkdownPaths.parseFileURL(normalized) : nil)
      ?? MarkdownPaths.splitSearchAndHash(normalized)
    // A percent-encoded drive colon (`/c%3A/`) only becomes strippable once decoded.
    let path = MarkdownPaths.stripSlashPrefixedDrive(
      MarkdownPaths.safeDecode(source.path.trimmingCharacters(in: .whitespacesAndNewlines)))
    let hash = MarkdownPaths.safeDecode(source.hash.trimmingCharacters(in: .whitespacesAndNewlines))
    if path.isEmpty || hasExternalScheme(path) { return nil }
    var position = MarkdownPaths.splitPosition(path, hash: hash)
    guard looksLikeFilePath(position.path, authored: path) else { return nil }
    // Relative paths are anchored when a base is known; `~/` is left for the UI (it knows
    // the home directory). Without a base the path stays as authored.
    if MarkdownPaths.isRelativePath(position.path), let base = baseDirectory, !base.isEmpty {
      position.path = MarkdownPaths.join(base: base, relative: position.path)
    }
    return position
  }

  /// Path-shaped inline code (`src/main.ts:12`) → file link. Inline code mostly holds
  /// identifiers and commands, so this demands stronger evidence than an explicit link:
  /// an unambiguous path prefix, a file extension, or a :line suffix.
  public static func inlineCodeFile(_ codeText: String, baseDirectory: String? = nil) -> MarkdownFileTarget? {
    guard let candidate = inlineCodeCandidate(codeText),
      let target = fileTarget(href: candidate, baseDirectory: baseDirectory)
    else { return nil }
    // Web parity: a relative path with nothing to resolve against is not a link.
    if MarkdownPaths.isRelativePath(target.path), baseDirectory?.isEmpty ?? true { return nil }
    return target
  }

  static func inlineCodeCandidate(_ codeText: String) -> String? {
    let trimmed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || inlineDisqualifier.matches(trimmed) { return nil }
    let candidate = MarkdownPaths.isWindowsAbsolute(trimmed) ? trimmed : trimmed.replacingOccurrences(of: "\\", with: "/")
    let hasPosition = positionSuffixAny.matches(candidate)
    if !hasPosition && !pathSeparator.matches(candidate) { return nil }
    let explicitShape = relativePrefix.matches(candidate) || candidate.hasPrefix("/") || MarkdownPaths.isWindowsAbsolute(candidate)
    if !explicitShape {
      var withoutPosition = candidate
      if let m = positionSuffixAny.firstMatch(in: candidate)?[0] { withoutPosition = String(candidate.dropLast(m.count)) }
      let first = withoutPosition.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? withoutPosition
      if looksLikeHostname(first, hasPosition: hasPosition) { return nil }
      var t = Substring(withoutPosition)
      while let l = t.last, l == "/" || l == "\\" { t = t.dropLast() }
      let base = t.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
      if !hasPosition && !fileExtension.matches(base) { return nil }
    }
    return candidate
  }
}

extension MarkdownImageSource {
  /// Port of `classifyMarkdownImageSource`.
  public static func classify(_ value: String?, workspaceRoot: String? = nil) -> MarkdownImageSource {
    guard let value else { return .blocked }
    let source = MarkdownPaths.normalizeDestination(value)
    if source.isEmpty || source.hasPrefix("#") || source.hasPrefix("?") { return .blocked }
    let lower = source.lowercased()
    if ["http:", "https:", "data:", "blob:", "//"].contains(where: { lower.hasPrefix($0) }) { return .direct(source) }
    if lower.hasPrefix("file:") {
      guard let target = MarkdownPaths.parseFileURL(source) else { return .blocked }
      return .workspaceFile(MarkdownPaths.stripSlashPrefixedDrive(MarkdownPaths.safeDecode(target.path)))
    }
    let path = MarkdownPaths.stripSlashPrefixedDrive(
      MarkdownPaths.safeDecode(MarkdownPaths.splitSearchAndHash(source).path))
    if path.isEmpty { return .blocked }
    if path.hasPrefix("/") || MarkdownPaths.isWindowsAbsolute(path) { return .workspaceFile(path) }
    if uriScheme.matches(path) || path.hasPrefix("~/") || path.hasPrefix("~\\") { return .blocked }
    guard let root = workspaceRoot, !root.isEmpty else { return .blocked }
    return .workspaceFile(MarkdownPaths.join(base: root, relative: path))
  }
}
