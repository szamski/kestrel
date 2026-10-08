import Foundation

/// The inline chips of the rich composer document.
public enum RichAtom: Sendable, Hashable {
  case mention(path: String, source: String)
  case skill(name: String, label: String, description: String?)
  case citation(AssistantCitation, source: String)
  case contextReference(kind: String, contextId: String, label: String, source: String)

  /// The Markdown a chip serializes to.
  public var source: String {
    switch self {
    case .mention(_, let source), .citation(_, let source), .contextReference(_, _, _, let source): source
    case .skill(let name, _, _): name.isEmpty ? "" : "$\(name)"
    }
  }

  public var nodeName: String {
    switch self {
    case .mention: "composer-mention"
    case .skill: "composer-skill"
    case .citation: "composer-citation"
    case .contextReference: "composer-context-reference"
    }
  }
}

public enum RichInline: Sendable, Hashable {
  case text(String, marks: [RichTextMark])
  case atom(RichAtom, marks: [RichTextMark])

  var marks: [RichTextMark] {
    switch self {
    case .text(_, let marks), .atom(_, let marks): marks
    }
  }
}

public struct RichTaskItem: Sendable, Hashable {
  public var checked: Bool
  public var indent: String
  public var markerSpace: String
  public var contentSpace: String
  public var content: [RichInline]
  public var children: [RichTaskItem]

  public init(
    checked: Bool, indent: String = "", markerSpace: String = " ", contentSpace: String = " ",
    content: [RichInline] = [], children: [RichTaskItem] = []
  ) {
    self.checked = checked
    self.indent = indent
    self.markerSpace = markerSpace
    self.contentSpace = contentSpace
    self.content = content
    self.children = children
  }
}

public enum RichBlock: Sendable, Hashable {
  case paragraph([RichInline])
  case taskList([RichTaskItem])
}

public struct SkillMeta: Sendable, Hashable {
  public var label: String
  public var description: String?

  public init(label: String, description: String? = nil) {
    self.label = label
    self.description = description
  }
}

/// One serialized piece of the document in all coordinate spaces (see `RichDocMap`).
public struct RichRun: Sendable, Hashable {
  public enum Kind: String, Sendable { case text, token, `break`, prefix }
  public var kind: Kind
  /// Flat editor offset (chips count 1, markers excluded).
  public var flatStart: Int
  public var docLen: Int
  /// Collapsed cursor length (markers literal, chips count 1).
  public var collapsedLen: Int
  /// Markdown length (chips expand to their source).
  public var mdLen: Int
  public var openLen: Int
  public var closeLen: Int
  public var mdStart: Int
  public var collapsedStart: Int
  /// For chips: the editor node kind (`composer-mention`, `composer-skill`, ...).
  public var nodeName: String?
}

/// Serialized document: canonical Markdown plus the run table that converts cursor offsets between
/// the three coordinate spaces.
///
/// - flat ("editor"): chips count 1, style markers excluded, paragraph boundaries count 1
/// - collapsed: style markers literal, chips count 1; what the draft store and mention detection use
/// - markdown: markers literal, chips expand to their source
public struct RichDocMap: Sendable, Hashable {
  public var value: String
  public var runs: [RichRun]
  public var docLength: Int
  public var contextIds: [String]

  private func lastRunEnd(collapsed: Bool) -> Int {
    guard let last = runs.last else { return 0 }
    return collapsed ? last.collapsedStart + last.collapsedLen : last.mdStart + last.mdLen
  }

  public func flatToCollapsed(_ flatOffset: Int) -> Int {
    let bounded = max(0, min(flatOffset, docLength))
    for run in runs where bounded < run.flatStart + run.docLen {
      if run.kind == .text || run.kind == .token { return run.collapsedStart + run.openLen + (bounded - run.flatStart) }
      return run.collapsedStart + (bounded - run.flatStart)
    }
    return lastRunEnd(collapsed: true)
  }

  public func flatToMarkdown(_ flatOffset: Int) -> Int {
    let bounded = max(0, min(flatOffset, docLength))
    for run in runs where bounded < run.flatStart + run.docLen {
      if run.kind == .text || run.kind == .token { return run.mdStart + run.openLen + (bounded - run.flatStart) }
      return run.mdStart + (bounded - run.flatStart)
    }
    return lastRunEnd(collapsed: false)
  }

  public func collapsedToFlat(_ collapsedOffset: Int) -> Int {
    for run in runs where collapsedOffset < run.collapsedStart + run.collapsedLen {
      // Checkbox prefixes and style markers are shown, never edited: every offset inside them
      // clamps to the adjacent document position.
      if run.kind == .prefix { return run.flatStart }
      if run.kind == .text || run.kind == .token {
        let within = collapsedOffset - run.collapsedStart
        if within <= run.openLen { return run.flatStart }
        if within >= run.openLen + run.docLen { return run.flatStart + run.docLen }
        return run.flatStart + (within - run.openLen)
      }
      return run.flatStart + (collapsedOffset - run.collapsedStart)
    }
    return docLength
  }
}

/// Pure document model of the rich composer: the Markdown stored in drafts parses into blocks of
/// styled text and chips, and serializes back to the same canonical Markdown.
public struct RichDoc: Sendable, Hashable {
  public var blocks: [RichBlock]

  public init(blocks: [RichBlock]) { self.blocks = blocks }

  // MARK: Markdown -> document

  private struct TaskPrefix {
    var indent: String
    var checked: Bool
    var markerSpace: String
    var contentSpace: String
  }

  private static func isInlineSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

  /// `/^([ \t]*)-([ \t]+)\[([ xX])\]([ \t]*)/`, rejecting text right after the box.
  private static func parseTaskPrefix(_ head: [UInt16]) -> (prefix: TaskPrefix, markerLength: Int)? {
    let count = head.count
    var index = 0
    while index < count, isInlineSpace(head[index]) { index += 1 }
    let indentEnd = index
    guard index < count, head[index] == 0x2D else { return nil }
    index += 1
    let markerStart = index
    while index < count, isInlineSpace(head[index]) { index += 1 }
    guard index > markerStart, index + 2 < count, head[index] == 0x5B, head[index + 2] == 0x5D else { return nil }
    let box = head[index + 1]
    guard box == 0x20 || box == 0x78 || box == 0x58 else { return nil }
    let markerSpace = String(decoding: head[markerStart..<index], as: UTF16.self)
    index += 3
    let contentStart = index
    while index < count, isInlineSpace(head[index]) { index += 1 }
    let contentSpace = String(decoding: head[contentStart..<index], as: UTF16.self)
    if index < count && contentSpace.isEmpty { return nil }
    return (
      TaskPrefix(
        indent: String(decoding: head[0..<indentEnd], as: UTF16.self), checked: box != 0x20,
        markerSpace: markerSpace, contentSpace: contentSpace), index
    )
  }

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

  private struct DocLine {
    var task: TaskPrefix?
    var inline: [RichInline]
  }

  private final class PendingItem {
    var prefix: TaskPrefix
    var content: [RichInline]
    var children: [PendingItem] = []
    init(prefix: TaskPrefix, content: [RichInline]) {
      self.prefix = prefix
      self.content = content
    }
  }

  /// One indentation level of the task-list stack. A child level shares its parent item's
  /// `children`, so appending to it nests the item.
  private final class Level {
    var indent: String
    private var own: [PendingItem] = []
    private let owner: PendingItem?
    init(indent: String, owner: PendingItem?) {
      self.indent = indent
      self.owner = owner
    }
    var items: [PendingItem] {
      get { owner?.children ?? own }
      set {
        if let owner { owner.children = newValue } else { own = newValue }
      }
    }
  }

  private static func frozen(_ items: [PendingItem]) -> [RichTaskItem] {
    items.map {
      RichTaskItem(
        checked: $0.prefix.checked, indent: $0.prefix.indent, markerSpace: $0.prefix.markerSpace,
        contentSpace: $0.prefix.contentSpace, content: $0.content, children: frozen($0.children))
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

  /// `buildTiptapContent`: `styling: false` is the plain-text mode where formatting stays literal.
  public init(markdown value: String, skillMeta: (String) -> SkillMeta = { SkillMeta(label: $0) }, styling: Bool = true) {
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
    var masked: [UInt16] = []
    for segment in ComposerPromptSegments.split(value) {
      if case .text(let text) = segment {
        masked.append(contentsOf: text.utf16)
      } else {
        atoms.append(Self.atom(for: segment, skillMeta: skillMeta))
        masked.append(sentinel)
      }
    }
    var atomIndex = 0
    var lines: [DocLine] = []
    for lineUnits in masked.split(separator: 0x0A, omittingEmptySubsequences: false) {
      let line = Array(lineUnits)
      let parsed = styling ? Self.parseTaskPrefix(line) : nil
      let content = parsed.map { Array(line[$0.markerLength...]) } ?? line
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
      lines.append(DocLine(task: parsed?.prefix, inline: Self.normalized(inline)))
    }

    // Pass 2: consecutive task lines group into (possibly nested) task lists by indent prefix;
    // everything else stays a paragraph.
    var blocks: [RichBlock] = []
    var stack: [Level] = []
    func flushTasks() {
      if !stack.isEmpty {
        blocks.append(.taskList(Self.frozen(stack[0].items)))
        stack = []
      }
    }
    for line in lines {
      guard let task = line.task else {
        flushTasks()
        blocks.append(.paragraph(line.inline))
        continue
      }
      let item = PendingItem(prefix: task, content: line.inline)
      while true {
        guard let top = stack.last else {
          // A leading indented item with no parent flattens but keeps indent.
          stack.append(Level(indent: item.prefix.indent, owner: nil))
          continue
        }
        if top.indent == item.prefix.indent {
          top.items.append(item)
          break
        }
        if top.indent != "" && !item.prefix.indent.hasPrefix(top.indent) {
          if stack.count > 1 {
            stack.removeLast()
            continue
          }
          top.indent = item.prefix.indent
          top.items.append(item)
          break
        }
        guard let parent = top.items.last else {
          top.items.append(item)
          break
        }
        parent.children.append(item)
        stack.append(Level(indent: item.prefix.indent, owner: parent))
        break
      }
    }
    flushTasks()
    self.blocks = blocks
  }

  private static func sortedMarks(_ marks: [RichTextMark]) -> [RichTextMark] {
    marks.sorted { $0.nestingIndex < $1.nestingIndex }
  }
}
