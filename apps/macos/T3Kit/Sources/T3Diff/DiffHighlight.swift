import Foundation
import T3Markdown

/// Syntax colouring for a file's diff lines, from the same highlight.js engine as chat code blocks.
///
/// ponytail: each side is highlighted as the concatenation of its hunk lines, so a multi-line
/// construct that starts outside every hunk (an open block comment) may colour as code. Highlighting
/// the full file needs `review.getDiffFileContents`; add when that matters.
/// A coloured run inside one diff line, in UTF-16 offsets from the line's start.
public struct DiffSpan: Sendable, Hashable {
  public var location: Int
  public var length: Int
  public var role: SyntaxRole
}

public enum DiffHighlighter {
  public static func language(forPath path: String) -> String? {
    let name = (path as NSString).lastPathComponent.lowercased()
    if name == "makefile" { return "makefile" }
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? nil : ext
  }

  /// Spans per `file.lines` index, relative to the line's own start. Empty when the language is unknown.
  @concurrent
  public static func spans(for file: DiffFile) async -> [[DiffSpan]] {
    guard let language = language(forPath: file.path), !file.lines.isEmpty else { return [] }
    var result = Array(repeating: [DiffSpan](), count: file.lines.count)
    for side in [Side.old, .new] {
      let members = file.lines.indices.filter { side.includes(file.lines[$0].kind) }
      guard !members.isEmpty else { continue }
      var starts: [Int] = [], lengths: [Int] = []
      var offset = 0
      var parts: [String] = []
      for index in members {
        starts.append(offset)
        let length = file.lines[index].text.utf16.count
        lengths.append(length)
        offset += length + 1
        parts.append(file.lines[index].text)
      }
      let highlighted = await SyntaxHighlighter.shared.highlightAsync(code: parts.joined(separator: "\n"), language: language)
      for span in highlighted.spans where span.role != .plain {
        var k = lastIndex(of: span.location, in: starts)
        let end = span.location + span.length
        while k < members.count, starts[k] < end {
          let from = max(span.location, starts[k]), to = min(end, starts[k] + lengths[k])
          if to > from { result[members[k]].append(DiffSpan(location: from - starts[k], length: to - from, role: span.role)) }
          k += 1
        }
      }
    }
    return result
  }

  private enum Side {
    case old, new
    func includes(_ kind: DiffLine.Kind) -> Bool {
      switch (self, kind) {
      case (_, .noNewline): false
      case (.old, .addition), (.new, .deletion): false
      // Context lines take the new side's colouring.
      case (.old, .context): false
      default: true
      }
    }
  }

  /// The last line start at or before `location`.
  private static func lastIndex(of location: Int, in starts: [Int]) -> Int {
    var low = 0, high = starts.count - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if starts[mid] <= location { low = mid } else { high = mid - 1 }
    }
    return low
  }
}
