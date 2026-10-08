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

  private static func walkTaskList(_ items: [RichTaskItem], into acc: inout Accumulator) {
    var firstItem = true
    for item in items {
      // Sibling items are separated by one newline in every coordinate space.
      if !firstItem { acc.pushBreak() }
      firstItem = false
      let empty = item.content.isEmpty
      let contentSpace = item.contentSpace.isEmpty ? (empty ? "" : " ") : item.contentSpace
      let prefix = "\(item.indent)-\(item.markerSpace)[\(item.checked ? "x" : " ")]\(contentSpace)"
      // The checkbox owns no document characters; every prefix offset clamps to the item text.
      acc.runs.append(
        RichRun(
          kind: .prefix, flatStart: acc.flat, docLen: 0, collapsedLen: prefix.jsLength, mdLen: prefix.jsLength,
          openLen: 0, closeLen: 0, mdStart: acc.md, collapsedStart: acc.collapsed))
      acc.value += prefix
      acc.collapsed += prefix.jsLength
      acc.md += prefix.jsLength
      appendInlineRuns(item.content, into: &acc)
      if !item.children.isEmpty {
        acc.pushBreak()
        walkTaskList(item.children, into: &acc)
      }
    }
  }

  /// `serializeEditorDoc`: canonical Markdown and the run table behind the cursor conversions.
  public func serialize() -> RichDocMap {
    var acc = Accumulator()
    for (index, block) in blocks.enumerated() {
      if index > 0 { acc.pushBreak() }
      switch block {
      case .taskList(let items): Self.walkTaskList(items, into: &acc)
      case .paragraph(let inline): Self.appendInlineRuns(inline, into: &acc)
      }
    }
    return RichDocMap(
      value: acc.value, runs: acc.runs, docLength: acc.flat,
      contextIds: ComposerContextReferences.collectInlineContextIds(acc.value))
  }
}
