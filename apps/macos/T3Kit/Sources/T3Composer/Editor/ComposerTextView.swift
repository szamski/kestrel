import AppKit
import Foundation

/// The editor's view of itself after an edit or a selection change.
public struct EditorSnapshot: Equatable, Sendable {
  /// Canonical Markdown.
  public var value: String
  /// Caret in the collapsed coordinate space (a chip counts one).
  public var cursor: Int
  /// Caret in the Markdown string.
  public var expandedCursor: Int
  /// The selection in Markdown offsets.
  public var selection: Range<Int>
  /// Context ids referenced by chips, in document order.
  public var contextIds: [String]

  public static let empty = EditorSnapshot(value: "", cursor: 0, expandedCursor: 0, selection: 0..<0, contextIds: [])
}

public enum ComposerCommandKey: Sendable {
  case arrowUp, arrowDown, enter, tab, escape
}

/// What the text view asks of its owner. Everything that needs the draft, the thread or the
/// environment lives behind this.
@MainActor
public protocol ComposerTextViewDelegate: AnyObject {
  func composerTextView(_ view: ComposerTextView, didChange snapshot: EditorSnapshot)
  func composerTextView(_ view: ComposerTextView, didChangeSelection snapshot: EditorSnapshot)
  /// A command key. Return true when handled; the view then does nothing else.
  func composerTextView(_ view: ComposerTextView, handle key: ComposerCommandKey, event: NSEvent, isTaskItem: Bool) -> Bool
  /// A paste the owner may claim (files, large text, structured chips). False falls back to inserting text.
  func composerTextView(_ view: ComposerTextView, paste pasteboard: NSPasteboard) -> Bool
  /// The structured payload to copy for the chips in a selection.
  func composerTextView(_ view: ComposerTextView, clipboardFragmentFor contextIds: [String]) -> ComposerContextClipboardFragment?
  /// Imports a pasted fragment's records; returns the context ids that changed.
  func composerTextView(_ view: ComposerTextView, importFragment fragment: ComposerContextClipboardFragment) -> [String: String]
  /// Files dropped on the editor. Return true when handled.
  func composerTextView(_ view: ComposerTextView, dropFiles urls: [URL]) -> Bool
  func composerTextView(_ view: ComposerTextView, didActivate atom: RichAtom, action: ChipAction, rect: NSRect)
  func composerTextViewFocusChanged(_ view: ComposerTextView, isFocused: Bool)
}

public enum ChipAction: Sendable { case open, editComment }

/// The composer's text editor: NSTextView on TextKit 2 with chips as attachment characters.
///
/// The storage is the document's flat coordinate space (see `EditorContent`), so offsets here are
/// the editor offsets of `RichDocMap`. Markdown is derived on every edit; it is never the thing
/// being edited.
@MainActor
public final class ComposerTextView: NSTextView, @preconcurrency NSTextLayoutManagerDelegate {
  public weak var composerDelegate: ComposerTextViewDelegate?
  public var composerStyle = ComposerEditorStyle() { didSet { applyStyleToTypingAttributes() } }
  public var richTextEnabled = true
  public var chipPresentation: ChipPresentationProvider = { atom in ChipPresentation(kind: .neutral, symbol: "doc", label: atom.source) }
  public var skillMeta: (String) -> SkillMeta = { SkillMeta(label: $0) }
  public var placeholder = "" { didSet { needsDisplay = true } }
  /// The pasteboard copy, cut and paste use; tests substitute a private one.
  public var pasteboard: NSPasteboard = .general
  public var isInteractionDisabled = false { didSet { isEditable = !isInteractionDisabled } }

  /// Task attributes of an empty last paragraph, which has no character to carry them.
  private(set) var trailingTask: TaskAttrsBox?
  private var isLoading = false
  private var lastSnapshot = EditorSnapshot.empty
  private var lastEmittedValue = ""

  // MARK: Construction

  public static func make() -> ComposerTextView {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.textContainer = container
    let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
    view.configure()
    return view
  }

  private func configure() {
    textLayoutManager?.delegate = self
    isRichText = true
    allowsUndo = true
    importsGraphics = false
    allowsImageEditing = false
    usesFontPanel = false
    usesRuler = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isContinuousSpellCheckingEnabled = false
    smartInsertDeleteEnabled = false
    drawsBackground = false
    isVerticallyResizable = true
    isHorizontallyResizable = false
    autoresizingMask = [.width]
    textContainerInset = NSSize(width: 2, height: 4)
    textContainer?.lineFragmentPadding = 2
    registerForDraggedTypes([.fileURL])
    setAccessibilityLabel("Message")
    setAccessibilityRole(.textArea)
    applyStyleToTypingAttributes()
  }

  private func applyStyleToTypingAttributes() {
    typingAttributes = EditorContent.plainAttributes(style: composerStyle, task: nil, mask: 0)
  }

  // MARK: Loading and reading

  /// The snapshot of the current content and selection.
  public func currentSnapshot() -> EditorSnapshot {
    let map = currentDoc().serialize()
    return snapshot(map: map, selection: selectedRange())
  }

  func currentDoc() -> RichDoc {
    EditorContent.doc(from: textStorage ?? NSTextStorage(), styling: richTextEnabled, trailingTask: effectiveTrailingTask)
  }

  private var effectiveTrailingTask: TaskAttrsBox? {
    let string = textStorage?.string ?? ""
    return string.isEmpty || string.hasSuffix("\n") ? trailingTask : nil
  }

  private func snapshot(map: RichDocMap, selection: NSRange) -> EditorSnapshot {
    let start = max(0, min(selection.location, map.docLength))
    let end = max(start, min(selection.location + selection.length, map.docLength))
    let expandedStart = max(0, min(map.value.jsLength, map.flatToMarkdown(start)))
    let expandedEnd = max(expandedStart, min(map.value.jsLength, map.flatToMarkdown(end)))
    return EditorSnapshot(
      value: map.value, cursor: ComposerLogic.clampCollapsedCursor(map.value, map.flatToCollapsed(start)), expandedCursor: expandedStart,
      selection: expandedStart..<expandedEnd, contextIds: map.contextIds)
  }

  /// Replaces the whole content from Markdown and puts the caret at `cursor` (collapsed coordinates).
  /// `undoable` keeps the replacement on the undo stack (menu insertions); a thread switch clears it.
  public func load(markdown: String, cursor: Int, undoable: Bool, selectAll: Bool = false) {
    guard let storage = textStorage else { return }
    let doc = RichDoc(markdown: markdown, skillMeta: skillMeta, styling: richTextEnabled)
    let loaded = EditorContent.load(doc, style: composerStyle, presentation: chipPresentation)
    isLoading = true
    defer { isLoading = false }
    let full = NSRange(location: 0, length: storage.length)
    if undoable, shouldChangeText(in: full, replacementString: loaded.string.string) {
      storage.replaceCharacters(in: full, with: loaded.string)
      didChangeText()
    } else {
      storage.setAttributedString(loaded.string)
      if !undoable { undoManager?.removeAllActions() }
    }
    trailingTask = loaded.trailingTask
    let map = doc.serialize()
    let flat = map.collapsedToFlat(ComposerLogic.clampCollapsedCursor(markdown, cursor))
    setSelectedRange(NSRange(location: min(flat, storage.length), length: 0))
    refreshTypingAttributes()
    lastSnapshot = snapshot(map: map, selection: selectedRange())
    lastEmittedValue = map.value
    needsDisplay = true
  }

  /// Re-reads each chip's presentation (upload progress, resolved records) and repaints.
  public func refreshChips() {
    guard let storage = textStorage else { return }
    var changed = false
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard let chip = value as? ChipAttachment else { return }
      let before = chip.bounds
      EditorContent.configure(chip, presentation: chipPresentation(chip.atom), style: composerStyle)
      if before != chip.bounds { changed = true }
      textContentStorage?.performEditingTransaction { storage.edited(.editedAttributes, range: range, changeInLength: 0) }
    }
    if changed { invalidateIntrinsicContentSize() }
    needsDisplay = true
  }

  // MARK: Change tracking

  public override func didChangeText() {
    super.didChangeText()
    guard !isLoading else { return }
    emitChange()
  }

  private func emitChange() {
    if hasMarkedText() { return }  // IME composition never reaches the draft until it commits
    if let storage = textStorage, !(storage.string.isEmpty || storage.string.hasSuffix("\n")) { trailingTask = nil }
    let next = currentSnapshot()
    guard next.value != lastEmittedValue else {
      // The text is unchanged (a selection or attribute-only change): report the selection if it moved.
      if next != lastSnapshot {
        lastSnapshot = next
        composerDelegate?.composerTextView(self, didChangeSelection: next)
      }
      return
    }
    lastSnapshot = next
    lastEmittedValue = next.value
    composerDelegate?.composerTextView(self, didChange: next)
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
    super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    guard !isLoading, !stillSelectingFlag else { return }
    refreshTypingAttributes()
    if hasMarkedText() { return }
    let next = currentSnapshot()
    // A selection move that comes with an edit is reported by `didChangeText`, which follows.
    if next.value != lastEmittedValue { return }
    if next != lastSnapshot {
      lastSnapshot = next
      composerDelegate?.composerTextView(self, didChangeSelection: next)
    }
  }

  /// Typing next to a chip must not inherit the attachment, and task paragraphs keep their style.
  private func refreshTypingAttributes() {
    var attributes = typingAttributes
    attributes[.attachment] = nil
    if attributes[.t3Marks] == nil { attributes[.t3Marks] = 0 }
    typingAttributes = attributes
  }

  // MARK: Focus

  public override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { composerDelegate?.composerTextViewFocusChanged(self, isFocused: true) }
    return accepted
  }

  public override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { composerDelegate?.composerTextViewFocusChanged(self, isFocused: false) }
    return accepted
  }

  // MARK: Keys

  public override func keyDown(with event: NSEvent) {
    if hasMarkedText() { return super.keyDown(with: event) }
    let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
    let isTask = paragraphTask(at: selectedRange().location) != nil && richTextEnabled
    switch event.keyCode {
    case 36, 76:  // Return, keypad Enter
      if composerDelegate?.composerTextView(self, handle: .enter, event: event, isTaskItem: isTask) == true { return }
      if flags.contains(.option) && !flags.contains(.command) { return super.keyDown(with: event) }
      if isTask, flags.isDisjoint(with: [.command, .control, .option]) {
        insertTaskNewline()
        return
      }
      insertNewline(nil)
      return
    case 48:  // Tab
      let key = ComposerCommandKey.tab
      if composerDelegate?.composerTextView(self, handle: key, event: event, isTaskItem: isTask) == true { return }
      // The editor never inserts a tab character: Tab moves focus like a text field would.
      if flags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
      return
    case 53:  // Escape
      if composerDelegate?.composerTextView(self, handle: .escape, event: event, isTaskItem: isTask) == true { return }
    case 126, 125:  // Up, Down
      if flags.isEmpty, composerDelegate?.composerTextView(self, handle: event.keyCode == 126 ? .arrowUp : .arrowDown, event: event, isTaskItem: isTask) == true { return }
    case 11 where flags == .command && richTextEnabled:  // ⌘B
      toggleMark(.bold)
      return
    case 34 where flags == .command && richTextEnabled:  // ⌘I
      toggleMark(.italic)
      return
    case 14 where flags == .command && richTextEnabled:  // ⌘E
      toggleMark(.code)
      return
    case 1 where flags == [.command, .shift] && richTextEnabled:  // ⌘⇧S
      toggleMark(.strike)
      return
    default: break
    }
    super.keyDown(with: event)
  }

  // MARK: Typing rules

  public override func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    let selection = selectedRange()
    if replacementRange.location == NSNotFound, selection.length > 0, text.count == 1, let typed = text.first,
      let closer = EditorRules.surroundClose[typed], surround(selection: selection, open: typed, close: closer)
    {
      return
    }
    super.insertText(string, replacementRange: replacementRange)
    guard richTextEnabled, !hasMarkedText(), !isLoading, text.utf16.count == 1 else { return }
    applyInputRules()
  }

  /// Typing an opener over a selection wraps it: the web editor's `handleTextInput`.
  private func surround(selection: NSRange, open: Character, close: Character) -> Bool {
    guard let storage = textStorage else { return false }
    var special = false
    storage.enumerateAttributes(in: selection) { attributes, _, stop in
      if attributes[.attachment] != nil || ((attributes[.t3Marks] as? Int) ?? 0) != 0 {
        special = true
        stop.pointee = true
      }
    }
    if special { return false }
    let map = currentDoc().serialize()
    let startMd = map.flatToMarkdown(selection.location)
    let endMd = map.flatToMarkdown(selection.location + selection.length)
    if ComposerPromptSegments.selectionTouchesMentionBoundary(map.value, start: startMd, end: endMd) { return false }
    let selected = storage.attributedSubstring(from: selection).string
    let replacement = NSMutableAttributedString(string: "\(open)\(selected)\(close)", attributes: typingAttributes)
    guard shouldChangeText(in: selection, replacementString: replacement.string) else { return false }
    storage.replaceCharacters(in: selection, with: replacement)
    didChangeText()
    setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
    return true
  }

  /// Mark and task input rules on the paragraph text before the caret.
  private func applyInputRules() {
    guard let storage = textStorage else { return }
    let caret = selectedRange()
    guard caret.length == 0 else { return }
    let nsString = storage.string as NSString
    let paragraphStart = nsString.paragraphRange(for: NSRange(location: caret.location, length: 0)).location
    let before = nsString.substring(with: NSRange(location: paragraphStart, length: caret.location - paragraphStart))
    if let checked = EditorRules.taskMatch(textBeforeCaret: before), paragraphStart + before.utf16.count == caret.location {
      let range = NSRange(location: paragraphStart, length: before.utf16.count)
      guard shouldChangeText(in: range, replacementString: "") else { return }
      storage.replaceCharacters(in: range, with: "")
      setSelectedRange(NSRange(location: paragraphStart, length: 0))
      setTask(TaskAttrsBox(checked: checked), inParagraphAt: paragraphStart)
      didChangeText()
      return
    }
    guard let match = EditorRules.markMatch(textBeforeCaret: before) else { return }
    let base = paragraphStart
    let content = NSRange(location: base + match.contentRange.lowerBound, length: match.contentRange.count)
    let close = NSRange(location: base + match.closeRange.lowerBound, length: match.closeRange.count)
    let open = NSRange(location: base + match.openRange.lowerBound, length: match.openRange.count)
    guard shouldChangeText(in: NSRange(location: open.location, length: caret.location - open.location), replacementString: nil) else { return }
    storage.beginEditing()
    storage.deleteCharacters(in: close)
    storage.deleteCharacters(in: open)
    let shifted = NSRange(location: content.location - open.length, length: content.length)
    applyMark(match.mark, to: shifted, on: true, in: storage)
    storage.endEditing()
    let caretAfter = shifted.location + shifted.length
    setSelectedRange(NSRange(location: caretAfter, length: 0))
    // Text typed after the closed span is not marked.
    var attributes = EditorContent.plainAttributes(style: composerStyle, task: paragraphTask(at: caretAfter), mask: 0)
    attributes[.attachment] = nil
    typingAttributes = attributes
    didChangeText()
  }

  // MARK: Marks

  private func applyMark(_ mark: RichTextMark, to range: NSRange, on: Bool, in storage: NSTextStorage) {
    guard range.length > 0 else { return }
    storage.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
      var mask = (attributes[.t3Marks] as? Int) ?? 0
      mask = on ? mask | mark.bit : mask & ~mark.bit
      storage.addAttributes(EditorContent.plainAttributes(style: composerStyle, task: nil, mask: mask).filter { $0.key != .paragraphStyle && $0.key != .foregroundColor }, range: runRange)
      if !on && mark == .strike { storage.removeAttribute(.strikethroughStyle, range: runRange) }
      if !on && mark == .code { storage.removeAttribute(.backgroundColor, range: runRange) }
    }
  }

  /// ⌘B, ⌘I, ⌘E, ⌘⇧S: toggles the mark on the selection, or for the next typed text.
  public func toggleMark(_ mark: RichTextMark) {
    guard richTextEnabled, let storage = textStorage else { return }
    let selection = selectedRange()
    if selection.length == 0 {
      var mask = (typingAttributes[.t3Marks] as? Int) ?? 0
      mask ^= mark.bit
      var attributes = typingAttributes
      for (key, value) in EditorContent.plainAttributes(style: composerStyle, task: nil, mask: mask) where key != .paragraphStyle { attributes[key] = value }
      if mask & RichTextMark.strike.bit == 0 { attributes[.strikethroughStyle] = nil }
      if mask & RichTextMark.code.bit == 0 { attributes[.backgroundColor] = nil }
      typingAttributes = attributes
      return
    }
    var allMarked = true
    storage.enumerateAttribute(.t3Marks, in: selection) { value, _, _ in
      if (((value as? Int) ?? 0) & mark.bit) == 0 { allMarked = false }
    }
    guard shouldChangeText(in: selection, replacementString: nil) else { return }
    storage.beginEditing()
    applyMark(mark, to: selection, on: !allMarked, in: storage)
    storage.endEditing()
    didChangeText()
  }

  // MARK: Tasks

  func paragraphTask(at location: Int) -> TaskAttrsBox? {
    guard let storage = textStorage, storage.length > 0 else { return location >= (textStorage?.length ?? 0) ? effectiveTrailingTask : nil }
    let nsString = storage.string as NSString
    let paragraph = nsString.paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
    if paragraph.location >= storage.length { return effectiveTrailingTask }
    return storage.attribute(.t3Task, at: paragraph.location, effectiveRange: nil) as? TaskAttrsBox
  }

  /// Sets or clears (`nil`) the task attributes of the paragraph containing `location`.
  func setTask(_ task: TaskAttrsBox?, inParagraphAt location: Int) {
    guard let storage = textStorage else { return }
    let nsString = storage.string as NSString
    let clamped = min(location, storage.length)
    let range = nsString.paragraphRange(for: NSRange(location: clamped, length: 0))
    let style = composerStyle.paragraphStyle(task: task)
    if range.length > 0 {
      storage.beginEditing()
      if let task { storage.addAttribute(.t3Task, value: task, range: range) } else { storage.removeAttribute(.t3Task, range: range) }
      storage.addAttribute(.paragraphStyle, value: style, range: range)
      storage.endEditing()
    }
    if range.location >= storage.length || range.length == 0 {
      trailingTask = task
    }
    var attributes = typingAttributes
    attributes[.t3Task] = task
    attributes[.paragraphStyle] = style
    typingAttributes = attributes
  }

  /// Enter inside a task item: an empty item lifts out of the list, otherwise a new unchecked item follows.
  private func insertTaskNewline() {
    guard let storage = textStorage else { return }
    let caret = selectedRange()
    let nsString = storage.string as NSString
    let paragraph = nsString.paragraphRange(for: NSRange(location: caret.location, length: 0))
    let contentLength = paragraph.length - (nsString.substring(with: paragraph).hasSuffix("\n") ? 1 : 0)
    guard let task = paragraphTask(at: caret.location) else { return insertNewline(nil) }
    if contentLength == 0 {
      setTask(nil, inParagraphAt: caret.location)
      didChangeText()
      return
    }
    super.insertNewline(nil)
    let next = TaskAttrsBox(checked: false, indent: task.indent, markerSpace: task.markerSpace)
    setTask(next, inParagraphAt: selectedRange().location)
    didChangeText()
  }

  public override func deleteBackward(_ sender: Any?) {
    let selection = selectedRange()
    if richTextEnabled, selection.length == 0, paragraphTask(at: selection.location) != nil, let storage = textStorage {
      let nsString = storage.string as NSString
      let paragraphStart = nsString.paragraphRange(for: NSRange(location: min(selection.location, storage.length), length: 0)).location
      if paragraphStart == selection.location {
        // Backspace at the start of a task item lifts it out of the list instead of merging.
        setTask(nil, inParagraphAt: selection.location)
        didChangeText()
        return
      }
    }
    super.deleteBackward(sender)
  }

  /// Toggles a checkbox clicked in the gutter.
  func toggleTask(atParagraphLocation location: Int) {
    guard let task = paragraphTask(at: location), let storage = textStorage else { return }
    let range = (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
    guard shouldChangeText(in: range, replacementString: nil) else { return }
    setTask(task.with(checked: !task.checked), inParagraphAt: location)
    didChangeText()
  }

  // MARK: Pointer

  public override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let (location, rect) = taskCheckboxHit(at: point) {
      _ = rect
      toggleTask(atParagraphLocation: location)
      return
    }
    if event.clickCount == 1, let hit = chipHit(at: point) {
      let action: ChipAction = hit.atom.isCitation && point.x > hit.rect.maxX - 22 ? .editComment : .open
      if action == .editComment || hit.atom.opensOnClick {
        setSelectedRange(NSRange(location: hit.range.location + 1, length: 0))
        composerDelegate?.composerTextView(self, didActivate: hit.atom, action: action, rect: hit.rect)
        return
      }
    }
    super.mouseDown(with: event)
  }

  struct ChipHit {
    var atom: RichAtom
    var range: NSRange
    var rect: NSRect
  }

  func chipHit(at point: NSPoint) -> ChipHit? {
    guard let storage = textStorage, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
    let origin = textContainerOrigin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard let fragment = layoutManager.textLayoutFragment(for: local) else { return nil }
    var found: ChipHit?
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
      guard let chip = value as? ChipAttachment,
        let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
        let end = contentManager.location(start, offsetBy: 1)
      else { return }
      guard let textRange = NSTextRange(location: start, end: end) else { return }
      var rect: CGRect?
      layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
        rect = segment
        return false
      }
      guard let rect else { return }
      let hitRect = rect.offsetBy(dx: origin.x, dy: origin.y)
      if hitRect.contains(point), fragment.layoutFragmentFrame.insetBy(dx: -1, dy: -1).contains(local) || true {
        found = ChipHit(atom: chip.atom, range: range, rect: hitRect)
        stop.pointee = true
      }
    }
    return found
  }

  // MARK: Copy, cut, paste

  public override func copy(_ sender: Any?) { writeSelection(cut: false) }

  public override func cut(_ sender: Any?) {
    writeSelection(cut: true)
  }

  private func writeSelection(cut: Bool) {
    guard let storage = textStorage else { return }
    let selection = selectedRange()
    guard selection.length > 0 else { return }
    let text = markdown(forFlatRange: selection)
    let ids = ComposerContextReferences.collectInlineContextIds(text)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    if !ids.isEmpty, let fragment = composerDelegate?.composerTextView(self, clipboardFragmentFor: ids), let encoded = ComposerContextClipboard.encode(fragment) {
      pasteboard.setString(encoded, forType: NSPasteboard.PasteboardType(ComposerContextClipboard.pasteboardType))
      pasteboard.setString(ComposerContextClipboard.encodeHTML(text: text, fragment: encoded), forType: .html)
    }
    if cut, shouldChangeText(in: selection, replacementString: "") {
      storage.replaceCharacters(in: selection, with: "")
      didChangeText()
    }
  }

  /// Canonical Markdown of a selection (never the DOM-like text: chip labels omit their source).
  func markdown(forFlatRange range: NSRange) -> String {
    guard let storage = textStorage else { return "" }
    let slice = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
    let nsString = storage.string as NSString
    let paragraphStart = nsString.paragraphRange(for: NSRange(location: range.location, length: 0)).location
    // A selection that starts mid-paragraph is plain content, not a task item.
    if paragraphStart != range.location, slice.length > 0 {
      let firstEnd = (slice.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
      slice.removeAttribute(.t3Task, range: firstEnd)
    }
    return EditorContent.doc(from: slice, styling: richTextEnabled).serialize().value
  }

  public override func paste(_ sender: Any?) {
    if composerDelegate?.composerTextView(self, paste: pasteboard) == true { return }
    pasteMarkdown(from: pasteboard)
  }

  /// Plain-text paste: structured chips come along, mentions at the boundaries are completed.
  func pasteMarkdown(from pasteboard: NSPasteboard) {
    guard let pasted = pasteboard.string(forType: .string), !pasted.isEmpty else { return }
    let fragmentRaw = pasteboard.string(forType: NSPasteboard.PasteboardType(ComposerContextClipboard.pasteboardType))
    var text = pasted
    if let fragment = ComposerContextClipboard.readPasted(text: pasted, fragment: fragmentRaw, html: pasteboard.string(forType: .html)),
      !fragment.records.isEmpty, let rewritten = composerDelegate?.composerTextView(self, importFragment: fragment)
    {
      text = ComposerContextClipboard.rewriteIds(in: pasted, with: rewritten)
    }
    insertMarkdown(text, completingBoundaries: true)
  }

  /// Inserts Markdown at the selection, rebuilding chips and styled spans.
  public func insertMarkdown(_ markdownText: String, completingBoundaries: Bool = false) {
    guard let storage = textStorage, isEditable else { return }
    var text = markdownText
    if completingBoundaries {
      let tokens = ComposerPromptSegments.collectTokens("\(text)\n")
      if let last = tokens.last, last.end == text.jsLength {
        switch last.payload {
        case .mention, .skill: text += " "
        default: break
        }
      }
      if let first = tokens.first, first.start == 0 {
        switch first.payload {
        case .mention, .skill:
          let map = currentDoc().serialize()
          let offset = map.flatToMarkdown(selectedRange().location)
          if offset > 0, let previous = map.value.jsUnit(at: offset - 1), !JS.isSpace(previous) { text = " " + text }
        default: break
        }
      }
    }
    let doc = RichDoc(markdown: text, skillMeta: skillMeta, styling: richTextEnabled)
    let inserted = EditorContent.attributedString(for: doc, style: composerStyle, presentation: chipPresentation)
    let selection = selectedRange()
    guard shouldChangeText(in: selection, replacementString: inserted.string) else { return }
    storage.replaceCharacters(in: selection, with: inserted)
    didChangeText()
    setSelectedRange(NSRange(location: selection.location + inserted.length, length: 0))
    scrollRangeToVisible(selectedRange())
  }

  // MARK: Drag and drop

  public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if isInteractionDisabled { return [] }
    if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
    return super.draggingEntered(sender)
  }

  public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    if !urls.isEmpty, composerDelegate?.composerTextView(self, dropFiles: urls) == true { return true }
    return super.performDragOperation(sender)
  }

  // MARK: Sizing

  /// The height the content needs at `width`, including the text container inset.
  public func contentHeight(forWidth width: CGFloat) -> CGFloat {
    guard let layoutManager = textLayoutManager, let container = textContainer else { return 0 }
    let inner = max(1, width - textContainerInset.width * 2)
    if abs(container.size.width - inner) > 0.5 { container.size = NSSize(width: inner, height: CGFloat.greatestFiniteMagnitude) }
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    return ceil(layoutManager.usageBoundsForTextContainer.height + textContainerInset.height * 2)
  }

  // MARK: Caret geometry

  /// True when a collapsed caret sits on the first (`start`) or last (`end`) visual line, counting
  /// soft wraps: prompt history only claims the arrows there.
  public func isCaretOnVisualEdge(start: Bool) -> Bool {
    let selection = selectedRange()
    guard selection.length == 0, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return false }
    let string = textStorage?.string ?? ""
    if string.isEmpty { return true }
    let nsString = string as NSString
    if start ? nsString.substring(to: selection.location).contains("\n") : nsString.substring(from: selection.location).contains("\n") { return false }
    guard let location = contentManager.location(contentManager.documentRange.location, offsetBy: selection.location) else { return false }
    layoutManager.ensureLayout(for: contentManager.documentRange)
    var caretLine: CGRect?
    var firstLine: CGRect?
    var lastLine: CGRect?
    layoutManager.enumerateTextLayoutFragments(from: contentManager.documentRange.location, options: [.ensuresLayout]) { fragment in
      for line in fragment.textLineFragments {
        let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        if firstLine == nil { firstLine = rect }
        lastLine = rect
        guard let fragmentStart = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location) as Int? else { continue }
        let lineRange = NSRange(location: fragmentStart + line.characterRange.location, length: line.characterRange.length)
        if selection.location >= lineRange.location && selection.location <= lineRange.location + lineRange.length,
          caretLine == nil || selection.location < lineRange.location + lineRange.length
        {
          caretLine = rect
        }
      }
      return true
    }
    _ = location
    guard let caretLine, let reference = start ? firstLine : lastLine else { return false }
    return abs(caretLine.minY - reference.minY) < 1
  }

  // MARK: Drawing

  public override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !placeholder.isEmpty, (textStorage?.length ?? 0) == 0, !hasMarkedText() else { return }
    let origin = textContainerOrigin
    let inset = (textContainer?.lineFragmentPadding ?? 0)
    let rect = NSRect(x: origin.x + inset, y: origin.y, width: max(0, bounds.width - origin.x * 2 - inset * 2), height: composerStyle.fontSize * 1.8)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    (placeholder as NSString).draw(
      in: rect, withAttributes: [.font: composerStyle.baseFont, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: paragraph])
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  // MARK: Accessibility

  /// The text with every chip spelled out, for assistive technology and tests.
  public func accessibleDescription() -> String {
    guard let storage = textStorage else { return "" }
    return accessibleText(of: storage)
  }

  private func accessibleText(of attributed: NSAttributedString) -> String {
    var out = ""
    attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
      if let chip = attributes[.attachment] as? ChipAttachment {
        out += " \(chipPresentation(chip.atom).accessibilityLabel) "
      } else {
        out += (attributed.string as NSString).substring(with: range)
      }
    }
    return out
  }
}

extension RichAtom {
  var isCitation: Bool {
    if case .citation = self { return true }
    return false
  }

  /// Chips that act on a plain click rather than placing the caret beside them.
  var opensOnClick: Bool {
    switch self {
    case .contextReference: true
    default: false
    }
  }
}
