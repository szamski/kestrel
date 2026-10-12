import Foundation

extension RichDoc {
  private struct Accumulator {
    var runs: [RichRun] = []
    var value = ""
    var flat = 0
    var collapsed = 0
    var md = 0

    /// Block boundary: one newline in every coordinate space.
    mutating func pushBreak() {
      runs.append(
        RichRun(
          kind: .break, flatStart: flat, docLen: 1, collapsedLen: 1, mdLen: 1, openLen: 0, closeLen: 0,
          mdStart: md, collapsedStart: collapsed))
      value += "\n"
      flat += 1
      collapsed += 1
      md += 1
    }
  }

  private struct Child {
    var text: String?
    var atomSource: String?
    var nodeName: String?
    var marks: [RichTextMark]

    var isText: Bool { text != nil }
    var isPlainText: Bool { isText && !marks.contains(.code) }
  }

  private static func commonLength(_ left: [RichTextMark], _ right: [RichTextMark]) -> Int {
    var index = 0
    while index < left.count, index < right.count, left[index] == right[index] { index += 1 }
    return index
  }

  private static func appendInlineRuns(_ inline: [RichInline], into acc: inout Accumulator) {
    var children: [Child] = []
    for node in inline {
      switch node {
      case .atom(let atom, let marks):
        children.append(Child(text: nil, atomSource: atom.source, nodeName: atom.nodeName, marks: marks))
      case .text(let text, let marks):
        if marks.contains(.code) {
          children.append(Child(text: text, atomSource: nil, nodeName: nil, marks: marks))
          continue
        }
        // Separate boundary whitespace so delimiters can move past it without changing the document
        // offsets or marks on the visible text.
        let units = Array(text.utf16)
        let start = units.count - text.jsTrimStart().jsLength
        let end = max(start, text.jsTrimEnd().jsLength)
        var offset = 0
        for boundary in [start, end, units.count] {
          if boundary > offset {
            children.append(
              Child(text: String(decoding: units[offset..<boundary], as: UTF16.self), atomSource: nil, nodeName: nil, marks: marks))
          }
          offset = boundary
        }
      }
    }
    // Emphasis cannot open or close next to whitespace. Retain a whitespace mark only when its
    // range has visible content on both sides.
    for mark in RichTextMark.nestingOrder where mark != .code {
      for direction in [1, -1] {
        var hasContent = false
        var index = direction == 1 ? 0 : children.count - 1
        while index >= 0 && index < children.count {
          let child = children[index]
          if !child.marks.contains(mark) {
            hasContent = false
          } else if child.isPlainText, let text = child.text, !text.isEmpty, text.utf16.allSatisfy(JS.isSpace) {
            if !hasContent { children[index].marks.removeAll { $0 == mark } }
          } else {
            hasContent = true
          }
          index += direction
        }
      }
    }
    // Longer shared marks surround shorter ones. This keeps both nested formatting and formatting
    // across chips inside a single delimiter pair.
    var markEnds: [RichTextMark: Int] = [:]
    var orderedMarks = [[RichTextMark]](repeating: [], count: children.count)
    for index in stride(from: children.count - 1, through: 0, by: -1) {
      let marks = children[index].marks
      for mark in RichTextMark.nestingOrder {
        if !marks.contains(mark) {
          markEnds[mark] = nil
        } else if markEnds[mark] == nil {
          markEnds[mark] = index
        }
      }
      orderedMarks[index] = marks.sorted { a, b in
        let ea = markEnds[a]!
        let eb = markEnds[b]!
        if ea != eb { return eb < ea }
        return a.nestingIndex < b.nestingIndex
      }
    }
    if orderedMarks.count > 1 {
      for index in 1..<orderedMarks.count {
        let marks = orderedMarks[index]
        var retained: [RichTextMark] = []
        for mark in orderedMarks[index - 1] {
          if !marks.contains(mark) { break }
          retained.append(mark)
        }
        orderedMarks[index] = retained + marks.filter { !retained.contains($0) }
      }
    }
    for (index, child) in children.enumerated() {
      let marks = orderedMarks[index]
      let previous = index > 0 ? orderedMarks[index - 1] : []
      let following = index + 1 < orderedMarks.count ? orderedMarks[index + 1] : []
      let open = marks.dropFirst(commonLength(marks, previous)).map(\.delimiter).joined()
      let close = marks.dropFirst(commonLength(marks, following)).reversed().map(\.delimiter).joined()
      let source = child.text ?? child.atomSource ?? ""
      let docLen = child.isText ? source.jsLength : 1
      let mdText = open + source + close
      let collapsedLen = open.jsLength + docLen + close.jsLength
      acc.runs.append(
        RichRun(
          kind: child.isText ? .text : .token, flatStart: acc.flat, docLen: docLen, collapsedLen: collapsedLen,
          mdLen: mdText.jsLength, openLen: open.jsLength, closeLen: close.jsLength, mdStart: acc.md,
          collapsedStart: acc.collapsed, nodeName: child.nodeName))
      acc.value += mdText
      acc.flat += docLen
      acc.collapsed += collapsedLen
      acc.md += mdText.jsLength
    }
    // Empty paragraphs have an editable position even though they emit no text.
    if children.isEmpty {
      acc.runs.append(
        RichRun(
          kind: .text, flatStart: acc.flat, docLen: 0, collapsedLen: 0, mdLen: 0, openLen: 0, closeLen: 0,
          mdStart: acc.md, collapsedStart: acc.collapsed))
    }
  }

  /// A block marker (`- `, `> `, `## `, a rule's source) owns no document characters: every offset
  /// inside it clamps to the start of the text after it.
  private static func appendPrefix(_ prefix: String, into acc: inout Accumulator) {
    acc.runs.append(
      RichRun(
        kind: .prefix, flatStart: acc.flat, docLen: 0, collapsedLen: prefix.jsLength, mdLen: prefix.jsLength, openLen: 0, closeLen: 0, mdStart: acc.md,
        collapsedStart: acc.collapsed))
    acc.value += prefix
    acc.collapsed += prefix.jsLength
    acc.md += prefix.jsLength
  }

  /// The literal prefix an item serializes to. Empty items keep their exact spacing.
  private static func prefix(of item: RichListItem) -> String {
    let empty = item.content.isEmpty
    switch item.prefix {
    case .task(let checked, let indent, let markerSpace, let contentSpace):
      return "\(indent)-\(markerSpace)[\(checked ? "x" : " ")]\(contentSpace.isEmpty ? (empty ? "" : " ") : contentSpace)"
    case .marker(let indent, let marker, let space):
      // A bare `-` keeps its missing space only while the item is empty: once it has text, `-text`
      // would not be a list line any more.
      return "\(indent)\(marker.isEmpty ? "-" : marker)\(space.isEmpty ? (empty ? "" : " ") : space)"
    }
  }

  private static func walkList(_ list: RichList, into acc: inout Accumulator) {
    var firstItem = true
    for item in list.items {
      // Sibling items are separated by one newline in every coordinate space.
      if !firstItem { acc.pushBreak() }
      firstItem = false
      appendPrefix(prefix(of: item), into: &acc)
      appendInlineRuns(item.content, into: &acc)
      for child in item.children {
        acc.pushBreak()
        walkList(child, into: &acc)
      }
    }
  }

  /// A fence becomes runs whose open and close lengths are the delimiters, so every cursor rule that
  /// clamps out of a style marker clamps out of a fence too. The code is literal text in the editor, but
  /// the draft store still counts a chip's source in it as one cursor position, so the run splits at each
  /// chip source, which spans its characters in the document and one position in the collapsed space.
  private static func appendCodeBlock(fence: String, language: String, close closeIn: String, text: String, followed: Bool, into acc: inout Accumulator) {
    var fence = fence.isEmpty ? "```" : fence
    var close = closeIn
    // Code holding a line that would close the fence, such as a pasted fence, is written inside a longer
    // one, so the agent reads all of it as code. A parsed block never holds such a line.
    let longest = text.split(separator: "\n", omittingEmptySubsequences: false).filter { isClosingFence(String($0), fence: fence) }.map { line in
      line.prefix { $0 == "`" || $0 == "~" }.count
    }.max()
    if let longest, longest > 0 {
      fence = String(repeating: fence.first!, count: longest + 1)
      if !close.isEmpty { close = "\n" + fence }
    }
    // An unclosed fence runs to the end of the draft, so with a block after it the fence is written
    // closed, or the next rebuild would read that block as code.
    if close.isEmpty && followed { close = "\n" + fence }
    let open = fence + language + (text.isEmpty ? "" : "\n")
    let pieces: [(length: Int, collapsed: Int)] =
      text.isEmpty
      ? [(0, 0)]
      : ComposerPromptSegments.split(text).map { segment in
        if case .text(let value) = segment { return (value.jsLength, value.jsLength) }
        return (segment.source.jsLength, 1)
      }
    for (index, piece) in pieces.enumerated() {
      let openLen = index == 0 ? open.jsLength : 0
      let closeLen = index == pieces.count - 1 ? close.jsLength : 0
      acc.runs.append(
        RichRun(
          kind: .text, flatStart: acc.flat, docLen: piece.length, collapsedLen: openLen + piece.collapsed + closeLen,
          mdLen: openLen + piece.length + closeLen, openLen: openLen, closeLen: closeLen, mdStart: acc.md, collapsedStart: acc.collapsed,
          nodeName: "codeBlock"))
      acc.flat += piece.length
      acc.collapsed += openLen + piece.collapsed + closeLen
      acc.md += openLen + piece.length + closeLen
    }
    acc.value += open + text + close
  }

  /// `serializeEditorDoc`: canonical Markdown and the run table behind the cursor conversions.
  public func serialize() -> RichDocMap {
    var acc = Accumulator()
    for (index, block) in blocks.enumerated() {
      // The empty line a final rule keeps after it writes nothing, not even its newline.
      if index > 0 && !isTrailingLineAfterRule(index) { acc.pushBreak() }
      switch block {
      case .list(let list): Self.walkList(list, into: &acc)
      case .codeBlock(let fence, let language, let close, let text):
        Self.appendCodeBlock(fence: fence, language: language, close: close, text: text, followed: index < blocks.count - 1, into: &acc)
      case .quote(let prefix, let lines):
        // Each paragraph of a quote is one source line behind the quote's prefix.
        for (lineIndex, inline) in lines.enumerated() {
          if lineIndex > 0 { acc.pushBreak() }
          Self.appendPrefix(prefix, into: &acc)
          Self.appendInlineRuns(inline, into: &acc)
        }
      case .heading(let level, let space, let content):
        Self.appendPrefix(String(repeating: "#", count: level) + space, into: &acc)
        Self.appendInlineRuns(content, into: &acc)
      case .rule(let source):
        Self.appendPrefix(source.isEmpty ? "---" : source, into: &acc)
      case .paragraph(let inline): Self.appendInlineRuns(inline, into: &acc)
      }
    }
    return RichDocMap(
      value: acc.value, runs: acc.runs, docLength: acc.flat,
      contextIds: ComposerContextReferences.collectInlineContextIds(acc.value))
  }

  func isTrailingLineAfterRule(_ index: Int) -> Bool {
    guard index == blocks.count - 1, index > 0, case .paragraph(let inline) = blocks[index], inline.isEmpty, case .rule = blocks[index - 1] else { return false }
    return true
  }
}
