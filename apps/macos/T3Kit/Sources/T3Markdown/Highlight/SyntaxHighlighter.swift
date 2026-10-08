import Foundation
import JavaScriptCore

/// Semantic token roles. Themes colour roles, never highlight.js class names, so switching
/// light/dark never re-highlights.
public enum SyntaxRole: UInt8, CaseIterable, Hashable, Sendable {
  case plain, keyword, string, comment, number, type, function, variable, property, attribute, op, punctuation, meta,
    tag, builtin, literal, symbol, addition, deletion, heading
}

/// A coloured run in the source, in UTF-16 offsets (what NSAttributedString uses).
public struct HighlightSpan: Hashable, Sendable {
  public var location: Int
  public var length: Int
  public var role: SyntaxRole
}

public struct HighlightedCode: Sendable {
  public var spans: [HighlightSpan]
  /// Language highlight.js resolved, nil when the block is left plain.
  public var language: String?
}

/// Syntax highlighting with highlight.js running in JavaScriptCore.
///
/// Why this and not tree-sitter: the agents emit dozens of languages, and highlight.js ships
/// every language this client needs in one 125 KB bundle with no grammar packages, no C
/// build step and no query files to vendor per language. Output is token classes, which map
/// onto `SyntaxRole`. The cost is regex-based accuracy rather than a real parse, which is
/// the right trade for chat snippets.
///
/// All JavaScript runs on one private serial queue (never the main thread). Results are
/// cached by content hash + language, theme-independent, so a streaming message never
/// re-highlights a block whose text did not change.
public final class SyntaxHighlighter: @unchecked Sendable {
  public static let shared = SyntaxHighlighter()

  /// Blocks beyond this size render plain: highlight.js is regex based and an enormous paste
  /// would hold the highlight queue for seconds.
  public static let maxHighlightedUTF16 = 200_000

  private let queue = DispatchQueue(label: "t3.markdown.highlight", qos: .userInitiated)
  private var hljs: JSValue?  // queue-confined
  private var loadFailed = false  // queue-confined
  private let cache = NSCache<NSString, CacheBox>()
  private let counterLock = NSLock()
  private var _highlightCalls = 0

  private final class CacheBox {
    let value: HighlightedCode
    init(_ v: HighlightedCode) { value = v }
  }

  public init() {
    cache.countLimit = 512
    cache.totalCostLimit = 48 * 1024 * 1024
  }

  /// Number of times highlight.js actually ran (cache hits excluded). For tests.
  public var highlightCalls: Int {
    counterLock.lock()
    defer { counterLock.unlock() }
    return _highlightCalls
  }

  // MARK: API

  /// Cache lookup only; never runs JavaScript. Safe on the main thread.
  public func cached(code: String, language: String?) -> HighlightedCode? {
    guard let lang = Self.canonicalLanguage(language) else { return HighlightedCode(spans: [], language: nil) }
    return cache.object(forKey: Self.key(code, lang))?.value
  }

  /// Blocking highlight. Call off the main thread (the async variant does).
  public func highlight(code: String, language: String?) -> HighlightedCode {
    guard let lang = Self.canonicalLanguage(language), code.utf16.count <= Self.maxHighlightedUTF16 else {
      return HighlightedCode(spans: [], language: nil)
    }
    let key = Self.key(code, lang)
    if let hit = cache.object(forKey: key) { return hit.value }
    let result = queue.sync { self.run(code: code, language: lang) }
    cache.setObject(CacheBox(result), forKey: key, cost: result.spans.count * 24 + 64)
    return result
  }

  public func highlightAsync(code: String, language: String?) async -> HighlightedCode {
    if let hit = cached(code: code, language: language) { return hit }
    return await withCheckedContinuation { (continuation: CheckedContinuation<HighlightedCode, Never>) in
      queue.async {
        guard let lang = Self.canonicalLanguage(language), code.utf16.count <= Self.maxHighlightedUTF16 else {
          continuation.resume(returning: HighlightedCode(spans: [], language: nil))
          return
        }
        let key = Self.key(code, lang)
        if let hit = self.cache.object(forKey: key) {
          continuation.resume(returning: hit.value)
          return
        }
        let result = self.run(code: code, language: lang)
        self.cache.setObject(CacheBox(result), forKey: key, cost: result.spans.count * 24 + 64)
        continuation.resume(returning: result)
      }
    }
  }

  /// Loads the JS engine in the background so the first real block does not pay for it.
  public func warmUp() {
    queue.async { _ = self.engine() }
  }

  // MARK: engine (queue-confined)

  private func engine() -> JSValue? {
    if let hljs { return hljs }
    if loadFailed { return nil }
    guard let context = JSContext() else {
      loadFailed = true
      return nil
    }
    context.evaluateScript(HighlightJSSource.source)
    guard let value = context.objectForKeyedSubscript("hljs"), !value.isUndefined else {
      loadFailed = true
      return nil
    }
    hljs = value
    return value
  }

  private func run(code: String, language: String) -> HighlightedCode {
    guard let hljs = engine() else { return HighlightedCode(spans: [], language: nil) }
    counterLock.lock()
    _highlightCalls += 1
    counterLock.unlock()
    let options: [String: Any] = ["language": language, "ignoreIllegals": true]
    guard let result = hljs.invokeMethod("highlight", withArguments: [code, options]),
      let html = result.objectForKeyedSubscript("value")?.toString(), !result.isUndefined
    else { return HighlightedCode(spans: [], language: nil) }
    return HighlightedCode(spans: HighlightHTML.spans(from: html), language: language)
  }

  /// Test hook: does the embedded bundle know `name` (its own alias table)?
  func bundleKnows(_ name: String) -> Bool {
    queue.sync { engine()?.invokeMethod("getLanguage", withArguments: [name])?.isUndefined == false }
  }

  // MARK: language names

  /// hljs resolves its own aliases (ts, tsx, js, jsx, sh, zsh, yml, toml→ini, html→xml, md, kt,
  /// rb, rs, py, golang, c++, objc, patch, jsonc…); this maps the extras agents write.
  private static let extraAliases: [String: String] = [
    "gitignore": "ini", "env": "ini", "dotenv": "ini", "conf": "ini", "cfg": "ini", "properties": "ini",
    "vue": "xml", "svelte": "xml", "svg": "xml", "xhtml": "xml", "plist": "xml", "xsl": "xml", "jsonl": "json",
    "json5": "json", "console": "shell", "shellsession": "shell", "terminal": "shell", "fish": "bash",
    "mdx": "markdown", "swiftinterface": "swift", "mts": "typescript", "cts": "typescript", "kts": "kotlin",
    "cs": "csharp", "gql": "graphql",
  ]
  private static let plainNames: Set<String> = ["", "text", "txt", "plaintext", "plain", "none", "output", "log", "logs"]

  /// nil: leave plain. A name outside the bundle falls through to plain too: highlight.js
  /// throws for unknown languages and we never auto-detect (misdetection is worse than none).
  static func canonicalLanguage(_ name: String?) -> String? {
    guard var n = name?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
    if n.hasPrefix("language-") { n.removeFirst(9) }
    if plainNames.contains(n) { return nil }
    let resolved = extraAliases[n] ?? n
    return supported.contains(resolved) ? resolved : nil
  }

  /// Every name and alias the bundle knows (static list, verified by a test against hljs).
  static let supported: Set<String> = [
    "bash", "sh", "zsh", "c", "h", "cpp", "cc", "c++", "h++", "hpp", "hh", "hxx", "cxx", "csharp", "cs", "c#", "css",
    "diff", "patch", "go", "golang", "graphql", "gql", "ini", "toml", "java", "jsp", "javascript", "js", "jsx", "mjs",
    "cjs", "json", "jsonc", "kotlin", "kt", "kts", "less", "lua", "makefile", "mk", "mak", "make", "markdown", "md",
    "mkdown", "mkd", "objectivec", "mm", "objc", "obj-c", "obj-c++", "objective-c++", "perl", "pl", "pm", "php",
    "php-template", "python", "py", "gyp", "ipython", "python-repl", "pycon", "r", "ruby", "rb", "gemspec", "podspec",
    "thor", "irb", "rust", "rs", "scss", "shell", "console", "shellsession", "sql", "swift", "typescript", "ts", "tsx",
    "mts", "cts", "vbnet", "vb", "wasm", "xml", "html", "xhtml", "rss", "atom", "xjb", "xsd", "xsl", "plist", "wsf",
    "svg", "yaml", "yml",
  ]

  private static func key(_ code: String, _ language: String) -> NSString {
    let h = FNV.hash(code.utf8)
    return "\(language):\(code.utf16.count):\(String(h, radix: 36))" as NSString
  }
}

/// Parses highlight.js HTML (`<span class="hljs-keyword">…</span>` with entity-escaped text)
/// into role spans over the *decoded* text, in UTF-16 offsets.
enum HighlightHTML {
  static func spans(from html: String) -> [HighlightSpan] {
    var spans: [HighlightSpan] = []
    var stack: [SyntaxRole] = []
    var offset = 0
    var runStart = 0
    var runRole = SyntaxRole.plain

    func emit(upTo end: Int) {
      if runRole != .plain, end > runStart {
        // Merge with the previous span when contiguous and equal.
        if let last = spans.last, last.role == runRole, last.location + last.length == runStart {
          spans[spans.count - 1].length += end - runStart
        } else {
          spans.append(HighlightSpan(location: runStart, length: end - runStart, role: runRole))
        }
      }
    }
    func setRole(_ role: SyntaxRole) {
      if role != runRole {
        emit(upTo: offset)
        runStart = offset
        runRole = role
      }
    }

    let u = Array(html.utf16)
    var i = 0
    let lt: UInt16 = 0x3C, gt: UInt16 = 0x3E, amp: UInt16 = 0x26, semi: UInt16 = 0x3B, slash: UInt16 = 0x2F
    while i < u.count {
      let c = u[i]
      if c == lt {
        var j = i + 1
        while j < u.count, u[j] != gt { j += 1 }
        if i + 1 < u.count, u[i + 1] == slash {
          if !stack.isEmpty { stack.removeLast() }
        } else {
          let tag = String(decoding: u[(i + 1)..<min(j, u.count)], as: UTF16.self)
          stack.append(role(forTag: tag, inherited: stack.last ?? .plain))
        }
        setRole(stack.last ?? .plain)
        i = j + 1
      } else if c == amp, let end = (i + 1..<min(i + 10, u.count)).first(where: { u[$0] == semi }) {
        let name = String(decoding: u[(i + 1)..<end], as: UTF16.self)
        let decoded: String? =
          switch name {
          case "amp": "&"
          case "lt": "<"
          case "gt": ">"
          case "quot": "\""
          case "#x27", "#39": "'"
          default: nil
          }
        if let decoded {
          offset += decoded.utf16.count
          i = end + 1
        } else {
          offset += 1
          i += 1
        }
      } else {
        offset += 1
        i += 1
      }
    }
    emit(upTo: offset)
    return spans
  }

  /// `<span class="hljs-title function_">` → role. Unknown classes inherit the parent so a
  /// wrapper span never erases the colour of what it wraps.
  static func role(forTag tag: String, inherited: SyntaxRole) -> SyntaxRole {
    guard let range = tag.range(of: "class=\"") else { return inherited }
    let rest = tag[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return inherited }
    let classes = rest[..<end].split(separator: " ").map(String.init)
    guard let primary = classes.first(where: { $0.hasPrefix("hljs-") })?.dropFirst(5) else { return inherited }
    switch primary {
    case "keyword": return .keyword
    case "built_in", "builtin-name": return .builtin
    case "type": return .type
    case "literal": return .literal
    case "number": return .number
    case "string", "regexp", "char", "code", "link": return .string
    case "comment", "doctag", "quote": return .comment
    case "meta": return .meta
    case "title":
      if classes.contains("function_") { return .function }
      if classes.contains("class_") { return .type }
      return .function
    case "attr", "property": return .property
    case "attribute", "selector-attr": return .attribute
    case "variable", "template-variable", "selector-id": return .variable
    case "symbol", "bullet", "selector-pseudo": return .symbol
    case "operator": return .op
    case "punctuation": return .punctuation
    case "tag", "name", "selector-class": return .tag
    case "addition": return .addition
    case "deletion": return .deletion
    case "section": return .heading
    case "subst", "params": return .plain
    default: return inherited
    }
  }
}
