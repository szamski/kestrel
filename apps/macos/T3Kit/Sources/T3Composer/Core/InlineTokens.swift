import Foundation

/// Port of `packages/shared/src/composerInlineTokens.ts`: `@file` mentions (canonical file links
/// and quoted `@"path"` text) and `$skill` tokens inside prose.
public struct ComposerInlineToken: Sendable, Hashable {
  public enum Kind: String, Sendable { case mention, skill }
  public var kind: Kind
  public var value: String
  public var source: String
  public var start: Int
  public var end: Int
}

public enum ComposerInlineTokens {
  private static let s = JS.spaceClass
  // A skill name may start with a digit, but compact amounts such as "$20", "$20k", "$100M" and
  // "$1e6" must stay prose: the composer chips any matched `$name` token, known or not.
  private static let skillToken = JSRegex(
    "(^|[\(s)])\\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:[\(s)]|\\z))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=[\(s)])"
  )
  private static let mentionToken = JSRegex(
    "(^|[\(s)])@(?:\"((?:\\\\[^\\n\\r\\u2028\\u2029]|[^\"\\\\])*)\"|([^\(s)@\"]+))(?=[\(s)])"
  )
  // The label body is bounded: unbounded, every whitespace is a candidate start and the scan is
  // quadratic on input like " [[[[[…".
  private static let maxFileLinkLabelLength = 512
  private static let fileLinkToken = JSRegex(
    "(^|[\(s)])\\[((?:\\\\[^\\n\\r\\u2028\\u2029]|[^\\]\\\\]){0,\(maxFileLinkLabelLength)})\\]\\(([^\\)\(s)]+)\\)(?=[\(s)])"
  )
  private static let uriScheme = JSRegex("^[A-Za-z][A-Za-z0-9+.-]*:")
  private static let windowsDrivePath = JSRegex("^[A-Za-z]:[\\\\/]")
  // Autocomplete emits canonical file links, so ambiguous bare @scope/package text stays a package.
  private static let scopedPackage = JSRegex(
    "^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*(?:/[^\(s)@\"]+)*\\z"
  )

  /// `replace(/\\(.)/g, "$1")`
  static func unescapeBackslashes(_ text: String) -> String {
    let units = Array(text.utf16)
    var out: [UInt16] = []
    var index = 0
    while index < units.count {
      if units[index] == 0x5C, index + 1 < units.count, !isLineTerminator(units[index + 1]) {
        out.append(units[index + 1])
        index += 2
      } else {
        out.append(units[index])
        index += 1
      }
    }
    return String(decoding: out, as: UTF16.self)
  }

  private static func isLineTerminator(_ unit: UInt16) -> Bool {
    unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
  }

  private static func basename(_ path: String) -> String {
    let slash = path.jsLastIndex(of: 0x2F, from: path.jsLength)
    let back = path.jsLastIndex(of: 0x5C, from: path.jsLength)
    let separator = max(slash, back)
    return separator >= 0 ? path.jsSlice(separator + 1) : path
  }

  private static func collectMentionTokens(_ text: String) -> [ComposerInlineToken] {
    var matches: [ComposerInlineToken] = []
    for match in fileLinkToken.matches(in: text) {
      let prefix = match.group(1) ?? ""
      let label = unescapeBackslashes(match.group(2) ?? "")
      let encodedPath = match.group(3) ?? ""
      // Preserve malformed source rather than dropping a user-authored token.
      let path = URICodec.decodeComponent(encodedPath) ?? encodedPath
      let hasExternalScheme = uriScheme.test(path) && !windowsDrivePath.test(path)
      if path.isEmpty || hasExternalScheme || label != basename(path) { continue }
      let start = match.index + prefix.jsLength
      let end = match.range.upperBound
      matches.append(ComposerInlineToken(kind: .mention, value: path, source: text.jsSlice(start, end), start: start, end: end))
    }
    for match in mentionToken.matches(in: text) {
      let prefix = match.group(1) ?? ""
      let quoted = match.group(2)
      let path = quoted.map(unescapeBackslashes) ?? (match.group(3) ?? "")
      if path.isEmpty || (quoted == nil && scopedPackage.test(path)) { continue }
      let start = match.index + prefix.jsLength
      let end = match.range.upperBound
      matches.append(ComposerInlineToken(kind: .mention, value: path, source: text.jsSlice(start, end), start: start, end: end))
    }
    return matches
  }

  public static func collect(_ text: String, preserveTrailingFrom: [ComposerInlineToken] = []) -> [ComposerInlineToken] {
    var matches = collectMentionTokens(text)
    for match in skillToken.matches(in: text) {
      let prefix = match.group(1) ?? ""
      let value = match.group(2) ?? ""
      if value.isEmpty { continue }
      let start = match.index + prefix.jsLength
      let end = match.range.upperBound
      matches.append(ComposerInlineToken(kind: .skill, value: value, source: text.jsSlice(start, end), start: start, end: end))
    }
    let length = text.jsLength
    for token in preserveTrailingFrom
    where token.end == length && text.jsSlice(token.start, token.end) == token.source
      && !matches.contains(where: { $0.kind == token.kind && $0.start == token.start && $0.end == token.end })
    {
      matches.append(token)
    }
    return matches.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
  }
}
