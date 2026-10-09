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
/// The storage holds exactly the "flat" coordinate space of `RichDocMap`: paragraphs joined by one
/// newline, a chip as one U+FFFC attachment character, style markers and task checkboxes carried as
/// attributes rather than characters. So an NSRange offset in the storage *is* a flat offset.
@MainActor
enum EditorContent {
  static let objectReplacement = "\u{FFFC}"

  /// A loaded document: its attributed string plus the task attributes of an *empty last
  /// paragraph*, which has no character to carry them (the text view keeps them as typing attributes).
  struct Loaded {
    var string: NSAttributedString
    var trailingTask: TaskAttrsBox?
  }

  static func attributedString(for doc: RichDoc, style: ComposerEditorStyle, presentation: ChipPresentationProvider) -> NSAttributedString {
    load(doc, style: style, presentation: presentation).string
  }

  static func load(_ doc: RichDoc, style: ComposerEditorStyle, presentation: ChipPresentationProvider) -> Loaded {
    let output = NSMutableAttributedString()
    var firstParagraph = true
    func beginParagraph() {
      if !firstParagraph { output.append(NSAttributedString(string: "\n", attributes: plainAttributes(style: style, task: nil, mask: 0))) }
      firstParagraph = false
    }
    func appendInline(_ inline: [RichInline], task: TaskAttrsBox?) {
      for node in inline {
        switch node {
        case .text(let text, let marks):
          output.append(NSAttributedString(string: text, attributes: plainAttributes(style: style, task: task, mask: RichTextMark.mask(marks))))
        case .atom(let atom, let marks):
          output.append(chipString(atom, marks: RichTextMark.mask(marks), style: style, presentation: presentation, task: task))
        }
      }
    }
    func appendTask(_ item: RichTaskItem) {
      beginParagraph()
      let task = TaskAttrsBox(checked: item.checked, indent: item.indent, markerSpace: item.markerSpace, contentSpace: item.contentSpace)
      let start = output.length
      appendInline(item.content, task: task)
      if output.length == start { output.append(NSAttributedString(string: "", attributes: nil)) }
      for child in item.children { appendTask(child) }
    }
    for block in doc.blocks {
      switch block {
      case .paragraph(let inline):
        beginParagraph()
        appendInline(inline, task: nil)
      case .taskList(let items):
        for item in items { appendTask(item) }
      }
    }
    applyTaskAttributes(to: output, doc: doc, style: style)
    var trailing: TaskAttrsBox?
    if let last = lastTaskParagraph(doc), (output.string as NSString).length == 0 || output.string.hasSuffix("\n") {
      trailing = last
    }
    return Loaded(string: output, trailingTask: trailing)
  }

  /// The task attributes of the document's last paragraph when it is a task item.
  private static func lastTaskParagraph(_ doc: RichDoc) -> TaskAttrsBox? {
    guard case .taskList(let items)? = doc.blocks.last else { return nil }
    var item = items.last
    while let current = item, let child = current.children.last { item = child }
    guard let item, item.content.isEmpty else { return nil }
    return TaskAttrsBox(checked: item.checked, indent: item.indent, markerSpace: item.markerSpace, contentSpace: item.contentSpace)
  }

  /// Task attributes cover the whole paragraph including its newline, even when it is empty, so
  /// they are applied after the text exists.
  private static func applyTaskAttributes(to output: NSMutableAttributedString, doc: RichDoc, style: ComposerEditorStyle) {
    var tasks: [TaskAttrsBox?] = []
    func collect(_ item: RichTaskItem) {
      tasks.append(TaskAttrsBox(checked: item.checked, indent: item.indent, markerSpace: item.markerSpace, contentSpace: item.contentSpace))
      item.children.forEach(collect)
    }
    for block in doc.blocks {
      switch block {
      case .paragraph: tasks.append(nil)
      case .taskList(let items): items.forEach(collect)
      }
    }
    let string = output.string as NSString
    var location = 0
    for task in tasks {
      let lineEnd = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
      let end = lineEnd.location == NSNotFound ? string.length : lineEnd.location
      let range = NSRange(location: location, length: min(string.length, end + (lineEnd.location == NSNotFound ? 0 : 1)) - location)
      if let task, range.length > 0 {
        output.addAttribute(.t3Task, value: task, range: range)
        output.addAttribute(.paragraphStyle, value: style.paragraphStyle(task: task), range: range)
      } else {
        output.addAttribute(.paragraphStyle, value: style.paragraphStyle(task: nil), range: range.length > 0 ? range : NSRange(location: 0, length: 0))
      }
      location = end + 1
    }
  }

  static func plainAttributes(style: ComposerEditorStyle, task: TaskAttrsBox?, mask: Int) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: style.font(for: mask), .foregroundColor: style.textColor ?? NSColor.labelColor, .t3Marks: mask, .paragraphStyle: style.paragraphStyle(task: task),
    ]
    if mask & RichTextMark.strike.bit != 0 { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if mask & RichTextMark.code.bit != 0 { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
    if let task { attributes[.t3Task] = task }
    return attributes
  }

  static func chipString(_ atom: RichAtom, marks: Int, style: ComposerEditorStyle, presentation: ChipPresentationProvider, task: TaskAttrsBox?) -> NSAttributedString {
    let attachment = ChipAttachment(atom: atom)
    configure(attachment, presentation: presentation(atom), style: style)
    var attributes = plainAttributes(style: style, task: task, mask: marks)
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
  /// `trailingTask` describes an empty last paragraph that is a task item.
  static func doc(from storage: NSAttributedString, styling: Bool = true, trailingTask: TaskAttrsBox? = nil) -> RichDoc {
    let string = storage.string as NSString
    var blocks: [RichBlock] = []
    var location = 0
    while true {
      let newline = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
      let end = newline.location == NSNotFound ? string.length : newline.location
      let range = NSRange(location: location, length: end - location)
      var task = styling && location < string.length ? storage.attribute(.t3Task, at: location, effectiveRange: nil) as? TaskAttrsBox : nil
      if styling && location >= string.length && range.length == 0 { task = trailingTask }
      let inline = inlineNodes(in: storage, range: range, styling: styling)
      if let task {
        blocks.append(.taskList([RichTaskItem(checked: task.checked, indent: task.indent, markerSpace: task.markerSpace, contentSpace: task.contentSpace, content: inline)]))
      } else {
        blocks.append(.paragraph(inline))
      }
      if newline.location == NSNotFound { break }
      location = end + 1
    }
    return RichDoc(blocks: blocks)
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
