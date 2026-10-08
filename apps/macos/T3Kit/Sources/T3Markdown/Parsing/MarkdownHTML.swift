import Foundation

enum HTMLEntities {
  private static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
    "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
    "rdquo": "”", "bull": "•", "middot": "·", "times": "×", "rarr": "→", "larr": "←", "uarr": "↑",
    "darr": "↓", "harr": "↔", "check": "✓", "deg": "°", "plusmn": "±", "laquo": "«", "raquo": "»",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "infin": "∞", "ne": "≠",
    "le": "≤", "ge": "≥",
  ]

  static func decode(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
        let name = String(s[s.index(after: i)..<semi])
        if let r = replacement(name) {
          out += r
          i = s.index(after: semi)
          continue
        }
      }
      out.append(c)
      i = s.index(after: i)
    }
    return out
  }

  private static func replacement(_ name: String) -> String? {
    if name.hasPrefix("#") {
      let digits = name.dropFirst()
      let value: UInt32?
      if digits.first == "x" || digits.first == "X" {
        value = UInt32(digits.dropFirst(), radix: 16)
      } else {
        value = UInt32(digits)
      }
      guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
      return String(Character(scalar))
    }
    return named[name]
  }
}

/// One lexical piece of an HTML fragment.
enum HTMLToken: Equatable {
  case text(String)
  case open(name: String, attributes: [String: String], selfClosing: Bool, raw: String)
  case close(name: String, raw: String)
  case comment
}

enum HTMLTokenizer {
  /// Tokenizes a fragment. Anything that does not form a well-formed tag stays text, so the
  /// caller can show it literally.
  static func tokenize(_ html: String) -> [HTMLToken] {
    var tokens: [HTMLToken] = []
    let chars = Array(html)
    var i = 0
    var text = ""
    func flush() {
      if !text.isEmpty {
        tokens.append(.text(text))
        text = ""
      }
    }
    while i < chars.count {
      let c = chars[i]
      guard c == "<" else {
        text.append(c)
        i += 1
        continue
      }
      if matches(chars, i, "<!--") {
        var j = i + 4
        while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
        if j + 2 < chars.count {
          flush()
          tokens.append(.comment)
          i = j + 3
          continue
        }
      }
      if let (token, end) = parseTag(chars, i) {
        flush()
        tokens.append(token)
        i = end
      } else {
        text.append(c)
        i += 1
      }
    }
    flush()
    return tokens
  }

  private static func matches(_ chars: [Character], _ at: Int, _ s: String) -> Bool {
    let lit = Array(s)
    return at + lit.count <= chars.count && Array(chars[at..<(at + lit.count)]) == lit
  }

  private static func parseTag(_ chars: [Character], _ start: Int) -> (HTMLToken, Int)? {
    var i = start + 1
    guard i < chars.count else { return nil }
    let closing = chars[i] == "/"
    if closing { i += 1 }
    let nameStart = i
    while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i].isNumber || chars[i] == "-" { i += 1 }
    guard i > nameStart, chars[nameStart].isLetter else { return nil }
    let name = String(chars[nameStart..<i]).lowercased()
    var attrs: [String: String] = [:]
    var selfClosing = false
    while true {
      while i < chars.count, chars[i].isWhitespace { i += 1 }
      guard i < chars.count else { return nil }
      if chars[i] == ">" {
        i += 1
        break
      }
      if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == ">" {
        selfClosing = true
        i += 2
        break
      }
      if closing { return nil }
      let keyStart = i
      while i < chars.count, !chars[i].isWhitespace, !"=/>\"'".contains(chars[i]) { i += 1 }
      guard i > keyStart else { return nil }
      let key = String(chars[keyStart..<i]).lowercased()
      while i < chars.count, chars[i].isWhitespace { i += 1 }
      if i < chars.count, chars[i] == "=" {
        i += 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count else { return nil }
        if chars[i] == "\"" || chars[i] == "'" {
          let q = chars[i]
          i += 1
          let vs = i
          while i < chars.count, chars[i] != q { i += 1 }
          guard i < chars.count else { return nil }
          attrs[key] = HTMLEntities.decode(String(chars[vs..<i]))
          i += 1
        } else {
          let vs = i
          while i < chars.count, !chars[i].isWhitespace, chars[i] != ">" { i += 1 }
          attrs[key] = HTMLEntities.decode(String(chars[vs..<i]))
        }
      } else {
        attrs[key] = ""
      }
    }
    let raw = String(chars[start..<i])
    return (closing ? .close(name: name, raw: raw) : .open(name: name, attributes: attrs, selfClosing: selfClosing, raw: raw), i)
  }
}

/// Converts HTML tokens into the render model using the sanitizer's tag allow-list
/// (hast-util-sanitize default schema, as used by ChatMarkdown). Tags outside the list
/// -- script, style, iframe, form controls, event-handler carriers -- are emitted as the
/// literal source text. Nothing here ever loads or executes anything; `img`/`a` only produce
/// typed model values the UI decides how to open.
struct HTMLInlineBuilder {
  let baseDirectory: String?

  private static let passthrough: Set<String> = [
    "span", "abbr", "bdo", "time", "ruby", "rt", "rp", "wbr", "cite", "dfn", "var", "i", "em", "b", "strong",
    "s", "strike", "del", "ins", "sub", "sup", "mark", "kbd", "tt", "samp", "code", "small", "q", "a", "details",
    "summary", "figure", "figcaption", "caption", "div", "p", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead",
    "tbody", "tfoot", "tr", "td", "th", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
  ]
  static let blockTags: Set<String> = [
    "div", "p", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr", "blockquote",
    "pre", "h1", "h2", "h3", "h4", "h5", "h6", "details", "summary", "figure", "figcaption", "caption", "hr",
  ]
  static func isAllowed(_ name: String) -> Bool {
    passthrough.contains(name) || name == "br" || name == "img" || name == "hr" || name == "input"
  }

  func style(for name: String) -> (([MarkdownInline]) -> MarkdownInline)? {
    switch name {
    case "b", "strong": return { .strong($0) }
    case "i", "em", "cite", "dfn", "var": return { .emphasis($0) }
    case "s", "strike", "del": return { .strikethrough($0) }
    case "ins": return { .styled(.underlined, $0) }
    case "sub": return { .styled(.subscripted, $0) }
    case "sup": return { .styled(.superscripted, $0) }
    case "mark": return { .styled(.highlighted, $0) }
    case "kbd": return { .styled(.keyboard, $0) }
    case "tt", "code", "samp": return { .styled(.monospace, $0) }
    case "small": return { .styled(.small, $0) }
    case "q": return { .styled(.quoted, $0) }
    default: return nil
    }
  }

  func image(_ attrs: [String: String]) -> MarkdownImage? {
    guard let src = attrs["src"] else { return nil }
    return MarkdownImage(
      source: MarkdownImageSource.classify(src, workspaceRoot: baseDirectory), destination: src,
      alt: attrs["alt"] ?? "", title: nil, width: attrs["width"].flatMap { Int($0) },
      height: attrs["height"].flatMap { Int($0) })
  }

  func link(_ attrs: [String: String]) -> MarkdownLink? {
    guard let href = attrs["href"], let link = MarkdownLink.resolve(destination: href, baseDirectory: baseDirectory)
    else { return nil }
    switch link {
    case .web, .file, .anchor: return link
    default: return nil
    }
  }

  static func alignment(_ attrs: [String: String]) -> MarkdownAlignment {
    switch attrs["align"]?.lowercased() {
    case "center": .center
    case "right": .right
    case "left": .left
    default: .natural
    }
  }
}
