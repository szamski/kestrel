import Foundation
import T3Contracts

// JavaScript semantics the TypeScript derivations rely on, kept in one place so the ports read
// like the source: `trim`, `\s`, `localeCompare`, `Date.parse`, UTF-16 `slice`, loose records.

// MARK: - Strings

private let jsWhitespace: Set<Unicode.Scalar> = {
  var set: Set<Unicode.Scalar> = [
    "\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0020}", "\u{00A0}", "\u{1680}",
    "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}",
  ]
  for value in 0x2000...0x200A { set.insert(Unicode.Scalar(UInt32(value))!) }
  return set
}()

func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool { jsWhitespace.contains(scalar) }

extension String {
  /// `String.prototype.trim`.
  var jsTrimmed: String {
    let scalars = unicodeScalars
    guard let start = scalars.firstIndex(where: { !isJSWhitespace($0) }) else { return "" }
    let end = scalars.lastIndex(where: { !isJSWhitespace($0) })!
    return String(scalars[start...end])
  }

  /// `value.replace(/\s+/g, " ").trim()`.
  var jsCollapsedWhitespace: String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in unicodeScalars {
      if isJSWhitespace(scalar) {
        pendingSpace = true
      } else {
        if pendingSpace { out.append(" ") }
        pendingSpace = false
        out.append(scalar)
      }
    }
    // A trailing run is dropped and a leading run is kept as one space until trimmed.
    return String(out).jsTrimmed
  }

  var utf16Length: Int { utf16.count }

  /// `value.slice(from, to)` over UTF-16 code units; a negative index counts from the end.
  func jsSlice(_ from: Int, _ to: Int? = nil) -> String {
    let units = Array(utf16)
    let count = units.count
    func clamp(_ index: Int) -> Int { index < 0 ? max(0, count + index) : min(index, count) }
    let lower = clamp(from)
    let upper = to.map(clamp) ?? count
    guard lower < upper else { return "" }
    return String(decoding: units[lower..<upper], as: UTF16.self)
  }

  var jsTrimmedEnd: String {
    let scalars = unicodeScalars
    guard let end = scalars.lastIndex(where: { !isJSWhitespace($0) }) else { return "" }
    return String(scalars[...end])
  }

  func jsCapitalizedFirst() -> String {
    guard let first = first else { return self }
    return first.uppercased() + dropFirst()
  }
}

/// ICU root collation order of the ASCII punctuation that appears in ids and timestamps.
private let punctuationRank: [Character: Int] = {
  let order = Array("_-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$")
  var ranks: [Character: Int] = [:]
  for (index, character) in order.enumerated() { ranks[character] = index }
  return ranks
}()

private func collationKey(_ scalar: Unicode.Scalar) -> (Int, UInt32) {
  let character = Character(scalar)
  if scalar.properties.isWhitespace { return (0, scalar.value) }
  if let rank = punctuationRank[character] { return (1, UInt32(rank)) }
  if ("0"..."9").contains(character) { return (2, scalar.value) }
  if scalar.isASCII, scalar.properties.isAlphabetic {
    return (3, Character(scalar).lowercased().unicodeScalars.first!.value)
  }
  return (4, scalar.value)
}

/// `a.localeCompare(b)` for the ids and ISO timestamps this module orders. ASCII follows the
/// ICU root collation (punctuation < digits < letters, case-insensitive first, lowercase first on
/// ties); anything else falls back to code point order.
func jsLocaleCompare(_ left: String, _ right: String) -> Int {
  if left == right { return 0 }
  // Fast path: after an identical prefix, a first difference between two characters of
  // [0-9a-z-] is decided by their primary weights, which follow byte order for that set. That
  // covers ISO timestamps (digits) and UUID-like ids.
  var leftIterator = left.utf8.makeIterator()
  var rightIterator = right.utf8.makeIterator()
  while true {
    switch (leftIterator.next(), rightIterator.next()) {
    case (let a?, let b?):
      if a == b { continue }
      if isPlainCollationByte(a) && isPlainCollationByte(b) { return a < b ? -1 : 1 }
    case (nil, _?): if left.utf8.count < right.utf8.count && right.hasPrefix(left) { return -1 }
    case (_?, nil): if right.utf8.count < left.utf8.count && left.hasPrefix(right) { return 1 }
    case (nil, nil): return 0
    }
    break
  }
  return jsLocaleCompareSlow(left, right)
}

@inline(__always)
private func isPlainCollationByte(_ byte: UInt8) -> Bool { (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || byte == 45 }

private func jsLocaleCompareSlow(_ left: String, _ right: String) -> Int {
  let l = Array(left.unicodeScalars)
  let r = Array(right.unicodeScalars)
  let shared = min(l.count, r.count)
  for index in 0..<shared {
    let a = collationKey(l[index])
    let b = collationKey(r[index])
    if a.0 != b.0 { return a.0 < b.0 ? -1 : 1 }
    if a.1 != b.1 { return a.1 < b.1 ? -1 : 1 }
  }
  if l.count != r.count { return l.count < r.count ? -1 : 1 }
  // Same primary sequence: lowercase sorts before uppercase.
  for index in 0..<shared where l[index] != r[index] {
    let aLower = l[index].properties.isLowercase
    return aLower ? -1 : 1
  }
  return 0
}

/// Default `Array.prototype.sort()` order for strings: UTF-16 code unit order.
func jsCodeUnitSorted(_ values: [String]) -> [String] {
  values.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}

extension Array {
  /// `toSorted` with a three-way comparator. JS sorts are stable; so is this.
  func stableSorted(by compare: (Element, Element) -> Int) -> [Element] {
    enumerated()
      .sorted { lhs, rhs in
        let result = compare(lhs.element, rhs.element)
        return result != 0 ? result < 0 : lhs.offset < rhs.offset
      }
      .map(\.element)
  }
}

// MARK: - Dates

/// `Date.parse` for the ISO-8601 strings the server writes, in milliseconds since the epoch.
/// Fractional digits beyond milliseconds are truncated like V8 does. nil when not parseable.
func jsDateParse(_ value: String) -> Double? {
  let bytes = Array(value.utf8)
  var index = 0
  func digits(_ count: Int) -> Int? {
    guard index + count <= bytes.count else { return nil }
    var result = 0
    for offset in 0..<count {
      let byte = bytes[index + offset]
      guard byte >= 48, byte <= 57 else { return nil }
      result = result * 10 + Int(byte - 48)
    }
    index += count
    return result
  }
  func expect(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }
  guard let year = digits(4), expect(45), let month = digits(2), expect(45), let day = digits(2) else { return nil }
  var hour = 0, minute = 0, second = 0, millisecond = 0
  var offsetMinutes = 0
  if index < bytes.count {
    guard expect(84) || expect(32), let h = digits(2), expect(58), let m = digits(2) else { return nil }
    hour = h
    minute = m
    if expect(58) {
      guard let s = digits(2) else { return nil }
      second = s
      if expect(46) || expect(44) {
        var scale = 100
        var any = false
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
          millisecond += Int(bytes[index] - 48) * scale
          scale /= 10
          index += 1
          any = true
        }
        guard any else { return nil }
      }
    }
    if index < bytes.count {
      if expect(90) {
        // Z
      } else if bytes[index] == 43 || bytes[index] == 45 {
        let sign = bytes[index] == 45 ? -1 : 1
        index += 1
        guard let oh = digits(2) else { return nil }
        _ = expect(58)
        guard let om = digits(2) else { return nil }
        offsetMinutes = sign * (oh * 60 + om)
      } else {
        return nil
      }
    }
  }
  guard index == bytes.count, (1...12).contains(month), (1...31).contains(day), hour <= 24, minute < 60, second < 60 else {
    return nil
  }
  // Days from civil (Howard Hinnant).
  let y = month <= 2 ? year - 1 : year
  let era = (y >= 0 ? y : y - 399) / 400
  let yoe = y - era * 400
  let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  let days = era * 146_097 + doe - 719_468
  let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetMinutes * 60
  return Double(seconds) * 1000 + Double(millisecond)
}

// MARK: - JSON records

typealias JSObject = [String: JSONValue]

extension JSONValue {
  /// session-logic `asRecord`: `typeof value === "object"` minus null, so arrays count (and
  /// have no named keys).
  var looseRecord: JSObject? {
    switch self {
    case .object(let object): object
    case .array: [:]
    default: nil
    }
  }

  /// presentation `asRecord`: plain objects only.
  var strictRecord: JSObject? {
    if case .object(let object) = self { return object }
    return nil
  }

  /// `asTrimmedString`: a string with content after `trim()`, trimmed.
  var trimmedString: String? {
    guard case .string(let value) = self else { return nil }
    let trimmed = value.jsTrimmed
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `asNumber`: finite numbers only.
  var finiteNumber: Double? {
    switch self {
    case .int(let value): Double(value)
    case .double(let value): value.isFinite ? value : nil
    default: nil
    }
  }

  var isNullish: Bool {
    if case .null = self { return true }
    return false
  }

  var stringOrNil: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var boolOrNil: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var arrayOrNil: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }
}

extension Optional where Wrapped == JSONValue {
  var looseRecord: JSObject? { self?.looseRecord }
  var strictRecord: JSObject? { self?.strictRecord }
  var trimmedString: String? { self?.trimmedString }
  var finiteNumber: Double? { self?.finiteNumber }
  var stringOrNil: String? { self?.stringOrNil }
  var arrayOrNil: [JSONValue]? { self?.arrayOrNil }
}

extension Optional where Wrapped == JSObject {
  subscript(key: String) -> JSONValue? { self?[key] }
}

/// `String(value)` for the few places the TypeScript coerces an unknown to text.
func jsString(_ value: JSONValue?) -> String {
  switch value {
  case nil: "undefined"
  case .null?: "null"
  case .bool(let flag)?: flag ? "true" : "false"
  case .int(let number)?: String(number)
  case .double(let number)?: number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
  case .string(let text)?: text
  case .array(let items)?: items.map { jsString($0) }.joined(separator: ",")
  case .object?: "[object Object]"
  }
}

/// `Number.prototype.toLocaleString()` in the en-US locale.
func jsLocaleNumber(_ value: Double) -> String {
  let formatter = NumberFormatter()
  formatter.locale = Locale(identifier: "en_US")
  formatter.numberStyle = .decimal
  formatter.usesGroupingSeparator = true
  formatter.maximumFractionDigits = 3
  return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

func jsLocaleNumber(_ value: Int) -> String { jsLocaleNumber(Double(value)) }

// MARK: - Regex helpers

/// Compiled regular expressions by pattern. Compiling dominates the cost of the small matches
/// the derivations run per activity, so every dynamic pattern goes through here.
final class RegexCache: @unchecked Sendable {
  static let shared = RegexCache()
  private var cache: [String: NSRegularExpression] = [:]
  private let lock = NSLock()

  func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
    let key = caseInsensitive ? "i:\(pattern)" : "s:\(pattern)"
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[key] { return cached }
    let compiled = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    cache[key] = compiled
    return compiled
  }
}

extension String {
  func matches(_ pattern: String, caseInsensitive: Bool = false) -> Bool {
    let regex = RegexCache.shared.regex(pattern, caseInsensitive: caseInsensitive)
    return regex.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) != nil
  }
}
