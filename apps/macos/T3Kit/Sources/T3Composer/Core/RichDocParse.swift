import Foundation

/// One source line of the document as the editor stores it: what kind of line it is and its inline
/// content. Markdown parses into lines, the editor storage reads back into lines, and `RichDoc(lines:)`
/// groups them into blocks, so both directions share one grouping rule.
struct RichLine: Sendable, Hashable {
  /// The delimiters of one fence. `id` tells two adjacent fences apart; every line of a fence carries it.
  struct CodeFence: Sendable, Hashable {
    var id: Int
    var fence: String
    var language: String
    var close: String
  }

  enum Kind: Sendable, Hashable {
    case paragraph
    case list(RichListItem.Prefix)
    case heading(level: Int, space: String)
    case quote(prefix: String)
    case code(CodeFence)
    case rule(source: String)
  }

  var kind: Kind
  var inline: [RichInline] = []
}

/// Pure document model of the rich composer: the Markdown stored in drafts parses into blocks of
/// styled text and chips, and serializes back to the same canonical Markdown.
public struct RichDoc: Sendable, Hashable {
  public var blocks: [RichBlock]

  public init(blocks: [RichBlock]) { self.blocks = blocks }

  // MARK: Line grammar (UTF-16, like the JavaScript regexes it ports)

  private static func isInlineSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

  private static func skipSpaces(_ units: [UInt16], _ from: Int) -> Int {
    var index = from
    while index < units.count, isInlineSpace(units[index]) { index += 1 }
    return index
  }

  private static func string(_ units: [UInt16], _ range: Range<Int>) -> String { String(decoding: units[range], as: UTF16.self) }

  /// `/^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]*)/`, rejecting text right after the box.
  private static func parseTaskPrefix(_ head: [UInt16]) -> (prefix: RichListItem.Prefix, markerLength: Int)? {
    let count = head.count
    let indentEnd = skipSpaces(head, 0)
    guard indentEnd < count, head[indentEnd] == 0x2D else { return nil }
    let markerStart = indentEnd + 1
    let index = skipSpaces(head, markerStart)
    guard index > markerStart, index + 2 < count, head[index] == 0x5B, head[index + 2] == 0x5D else { return nil }
    let box = head[index + 1]
    guard box == 0x20 || box == 0x78 || box == 0x58 else { return nil }
    let contentStart = index + 3
    let end = skipSpaces(head, contentStart)
    if end < count && end == contentStart { return nil }
    return (
      .task(
        checked: box != 0x20, indent: string(head, 0..<indentEnd), markerSpace: string(head, markerStart..<index),
        contentSpace: string(head, contentStart..<end)), end
    )
  }

  /// The same grammar the literal continuation uses, so plain and rich mode agree on what a list line
  /// is: a task first (it also looks like a bullet), then an ordered marker, then a bullet. A marker
  /// followed by nothing is an empty item.
  private static func parseListPrefix(_ line: [UInt16]) -> (prefix: RichListItem.Prefix, markerLength: Int)? {
    if let task = parseTaskPrefix(line) { return task }
    let indentEnd = skipSpaces(line, 0)
    var index = indentEnd
    while index < line.count, line[index] >= 0x30, line[index] <= 0x39 { index += 1 }
    var markerEnd = indentEnd
    if index > indentEnd, index < line.count, line[index] == 0x2E || line[index] == 0x29 {
      markerEnd = index + 1  // `\d+[.)]`
    } else if indentEnd < line.count, line[indentEnd] == 0x2D || line[indentEnd] == 0x2A || line[indentEnd] == 0x2B {
      markerEnd = indentEnd + 1  // `[-*+]`
    }
    guard markerEnd > indentEnd else { return nil }
    let spaceEnd = skipSpaces(line, markerEnd)
    // The marker needs whitespace after it, or the end of the line (an empty item).
    guard spaceEnd > markerEnd || spaceEnd == line.count else { return nil }
    return (.marker(indent: string(line, 0..<indentEnd), marker: string(line, indentEnd..<markerEnd), space: string(line, markerEnd..<spaceEnd)), spaceEnd)
  }

  /// An opening fence: three or more backticks or tildes at the start of a line followed by an info
  /// string. A backtick fence cannot carry a backtick in its info string, which is what keeps
  /// `` `code` `` on its own line literal. Indented fences stay paragraphs.
  private static func parseOpeningFence(_ line: [UInt16]) -> (fence: String, language: String)? {
    var run = 0
    guard let first = line.first, first == 0x60 || first == 0x7E else { return nil }
    while run < line.count, line[run] == first { run += 1 }
    guard run >= 3 else { return nil }
    let language = string(line, run..<line.count)
    if first == 0x60 && language.utf16.contains(0x60) { return nil }
    return (string(line, 0..<run), language)
  }

  /// A closing fence matches the opening run's character and is at least as long.
  static func isClosingFence(_ line: String, fence: String) -> Bool {
    isClosingFence(Array(line.utf16), fence: Array(fence.utf16))
  }

  private static func isClosingFence(_ line: [UInt16], fence: [UInt16]) -> Bool {
    guard let first = line.first, first == 0x60 || first == 0x7E else { return false }
    var run = 0
    while run < line.count, line[run] == first { run += 1 }
    guard run >= 3 else { return false }
    var end = skipSpaces(line, run)
    if end < line.count, line[end] == 0x0D { end += 1 }
    return end == line.count && first == fence.first && run >= fence.count
  }

  /// `/^([-*_])(?:[ \t]*\1){2,}[ \t]*\r?$/`: `- - -`, `***`, `_____`.
  private static func isRule(_ line: [UInt16]) -> Bool {
    guard let first = line.first, first == 0x2D || first == 0x2A || first == 0x5F else { return false }
    var index = 1
    var repeats = 0
    while true {
      let next = skipSpaces(line, index)
      guard next < line.count, line[next] == first else { break }
      repeats += 1
      index = next + 1
    }
    var end = skipSpaces(line, index)
    if end < line.count, line[end] == 0x0D { end += 1 }
    return repeats >= 2 && end == line.count
  }

  /// `/^(#{1,6})([ \t]+)([^\n]*)$/`
  private static func parseHeading(_ line: [UInt16]) -> (level: Int, space: String, text: [UInt16])? {
    var hashes = 0
    while hashes < line.count, line[hashes] == 0x23 { hashes += 1 }
    guard (1...6).contains(hashes) else { return nil }
    let end = skipSpaces(line, hashes)
    guard end > hashes else { return nil }
    return (hashes, string(line, hashes..<end), Array(line[end...]))
  }

  /// `/^(>[ \t]*)([^\n]*)$/`
  private static func parseQuote(_ line: [UInt16]) -> (prefix: String, text: [UInt16])? {
    guard line.first == 0x3E else { return nil }
    let end = skipSpaces(line, 1)
    return (string(line, 0..<end), Array(line[end...]))
  }

  // MARK: Markdown -> lines

  private static func atom(for segment: ComposerPromptSegment, skillMeta: (String) -> SkillMeta) -> RichAtom {
    switch segment {
    case .mention(let path, let source):
      return .mention(path: path, source: source)
    case .skill(let name, _):
      let meta = skillMeta(name)
      return .skill(name: name, label: meta.label, description: meta.description)
    case .citation(let citation, let source):
      return .citation(citation, source: source)
    case .contextReference(let kind, let contextId, let label, let source):
      return .contextReference(kind: kind, contextId: contextId, label: label, source: source)
    case .text:
      fatalError("text is not an atom")
    }
  }

  /// Adjacent text with equal marks is one node, like in ProseMirror.
  static func normalized(_ inline: [RichInline]) -> [RichInline] {
    var out: [RichInline] = []
    for node in inline {
      if case .text(let text, let marks) = node {
        if text.isEmpty { continue }
        if case .text(let previous, let previousMarks)? = out.last, previousMarks == marks {
          out[out.count - 1] = .text(previous + text, marks: marks)
          continue
        }
      }
      out.append(node)
    }
    return out
  }

  /// `buildTiptapContent`: `styling: false` is the plain-text mode where formatting and blocks stay
  /// literal; `literalText` (editor answers) keeps every line verbatim, chip sources included. `blocks:
  /// false` keeps inline marks without block syntax, for text pasted where no line starts.
  public init(
    markdown value: String, skillMeta: (String) -> SkillMeta = { SkillMeta(label: $0) }, styling: Bool = true, blocks: Bool = true, literalText: Bool = false
  ) {
    if literalText {
      let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        RichLine(kind: .paragraph, inline: line.isEmpty ? [] : [.text(String(line), marks: [])])
      }
      self.init(lines: lines)
      return
    }
    // Hide token source from the Markdown parser, then restore the atoms with the marks of their
    // surrounding text. Choose a sentinel absent from the input.
    var sentinel: UInt16 = 0xFFFC
    var next: UInt16 = 0xE000
    let valueUnits = Set(value.utf16)
    while valueUnits.contains(sentinel) {
      sentinel = next
      next += 1
    }
    var atoms: [RichAtom] = []
    // Code fences hold no chips, so their lines put the original source back in place of the sentinel.
    var atomSources: [String] = []
    var masked: [UInt16] = []
    for segment in ComposerPromptSegments.split(value) {
      if case .text(let text) = segment {
        masked.append(contentsOf: text.utf16)
      } else {
        atoms.append(Self.atom(for: segment, skillMeta: skillMeta))
        atomSources.append(segment.source)
        masked.append(sentinel)
      }
    }
    var atomIndex = 0
    func buildInline(_ content: ArraySlice<UInt16>) -> [RichInline] {
      let contentString = String(decoding: content, as: UTF16.self)
      let spans = styling ? RichText.parseInline(contentString) : [RichTextSpan(text: contentString, marks: [])]
      var inline: [RichInline] = []
      for span in spans {
        let pieces = Array(span.text.utf16).split(separator: sentinel, omittingEmptySubsequences: false)
        for (pieceIndex, piece) in pieces.enumerated() {
          if pieceIndex > 0 {
            inline.append(.atom(atoms[atomIndex], marks: Self.sortedMarks(span.marks)))
            atomIndex += 1
          }
          if !piece.isEmpty { inline.append(.text(String(decoding: piece, as: UTF16.self), marks: Self.sortedMarks(span.marks))) }
        }
      }
      return Self.normalized(inline)
    }
    func restoreSources(_ line: ArraySlice<UInt16>) -> String {
      var joined = ""
      for (index, piece) in line.split(separator: sentinel, omittingEmptySubsequences: false).enumerated() {
        if index > 0 {
          joined += atomSources[atomIndex]
          atomIndex += 1
        }
        joined += String(decoding: piece, as: UTF16.self)
      }
      return joined
    }

    // Fenced blocks claim their lines whole; every other line is classified by its first characters.
    let sourceLines = masked.split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) }
    var lines: [RichLine] = []
    var fenceId = 0
    var index = 0
    while index < sourceLines.count {
      let line = sourceLines[index]
      index += 1
      guard styling && blocks else {
        lines.append(RichLine(kind: .paragraph, inline: buildInline(line[...])))
        continue
      }
      guard let opening = Self.parseOpeningFence(line) else {
        // A thematic break outranks a list: `- - -` and `* * *` are rules, and `***` on its own line is
        // a rule rather than an empty bold span.
        if Self.isRule(line) {
          lines.append(RichLine(kind: .rule(source: String(decoding: line, as: UTF16.self))))
        } else if let heading = Self.parseHeading(line) {
          lines.append(RichLine(kind: .heading(level: heading.level, space: heading.space), inline: buildInline(heading.text[...])))
        } else if let quote = Self.parseQuote(line) {
          lines.append(RichLine(kind: .quote(prefix: quote.prefix), inline: buildInline(quote.text[...])))
        } else if let list = Self.parseListPrefix(line) {
          lines.append(RichLine(kind: .list(list.prefix), inline: buildInline(line[list.markerLength...])))
        } else {
          lines.append(RichLine(kind: .paragraph, inline: buildInline(line[...])))
        }
        continue
      }
      // The info string went through the sentinel pass like every line, so a token in it is put back as
      // source here, in order, before the body.
      let language = restoreSources(Array(opening.language.utf16)[...])
      var body: [String] = []
      // An unclosed fence runs to the end of the prompt, which is what the user sees while typing it.
      var close = ""
      while index < sourceLines.count {
        let candidate = sourceLines[index]
        index += 1
        if Self.isClosingFence(candidate, fence: Array(opening.fence.utf16)) {
          close = "\n" + String(decoding: candidate, as: UTF16.self)
          break
        }
        body.append(restoreSources(candidate[...]))
      }
      let fence = RichLine.CodeFence(id: fenceId, fence: opening.fence, language: language, close: close)
      fenceId += 1
      // An empty block (no body, or one blank line) is a single empty line.
      for text in Self.codeLines(body.joined(separator: "\n")) {
        lines.append(RichLine(kind: .code(fence), inline: text.isEmpty ? [] : [.text(text, marks: [])]))
      }
    }
    self.init(lines: lines)
  }

  static func codeLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  static func sortedMarks(_ marks: [RichTextMark]) -> [RichTextMark] {
    marks.sorted { $0.nestingIndex < $1.nestingIndex }
  }

  // MARK: Blocks -> lines

  /// The document as editor lines, in order: a list item and its nested items are separate lines, each
  /// line of a quote or a fence too. The empty line a final rule keeps after it has no line of its own.
  var lines: [RichLine] {
    var out: [RichLine] = []
    func flatten(_ list: RichList) {
      for item in list.items {
        out.append(RichLine(kind: .list(item.prefix), inline: item.content))
        item.children.forEach(flatten)
      }
    }
    for (index, block) in blocks.enumerated() {
      switch block {
      case .paragraph(let inline):
        if !isTrailingLineAfterRule(index) { out.append(RichLine(kind: .paragraph, inline: inline)) }
      case .heading(let level, let space, let content): out.append(RichLine(kind: .heading(level: level, space: space), inline: content))
      case .quote(let prefix, let lines): for inline in lines { out.append(RichLine(kind: .quote(prefix: prefix), inline: inline)) }
      case .codeBlock(let fence, let language, let close, let text):
        let delimiters = RichLine.CodeFence(id: index, fence: fence, language: language, close: close)
        for line in Self.codeLines(text) { out.append(RichLine(kind: .code(delimiters), inline: line.isEmpty ? [] : [.text(line, marks: [])])) }
      case .rule(let source): out.append(RichLine(kind: .rule(source: source)))
      case .list(let list): flatten(list)
      }
    }
    return out
  }

  // MARK: Lines -> blocks

  /// The lists directly under the document or under one item; a reference, so an item's nested lists
  /// can be appended to through the indent stack.
  private final class ListContainer {
    var lists: [PendingList] = []
  }

  private final class PendingItem {
    var prefix: RichListItem.Prefix
    var content: [RichInline]
    /// Nested lists, in order; a parent can hold lists of different kinds.
    let children = ListContainer()
    init(prefix: RichListItem.Prefix, content: [RichInline]) {
      self.prefix = prefix
      self.content = content
    }
  }

  private final class PendingList {
    let key: String
    var items: [PendingItem] = []
    init(key: String) { self.key = key }
  }

  /// Items of one kind and marker family belong to one list; a change starts a sibling list.
  private static func listKey(_ prefix: RichListItem.Prefix) -> String {
    switch prefix {
    case .task: "task"
    case .marker(_, let marker, _):
      marker.last.map { $0 == "." || $0 == ")" } == true ? "ordered:\(marker.last!)" : "bullet:\(marker)"
    }
  }

  private static func frozen(_ list: PendingList) -> RichList {
    let items = list.items.map { RichListItem(prefix: $0.prefix, content: $0.content, children: $0.children.lists.map(frozen)) }
    switch list.items[0].prefix {
    case .task: return RichList(kind: .task, items: items)
    case .marker(_, let marker, _):
      guard marker.last == "." || marker.last == ")" else { return RichList(kind: .bullet, items: items) }
      let number = Double(marker.dropLast()) ?? 0
      return RichList(kind: .ordered(start: number == 0 ? 1 : number), items: items)
    }
  }

  /// Groups lines into blocks: consecutive list lines nest by indent prefix, quote lines with one
  /// prefix share a quote, the lines of one fence share a code block. Items of a different kind or
  /// marker at the same indent start a sibling list, so `* a` under `- b` keeps its star and a task
  /// list can follow a bullet list.
  init(lines: [RichLine]) {
    var blocks: [RichBlock] = []
    var root = ListContainer()
    var stack: [(indent: String, list: PendingList, container: ListContainer)] = []
    func flushLists() {
      for list in root.lists { blocks.append(.list(Self.frozen(list))) }
      root = ListContainer()
      stack = []
    }
    var openQuote: (prefix: String, lines: [[RichInline]])?
    func flushQuote() {
      guard let quote = openQuote else { return }
      blocks.append(.quote(prefix: quote.prefix, lines: quote.lines))
      openQuote = nil
    }
    var openCode: (fence: RichLine.CodeFence, lines: [String])?
    func flushCode() {
      guard let code = openCode else { return }
      blocks.append(.codeBlock(fence: code.fence.fence, language: code.fence.language, close: code.fence.close, text: code.lines.joined(separator: "\n")))
      openCode = nil
    }
    func codeText(_ inline: [RichInline]) -> String {
      inline.map { node in
        switch node {
        case .text(let text, _): text
        case .atom(let atom, _): atom.source
        }
      }.joined()
    }
    func openList(_ key: String, in container: ListContainer) -> PendingList {
      let list = PendingList(key: key)
      container.lists.append(list)
      return list
    }

    for line in lines {
      if case .quote(let prefix) = line.kind {
        flushCode()
        flushLists()
        if let open = openQuote, open.prefix != prefix { flushQuote() }
        if openQuote == nil { openQuote = (prefix, []) }
        openQuote!.lines.append(line.inline)
        continue
      }
      flushQuote()
      if case .code(let fence) = line.kind {
        flushLists()
        if let open = openCode, open.fence.id != fence.id { flushCode() }
        if openCode == nil { openCode = (fence, []) }
        openCode!.lines.append(codeText(line.inline))
        continue
      }
      flushCode()
      switch line.kind {
      case .rule(let source):
        flushLists()
        blocks.append(.rule(source: source))
      case .heading(let level, let space):
        flushLists()
        blocks.append(.heading(level: level, space: space, content: line.inline))
      case .paragraph:
        flushLists()
        blocks.append(.paragraph(line.inline))
      case .quote, .code:
        break
      case .list(let prefix):
        let item = PendingItem(prefix: prefix, content: line.inline)
        let key = Self.listKey(prefix)
        let indent = prefix.indent
        while true {
          guard let top = stack.last else {
            // A leading indented item with no parent flattens but keeps indent.
            stack.append((indent, openList(key, in: root), root))
            continue
          }
          if top.indent == indent {
            if top.list.key != key { stack[stack.count - 1].list = openList(key, in: top.container) }
            stack[stack.count - 1].list.items.append(item)
            break
          }
          if !top.indent.isEmpty && !indent.hasPrefix(top.indent) {
            if stack.count > 1 {
              stack.removeLast()
              continue
            }
            stack[stack.count - 1].indent = indent
            if top.list.key != key { stack[stack.count - 1].list = openList(key, in: top.container) }
            stack[stack.count - 1].list.items.append(item)
            break
          }
          guard let parent = top.list.items.last else {
            top.list.items.append(item)
            break
          }
          let list = openList(key, in: parent.children)
          stack.append((indent, list, parent.children))
          list.items.append(item)
          break
        }
      }
    }
    flushQuote()
    flushCode()
    flushLists()
    // The empty line a final rule keeps after it, so the caret has somewhere to go.
    if case .rule? = blocks.last { blocks.append(.paragraph([])) }
    self.blocks = blocks
  }
}
