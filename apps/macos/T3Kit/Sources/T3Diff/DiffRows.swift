import Foundation

public enum DiffLayoutMode: String, Sendable, Codable, CaseIterable {
  case stacked, split
}

/// One display row. The table renders from these without touching the parsed lines again.
public struct DiffRow: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case fileHeader
    case hunk(Int)
    /// Stacked layout: an index into `DiffFile.lines`.
    case line(Int)
    /// Split layout: left and right indices into `DiffFile.lines`, -1 for an empty side.
    case pair(Int, Int)
    case notice(String)
  }

  public var file: Int
  public var kind: Kind
}

/// Lines `lo...hi` (indices into `DiffFile.lines`) of one file.
public struct DiffSelection: Sendable, Equatable {
  public var fileId: String
  public var lo: Int
  public var hi: Int

  public init(fileId: String, lo: Int, hi: Int) {
    self.fileId = fileId
    self.lo = lo
    self.hi = hi
  }

  public func contains(file id: String, line: Int) -> Bool { id == fileId && line >= lo && line <= hi }
}

public enum DiffRows {
  /// `annotations` are inline notes (a pull request's review threads): file id, then index in `DiffFile.lines`, then one
  /// notice row per text, shown right under that line.
  public static func build(files: [DiffFile], collapsed: Set<String>, layout: DiffLayoutMode, annotations: [String: [Int: [String]]] = [:]) -> [DiffRow] {
    var rows: [DiffRow] = []
    rows.reserveCapacity(files.reduce(files.count) { $0 + $1.lines.count + $1.hunks.count })
    for (index, file) in files.enumerated() {
      rows.append(DiffRow(file: index, kind: .fileHeader))
      if collapsed.contains(file.id) { continue }
      if file.hunks.isEmpty {
        rows.append(DiffRow(file: index, kind: .notice(notice(for: file))))
        continue
      }
      for (hunkIndex, hunk) in file.hunks.enumerated() {
        rows.append(DiffRow(file: index, kind: .hunk(hunkIndex)))
        let notes = annotations[file.id] ?? [:]
        switch layout {
        case .stacked:
          for line in hunk.lines {
            rows.append(DiffRow(file: index, kind: .line(line)))
            for text in notes[line] ?? [] { rows.append(DiffRow(file: index, kind: .notice(text))) }
          }
        case .split:
          let before = rows.count
          appendSplit(file, hunk, index, &rows)
          if !notes.isEmpty { weaveNotes(notes, file: index, from: before, into: &rows) }
        }
      }
    }
    return rows
  }

  /// Split rows hold two line indices; the notes of both go under their row.
  private static func weaveNotes(_ notes: [Int: [String]], file: Int, from start: Int, into rows: inout [DiffRow]) {
    var woven = Array(rows[..<start])
    for row in rows[start...] {
      woven.append(row)
      guard case .pair(let left, let right) = row.kind else { continue }
      for index in [left, right] where index >= 0 {
        for text in notes[index] ?? [] { woven.append(DiffRow(file: file, kind: .notice(text))) }
      }
    }
    rows = woven
  }

  static func notice(for file: DiffFile) -> String {
    if file.isBinary { return "Binary file not shown" }
    if let mode = file.modeChange { return "Mode changed \(mode.old) \u{2192} \(mode.new)" }
    switch file.changeType {
    case .renamed: return "Renamed without changes"
    case .copied: return "Copied without changes"
    case .added: return "Empty file"
    case .deleted: return "File deleted"
    case .modified: return "No textual changes"
    }
  }

  /// Context lines on both sides; a block of deletions beside the additions that replace it.
  private static func appendSplit(_ file: DiffFile, _ hunk: DiffHunk, _ index: Int, _ rows: inout [DiffRow]) {
    var i = hunk.lines.lowerBound
    let end = hunk.lines.upperBound
    func kind(_ at: Int) -> DiffLine.Kind? { at < end ? file.lines[at].kind : nil }
    while i < end {
      switch file.lines[i].kind {
      case .context:
        rows.append(DiffRow(file: index, kind: .pair(i, i)))
        i += 1
        if kind(i) == .noNewline { rows.append(DiffRow(file: index, kind: .pair(-1, i))); i += 1 }
      case .noNewline:
        rows.append(DiffRow(file: index, kind: .pair(-1, i)))
        i += 1
      case .deletion, .addition:
        var deletions: [Int] = [], additions: [Int] = []
        var deletionMarker = -1, additionMarker = -1
        while kind(i) == .deletion {
          deletions.append(i); i += 1
          if kind(i) == .noNewline { deletionMarker = i; i += 1 }
        }
        while kind(i) == .addition {
          additions.append(i); i += 1
          if kind(i) == .noNewline { additionMarker = i; i += 1 }
        }
        for k in 0..<max(deletions.count, additions.count) {
          rows.append(DiffRow(file: index, kind: .pair(k < deletions.count ? deletions[k] : -1, k < additions.count ? additions[k] : -1)))
        }
        if deletionMarker >= 0 || additionMarker >= 0 { rows.append(DiffRow(file: index, kind: .pair(deletionMarker, additionMarker))) }
      }
    }
  }
}
