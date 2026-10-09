import Foundation

/// What a "Comment" on selected diff lines carries into the composer chip. Port of the partial-diff
/// path of `apps/web/src/reviewCommentContext.ts` (a patch never has the file's expanded context, so
/// row indexes count the hunk lines only). The app turns it into a `review-comment` context record.
public struct ReviewCommentDraft: Sendable, Equatable {
  public var id: String
  public var sectionId: String
  public var sectionTitle: String
  public var filePath: String
  public var startIndex: Int
  public var endIndex: Int
  public var rangeLabel: String
  public var text: String
  public var diff: String
  public var fenceLanguage: String

  public init(
    id: String, sectionId: String, sectionTitle: String, filePath: String, startIndex: Int, endIndex: Int, rangeLabel: String, text: String,
    diff: String, fenceLanguage: String
  ) {
    self.id = id
    self.sectionId = sectionId
    self.sectionTitle = sectionTitle
    self.filePath = filePath
    self.startIndex = startIndex
    self.endIndex = endIndex
    self.rangeLabel = rangeLabel
    self.text = text
    self.diff = diff
    self.fenceLanguage = fenceLanguage
  }
}

public enum ReviewComment {
  /// `lo...hi` are indices into `file.lines` (a selection's ends); markers are skipped.
  public static func build(id: String, sectionId: String, sectionTitle: String, file: DiffFile, lo: Int, hi: Int, text: String) -> ReviewCommentDraft? {
    guard lo >= 0, hi < file.lines.count, lo <= hi else { return nil }
    let selected = file.lines[lo...hi].filter { $0.kind != .noNewline }
    guard let first = selected.first, let last = selected.last else { return nil }

    let withOld = selected.filter { $0.kind != .addition }
    let withNew = selected.filter { $0.kind != .deletion }
    let header = "@@ -\(withOld.first?.oldNumber ?? 0),\(withOld.count) +\(withNew.first?.newNumber ?? 0),\(withNew.count) @@"
    let body = selected.map { marker($0.kind) + $0.text }

    return ReviewCommentDraft(
      id: id, sectionId: sectionId, sectionTitle: sectionTitle, filePath: file.path,
      startIndex: first.ordinal, endIndex: last.ordinal, rangeLabel: rangeLabel(selected),
      text: text.trimmingCharacters(in: .whitespacesAndNewlines), diff: ([header] + body).joined(separator: "\n"), fenceLanguage: "diff")
  }

  /// The selection a stored comment covers, from its persisted row indexes.
  public static func lineRange(in file: DiffFile, startIndex: Int, endIndex: Int) -> ClosedRange<Int>? {
    guard startIndex <= endIndex else { return nil }
    var lo: Int?, hi: Int?
    for (index, line) in file.lines.enumerated() where line.kind != .noNewline {
      if line.ordinal == startIndex { lo = index }
      if line.ordinal == endIndex { hi = index; break }
    }
    guard let lo, let hi else { return nil }
    return lo...hi
  }

  private static func marker(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .addition: "+"
    case .deletion: "-"
    default: " "
    }
  }

  private static func rangeLabel(_ lines: [DiffLine]) -> String {
    guard let first = lines.first, let last = lines.last else { return "line" }
    func number(_ line: DiffLine) -> Int { line.newNumber > 0 ? line.newNumber : line.oldNumber }
    let sign = lines.allSatisfy { $0.kind == first.kind } ? marker(first.kind).trimmingCharacters(in: .whitespaces) : ""
    let a = number(first), b = number(last)
    return a == b ? "\(sign)\(a)" : "\(sign)\(a) to \(sign)\(b)"
  }
}
