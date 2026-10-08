import Foundation
import T3Contracts

/// `Date.parse` / `toISOString` semantics for the server's ISO-8601 strings. Sorting and
/// settle logic parse thousands of timestamps per update, so the common
/// `YYYY-MM-DDTHH:MM:SS[.fff]Z` shape is parsed by hand; anything else falls back to Foundation.
public enum IsoTimestamp {
  /// Milliseconds since the epoch, or nil when `string` is not a date (`Date.parse` -> NaN).
  public static func parse(_ string: String) -> Double? {
    if let fast = fastParse(string) { return fast }
    guard let date = IsoDateTime(string).date else { return nil }
    return (date.timeIntervalSince1970 * 1000).rounded(.down)
  }

  public static func parse(_ value: IsoDateTime) -> Double? { parse(value.rawValue) }

  /// `new Date(ms).toISOString()`.
  public static func format(milliseconds: Double) -> IsoDateTime {
    let whole = Int64(milliseconds.rounded(.down))
    let (days, msOfDay) = divmod(whole, 86_400_000)
    let (y, m, d) = civil(fromDays: days)
    let hour = msOfDay / 3_600_000
    let minute = msOfDay / 60_000 % 60
    let second = msOfDay / 1000 % 60
    let ms = msOfDay % 1000
    func pad(_ v: Int64, _ w: Int) -> String { String(repeating: "0", count: max(0, w - String(v).count)) + String(v) }
    return IsoDateTime("\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(ms, 3))Z")
  }

  // MARK: Internals

  private static func fastParse(_ string: String) -> Double? {
    var utf8 = string.utf8.makeIterator()
    func digits(_ count: Int) -> Int64? {
      var value: Int64 = 0
      for _ in 0..<count {
        guard let c = utf8.next(), c >= 48, c <= 57 else { return nil }
        value = value * 10 + Int64(c - 48)
      }
      return value
    }
    func expect(_ ch: Character) -> Bool { utf8.next() == ch.asciiValue }
    guard let y = digits(4), expect("-"), let mo = digits(2), expect("-"), let d = digits(2),
      expect("T"), let h = digits(2), expect(":"), let mi = digits(2), expect(":"), let s = digits(2),
      mo >= 1, mo <= 12, d >= 1, d <= 31, h < 24, mi < 60, s < 60
    else { return nil }
    var ms: Int64 = 0
    var next = utf8.next()
    if next == UInt8(ascii: ".") {
      var scale: Int64 = 100
      var any = false
      next = utf8.next()
      while let c = next, c >= 48, c <= 57 {
        ms += Int64(c - 48) * scale  // digits beyond milliseconds are truncated, like V8
        scale /= 10
        any = true
        next = utf8.next()
      }
      if !any { return nil }
    }
    guard next == UInt8(ascii: "Z"), utf8.next() == nil else { return nil }
    let days = daysFromCivil(y, mo, d)
    return Double(days * 86_400_000 + h * 3_600_000 + mi * 60_000 + s * 1000 + ms)
  }

  private static func divmod(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
    var q = a / b
    var r = a % b
    if r < 0 { r += b; q -= 1 }
    return (q, r)
  }

  /// Howard Hinnant's days-from-civil.
  private static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  private static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }
}

/// Orderings used by the reducers. JavaScript compares strings by UTF-16 code unit and
/// `localeCompare` is only used on ASCII identifiers here.
enum JS {
  /// `a < b` on strings (code-unit order).
  static func less(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
  /// `a.localeCompare(b)` restricted to the ASCII ids the server generates: ICU orders
  /// digits before letters and ignores case at the first level, which `caseInsensitiveCompare` mirrors.
  static func localeCompare(_ a: String, _ b: String) -> Int {
    switch a.compare(b, options: [.caseInsensitive, .literal], range: nil, locale: nil) {
    case .orderedAscending: return -1
    case .orderedDescending: return 1
    case .orderedSame:
      // Lowercase sorts before uppercase at ICU's tertiary level.
      if a == b { return 0 }
      return a.compare(b, options: [.literal]) == .orderedDescending ? -1 : 1
    }
  }
}
