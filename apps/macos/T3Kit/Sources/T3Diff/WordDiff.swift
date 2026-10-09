import Foundation

/// Intra-line highlights: which runs of a deleted line and its paired added line really changed.
/// Ranges are UTF-16 offsets into each line's text.
public enum WordDiff {
  public struct Result: Sendable, Equatable {
    public var old: [Range<Int>]
    public var new: [Range<Int>]
  }

  /// Lines longer than this stay whole-line highlighted; the diff runs per visible row.
  static let maxLineLength = 1_000
  /// Above this token product the middle section is marked changed instead of diffed.
  static let maxCells = 40_000

  public static func changedRanges(old: String, new: String) -> Result {
    let a = Array(old.utf16), b = Array(new.utf16)
    guard !a.isEmpty, !b.isEmpty, a.count <= maxLineLength, b.count <= maxLineLength else { return Result(old: [], new: []) }
    let ta = tokens(a), tb = tokens(b)
    let ia = ids(ta, a), ib = ids(tb, b, shared: ia.table)

    var prefix = 0
    while prefix < ia.ids.count, prefix < ib.ids.count, ia.ids[prefix] == ib.ids[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < ia.ids.count - prefix, suffix < ib.ids.count - prefix, ia.ids[ia.ids.count - 1 - suffix] == ib.ids[ib.ids.count - 1 - suffix] { suffix += 1 }

    var keptA = Array(repeating: false, count: ta.count), keptB = Array(repeating: false, count: tb.count)
    for k in 0..<prefix { keptA[k] = true; keptB[k] = true }
    for k in 0..<suffix { keptA[ta.count - 1 - k] = true; keptB[tb.count - 1 - k] = true }

    let midA = Array(ia.ids[prefix..<(ia.ids.count - suffix)]), midB = Array(ib.ids[prefix..<(ib.ids.count - suffix)])
    if !midA.isEmpty, !midB.isEmpty, midA.count * midB.count <= maxCells {
      for (x, y) in lcs(midA, midB) { keptA[prefix + x] = true; keptB[prefix + y] = true }
    }

    // Lines with little in common read better as a plain whole-line change.
    let keptLength = zip(ta, keptA).reduce(0) { $0 + ($1.1 ? $1.0.count : 0) }
    if keptLength * 5 < max(a.count, b.count) * 2 { return Result(old: [], new: []) }
    return Result(old: ranges(ta, keptA, a), new: ranges(tb, keptB, b))
  }

  // MARK: Tokens

  private enum Class { case word, space, other }

  private static func classify(_ unit: UInt16) -> Class {
    switch unit {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: .word
    case 0x20, 0x09: .space
    case 0x80...: .word
    default: .other
    }
  }

  /// Word runs, whitespace runs and single punctuation marks.
  private static func tokens(_ units: [UInt16]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = 0
    while start < units.count {
      let kind = classify(units[start])
      var end = start + 1
      if kind != .other { while end < units.count, classify(units[end]) == kind { end += 1 } }
      out.append(start..<end)
      start = end
    }
    return out
  }

  private static func ids(_ tokens: [Range<Int>], _ units: [UInt16], shared: [[UInt16]: Int]? = nil) -> (ids: [Int], table: [[UInt16]: Int]) {
    var table = shared ?? [:]
    let ids = tokens.map { range -> Int in
      let key = Array(units[range])
      if let id = table[key] { return id }
      let id = table.count
      table[key] = id
      return id
    }
    return (ids, table)
  }

  private static func lcs(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
    let n = a.count, m = b.count
    var table = Array(repeating: Array(repeating: UInt16(0), count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    var pairs: [(Int, Int)] = []
    var i = 0, j = 0
    while i < n, j < m {
      if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 } else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
    }
    return pairs
  }

  /// Changed tokens as runs; a lone space between two changed tokens joins them.
  private static func ranges(_ tokens: [Range<Int>], _ kept: [Bool], _ units: [UInt16]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var index = 0
    while index < tokens.count {
      if kept[index] { index += 1; continue }
      var end = index
      while end + 1 < tokens.count {
        if !kept[end + 1] { end += 1; continue }
        let isSpace = tokens[end + 1].count == 1 && classify(units[tokens[end + 1].lowerBound]) == .space
        if isSpace, end + 2 < tokens.count, !kept[end + 2] { end += 2; continue }
        break
      }
      out.append(tokens[index].lowerBound..<tokens[end].upperBound)
      index = end + 1
    }
    return out
  }
}
