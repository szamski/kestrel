import AppKit

/// The editor's attachment character: a chip. The attachment keeps its atom so reading the
/// storage back never needs the presentation layer.
final class ChipAttachment: NSTextAttachment {
  let atom: RichAtom

  init(atom: RichAtom) {
    self.atom = atom
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { fatalError("ChipAttachment is not archived") }
}

/// Converts between the editor's attributed storage and the Markdown document model.
///
/// The storage holds exactly the "flat" coordinate space of `RichDocMap`: lines joined by one
/// newline, a chip as one U+FFFC attachment character, style markers, block prefixes (list markers,
/// `>`, `#`, fences) and rules carried as attributes rather than characters. So an NSRange offset in
/// the storage *is* a flat offset. A line that is not plain prose carries `.t3Block` over the whole
/// paragraph including its newline.
@MainActor
enum EditorContent {
  static let objectReplacement = "\u{FFFC}"

  /// A loaded document: its attributed string plus the block attributes of an *empty last
  /// paragraph*, which has no character to carry them (the text view keeps them as typing attributes).
  struct Loaded {
    var string: NSAttributedString
    var trailingBlock: BlockAttrs?
  }

  /// Fence ids tell adjacent code blocks apart, also across loads and pastes.
  private static var fenceCounter = 0

  static func attributedString(for doc: RichDoc, style: ComposerEditorStyle, presentation: ChipPresentationProvider) -> NSAttributedString {
    load(doc, style: style, presentation: presentation).string
  }

  static func load(_ doc: RichDoc, style: ComposerEditorStyle, presentation: ChipPresentationProvider) -> Loaded {
    let output = NSMutableAttributedString()
    let lines = doc.lines
    var fenceIds: [Int: Int] = [:]
    var lastBlock: BlockAttrs?
    for (index, line) in lines.enumerated() {
      var kind = line.kind
      if case .code(var fence) = kind {
        if fenceIds[fence.id] == nil {
          fenceCounter += 1
          fenceIds[fence.id] = fenceCounter
        }
        fence.id = fenceIds[fence.id]!
        kind = .code(fence)
      }
      let block: BlockAttrs? = if case .paragraph = kind { nil } else { BlockAttrs(kind) }
      lastBlock = block
      for node in line.inline {
        switch node {
        case .text(let text, let marks):
          output.append(NSAttributedString(string: text, attributes: plainAttributes(style: style, block: block, mask: RichTextMark.mask(marks))))
        case .atom(let atom, let marks):
          output.append(chipString(atom, marks: RichTextMark.mask(marks), style: style, presentation: presentation, block: block))
        }
      }
      // A paragraph's newline belongs to it, so the block attributes cover the whole paragraph.
      if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: plainAttributes(style: style, block: block, mask: 0))) }
    }
    let ends = output.length == 0 || output.string.hasSuffix("\n")
    return Loaded(string: output, trailingBlock: ends ? lastBlock : nil)
  }

  static func plainAttributes(style: ComposerEditorStyle, block: BlockAttrs?, mask: Int) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: style.font(for: mask, block: block), .foregroundColor: style.textColor ?? NSColor.labelColor, .t3Marks: mask,
      .paragraphStyle: style.paragraphStyle(block: block),
    ]
    if mask & RichTextMark.strike.bit != 0 { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if mask & RichTextMark.code.bit != 0 { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
    if let block { attributes[.t3Block] = block }
    return attributes
  }

  static func chipString(_ atom: RichAtom, marks: Int, style: ComposerEditorStyle, presentation: ChipPresentationProvider, block: BlockAttrs?) -> NSAttributedString {
    let attachment = ChipAttachment(atom: atom)
    configure(attachment, presentation: presentation(atom), style: style)
    var attributes = plainAttributes(style: style, block: block, mask: marks)
    attributes[.attachment] = attachment
    return NSAttributedString(string: objectReplacement, attributes: attributes)
  }

  /// Sizes and paints the attachment for `presentation`.
  static func configure(_ attachment: ChipAttachment, presentation: ChipPresentation, style: ComposerEditorStyle) {
    let font = style.baseFont
    let size = ChipRenderer.size(for: presentation, textFont: font)
    attachment.image = ChipRenderer.image(for: presentation, textFont: font)
    // Sit the chip on the text baseline, centered on the x-height.
    attachment.bounds = CGRect(x: 0, y: font.descender + (font.capHeight - size.height) / 2 + 1, width: size.width, height: size.height)
    attachment.allowsTextAttachmentView = false
  }

  // MARK: Storage to document

  /// The document the storage currently encodes. `styling: false` (plain mode) reads text only.
  /// `trailingBlock` describes an empty last paragraph that is not plain prose.
  static func doc(from storage: NSAttributedString, styling: Bool = true, trailingBlock: BlockAttrs? = nil) -> RichDoc {
    let string = storage.string as NSString
    var lines: [RichLine] = []
    var location = 0
    while true {
      let newline = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
      let end = newline.location == NSNotFound ? string.length : newline.location
      let range = NSRange(location: location, length: end - location)
      var block = styling && location < string.length ? storage.attribute(.t3Block, at: location, effectiveRange: nil) as? BlockAttrs : nil
      if styling && location >= string.length && range.length == 0 { block = trailingBlock }
      var inline = inlineNodes(in: storage, range: range, styling: styling)
      var kind = block?.kind ?? .paragraph
      switch kind {
      case .code:
        // Code is literal: a chip in it reads back as its source.
        let text = inline.map { node -> String in
          switch node {
          case .text(let text, _): text
          case .atom(let atom, _): atom.source
          }
        }.joined()
        inline = text.isEmpty ? [] : [.text(text, marks: [])]
      case .rule:
        // A rule owns no characters: text typed on its line replaces it.
        if !inline.isEmpty { kind = .paragraph }
      default: break
      }
      lines.append(RichLine(kind: kind, inline: inline))
      if newline.location == NSNotFound { break }
      location = end + 1
    }
    return RichDoc(lines: lines)
  }

  private static func inlineNodes(in storage: NSAttributedString, range: NSRange, styling: Bool) -> [RichInline] {
    guard range.length > 0 else { return [] }
    var nodes: [RichInline] = []
    storage.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
      let mask = styling ? (attributes[.t3Marks] as? Int ?? 0) : 0
      let marks = RichTextMark.marks(fromMask: mask)
      if let attachment = attributes[.attachment] as? ChipAttachment, storage.attributedSubstring(from: runRange).string == objectReplacement {
        nodes.append(.atom(attachment.atom, marks: marks))
      } else {
        nodes.append(.text(storage.attributedSubstring(from: runRange).string, marks: marks))
      }
    }
    return RichDoc.normalized(nodes)
  }
}
