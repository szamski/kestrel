import Foundation

// Port of apps/web/src/terminal-links.ts: the same URL/path rules, so a line links the same way on
// every client. Offsets are UTF-16 units (NSRange) like the JS original.

public enum TerminalLinkKind: Sendable, Hashable { case url, path }

public struct TerminalLinkMatch: Sendable, Hashable {
  public let kind: TerminalLinkKind
  public let text: String
  public let start: Int
  public let end: Int
}

/// One physical terminal row. `translateToString(trimRight:)` mirrors xterm's buffer line API.
public protocol TerminalBufferLine {
  var isWrapped: Bool { get }
  func translateToString(trimRight: Bool) -> String
}

public struct WrappedTerminalLinkLineSegment: Sendable, Hashable {
  public let bufferLineNumber: Int
  public let text: String
  public let startIndex: Int
  public let endIndex: Int
}

public struct WrappedTerminalLinkLine: Sendable, Hashable {
  public let text: String
  public let segments: [WrappedTerminalLinkLineSegment]
}

public enum TerminalLinks {
  private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'`<>]+"#, options: [.caseInsensitive])
  private static let filePathPattern = try! NSRegularExpression(
    pattern: #"(?:~/|\.{1,2}/|/|[A-Za-z]:[\\/]|\\\\)[^\s"'`<>]+|[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+(?::\d+){0,2}"#)
  private static let trailingPunctuation = try! NSRegularExpression(pattern: #"[.,;!?]+$"#)
  // Paths also drop a trailing colon: compilers end `file:line:col:` with one.
  private static let trailingPathPunctuation = try! NSRegularExpression(pattern: #"[.,;:!?]+$"#)
  private static let urlScheme = try! NSRegularExpression(pattern: #"^https?://"#, options: [.caseInsensitive])
  private static let positionSuffix = try! NSRegularExpression(pattern: #":(\d+)(?::(\d+))?$"#)

  private static func trimClosingDelimiters(_ value: String, kind: TerminalLinkKind) -> String {
    let punctuation = kind == .path ? trailingPathPunctuation : trailingPunctuation
    var output = punctuation.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
    if output.isEmpty { return output }
    func trimUnbalanced(_ open: Character, _ close: Character) {
      while output.last == close {
        let opens = output.filter { $0 == open }.count
        let closes = output.filter { $0 == close }.count
        if opens >= closes { return }
        output.removeLast()
      }
    }
    trimUnbalanced("(", ")")
    trimUnbalanced("[", "]")
    trimUnbalanced("{", "}")
    return output
  }

  private static func collect(_ line: String, kind: TerminalLinkKind, pattern: NSRegularExpression, existing: [TerminalLinkMatch]) -> [TerminalLinkMatch] {
    var matches: [TerminalLinkMatch] = []
    let nsLine = line as NSString
    for raw in pattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
      guard raw.range.length > 0 else { continue }
      let trimmed = trimClosingDelimiters(nsLine.substring(with: raw.range), kind: kind)
      if trimmed.isEmpty { continue }
      if kind == .path && isURL(trimmed) { continue }
      let candidate = TerminalLinkMatch(kind: kind, text: trimmed, start: raw.range.location, end: raw.range.location + (trimmed as NSString).length)
      if (existing + matches).contains(where: { candidate.start < $0.end && $0.start < candidate.end }) { continue }
      matches.append(candidate)
    }
    return matches
  }

  public static func extract(from line: String) -> [TerminalLinkMatch] {
    let urls = collect(line, kind: .url, pattern: urlPattern, existing: [])
    let paths = collect(line, kind: .path, pattern: filePathPattern, existing: urls)
    return (urls + paths).sorted { $0.start < $1.start }
  }

  public static func isURL(_ value: String) -> Bool {
    urlScheme.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }

  /// The match covering a UTF-16 offset in `line`, if any.
  public static func link(in line: String, atUTF16Offset offset: Int) -> TerminalLinkMatch? {
    extract(from: line).first { offset >= $0.start && offset < $0.end }
  }

  /// Rebuilds the logical line a physical row belongs to by following soft wraps both ways.
  /// `bufferLineNumber` is 1-based like xterm; `line(index)` is 0-based.
  public static func collectWrappedLine(
    bufferLineNumber: Int, line: (Int) -> (any TerminalBufferLine)?
  ) -> WrappedTerminalLinkLine? {
    guard var startLine = line(bufferLineNumber - 1) else { return nil }
    var startNumber = bufferLineNumber
    while startNumber > 1 && startLine.isWrapped {
      guard let previous = line(startNumber - 2) else { return nil }
      startNumber -= 1
      startLine = previous
    }
    var segments: [WrappedTerminalLinkLineSegment] = []
    var nextStart = 0
    var current = startNumber
    while let currentLine = line(current - 1) {
      let continues = line(current)?.isWrapped == true
      let text = currentLine.translateToString(trimRight: !continues)
      let length = (text as NSString).length
      segments.append(.init(bufferLineNumber: current, text: text, startIndex: nextStart, endIndex: nextStart + length))
      nextStart += length
      if !continues { break }
      current += 1
    }
    return WrappedTerminalLinkLine(text: segments.map(\.text).joined(), segments: segments)
  }

  /// ⌘-click on macOS (⌃ elsewhere); a plain click selects.
  public static func isActivation(command: Bool, control: Bool) -> Bool { command && !control }

  // MARK: Path targets

  private static func isWindowsAbsolute(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || value.hasPrefix(#"\\"#)
  }

  public static func isAbsolutePath(_ value: String) -> Bool { value.hasPrefix("/") || isWindowsAbsolute(value) }

  private static func isWindowsStyle(_ value: String) -> Bool {
    isWindowsAbsolute(value) || value.range(of: #"[A-Za-z]:\\"#, options: .regularExpression) != nil
  }

  private static func join(_ base: String, _ next: String, windows: Bool) -> String {
    let cleanBase = base.replacingOccurrences(of: #"[\\/]+$"#, with: "", options: .regularExpression)
    if windows { return cleanBase + "\\" + next.replacingOccurrences(of: "/", with: "\\") }
    return cleanBase + "/" + next.replacingOccurrences(of: #"^/+"#, with: "", options: .regularExpression)
  }

  private static func inferHome(fromCwd cwd: String) -> String? {
    for pattern in [#"^/Users/[^/]+"#, #"^/home/[^/]+"#, #"^[A-Za-z]:\\Users\\[^\\]+"#] {
      if let range = cwd.range(of: pattern, options: .regularExpression) { return String(cwd[range]) }
    }
    return nil
  }

  /// `path[:line[:column]]` split as markdownLinks.ts `splitFilePathPosition`.
  static func splitPosition(_ path: String) -> (path: String, line: Int?, column: Int?) {
    let ns = path as NSString
    guard let match = positionSuffix.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
      let lineValue = Int(ns.substring(with: match.range(at: 1)))
    else { return (path, nil, nil) }
    let column = match.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 2)))
    return (ns.substring(to: match.range.location), lineValue > 0 ? lineValue : nil, column.flatMap { $0 > 0 ? $0 : nil })
  }

  static func formatPosition(path: String, line: Int?, column: Int?) -> String {
    guard let line else { return path }
    return "\(path):\(line)" + (column.map { ":\($0)" } ?? "")
  }

  /// Absolute target for a path link, keeping its `:line:column`; relative paths resolve against `cwd`.
  public static func resolvePathTarget(_ rawPath: String, cwd: String) -> String {
    let position = splitPosition(rawPath)
    var resolved = position.path
    if resolved.hasPrefix("~/") {
      if let home = inferHome(fromCwd: cwd) { resolved = join(home, String(resolved.dropFirst(2)), windows: isWindowsStyle(home)) }
    } else if !isAbsolutePath(resolved) {
      resolved = join(cwd, resolved, windows: isWindowsStyle(cwd))
    }
    return formatPosition(path: resolved, line: position.line, column: position.column)
  }
}
