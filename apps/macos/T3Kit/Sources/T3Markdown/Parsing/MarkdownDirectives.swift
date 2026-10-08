import Foundation

/// Codex emits two directives that CommonMark cannot see: `:codex-file-citation{…}` (text)
/// and `::artifact-template{…}` (leaf). The web parses them with a micromark extension; the
/// native renderer rewrites them before cmark runs, the same adapter strategy as
/// `renderCodexFileCitationsAsMarkdown`: a citation becomes an ordinary file link and a
/// template becomes a sentinel paragraph the block converter swaps for a result card.
/// Directives inside fences, code spans, escapes and link labels stay literal text.
struct MarkdownDirectivePreprocessor {
  struct Output {
    var source: String
    var templates: [MarkdownArtifactTemplate]
  }

  /// Private-use sentinels survive cmark as plain text.
  static let sentinelOpen = "\u{E000}t3-artifact:"
  static let sentinelClose = "\u{E001}"

  static func process(_ source: String) -> Output {
    // Cheap exit: the vast majority of messages contain neither directive.
    guard source.contains(":codex-file-citation") || source.contains("::artifact-template") else {
      return Output(source: source, templates: [])
    }
    var templates: [MarkdownArtifactTemplate] = []
    var rewritten: [String] = []
    var fence: (char: Character, length: Int)?
    var previousBlank = true
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      defer { previousBlank = line.allSatisfy { $0 == " " || $0 == "\t" } }
      let indent = line.prefix(while: { $0 == " " }).count
      let stripped = line.dropFirst(indent)
      if let open = fence {
        if indent <= 3, let run = fenceRun(stripped), run.char == open.char, run.length >= open.length,
          stripped.dropFirst(run.length).allSatisfy({ $0 == " " || $0 == "\t" })
        {
          fence = nil
        }
        rewritten.append(String(line))
        continue
      }
      if indent <= 3, let run = fenceRun(stripped) {
        fence = run
        rewritten.append(String(line))
        continue
      }
      let indentedCode = (indent >= 4 || line.first == "\t") && previousBlank
      if indentedCode {
        rewritten.append(String(line))
        continue
      }
      if indent <= 3, stripped.hasPrefix("::artifact-template"),
        let attrs = parseDirective(String(stripped.dropFirst(2)), name: "artifact-template", requireEnd: true),
        let template = MarkdownArtifactTemplate(attributes: attrs)
      {
        templates.append(template)
        // Blank lines make the card its own paragraph even when it follows text.
        rewritten.append("")
        rewritten.append("\(sentinelOpen)\(templates.count - 1)\(sentinelClose)")
        rewritten.append("")
        continue
      }
      rewritten.append(line.contains(":codex-file-citation") ? rewriteCitations(String(line)) : String(line))
    }
    return Output(source: rewritten.joined(separator: "\n"), templates: templates)
  }

  private static func fenceRun(_ s: Substring) -> (char: Character, length: Int)? {
    guard let c = s.first, c == "`" || c == "~" else { return nil }
    let n = s.prefix(while: { $0 == c }).count
    guard n >= 3 else { return nil }
    // A backtick fence's info string cannot contain a backtick (else it is inline code).
    if c == "`", s.dropFirst(n).contains("`") { return nil }
    return (c, n)
  }

  // MARK: citations

  private static func rewriteCitations(_ line: String) -> String {
    let chars = Array(line)
    var result = ""
    var i = 0
    var bracketDepth = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\\" {  // escapes keep the next character literal
        result.append(c)
        if i + 1 < chars.count { result.append(chars[i + 1]) }
        i += 2
        continue
      }
      if c == "`" {  // code span: copy through the matching run
        let run = chars[i...].prefix(while: { $0 == "`" }).count
        var j = i + run
        var closed: Int?
        while j < chars.count {
          if chars[j] == "`" {
            let r = chars[j...].prefix(while: { $0 == "`" }).count
            if r == run {
              closed = j + r
              break
            }
            j += r
          } else {
            j += 1
          }
        }
        let end = closed ?? (i + run)
        result.append(contentsOf: chars[i..<end])
        i = end
        continue
      }
      if c == "[" { bracketDepth += 1 }
      if c == "]" { bracketDepth = max(0, bracketDepth - 1) }
      if c == ":", i == 0 || chars[i - 1] != ":", matches(chars, i, ":codex-file-citation") {
        let rest = String(chars[i...])
        if let (attrs, consumed) = parseDirectivePrefix(rest, name: "codex-file-citation"),
          let link = citationMarkdown(attrs)
        {
          // Inside a link label the directive would nest links: leave it literal.
          let after = String(chars[(i + consumed)...])
          let insideLabel = bracketDepth > 0 && after.contains("](")
          if !insideLabel {
            result += link
            i += consumed
            continue
          }
        }
      }
      result.append(c)
      i += 1
    }
    return result
  }

  private static func matches(_ chars: [Character], _ at: Int, _ literal: String) -> Bool {
    let lit = Array(literal)
    guard at + lit.count <= chars.count, Array(chars[at..<(at + lit.count)]) == lit else { return false }
    // The name must end: `:codex-file-citation-extra{…}` is not ours.
    let next = at + lit.count
    guard next < chars.count else { return false }
    let n = chars[next]
    return n == "{" || n.isWhitespace || (n.isPunctuation && n != "-" && n != "_")
  }

  private static func citationMarkdown(_ attrs: [String: String]) -> String? {
    guard let raw = attrs["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    let line = attrs["line_range_start"].flatMap { v -> Int? in
      let t = v.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty, let n = Int(t), n > 0 else { return nil }
      return n
    }
    var normalized = raw.replacingOccurrences(of: "\\", with: "/")
    while normalized.hasSuffix("/") { normalized.removeLast() }
    let label0 = normalized.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? normalized
    let label = label0.isEmpty ? (normalized.isEmpty ? "File" : normalized) : label0
    var dest = raw.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23")
      .replacingOccurrences(of: "?", with: "%3F")
    if let line { dest += "#L\(line)" }
    dest = dest.replacingOccurrences(of: "\\", with: "%5C").replacingOccurrences(of: "<", with: "%3C")
      .replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\r", with: "%0D")
      .replacingOccurrences(of: "\n", with: "%0A")
    var escaped = ""
    for ch in label {
      if "\\[]*_`<&".contains(ch) { escaped.append("\\") }
      escaped.append(ch)
    }
    return "[\(escaped)](<\(dest)>)"
  }

  // MARK: attribute parsing

  /// `::name{…}` / `:name{…}` text starting at the leading colons. Returns attributes only
  /// when the whole directive is well formed (and, for leaf directives, ends the line).
  private static func parseDirective(_ s: String, name: String, requireEnd: Bool) -> [String: String]? {
    guard s.hasPrefix(name) else { return nil }
    let rest = String(s.dropFirst(name.count))
    guard rest.hasPrefix("{"), let (attrs, consumed) = parseAttributes(rest) else { return nil }
    let tail = rest.dropFirst(consumed)
    if requireEnd, !tail.allSatisfy({ $0 == " " || $0 == "\t" }) { return nil }
    return attrs
  }

  private static func parseDirectivePrefix(_ s: String, name: String) -> ([String: String], Int)? {
    let prefix = ":" + name
    guard s.hasPrefix(prefix) else { return nil }
    let rest = String(s.dropFirst(prefix.count))
    guard rest.hasPrefix("{"), let (attrs, consumed) = parseAttributes(rest) else { return nil }
    return (attrs, prefix.count + consumed)
  }

  /// Parses `{a="b" c=d e}`; returns attributes and the number of characters consumed.
  private static func parseAttributes(_ s: String) -> ([String: String], Int)? {
    let chars = Array(s)
    guard chars.first == "{" else { return nil }
    var i = 1
    var attrs: [String: String] = [:]
    func skipSpace() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
    while true {
      skipSpace()
      guard i < chars.count else { return nil }
      if chars[i] == "}" { return (attrs, i + 1) }
      // `.class` / `#id` shorthands are legal directive syntax; they carry nothing for us.
      if chars[i] == "." || chars[i] == "#" {
        i += 1
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "}" { i += 1 }
        continue
      }
      let nameStart = i
      guard chars[i].isLetter || chars[i] == "_" || chars[i] == ":" else { return nil }
      while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_.:-".contains(chars[i]) { i += 1 }
      let key = String(chars[nameStart..<i])
      skipSpace()
      guard i < chars.count, chars[i] == "=" else {
        attrs[key] = ""  // bare attribute
        continue
      }
      i += 1
      skipSpace()
      guard i < chars.count else { return nil }
      var value = ""
      if chars[i] == "\"" || chars[i] == "'" {
        let quote = chars[i]
        i += 1
        let start = i
        while i < chars.count, chars[i] != quote { i += 1 }
        guard i < chars.count else { return nil }
        value = String(chars[start..<i])
        i += 1
      } else {
        let start = i
        while i < chars.count, !chars[i].isWhitespace, !"\"'=<>`}".contains(chars[i]) { i += 1 }
        guard i > start else { return nil }
        value = String(chars[start..<i])
      }
      attrs[key] = HTMLEntities.decode(value)
    }
  }
}
