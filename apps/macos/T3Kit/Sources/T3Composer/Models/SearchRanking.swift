import Foundation

/// Port of `packages/shared/src/searchRanking.ts`: tiered match scoring (lower is better).
public enum SearchRanking {
  public struct Ranked<T> {
    public var item: T
    public var score: Int
    public var tieBreaker: String
  }

  /// Trimmed and lowercased; `trimLeading` strips a leading run of matching scalars first.
  public static func normalizeQuery(_ input: String, trimLeading: ((Unicode.Scalar) -> Bool)? = nil) -> String {
    let trimmed = input.jsTrim()
    if trimmed.isEmpty { return "" }
    guard let trimLeading else { return trimmed.lowercased() }
    var scalars = Array(trimmed.unicodeScalars)
    var drop = 0
    while drop < scalars.count, trimLeading(scalars[drop]) { drop += 1 }
    scalars.removeFirst(drop)
    return String(String.UnicodeScalarView(scalars)).lowercased()
  }

  public static func subsequenceScore(_ value: String, _ query: String) -> Int? {
    if query.isEmpty { return 0 }
    let v = Array(value.utf16)
    let q = Array(query.utf16)
    var queryIndex = 0
    var first = -1
    var previous = -1
    var gap = 0
    for valueIndex in 0..<v.count where v[valueIndex] == q[queryIndex] {
      if first == -1 { first = valueIndex }
      if previous != -1 { gap += valueIndex - previous - 1 }
      previous = valueIndex
      queryIndex += 1
      if queryIndex == q.count {
        let span = valueIndex - first + 1 - q.count
        let length = min(64, v.count - q.count)
        return first * 2 + gap * 3 + span + length
      }
    }
    return nil
  }

  private static func lengthPenalty(_ value: String, _ query: String) -> Int {
    min(64, max(0, value.jsLength - query.jsLength))
  }

  private static func indexOf(_ needle: String, in value: String) -> Int {
    let v = Array(value.utf16)
    let n = Array(needle.utf16)
    guard !n.isEmpty, v.count >= n.count else { return n.isEmpty ? 0 : -1 }
    var index = 0
    while index + n.count <= v.count {
      if Array(v[index..<(index + n.count)]) == n { return index }
      index += 1
    }
    return -1
  }

  private static func boundaryMatchIndex(_ value: String, _ query: String, markers: [String]) -> Int? {
    var best: Int?
    for marker in markers {
      let index = indexOf("\(marker)\(query)", in: value)
      if index == -1 { continue }
      let match = index + marker.jsLength
      if best == nil || match < best! { best = match }
    }
    return best
  }

  /// Both `value` and `query` must already be normalized.
  public static func queryScore(
    value: String, query: String, exactBase: Int, prefixBase: Int? = nil, boundaryBase: Int? = nil, includesBase: Int? = nil,
    fuzzyBase: Int? = nil, boundaryMarkers: [String] = [" ", "-", "_", "/"]
  ) -> Int? {
    if value.isEmpty || query.isEmpty { return nil }
    if value == query { return exactBase }
    if let prefixBase, value.hasPrefix(query) { return prefixBase + lengthPenalty(value, query) }
    if let boundaryBase, let index = boundaryMatchIndex(value, query, markers: boundaryMarkers) {
      return boundaryBase + index * 2 + lengthPenalty(value, query)
    }
    if let includesBase {
      let index = indexOf(query, in: value)
      if index != -1 { return includesBase + index * 2 + lengthPenalty(value, query) }
    }
    if let fuzzyBase, let fuzzy = subsequenceScore(value, query) { return fuzzyBase + fuzzy }
    return nil
  }

  /// `String.prototype.localeCompare` with the default (root) collation.
  public static func localeCompare(_ left: String, _ right: String) -> Int {
    switch left.compare(right, options: [], range: nil, locale: Locale(identifier: "en")) {
    case .orderedAscending: -1
    case .orderedSame: 0
    case .orderedDescending: 1
    }
  }

  /// Insert keeping score then tie-breaker order, bounded by `limit`.
  public static func insert<T>(_ entries: inout [Ranked<T>], _ candidate: Ranked<T>, limit: Int = Int.max) {
    if limit <= 0 { return }
    func compare(_ l: Ranked<T>, _ r: Ranked<T>) -> Int {
      l.score != r.score ? l.score - r.score : localeCompare(l.tieBreaker, r.tieBreaker)
    }
    var low = 0
    var high = entries.count
    while low < high {
      let middle = low + (high - low) / 2
      if compare(candidate, entries[middle]) < 0 { high = middle } else { low = middle + 1 }
    }
    if entries.count < limit {
      entries.insert(candidate, at: low)
      return
    }
    if low >= limit { return }
    entries.insert(candidate, at: low)
    entries.removeLast()
  }
}
