import AppKit

/// A fenced code block: sizes itself arithmetically (header + lines × a fixed line height), so
/// layout and the cached row height never depend on a live view, and builds its text lazily
/// for the blocks that actually scroll into view.
final class CodeBlockContent: @unchecked Sendable {
  let id: String
  let language: String?
  let code: String
  let spans: [HighlightSpan]
  let theme: MarkdownTheme
  let lineCount: Int
  let lineHeight: CGFloat
  let headerHeight: CGFloat
  let bottomPad: CGFloat
  let labelFont: NSFont

  init(id: String, language: String?, code: String, spans: [HighlightSpan], theme: MarkdownTheme) {
    self.id = id
    self.language = language
    self.code = code
    self.spans = spans
    self.theme = theme
    lineCount = 1 + code.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    let font = theme.codeFont
    lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
    labelFont = NSFont.systemFont(ofSize: theme.bodyFont.pointSize - 2.5, weight: .medium)
    headerHeight = ceil(labelFont.ascender - labelFont.descender) + ceil(theme.codePadding * 0.7) + 4
    bottomPad = ceil(theme.codePadding * 0.7)
  }

  var pad: CGFloat { theme.codePadding }
  var bodyHeight: CGFloat { CGFloat(lineCount) * lineHeight }
  var height: CGFloat { headerHeight + bodyHeight + bottomPad }
  var label: String { language ?? "text" }

  /// Lines per paragraph in the text view. TextKit lays out a paragraph as a unit, so one
  /// paragraph for 2k lines would lay all of them out, and one paragraph per line makes it
  /// enumerate 2k elements just to size the view; paragraphs of this many lines keep both small.
  static let linesPerParagraph = 50

  /// `code` as the text view stores it: the same characters, but a line break is U+2028 inside
  /// a paragraph and "\n" after every `linesPerParagraph`-th line. `firstLine` is the index of
  /// the line `code` starts in, so an appended tail continues the pattern.
  static func storageText(_ code: String, firstLine: Int = 0) -> String {
    var out = ""
    out.reserveCapacity(code.utf8.count)
    var line = firstLine
    for ch in code {
      if ch == "\n" {
        line += 1
        out.append(line % linesPerParagraph == 0 ? "\n" : "\u{2028}")
      } else {
        out.append(ch)
      }
    }
    return out
  }

  /// Plain code from text-view text (copying).
  static func code(fromStorageText text: String) -> String { text.replacingOccurrences(of: "\u{2028}", with: "\n") }

  /// Attributes of every code character: one fixed line height (so a block is exactly
  /// `lineCount × lineHeight` tall), never wrapped, tab stops of four columns.
  var bodyAttributes: [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    style.lineBreakMode = .byClipping
    style.defaultTabInterval = spaceWidth * 4
    style.tabStops = []
    return [.font: theme.codeFont, .foregroundColor: theme.codeForeground, .paragraphStyle: style]
  }

  /// The code as paragraphs of one fixed height, never wrapped, tokens coloured.
  func bodyText() -> NSAttributedString {
    let text = NSMutableAttributedString(string: Self.storageText(code), attributes: bodyAttributes)
    applySpans(to: text, offset: 0)
    return text
  }

  /// Token colours over `text`, which holds the code from UTF-16 `offset` on.
  func applySpans(to text: NSMutableAttributedString, offset: Int) {
    for span in spans {
      let range = NSIntersectionRange(
        NSRange(location: span.location - offset, length: span.length), NSRange(location: 0, length: text.length))
      if range.length > 0 { text.addAttribute(.foregroundColor, value: theme.color(for: span.role), range: range) }
    }
  }

  private var spaceWidth: CGFloat { ("0" as NSString).size(withAttributes: [.font: theme.codeFont]).width }

  /// Width of the longest line plus the padding on both sides.
  private(set) lazy var naturalWidth: CGFloat = width(fromUTF8: 0)

  /// Same, for the lines that start at or after UTF-8 `offset`: a streaming block only
  /// re-measures what was appended. ASCII lines are columns × advance (the font is
  /// monospaced); only lines with other characters are measured.
  func width(fromUTF8 offset: Int) -> CGFloat {
    let advance = spaceWidth
    var columns = 0
    var measured: CGFloat = 0
    var utf8 = code
    utf8.withUTF8 { bytes in
      var start = min(offset, bytes.count)
      var column = 0
      var ascii = true
      func endLine(at end: Int) {
        if ascii {
          columns = max(columns, column)
        } else {
          let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
          measured = max(measured, (line as NSString).size(withAttributes: [.font: theme.codeFont]).width)
        }
        start = end + 1
        column = 0
        ascii = true
      }
      var i = start
      while i < bytes.count {
        let byte = bytes[i]
        if byte == 10 {
          endLine(at: i)
        } else {
          if byte >= 0x80 { ascii = false }
          column = byte == 9 ? (column / 4 + 1) * 4 : column + 1
        }
        i += 1
      }
      endLine(at: bytes.count)
    }
    return ceil(max(CGFloat(columns) * advance, measured)) + pad * 2
  }
}

/// TextKit 2 attachment whose view is a self-contained code block. The text view treats it
/// as one character: whole-message selection and copy include the full code through
/// `.t3PlainText`, while the block scrolls sideways and selects its own text.
final class CodeBlockAttachment: NSTextAttachment {
  let content: CodeBlockContent
  /// Where the block starts (list item, quote): the line offers the whole container width,
  /// the paragraph's head indent is applied afterwards.
  let indent: CGFloat

  /// The attachment character's font. The line always reaches its descent below the baseline;
  /// at one point that is a fraction of a point, which the bounds give up (`descender` is
  /// negative), so the line is exactly `content.height` tall.
  nonisolated(unsafe) static let anchorFont = NSFont.systemFont(ofSize: 1)

  init(content: CodeBlockContent, indent: CGFloat) {
    self.content = content
    self.indent = indent
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { fatalError("not archived") }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
    proposedLineFragment: CGRect, position: CGPoint
  ) -> CGRect {
    CGRect(x: 0, y: 0, width: max(proposedLineFragment.width - indent, 40), height: content.height + Self.anchorFont.descender)
  }

  override func viewProvider(
    for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    CodeBlockViewProvider(
      textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager,
      location: location)
  }
}

final class CodeBlockViewProvider: NSTextAttachmentViewProvider {
  private weak var host: NSView?
  private let offset: Int

  override init(
    textAttachment: NSTextAttachment, parentView: NSView?, textLayoutManager: NSTextLayoutManager?,
    location: any NSTextLocation
  ) {
    host = parentView
    offset = textLayoutManager.map { $0.offset(from: $0.documentRange.location, to: location) } ?? 0
    super.init(
      textAttachment: textAttachment, parentView: parentView, textLayoutManager: textLayoutManager, location: location)
  }

  /// The block's view comes from its message view, which keeps one per position in the text:
  /// a streaming delta or finished highlighting hands the same view the new content, so the
  /// code is appended or restyled in place and the horizontal scroll stays where it is.
  override func loadView() {
    guard let attachment = textAttachment as? CodeBlockAttachment else { return }
    let content = attachment.content
    let offset = offset
    view = MainActor.assumeIsolated { [host] in
      if let owner = host as? MarkdownTextView { return owner.codeBlockView(for: content, at: offset) }
      return CodeBlockView(content: content)
    }
  }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
    proposedLineFragment: CGRect, position: CGPoint
  ) -> CGRect {
    guard let attachment = textAttachment as? CodeBlockAttachment else { return .zero }
    return attachment.attachmentBounds(
      for: attributes, location: location, textContainer: textContainer, proposedLineFragment: proposedLineFragment,
      position: position)
  }
}

/// Header (language, Copy) over a horizontally scrolling, selectable, never-wrapping body.
@MainActor
final class CodeBlockView: NSView {
  private(set) var content: CodeBlockContent
  let scrollView = CodeScrollView()
  let textView: CodeTextView
  private let label = NSTextField(labelWithString: "")
  private let copyButton = NSButton()
  private var copiedTask: Task<Void, Never>?
  /// Width of the scrollable code (padding included), kept up to date incrementally.
  private var codeWidth: CGFloat = 0

  init(content: CodeBlockContent) {
    self.content = content
    textView = CodeTextView(usingTextLayoutManager: true)
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: content.height))
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.masksToBounds = true
    setAccessibilityRole(.group)

    label.autoresizingMask = [.maxXMargin]
    addSubview(label)

    copyButton.isBordered = false
    copyButton.target = self
    copyButton.action = #selector(copyCode)
    copyButton.toolTip = "Copy code"
    copyButton.setAccessibilityLabel("Copy code")
    copyButton.autoresizingMask = [.minXMargin]
    addSubview(copyButton)

    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = false
    textView.allowsUndo = false
    textView.usesFontPanel = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = false
    if let container = textView.textContainer {
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      container.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
    }

    // An overlay scroller floats over the bottom padding instead of taking space of its own.
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.verticalScrollElasticity = .none
    scrollView.horizontalScrollElasticity = .allowed
    scrollView.autoresizingMask = [.width]
    scrollView.documentView = textView
    addSubview(scrollView)

    applyChrome()
    textView.textContainerInset = NSSize(width: content.pad, height: 0)
    textView.textStorage?.setAttributedString(
      NSAttributedString(string: CodeBlockContent.storageText(content.code), attributes: content.bodyAttributes))
    codeWidth = content.naturalWidth
    layoutBlock()
    if !content.spans.isEmpty { restyle() }
  }

  deinit { stylingTask?.cancel() }

  required init?(coder: NSCoder) { fatalError("not archived") }

  override var isFlipped: Bool { true }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutBlock()
  }

  /// Width of the scrollable code (at least the visible width).
  var documentWidth: CGFloat { textView.frame.width }

  private func applyChrome() {
    let theme = content.theme
    layer?.backgroundColor = theme.codeBackground.cgColor
    layer?.borderColor = theme.border.cgColor
    layer?.cornerRadius = theme.cornerRadius
    setAccessibilityLabel("Code block, \(content.label)")
    textView.setAccessibilityLabel("Code, \(content.label)")
    label.attributedStringValue = NSAttributedString(
      string: content.label, attributes: [.font: content.labelFont, .foregroundColor: theme.muted])
    label.sizeToFit()
    label.frame.origin = NSPoint(x: content.pad, y: ceil(content.pad * 0.7))
    setCopyTitle(MarkdownAttributedBuilder.copyLabel)
  }

  private func layoutBlock() {
    let width = bounds.width
    scrollView.frame = NSRect(x: 0, y: content.headerHeight, width: width, height: content.bodyHeight + content.bottomPad)
    textView.frame = NSRect(x: 0, y: 0, width: max(codeWidth, width), height: content.bodyHeight)
    copyButton.sizeToFit()
    copyButton.frame.origin = NSPoint(x: width - copyButton.frame.width - content.pad * 0.6, y: ceil(content.pad * 0.7) - 1)
  }

  /// Shows `new` in this view. The same code with new colours is restyled in place, code that
  /// only grew gets just its new tail appended and measured, anything else is replaced; the
  /// horizontal scroll offset survives all three (clamped to the new width).
  func update(to new: CodeBlockContent) {
    let old = content
    content = new
    guard let storage = textView.textStorage else { return }
    let sameLook = old.theme == new.theme && old.language == new.language
    if !sameLook { applyChrome() }
    if sameLook, new.code == old.code {
      guard new.spans != old.spans else { return }
      restyle()
    } else if sameLook, new.code.hasPrefix(old.code) {
      let oldLength = (old.code as NSString).length
      storage.append(
        NSAttributedString(
          string: CodeBlockContent.storageText((new.code as NSString).substring(from: oldLength), firstLine: old.lineCount - 1),
          attributes: new.bodyAttributes))
      if !new.spans.isEmpty || !old.spans.isEmpty { restyle() }
      let lastLine = old.code.utf8.lastIndex(of: 10).map { old.code.utf8.distance(from: old.code.utf8.startIndex, to: $0) + 1 } ?? 0
      codeWidth = max(codeWidth, new.width(fromUTF8: lastLine))
    } else {
      storage.setAttributedString(
        NSAttributedString(string: CodeBlockContent.storageText(new.code), attributes: new.bodyAttributes))
      codeWidth = new.naturalWidth
      if !new.spans.isEmpty { restyle() }
    }
    layoutBlock()
    let maxX = max(documentWidth - bounds.width, 0)
    if scrollView.contentView.bounds.origin.x > maxX { scroll(toX: maxX) }
  }

  // MARK: colouring

  /// Colours are applied to the text storage in slices of about 75 lines, the ones around the
  /// visible lines first, one slice per run-loop turn: TextKit's cost is per attribute run, so
  /// colouring a 2k-line block in one go would hold the main thread for about 20 ms.
  private static let sliceLength = 6_000
  private var unstyled: Set<Int> = []
  private var stylingTask: Task<Void, Never>?

  private func restyle() {
    guard let storage = textView.textStorage else { return }
    unstyled = Set(0..<((storage.length + Self.sliceLength - 1) / Self.sliceLength))
    guard stylingTask == nil else { return }
    stylingTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled, let next = self.nextSlice() {
        self.style(slice: next)
        try? await Task.sleep(for: .milliseconds(1))
      }
      self?.stylingTask = nil
    }
    // The first slice is ready before the first frame.
    if let first = nextSlice() { style(slice: first) }
  }

  /// The unstyled slice closest to the visible lines.
  private func nextSlice() -> Int? {
    guard !unstyled.isEmpty else { return nil }
    let visibleTop = textView.visibleRect.minY
    let length = max(textView.textStorage?.length ?? 1, 1)
    let estimate = Int(visibleTop / max(content.bodyHeight, 1) * CGFloat(length)) / Self.sliceLength
    return unstyled.min { abs($0 - estimate) < abs($1 - estimate) }
  }

  private func style(slice: Int) {
    unstyled.remove(slice)
    guard let storage = textView.textStorage else { return }
    let start = slice * Self.sliceLength
    guard start < storage.length else { return }
    let range = NSRange(location: start, length: min(Self.sliceLength, storage.length - start))
    let theme = content.theme
    let spans = content.spans
    // First span that ends after the slice starts (spans are flat and sorted).
    var low = 0
    var high = spans.count
    while low < high {
      let mid = (low + high) / 2
      if spans[mid].location + spans[mid].length <= range.location { low = mid + 1 } else { high = mid }
    }
    storage.beginEditing()
    storage.addAttribute(.foregroundColor, value: theme.codeForeground, range: range)
    var index = low
    while index < spans.count, spans[index].location < range.upperBound {
      let part = NSIntersectionRange(NSRange(location: spans[index].location, length: spans[index].length), range)
      if part.length > 0 { storage.addAttribute(.foregroundColor, value: theme.color(for: spans[index].role), range: part) }
      index += 1
    }
    storage.endEditing()
  }

  /// Slices still waiting for their colours. For tests.
  var unstyledSlices: Int { unstyled.count }

  /// Scrolls the code horizontally (tests, screenshots).
  func scroll(toX x: CGFloat) {
    scrollView.contentView.scroll(to: NSPoint(x: min(max(x, 0), max(documentWidth - bounds.width, 0)), y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func clearSelection() { textView.setSelectedRange(NSRange(location: 0, length: 0)) }

  private func setCopyTitle(_ title: String) {
    copyButton.attributedTitle = NSAttributedString(
      string: title.trimmingCharacters(in: .whitespaces),
      attributes: [.font: content.labelFont, .foregroundColor: content.theme.muted])
  }

  @objc func copyCode() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(content.code, forType: .string)
    copiedTask?.cancel()
    setCopyTitle(MarkdownAttributedBuilder.copiedLabel)
    layoutBlock()
    copiedTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled, let self else { return }
      setCopyTitle(MarkdownAttributedBuilder.copyLabel)
      layoutBlock()
    }
  }
}

/// Vertical gestures belong to the timeline: a gesture that starts mostly vertical is passed
/// up, so scrolling a long chat is never caught by a code block under the pointer.
final class CodeScrollView: NSScrollView {
  private var passesUp = false

  override func scrollWheel(with event: NSEvent) {
    if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
      passesUp = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
    }
    if passesUp {
      nextResponder?.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }
}

/// Selecting inside a block starts a selection of its own, so the message's own selection is
/// dropped first (two highlighted selections would look like one).
final class CodeTextView: NSTextView {
  /// TextKit 2 lays out the text view's visible rect. A host that sizes a row to its content
  /// (nothing clips it) would make a 2k-line block entirely visible, so the window's content
  /// area bounds it too.
  override var visibleRect: NSRect {
    let rect = super.visibleRect
    // Before it has a window (while it is being built and sized) only a screenful at the top counts.
    guard let content = window?.contentView else { return rect.intersection(NSRect(x: 0, y: 0, width: rect.maxX, height: 800)) }
    return rect.intersection(convert(content.bounds, from: content))
  }

  /// Copies the code, with real newlines.
  private var selectedCode: String? {
    let range = selectedRange()
    guard range.length > 0 else { return nil }
    return CodeBlockContent.code(fromStorageText: (string as NSString).substring(with: range))
  }

  override func copy(_ sender: Any?) {
    guard let code = selectedCode else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
  }

  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let code = selectedCode else { return false }
    pboard.clearContents()
    return pboard.setString(code, forType: .string)
  }

  override func mouseDown(with event: NSEvent) {
    var view = superview
    while let current = view, !(current is MarkdownTextView) { view = current.superview }
    (view as? MarkdownTextView)?.clearSelections(except: self)
    super.mouseDown(with: event)
  }
}
