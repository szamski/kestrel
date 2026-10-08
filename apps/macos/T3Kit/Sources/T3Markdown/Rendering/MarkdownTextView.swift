import AppKit

/// Loads the bytes of an image the Markdown refers to. The module only classifies sources;
/// the host decides how a workspace path becomes a signed asset request.
public typealias MarkdownImageLoader = @MainActor (MarkdownImage) async -> NSImage?

/// Non-editable TextKit 2 view for one message. Everything (paragraphs, list items, code,
/// quotes, table and chip attachments) lives in one text storage, so selection and copy
/// work across blocks.
public final class MarkdownTextView: NSTextView, NSTextViewDelegate {
  /// Called for every activated link (typed). Web links fall back to NSWorkspace when unset.
  public var onLink: ((MarkdownLink) -> Void)?
  public var imageLoader: MarkdownImageLoader?
  /// Called when something the view loaded changes its height (an image arriving).
  public var onContentSizeInvalidated: (() -> Void)?

  public private(set) var rendered: RenderedMarkdown?

  private let layoutDelegate = MarkdownLayoutDelegate()
  private var applied: [AppliedSegment] = []
  private var appliedThemeKey: UInt64?
  /// UTF-16 offset from which layout may be stale (nil: everything laid out).
  private var dirtyFrom: Int? = 0
  /// UTF-16 length of the text the last `setContent` replaced. Streaming keeps this at the tail.
  private(set) var lastReplacedLength = 0

  struct AppliedSegment: Equatable {
    var id: UInt64
    var trimmed: Bool
    var highlighted: Int
    var length: Int
  }

  public init() {
    let content = NSTextContentStorage()
    let layout = NSTextLayoutManager()
    content.addTextLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    layout.textContainer = container
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 10), textContainer: container)
    layout.delegate = layoutDelegate
    configure(container)
  }

  required init?(coder: NSCoder) { fatalError("MarkdownTextView is created in code") }

  private func configure(_ container: NSTextContainer) {
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    allowsUndo = false
    usesFontPanel = false
    isAutomaticLinkDetectionEnabled = false
    isHorizontallyResizable = false
    isVerticallyResizable = false
    textContainerInset = .zero
    container.lineFragmentPadding = 0
    container.widthTracksTextView = false
    container.heightTracksTextView = false
    // Colours come from the attributed string; only the pointer changes for links.
    linkTextAttributes = [.cursor: NSCursor.pointingHand]
    delegate = self
    setAccessibilityRole(.group)
  }

  // MARK: content

  /// The raw Markdown of the whole message ("Copy as Markdown").
  public var markdown: String { rendered?.source ?? "" }

  /// Shows `rendered`, reusing every leading segment that did not change. Streaming appends
  /// therefore replace only the tail; selection inside the reused part survives.
  public func setContent(_ rendered: RenderedMarkdown) {
    guard let storage = textContentStorage?.textStorage else { return }
    self.rendered = rendered

    let segments = rendered.segments
    var next: [AppliedSegment] = []
    var strings: [NSAttributedString] = []
    for (i, seg) in segments.enumerated() {
      let isLast = i == segments.count - 1
      let text = isLast ? Self.trimmingTail(seg.text) : seg.text
      strings.append(text)
      next.append(AppliedSegment(id: seg.id, trimmed: isLast, highlighted: seg.highlighted, length: text.length))
    }
    if appliedThemeKey != rendered.themeKey { applied = [] }
    appliedThemeKey = rendered.themeKey

    var keep = 0
    while keep < min(applied.count, next.count), applied[keep].id == next[keep].id, applied[keep].trimmed == next[keep].trimmed {
      keep += 1
    }
    var base = 0
    var firstChanged = Int.max
    lastReplacedLength = 0
    textContentStorage?.performEditingTransaction {
      // Same text, new colours (highlighting finished): restyle in place so the selection stays.
      for i in 0..<keep {
        if applied[i].highlighted != next[i].highlighted {
          strings[i].enumerateAttributes(in: NSRange(location: 0, length: strings[i].length)) { attrs, range, _ in
            storage.setAttributes(attrs, range: NSRange(location: base + range.location, length: range.length))
          }
          firstChanged = min(firstChanged, base)
        }
        base += applied[i].length
      }
      if keep < next.count || keep < applied.count {
        let tail = NSMutableAttributedString()
        for s in strings[keep...] { tail.append(s) }
        lastReplacedLength = tail.length
        storage.replaceCharacters(in: NSRange(location: base, length: storage.length - base), with: tail)
        firstChanged = min(firstChanged, base)
      }
    }
    applied = next
    if firstChanged != Int.max { dirtyFrom = min(dirtyFrom ?? firstChanged, firstChanged) }
    loadImages(rendered.images)
    invalidateIntrinsicContentSize()
  }

  /// The last paragraph of a message must not leave a gap (nor an empty trailing line).
  static func trimmingTail(_ text: NSAttributedString) -> NSAttributedString {
    guard text.length > 0 else { return text }
    let m = NSMutableAttributedString(attributedString: text)
    m.deleteCharacters(in: NSRange(location: m.length - 1, length: 1))
    guard m.length > 0 else { return m }
    var effective = NSRange()
    let last = NSRange(location: m.length - 1, length: 1)
    if let style = m.attribute(.paragraphStyle, at: last.location, effectiveRange: &effective) as? NSParagraphStyle {
      let copy = style.mutableCopy() as! NSMutableParagraphStyle
      let decoration = m.attribute(.t3Decoration, at: last.location, effectiveRange: nil) as? ParagraphDecoration
      // A box still needs its bottom padding inside the fragment to draw into.
      copy.paragraphSpacing = decoration?.box.map { $0.roundBottom ? $0.padBottom : 0 } ?? 0
      m.addAttribute(.paragraphStyle, value: copy, range: effective)
    }
    return m
  }

  // MARK: width and height

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncContainerWidth()
  }

  private func syncContainerWidth() {
    guard let container = textContainer else { return }
    let width = max(bounds.width, 1)
    if container.size.width != width {
      container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
      dirtyFrom = 0
    }
  }

  /// Height of the content laid out at `width`.
  public func fittingHeight(forWidth width: CGFloat) -> CGFloat {
    guard let layout = textLayoutManager else { return 0 }
    let w = max(width.rounded(.down), 1)
    if abs(frame.width - w) > 0.01 { setFrameSize(NSSize(width: w, height: frame.height)) }
    // Only text from the first edit onward can be stale, so lay out just that range: a
    // streaming tail edit costs the tail, not the whole message. (Asking for the last
    // fragment alone is not enough; it would report an estimated position.)
    if let from = dirtyFrom, let content = textContentStorage,
      let start = content.location(layout.documentRange.location, offsetBy: from),
      let stale = NSTextRange(location: start, end: layout.documentRange.endLocation)
    {
      layout.ensureLayout(for: stale)
    }
    dirtyFrom = nil
    var bottom: CGFloat = 0
    layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) {
      bottom = $0.layoutFragmentFrame.maxY
      return false
    }
    return ceil(bottom) + textContainerInset.height * 2
  }

  public override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: bounds.width))
  }

  // MARK: images

  private func loadImages(_ images: [MarkdownImage]) {
    guard let loader = imageLoader else { return }
    let store = MarkdownImageStore.shared
    for image in images where store.beginLoading(image) {
      Task { @MainActor [weak self] in
        let result = await loader(image)
        store.finish(image, result: result)
        guard let self else { return }
        // Attachments re-ask for their size, which now comes from the picture.
        self.dirtyFrom = 0
        self.textLayoutManager?.invalidateLayout(for: self.textLayoutManager!.documentRange)
        self.needsDisplay = true
        self.invalidateIntrinsicContentSize()
        self.onContentSizeInvalidated?()
      }
    }
  }

  // MARK: links

  public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    guard let action = MarkdownLinkCoding.decode(link) else { return false }
    activate(action)
    return true
  }

  private func activate(_ action: MarkdownLinkCoding.Action) {
    switch action {
    case .toggleDetails(let key, let open):
      toggleDetails(key: key, open: !open)
    case .link(let link):
      if let onLink {
        onLink(link)
      } else if case .web(let url) = link {
        NSWorkspace.shared.open(url)
      }
    }
  }

  /// Expands or collapses one `<details>`: the choice is remembered (so it survives row
  /// recycling), the message re-renders with only the changed tail replaced, and the host is
  /// told the height changed.
  func toggleDetails(key: UInt64, open: Bool) {
    MarkdownDetailsStore.shared.set(key, open: open)
    guard let rendered else { return }
    setContent(MarkdownRenderer.shared.render(rendered.document, theme: rendered.theme))
    onContentSizeInvalidated?()
  }

  // MARK: mouse

  public override func mouseDown(with event: NSEvent) {
    clearSelections(except: self)
    let point = convert(event.locationInWindow, from: nil)
    if let (content, rect) = attachmentContent(at: point), let table = content as? TableContent {
      let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
      if let link = table.link(at: local), let action = MarkdownLinkCoding.decode(link) {
        activate(action)
        return
      }
    }
    super.mouseDown(with: event)
  }

  // MARK: code blocks

  /// One view per code block position in the text (UTF-16 offset of its attachment). A
  /// rebuilt block (streaming delta, finished highlighting) finds its old view here.
  private var codeViewPool: [Int: CodeBlockView] = [:]
  /// Code block views this text view ever built. For tests: streaming and highlighting update views, not rebuild them.
  private(set) var codeViewsCreated = 0

  func codeBlockView(for content: CodeBlockContent, at offset: Int) -> CodeBlockView {
    if let view = codeViewPool[offset] {
      view.update(to: content)
      return view
    }
    if codeViewPool.count > 64 { codeViewPool = codeViewPool.filter { $0.value.superview != nil } }
    let view = CodeBlockView(content: content)
    codeViewsCreated += 1
    codeViewPool[offset] = view
    return view
  }

  /// The live views of the code blocks currently in the viewport.
  var codeBlockViews: [CodeBlockView] {
    var found: [CodeBlockView] = []
    func collect(_ view: NSView) {
      for sub in view.subviews {
        if let block = sub as? CodeBlockView { found.append(block) } else { collect(sub) }
      }
    }
    collect(self)
    return found
  }

  /// Only one selection is shown: the message's, or the one inside a code block.
  func clearSelections(except keep: NSTextView) {
    if keep !== self { setSelectedRange(NSRange(location: 0, length: 0)) }
    for block in codeBlockViews where block.textView !== keep { block.clearSelection() }
  }

  /// The drawable attachment under `point` and its rect in view coordinates.
  func attachmentContent(at point: CGPoint) -> (DrawableContent, CGRect)? {
    guard let layout = textLayoutManager, let fragment = layout.textLayoutFragment(for: point),
      let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
      let attachment = paragraph.attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? ContentAttachment,
      let line = fragment.textLineFragments.first
    else { return nil }
    let size = attachment.laidOutSize
    let frame = fragment.layoutFragmentFrame
    let origin = CGPoint(
      x: frame.minX + line.typographicBounds.minX + line.glyphOrigin.x,
      y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y - size.height)
    let rect = CGRect(origin: origin, size: size)
    return rect.contains(point) ? (attachment.content, rect) : nil
  }

  // MARK: copy

  /// Plain text of the selection: attachments, list markers and rules contribute their
  /// plain form, code-block chrome is skipped, line separators become newlines.
  public func selectedPlainText() -> String? {
    guard let storage = textContentStorage?.textStorage else { return nil }
    let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
    guard !ranges.isEmpty else { return nil }
    return ranges.map { Self.plainText(of: storage, in: $0) }.joined(separator: "\n")
  }

  static func plainText(of text: NSAttributedString, in range: NSRange) -> String {
    var out = ""
    let ns = text.string as NSString
    text.enumerateAttributes(in: range, options: []) { attrs, r, _ in
      if attrs[.t3Chrome] != nil { return }
      if let replacement = attrs[.t3PlainText] as? String {
        out += replacement
        return
      }
      out += ns.substring(with: r).replacingOccurrences(of: "\u{2028}", with: "\n")
        .replacingOccurrences(of: "\u{200B}", with: "")
    }
    return out
  }

  /// Markdown for the selection, rebuilt from what is on screen: emphasis, strike, inline
  /// code, links, chips, list markers, tables and code blocks round-trip; headings, quotes and
  /// alert titles come out as plain text (the attributed text keeps no source positions).
  public func selectedMarkdown() -> String? {
    guard let storage = textContentStorage?.textStorage else { return nil }
    let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
    guard !ranges.isEmpty else { return nil }
    return ranges.map { Self.markdown(of: storage, in: $0) }.joined(separator: "\n")
  }

  static func markdown(of text: NSAttributedString, in range: NSRange) -> String {
    var out = ""
    let ns = text.string as NSString
    text.enumerateAttributes(in: range, options: []) { attrs, r, _ in
      if attrs[.t3Chrome] != nil { return }
      if let block = attrs[.attachment] as? CodeBlockAttachment {
        out += "```\(block.content.language ?? "")\n\(block.content.code)\n```"
        return
      }
      if let replacement = attrs[.t3PlainText] as? String {
        out += replacement == "\u{2022} " ? "- " : replacement
        return
      }
      var run = ns.substring(with: r).replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{200B}", with: "")
      guard !run.isEmpty, run != "\n" else { out += run; return }
      let trailing = run.hasSuffix("\n") ? "\n" : ""
      if !trailing.isEmpty { run.removeLast() }
      let font = attrs[.font] as? NSFont
      let traits = font?.fontDescriptor.symbolicTraits ?? []
      if traits.contains(.monoSpace) {
        run = "`\(run)`"
      } else {
        if traits.contains(.bold) { run = "**\(run)**" }
        if traits.contains(.italic) { run = "*\(run)*" }
        if attrs[.strikethroughStyle] != nil { run = "~~\(run)~~" }
      }
      if let link = attrs[.link], let action = MarkdownLinkCoding.decode(link), case .link(let target) = action {
        switch target {
        case .web(let url): run = "[\(run)](\(url.absoluteString))"
        case .file(let file): run = "[\(run)](\(file.pathWithPosition))"
        default: break
        }
      }
      out += run + trailing
    }
    return out
  }

  public override func copy(_ sender: Any?) {
    guard let text = selectedPlainText() else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard let text = selectedPlainText() else { return false }
    pboard.clearContents()
    return pboard.setString(text, forType: .string)
  }

  /// Copies the selection as Markdown, or the whole message's source when nothing is selected.
  @objc public func copyMarkdown(_ sender: Any? = nil) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(selectedMarkdown() ?? markdown, forType: .string)
  }

  public override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    let item = NSMenuItem(title: selectedMarkdown() == nil ? "Copy as Markdown" : "Copy Selection as Markdown", action: #selector(copyMarkdown(_:)), keyEquivalent: "")
    item.target = self
    menu.addItem(.separator())
    menu.addItem(item)
    return menu
  }

}
