import Foundation

/// Typing rules of the rich editor, as pure functions on the text before the caret: the Tiptap
/// input rules of StarterKit's marks and the task-item rule, plus surround-on-selection.
enum EditorRules {
  struct MarkMatch: Equatable {
    var mark: RichTextMark
    /// Offsets (UTF-16, relative to the text start) of the opening delimiter, the content and the closing delimiter.
    var openRange: Range<Int>
    var contentRange: Range<Int>
    var closeRange: Range<Int>
  }

  private static let s = JS.spaceClass

  private struct Rule {
    var mark: RichTextMark
    var regex: JSRegex
    var delimiterLength: Int
  }

  // `(?:^|\s)(<d>(?!\s+<d>)((?:[^<c>]+))<d>(?!\s+<d>))$` with the delimiter `d` and its character `c`.
  private static func delimited(_ delimiter: String, _ char: String) -> JSRegex {
    let d = NSRegularExpression.escapedPattern(for: delimiter)
    let c = NSRegularExpression.escapedPattern(for: char)
    return JSRegex("(?:^|[\(s)])(\(d)(?![\(s)]+\(d))((?:[^\(c)]+))\(d)(?![\(s)]+\(d)))\\z")
  }

  private static let rules: [Rule] = [
    Rule(mark: .bold, regex: delimited("**", "*"), delimiterLength: 2),
    Rule(mark: .bold, regex: delimited("__", "_"), delimiterLength: 2),
    Rule(mark: .italic, regex: delimited("*", "*"), delimiterLength: 1),
    Rule(mark: .italic, regex: delimited("_", "_"), delimiterLength: 1),
    Rule(mark: .strike, regex: delimited("~~", "~"), delimiterLength: 2),
  ]
  private static let codeRule = JSRegex("(^|[^`])`([^`]+)`(?!`)\\z")
  private static let taskRule = JSRegex("^- \\[([ xX])\\] \\z")

  /// The mark a just-typed closing delimiter completes in `textBeforeCaret` (the paragraph text up
  /// to and including the typed character), if any. Marks do not nest inside themselves.
  static func markMatch(textBeforeCaret text: String) -> MarkMatch? {
    for rule in rules {
      guard let match = rule.regex.firstMatch(in: text) else { continue }
      // Group 1 is the whole delimited span; its offsets come from the end of the match.
      let end = match.range.upperBound
      guard let span = match.group(1) else { continue }
      let spanLength = span.jsLength
      let start = end - spanLength
      let n = rule.delimiterLength
      return MarkMatch(
        mark: rule.mark, openRange: start..<(start + n), contentRange: (start + n)..<(end - n), closeRange: (end - n)..<end)
    }
    if let match = codeRule.firstMatch(in: text), let prefix = match.group(1), let content = match.group(2) {
      let end = match.range.upperBound
      let start = match.range.lowerBound + prefix.jsLength
      return MarkMatch(mark: .code, openRange: start..<(start + 1), contentRange: (start + 1)..<(start + 1 + content.jsLength), closeRange: (end - 1)..<end)
    }
    return nil
  }

  /// `- [ ] ` typed at the start of a paragraph: the checked state, nil for no match.
  static func taskMatch(textBeforeCaret text: String) -> Bool? {
    guard let match = taskRule.firstMatch(in: text), let box = match.group(1) else { return nil }
    return box.lowercased() == "x"
  }

  /// Typing one of these with a selection wraps it instead of replacing it.
  static let surroundClose: [Character: Character] = [
    "(": ")", "[": "]", "{": "}", "'": "'", "\"": "\"", "“": "”", "`": "`", "<": ">", "«": "»", "*": "*", "_": "_",
  ]
}
