import Foundation

/// Parses `git diff` output (and plain `diff -u`) into files, hunks and numbered lines.
///
/// Hunk bodies are consumed by their header counts, so a content line that happens to read
/// `--- a/x` or `diff --git` can never be mistaken for a file boundary.
public enum UnifiedDiffParser {
  public static func parse(_ patch: String) -> [DiffFile] {
    var files: [DiffFile] = []
    var builder: Builder?
    func flush() {
      guard var finished = builder else { return }
      finished.id = "\(files.count):\(finished.path)"
      files.append(finished.file)
      builder = nil
    }

    let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if line.hasPrefix("diff --git ") {
        flush()
        var next = Builder()
        (next.oldPath, next.newPath) = gitHeaderPaths(line.dropFirst(11))
        builder = next
        i += 1
        continue
      }
      if line.hasPrefix("--- "), i + 1 < lines.count, lines[i + 1].hasPrefix("+++ ") {
        // A header without `diff --git` (plain unified diff), or the ---/+++ pair of a git header.
        if builder == nil || builder!.sawPathLines || !builder!.hunks.isEmpty || builder!.isBinary { flush(); builder = Builder() }
        builder!.sawPathLines = true
        builder!.setPath(old: filePath(line.dropFirst(4), prefix: "a/"), new: filePath(lines[i + 1].dropFirst(4), prefix: "b/"))
        i += 2
        continue
      }
      guard builder != nil else { i += 1; continue }
      if builder!.isBinary { i += 1; continue }  // `GIT binary patch` payload: skip to the next file
      if line.hasPrefix("@@ "), let header = HunkHeader(line) {
        i = consumeHunk(header, lines: lines, from: i + 1, into: &builder!, text: String(line))
        continue
      }
      builder!.applyHeader(line)
      i += 1
    }
    flush()
    return files
  }

  // MARK: Hunks

  private static func consumeHunk(_ header: HunkHeader, lines: [Substring], from start: Int, into b: inout Builder, text: String) -> Int {
    var oldLeft = header.oldCount, newLeft = header.newCount
    var oldNo = header.oldStart, newNo = header.newStart
    let first = b.lines.count
    var i = start
    while i < lines.count {
      let l = lines[i]
      if oldLeft <= 0 && newLeft <= 0 {
        if l.hasPrefix("\\") { b.append(marker: l); i += 1; continue }
        break
      }
      switch l.utf8.first {
      case 0x20:
        b.append(kind: .context, text: l.dropFirst(), old: oldNo, new: newNo)
        oldLeft -= 1; newLeft -= 1; oldNo += 1; newNo += 1
      case 0x2D:  // -
        b.append(kind: .deletion, text: l.dropFirst(), old: oldNo, new: 0)
        oldLeft -= 1; oldNo += 1
      case 0x2B:  // +
        b.append(kind: .addition, text: l.dropFirst(), old: 0, new: newNo)
        newLeft -= 1; newNo += 1
      case 0x5C:  // backslash
        b.append(marker: l)
      case nil:
        // An empty line inside a hunk is a context line whose space an editor stripped, except
        // for the empty fragment after the patch's final newline.
        if i == lines.count - 1 { i = lines.count; continue }
        b.append(kind: .context, text: "", old: oldNo, new: newNo)
        oldLeft -= 1; newLeft -= 1; oldNo += 1; newNo += 1
      default:
        // `diff --git` of the next file in a truncated hunk.
        b.hunks.append(DiffHunk(header: text, oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart, newCount: header.newCount, lines: first..<b.lines.count))
        b.pairLines(in: first..<b.lines.count)
        return i
      }
      i += 1
    }
    b.hunks.append(DiffHunk(header: text, oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart, newCount: header.newCount, lines: first..<b.lines.count))
    b.pairLines(in: first..<b.lines.count)
    return i
  }

  struct HunkHeader {
    var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1

    /// `@@ -12,3 +14,4 @@ context`; counts default to 1 when omitted.
    init?(_ line: Substring) {
      var scanner = Array(line.utf8)[...]
      func eat(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard scanner.starts(with: bytes) else { return false }
        scanner = scanner.dropFirst(bytes.count)
        return true
      }
      func number() -> Int? {
        var value = 0, digits = 0
        while let c = scanner.first, c >= 0x30, c <= 0x39 { value = value * 10 + Int(c - 0x30); scanner = scanner.dropFirst(); digits += 1 }
        return digits > 0 ? value : nil
      }
      guard eat("@@ -"), let os = number() else { return nil }
      oldStart = os
      if eat(","), let oc = number() { oldCount = oc }
      guard eat(" +"), let ns = number() else { return nil }
      newStart = ns
      if eat(","), let nc = number() { newCount = nc }
      guard eat(" @@") else { return nil }
    }
  }

  // MARK: Paths

  /// `a/x b/y`, quoted or not. Ambiguous when a path contains " b/": prefer the split where both halves agree.
  static func gitHeaderPaths(_ rest: Substring) -> (String?, String?) {
    if rest.hasPrefix("\"") {
      var cursor = rest.startIndex
      guard let first = readQuoted(rest, &cursor) else { return (nil, nil) }
      let remainder = rest[cursor...].drop { $0 == " " }
      let second = remainder.hasPrefix("\"") ? { () -> String? in var c = remainder.startIndex; return readQuoted(remainder, &c) }() : String(remainder)
      return (stripPrefix(first, "a/"), second.map { stripPrefix($0, "b/") })
    }
    let text = String(rest)
    guard text.hasPrefix("a/") else { return (nil, nil) }
    var firstSplit: (String, String)?
    var searchRange = text.startIndex..<text.endIndex
    while let hit = text.range(of: " b/", range: searchRange) {
      let old = String(text[text.index(text.startIndex, offsetBy: 2)..<hit.lowerBound])
      let new = String(text[hit.upperBound...])
      if old == new { return (old, new) }
      if firstSplit == nil { firstSplit = (old, new) }
      searchRange = hit.upperBound..<text.endIndex
    }
    return firstSplit.map { ($0.0, $0.1) } ?? (nil, nil)
  }

  /// A `---`/`+++` path: `/dev/null` is nil, a trailing tab-separated timestamp is cut, quotes decoded.
  static func filePath(_ raw: Substring, prefix: String) -> String? {
    var text = raw
    if text.hasPrefix("\"") {
      var cursor = text.startIndex
      guard let unquoted = readQuoted(text, &cursor) else { return nil }
      return unquoted == "/dev/null" ? nil : stripPrefix(unquoted, prefix)
    }
    if let tab = text.firstIndex(of: "\t") { text = text[..<tab] }
    let path = String(text)
    return path == "/dev/null" ? nil : stripPrefix(path, prefix)
  }

  private static func stripPrefix(_ path: String, _ prefix: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }

  /// A C-style quoted path from git (`"a/caf\303\251.txt"`).
  private static func readQuoted(_ text: Substring, _ cursor: inout Substring.Index) -> String? {
    guard text[cursor] == "\"" else { return nil }
    var bytes: [UInt8] = []
    var index = text.index(after: cursor)
    while index < text.endIndex {
      let c = text[index]
      if c == "\"" { cursor = text.index(after: index); return String(decoding: bytes, as: UTF8.self) }
      if c == "\\", text.index(after: index) < text.endIndex {
        index = text.index(after: index)
        let e = text[index]
        switch e {
        case "n": bytes.append(0x0A)
        case "t": bytes.append(0x09)
        case "r": bytes.append(0x0D)
        case "0"..."7":
          var value = Int(e.asciiValue! - 0x30)
          var taken = 1
          while taken < 3, text.index(after: index) < text.endIndex, let d = text[text.index(after: index)].asciiValue, d >= 0x30, d <= 0x37 {
            index = text.index(after: index); value = value * 8 + Int(d - 0x30); taken += 1
          }
          bytes.append(UInt8(truncatingIfNeeded: value))
        default: bytes.append(contentsOf: Array(String(e).utf8))
        }
      } else {
        bytes.append(contentsOf: Array(String(c).utf8))
      }
      index = text.index(after: index)
    }
    return nil
  }

  // MARK: Builder

  private struct Builder {
    var id = ""
    var oldPath: String?
    var newPath: String?
    var changeType: DiffChangeType = .modified
    var isBinary = false
    var oldMode: String?
    var newMode: String?
    var sawPathLines = false
    var hunks: [DiffHunk] = []
    var lines: [DiffLine] = []
    var additions = 0
    var deletions = 0
    var nextOrdinal = 0

    var path: String { newPath ?? oldPath ?? "" }

    var file: DiffFile {
      DiffFile(id: id, oldPath: oldPath, newPath: newPath, changeType: changeType, isBinary: isBinary, oldMode: oldMode, newMode: newMode, hunks: hunks, lines: lines, additions: additions, deletions: deletions)
    }

    mutating func setPath(old: String?, new: String?) {
      oldPath = old
      newPath = new
      if old == nil, changeType == .modified { changeType = .added }
      if new == nil, changeType == .modified { changeType = .deleted }
    }

    /// The extended header lines between `diff --git` and the first hunk.
    mutating func applyHeader(_ line: Substring) {
      if line.hasPrefix("new file mode ") { changeType = .added; newMode = String(line.dropFirst(14)) }
      else if line.hasPrefix("deleted file mode ") { changeType = .deleted; oldMode = String(line.dropFirst(18)) }
      else if line.hasPrefix("old mode ") { oldMode = String(line.dropFirst(9)) }
      else if line.hasPrefix("new mode ") { newMode = String(line.dropFirst(9)) }
      else if line.hasPrefix("rename from ") { changeType = .renamed; oldPath = unquote(line.dropFirst(12)) }
      else if line.hasPrefix("rename to ") { changeType = .renamed; newPath = unquote(line.dropFirst(10)) }
      else if line.hasPrefix("copy from ") { changeType = .copied; oldPath = unquote(line.dropFirst(10)) }
      else if line.hasPrefix("copy to ") { changeType = .copied; newPath = unquote(line.dropFirst(8)) }
      else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { isBinary = true }
    }

    private func unquote(_ text: Substring) -> String {
      var cursor = text.startIndex
      return text.hasPrefix("\"") ? (UnifiedDiffParser.readQuoted(text, &cursor) ?? String(text)) : String(text)
    }

    mutating func append(kind: DiffLine.Kind, text: Substring, old: Int, new: Int) {
      var text = text
      if text.last == "\r" { text = text.dropLast() }
      var tabs = 0
      for byte in text.utf8 where byte == 0x09 { tabs += 1 }
      lines.append(DiffLine(kind: kind, text: String(text), oldNumber: old, newNumber: new, ordinal: nextOrdinal, columns: text.utf16.count + tabs * 3, pair: -1))
      nextOrdinal += 1
      if kind == .addition { additions += 1 } else if kind == .deletion { deletions += 1 }
    }

    mutating func append(marker: Substring) {
      let text = "No newline at end of file"
      lines.append(DiffLine(kind: .noNewline, text: text, oldNumber: 0, newNumber: 0, ordinal: -1, columns: text.utf16.count, pair: -1))
    }

    /// Pairs the k-th deletion of a change block with its k-th addition, for word diffs.
    mutating func pairLines(in range: Range<Int>) {
      var i = range.lowerBound
      while i < range.upperBound {
        guard lines[i].kind == .deletion else { i += 1; continue }
        var deletions: [Int] = [], additions: [Int] = []
        while i < range.upperBound, lines[i].kind == .deletion || lines[i].kind == .noNewline { if lines[i].kind == .deletion { deletions.append(i) }; i += 1 }
        while i < range.upperBound, lines[i].kind == .addition || lines[i].kind == .noNewline { if lines[i].kind == .addition { additions.append(i) }; i += 1 }
        for (d, a) in zip(deletions, additions) { lines[d].pair = a; lines[a].pair = d }
      }
    }
  }
}
