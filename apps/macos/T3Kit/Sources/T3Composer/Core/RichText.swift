import Foundation

/// Inline Markdown styling for the rich composer (port of `composer-rich-text.ts`). Deliberately
/// small: bold, italic, strikethrough and inline code. Unmatched markers stay literal so nothing
/// the user typed is ever lost.
public enum RichTextMark: String, Sendable, Hashable, CaseIterable, Codable {
  case bold, italic, strike, code

  public var delimiter: String {
    switch self {
    case .bold: "**"
    case .italic: "*"
    case .strike: "~~"
    case .code: "`"
    }
  }

  /// Outermost mark first, so closers mirror openers when nested.
  static let nestingOrder: [RichTextMark] = [.strike, .bold, .italic, .code]
  var nestingIndex: Int { Self.nestingOrder.firstIndex(of: self)! }
}

public struct RichTextSpan: Sendable, Hashable {
  public var text: String
  public var marks: [RichTextMark]

  public init(text: String, marks: [RichTextMark]) {
    self.text = text
    self.marks = marks
  }
}

public enum RichText {
  private struct Span {
    var text: [UInt16]
    var marks: [RichTextMark]
  }

  private struct Frame {
    var delimiter: [UInt16]
    var mark: RichTextMark
    var spans: [Span]
  }

  private static func isWord(_ unit: UInt16) -> Bool {
    (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
  }

  private static func push(_ spans: inout [Span], _ text: ArraySlice<UInt16>, _ marks: [RichTextMark]) {
    guard !text.isEmpty else { return }
    if let last = spans.last, last.marks == marks {
      spans[spans.count - 1].text.append(contentsOf: text)
    } else {
      spans.append(Span(text: Array(text), marks: marks))
    }
  }

  private static func indexOf(_ needle: [UInt16], in units: [UInt16], from: Int) -> Int {
    guard !needle.isEmpty, units.count >= needle.count else { return -1 }
    var index = max(0, from)
    while index + needle.count <= units.count {
      if units[index] == needle[0], Array(units[index..<(index + needle.count)]) == needle { return index }
      index += 1
    }
    return -1
  }

  /// Parse the supported inline styles, leaving unmatched and escaped markers literal.
  public static func parseInline(_ source: String) -> [RichTextSpan] {
    let text = Array(source.utf16)
    var root: [Span] = []
    var stack: [Frame] = []
    var index = 0

    func pushCurrent(_ slice: ArraySlice<UInt16>, _ marks: [RichTextMark]) {
      if stack.isEmpty {
        push(&root, slice, marks)
      } else {
        push(&stack[stack.count - 1].spans, slice, marks)
      }
    }

    while index < text.count {
      let char = text[index]
      if char == 0x5C {
        pushCurrent(text[index..<min(index + 2, text.count)], [])
        index += 2
        continue
      }
      if char == 0x60 {
        // Multi-backtick code stays literal; a single-backtick span owns its contents.
        var runEnd = index
        while runEnd < text.count, text[runEnd] == 0x60 { runEnd += 1 }
        let run = Array(text[index..<runEnd])
        let close = indexOf(run, in: text, from: index + run.count)
        if run.count == 1, close > index + 1, !text[index..<close].contains(0x0A),
          (close + 1 < text.count ? text[close + 1] : 0) != 0x60
        {
          pushCurrent(text[(index + 1)..<close], [.code])
          index = close + 1
        } else {
          pushCurrent(text[index..<runEnd], [])
          index = runEnd
        }
        continue
      }
      if char != 0x2A && char != 0x5F && char != 0x7E {
        pushCurrent(text[index..<(index + 1)], [])
        index += 1
        continue
      }
      var end = index
      while end < text.count, text[end] == char { end += 1 }
      let before: UInt16? = index > 0 ? text[index - 1] : nil
      let after: UInt16? = end < text.count ? text[end] : nil
      let canClose = before != nil && !JS.isSpace(before!) && (char != 0x5F || !(after.map(isWord) ?? false))
      let canOpen = after != nil && !JS.isSpace(after!) && (char != 0x5F || !(before.map(isWord) ?? false))
      while index < end {
        let top = stack.last
        // Inside italic, a double marker opens bold before closing the single marker. Once bold is
        // active, closing runs unwind both styles.
        let opensNestedBold =
          top?.mark == .italic && end - index == 2 && canOpen && (char == 0x2A || char == 0x5F)
          && !stack.contains { $0.mark == .bold }
        if !opensNestedBold, canClose, let top, index + top.delimiter.count <= end,
          Array(text[index..<min(text.count, index + top.delimiter.count)]) == top.delimiter
        {
          stack.removeLast()
          for span in top.spans { pushCurrent(span.text[...], [top.mark] + span.marks) }
          index += top.delimiter.count
        } else if canOpen && (char != 0x7E || end - index >= 2) {
          let length = (char == 0x7E || end - index >= 2) ? 2 : 1
          let mark: RichTextMark = char == 0x7E ? .strike : (length == 2 ? .bold : .italic)
          // A mark cannot nest inside itself, including alternate delimiters.
          if stack.contains(where: { $0.mark == mark }) {
            pushCurrent(text[index..<end], [])
            index = end
            continue
          }
          stack.append(Frame(delimiter: Array(repeating: char, count: length), mark: mark, spans: []))
          index += length
        } else {
          pushCurrent(text[index..<end], [])
          index = end
        }
      }
    }
    while let frame = stack.popLast() {
      pushCurrent(frame.delimiter[...], [])
      for span in frame.spans { pushCurrent(span.text[...], span.marks) }
    }
    return root.map { RichTextSpan(text: String(decoding: $0.text, as: UTF16.self), marks: $0.marks) }
  }
}
