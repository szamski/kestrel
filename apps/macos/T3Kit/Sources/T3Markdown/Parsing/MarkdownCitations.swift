import Foundation

// `t3-citation://v1/…` and `t3-context://v1/…` hrefs. Ports of
// packages/shared/src/assistantCitations.ts and composerContextReferences.ts.
enum MarkdownCitationParser {
  private static let citationPrefix = "t3-citation://v1/"
  private static let contextPrefix = "t3-context://v1/"
  // Percent encoding needs up to nine characters per UTF-16 unit; 16k covers selectors.
  private static let maxTextLength = 8_000
  private static let maxCommentLength = 8_000
  private static let maxContextLength = 32
  private static let maxHrefLength = 9 * (maxTextLength + maxCommentLength) + 16_000
  private static let kindPattern = Rx(#"^[a-z][a-z0-9-]{0,39}$"#)
  private static let idPattern = Rx(#"^[a-z0-9_-]{1,128}$"#, .caseInsensitive)
  private static let digits = Rx(#"^\d{1,16}$"#)

  static func parse(href: String) -> MarkdownCitation? {
    guard href.hasPrefix(citationPrefix), href.utf16.count <= maxHrefLength else { return nil }
    guard let c = URLComponents(string: href), c.scheme == "t3-citation", c.host == "v1",
      c.user == nil, c.password == nil, c.port == nil, c.fragment == nil
    else { return nil }
    // `percentEncodedPath` keeps `%2F` inside an id distinguishable from a separator.
    let parts = c.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    // URLSearchParams form-encodes: `+` is a space, everything else is percent-escaped.
    let items = (c.percentEncodedQueryItems ?? []).map { item in
      URLQueryItem(
        name: item.name,
        value: item.value.map {
          let spaced = $0.replacingOccurrences(of: "+", with: " ")
          return spaced.removingPercentEncoding ?? spaced
        })
    }
    let required = ["text", "start", "end", "prefix", "suffix"]
    let comment = items.filter { $0.name == "comment" }
    guard comment.count <= 1,
      items.count == required.count + comment.count,
      required.allSatisfy({ key in items.filter { $0.name == key }.count == 1 })
    else { return nil }
    func value(_ k: String) -> String { items.first { $0.name == k }?.value ?? "" }
    guard digits.matches(value("start")), digits.matches(value("end")),
      let start = Int(value("start")), let end = Int(value("end")), end > start
    else { return nil }
    let text = value("text")
    let prefix = value("prefix")
    let suffix = value("suffix")
    let commentText = comment.first?.value ?? nil
    guard !text.isEmpty, text.utf16.count <= maxTextLength,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      prefix.utf16.count <= maxContextLength, suffix.utf16.count <= maxContextLength,
      (commentText?.utf16.count ?? 0) <= maxCommentLength
    else { return nil }
    let ids = parts.map { String($0).removingPercentEncoding ?? String($0) }
    guard ids.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 512 }) else { return nil }
    return MarkdownCitation(
      environmentId: ids[0], threadId: ids[1], messageId: ids[2], text: text, comment: commentText,
      start: start, end: end, prefix: prefix, suffix: suffix)
  }

  static func parseContext(href: String) -> (kind: String, id: String)? {
    guard href.hasPrefix(contextPrefix) else { return nil }
    let parts = href.dropFirst(contextPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let kind = String(parts[0])
    let id = String(parts[1])
    guard kindPattern.matches(kind), idPattern.matches(id) else { return nil }
    return (kind, id)
  }
}
