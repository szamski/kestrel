import Foundation

/// JavaScript string semantics the composer relies on. Every offset in this module is a UTF-16
/// code-unit offset, exactly like `String.prototype.length` / `slice`, because the web composer
/// stores cursors and ranges that way and drafts must round-trip between clients.
enum JS {
  /// `\s` and `String.prototype.trim` agree on this set (WhiteSpace + LineTerminator).
  static func isSpace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
      true
    case 0x2000...0x200A: true
    default: false
    }
  }

  /// Regex class body equal to JS `\s`; ICU's own `\s` omits U+000B and U+FEFF.
  static let spaceClass = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
}

extension String {
  /// `String.length` in JavaScript.
  var jsLength: Int { utf16.count }

  /// `slice(start, end)` for non-negative arguments, clamped like JavaScript.
  func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
    let count = utf16.count
    let lower = Swift.max(0, Swift.min(start, count))
    let upper = Swift.max(lower, Swift.min(end ?? count, count))
    if lower == 0 && upper == count { return self }
    let from = utf16.index(utf16.startIndex, offsetBy: lower)
    let to = utf16.index(from, offsetBy: upper - lower)
    return String(utf16[from..<to]) ?? String(decoding: Array(utf16[from..<to]), as: UTF16.self)
  }

  /// `text[index]` as a code unit, or nil past either end.
  func jsUnit(at index: Int) -> UInt16? {
    guard index >= 0, index < utf16.count else { return nil }
    return utf16[utf16.index(utf16.startIndex, offsetBy: index)]
  }

  func jsTrim() -> String { jsTrimStart().jsTrimEnd() }

  func jsTrimStart() -> String {
    let units = Array(utf16)
    var start = 0
    while start < units.count, JS.isSpace(units[start]) { start += 1 }
    return start == 0 ? self : String(decoding: units[start...], as: UTF16.self)
  }

  func jsTrimEnd() -> String {
    let units = Array(utf16)
    var end = units.count
    while end > 0, JS.isSpace(units[end - 1]) { end -= 1 }
    return end == units.count ? self : String(decoding: units[..<end], as: UTF16.self)
  }

  /// `replace(/\s+/g, " ")`
  func jsCollapsingWhitespace() -> String {
    var out: [UInt16] = []
    var inRun = false
    for unit in utf16 {
      if JS.isSpace(unit) {
        if !inRun { out.append(0x20) }
        inRun = true
      } else {
        out.append(unit)
        inRun = false
      }
    }
    return String(decoding: out, as: UTF16.self)
  }

  /// `lastIndexOf(needle, fromIndex)` for a single code unit; -1 when absent.
  func jsLastIndex(of needle: UInt16, from: Int) -> Int {
    let units = Array(utf16)
    var index = Swift.min(from, units.count - 1)
    while index >= 0 {
      if units[index] == needle { return index }
      index -= 1
    }
    return -1
  }

  /// `indexOf(needle, fromIndex)` for a single code unit; -1 when absent.
  func jsIndex(of needle: UInt16, from: Int = 0) -> Int {
    let units = Array(utf16)
    var index = Swift.max(0, from)
    while index < units.count {
      if units[index] == needle { return index }
      index += 1
    }
    return -1
  }
}

/// A match of a `JSRegex`, with offsets in UTF-16 code units.
struct JSMatch {
  let range: Range<Int>
  /// Capture groups; `nil` where the group did not participate (JS `undefined`).
  let groups: [String?]
  let source: String

  var index: Int { range.lowerBound }
  var text: String { source.jsSlice(range.lowerBound, range.upperBound) }
  func group(_ number: Int) -> String? { number < groups.count ? groups[number] : nil }
}

/// Thin `NSRegularExpression` wrapper; patterns are written with the JS-vs-ICU differences
/// (`\s`, `$`, `.`) already spelled out by the caller.
struct JSRegex: @unchecked Sendable {
  private let regex: NSRegularExpression

  init(_ pattern: String, caseInsensitive: Bool = false) {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    // The patterns are compile-time constants; a failure is a programming error.
    regex = try! NSRegularExpression(pattern: pattern, options: options)
  }

  func matches(in text: String) -> [JSMatch] {
    let ns = text as NSString
    return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { result in
      var groups: [String?] = []
      for group in 0..<result.numberOfRanges {
        let range = result.range(at: group)
        groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
      }
      let full = result.range
      return JSMatch(range: full.location..<(full.location + full.length), groups: groups, source: text)
    }
  }

  func firstMatch(in text: String) -> JSMatch? {
    let ns = text as NSString
    guard let result = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
      return nil
    }
    var groups: [String?] = []
    for group in 0..<result.numberOfRanges {
      let range = result.range(at: group)
      groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
    }
    let full = result.range
    return JSMatch(range: full.location..<(full.location + full.length), groups: groups, source: text)
  }

  func test(_ text: String) -> Bool { firstMatch(in: text) != nil }
}
