import Foundation

public enum DiffChangeType: String, Sendable {
  case modified, added, deleted, renamed, copied
}

/// One line of a hunk. Numbers are 1-based; 0 means "not on that side".
public struct DiffLine: Sendable {
  public enum Kind: UInt8, Sendable { case context, addition, deletion, noNewline }

  public var kind: Kind
  public var text: String
  public var oldNumber: Int
  public var newNumber: Int
  /// Position among the file's content lines (markers excluded), the index review comments persist.
  public var ordinal: Int
  /// Width in monospace columns (a tab counts as 4).
  public var columns: Int
  /// Index in `DiffFile.lines` of the line this one is word-diffed against, -1 when none.
  public var pair: Int
}

public struct DiffHunk: Sendable {
  /// The `@@ -a,b +c,d @@ context` line as written.
  public var header: String
  public var oldStart: Int
  public var oldCount: Int
  public var newStart: Int
  public var newCount: Int
  /// Range in `DiffFile.lines`.
  public var lines: Range<Int>
}

public struct DiffFile: Sendable, Identifiable {
  public var id: String
  public var oldPath: String?
  public var newPath: String?
  public var changeType: DiffChangeType
  public var isBinary: Bool
  public var oldMode: String?
  public var newMode: String?
  public var hunks: [DiffHunk]
  public var lines: [DiffLine]
  public var additions: Int
  public var deletions: Int

  /// The path to show: the new one, or the old one for a deletion.
  public var path: String { newPath ?? oldPath ?? "" }
  public var fileName: String { (path as NSString).lastPathComponent }
  public var directory: String {
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? "" : dir + "/"
  }
  public var modeChange: (old: String, new: String)? {
    if let oldMode, let newMode, oldMode != newMode { return (oldMode, newMode) }
    return nil
  }
}
