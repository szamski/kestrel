import AppKit
import SwiftUI
import T3Markdown

/// Source text with a line-number gutter: read-only with selection, or editable (native undo, find bar) while a
/// file is being edited. Syntax colours come from the same highlight.js engine as chat code blocks.
struct SourceView: NSViewRepresentable {
  @Binding var text: String
  let path: String
  let isEditable: Bool
  let wordWrap: Bool
  /// 1-based inclusive lines to scroll to and mark; `token` makes the same lines scroll again.
  let reveal: FileReveal?
  /// Called once the reveal was applied, so it is not repeated when the view is recreated.
  let onRevealed: () -> Void
  /// The selected lines, nil when the selection is empty.
  let onSelection: (_ lines: ClosedRange<Int>?) -> Void
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    // TextKit 1 on purpose: the gutter reads line fragments from the layout manager.
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    layout.allowsNonContiguousLayout = true
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    layout.addTextContainer(container)
    let textView = NSTextView(frame: .zero, textContainer: container)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.isRichText = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.delegate = context.coordinator
    textView.setAccessibilityLabel("Source of \(FileLogic.basename(path))")

    let scroll = NSScrollView()
    scroll.documentView = textView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.drawsBackground = true
    let ruler = LineNumberRuler(scrollView: scroll, textView: textView)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    context.coordinator.textView = textView
    context.coordinator.ruler = ruler
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    guard let textView = coordinator.textView else { return }
    coordinator.parent = self
    let theme: MarkdownTheme = colorScheme == .dark ? .dark : .light
    let appearanceChanged = coordinator.appliedTheme != theme
    coordinator.appliedTheme = theme
    scroll.backgroundColor = theme.codeBackground
    textView.backgroundColor = theme.codeBackground
    textView.insertionPointColor = theme.codeForeground
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.allowsUndo = isEditable
    textView.font = theme.codeFont
    textView.textColor = theme.codeForeground
    coordinator.ruler?.apply(theme: theme)

    if textView.string != text {
      coordinator.isApplying = true
      let selection = textView.selectedRange()
      textView.string = text
      textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
      coordinator.isApplying = false
      coordinator.ruler?.textChanged()
      coordinator.highlight()
    } else if appearanceChanged {
      coordinator.highlight()
    }

    if coordinator.wrapApplied != wordWrap {
      coordinator.wrapApplied = wordWrap
      textView.textContainer?.widthTracksTextView = wordWrap
      textView.isHorizontallyResizable = !wordWrap
      textView.textContainer?.containerSize = NSSize(width: wordWrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      scroll.hasHorizontalScroller = !wordWrap
    }

    if let reveal, coordinator.revealApplied != reveal.token, !text.isEmpty {
      coordinator.revealApplied = reveal.token
      coordinator.reveal(start: reveal.start, end: reveal.end)
      let done = onRevealed
      Task { @MainActor in done() }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SourceView?
    weak var textView: NSTextView?
    var ruler: LineNumberRuler?
    var appliedTheme: MarkdownTheme?
    var isApplying = false
    var wrapApplied: Bool?
    var revealApplied = 0
    private var highlightTask: Task<Void, Never>?

    func textDidChange(_ notification: Notification) {
      guard !isApplying, let textView, let parent else { return }
      parent.text = textView.string
      ruler?.textChanged()
      highlight(after: .milliseconds(350))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView, let parent else { return }
      let range = textView.selectedRange()
      guard range.length > 0 else {
        parent.onSelection(nil)
        return
      }
      let lines = FileLogic.lineRange(in: textView.string as NSString, selection: range)
      parent.onSelection(lines.start...lines.end)
    }

    /// Colours the current text; skipped when the text changed while the engine ran.
    func highlight(after delay: Duration = .zero) {
      highlightTask?.cancel()
      guard let textView, let parent else { return }
      let code = textView.string
      let language = FileLogic.language(forPath: parent.path)
      let theme = appliedTheme ?? .light
      highlightTask = Task { [weak self] in
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !Task.isCancelled else { return }
        let result = await SyntaxHighlighter.shared.highlightAsync(code: code, language: language)
        guard !Task.isCancelled, let textView = self?.textView, textView.string == code, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.foregroundColor: theme.codeForeground, .font: theme.codeFont], range: whole)
        for span in result.spans where span.role != .plain && span.location + span.length <= storage.length {
          storage.addAttribute(.foregroundColor, value: theme.color(for: span.role), range: NSRange(location: span.location, length: span.length))
        }
        storage.endEditing()
      }
    }

    /// Marks and centres lines `start...end` (1-based).
    func reveal(start: Int, end: Int) {
      guard let textView, let layout = textView.layoutManager, let scroll = textView.enclosingScrollView else { return }
      let text = textView.string as NSString
      var location = 0
      var line = 1
      while line < start, location < text.length {
        let found = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
        if found.location == NSNotFound { return }
        location = found.location + 1
        line += 1
      }
      guard line == start else { return }
      var endLocation = location
      var current = start
      while current <= end, endLocation < text.length {
        let found = text.range(of: "\n", range: NSRange(location: endLocation, length: text.length - endLocation))
        endLocation = found.location == NSNotFound ? text.length : found.location
        current += 1
        if current <= end, endLocation < text.length { endLocation += 1 }
      }
      let range = NSRange(location: location, length: max(0, endLocation - location))
      layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
      layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.35), forCharacterRange: range)
      layout.ensureLayout(forCharacterRange: range)
      let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      let rect = layout.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!)
      let visible = scroll.contentView.bounds.height
      let top = max(0, rect.midY + textView.textContainerOrigin.y - visible / 2)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }
}

/// The line-number gutter: numbers logical lines, not wrapped fragments.
final class LineNumberRuler: NSRulerView {
  private weak var textView: NSTextView?
  private var lineStarts: [Int] = [0]
  private var attributes: [NSAttributedString.Key: Any] = [:]
  private var background = NSColor.clear

  init(scrollView: NSScrollView, textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 40
    NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    scrollView.contentView.postsBoundsChangedNotifications = true
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func redraw() { needsDisplay = true }

  func apply(theme: MarkdownTheme) {
    attributes = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(10, theme.codeFont.pointSize - 1), weight: .regular), .foregroundColor: theme.muted]
    background = theme.codeBackground
    needsDisplay = true
  }

  func textChanged() {
    guard let text = textView?.string as NSString? else { return }
    var starts = [0]
    var index = 0
    while index < text.length {
      let found = text.range(of: "\n", range: NSRange(location: index, length: text.length - index))
      if found.location == NSNotFound { break }
      starts.append(found.location + 1)
      index = found.location + 1
    }
    lineStarts = starts
    ruleThickness = CGFloat(String(starts.count).count) * 8 + 22
    needsDisplay = true
  }

  /// 1-based line whose first character is at `location`, if any.
  private func line(startingAt location: Int) -> Int? {
    var low = 0, high = lineStarts.count - 1
    while low <= high {
      let mid = (low + high) / 2
      if lineStarts[mid] == location { return mid + 1 }
      if lineStarts[mid] < location { low = mid + 1 } else { high = mid - 1 }
    }
    return nil
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
    background.setFill()
    bounds.fill()
    let visible = textView.visibleRect
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    func draw(_ number: Int, fragment: NSRect) {
      let label = NSAttributedString(string: String(number), attributes: attributes)
      let y = convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y), from: textView).y
      let size = label.size()
      label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2))
    }
    layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
      let location = layout.characterIndexForGlyph(at: glyphRange.location)
      if let number = self.line(startingAt: location) { draw(number, fragment: fragment) }
    }
    let extra = layout.extraLineFragmentRect
    if !extra.isEmpty, extra.intersects(visible) { draw(lineStarts.count, fragment: extra) }
  }
}
