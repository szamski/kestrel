import AppKit
import SwiftUI

/// The composer's text editor for SwiftUI. It owns an `NSScrollView` around a `ComposerTextView`
/// and reports edits to the model; model-driven changes arrive as `sync` requests applied once.
///
/// The height follows the content between `minHeight` and `maxHeight`; beyond that the editor scrolls.
struct ComposerEditorView: NSViewRepresentable {
  let model: ComposerModel
  let sync: EditorSyncRequest
  let focusRequest: Int
  let placeholder: String
  let isDisabled: Bool
  let richTextEnabled: Bool
  /// Changes whenever a chip's presentation can have changed (uploads, records, skills).
  let chipSignature: Int
  let style: ComposerEditorStyle
  var minHeight: CGFloat = 52
  var maxHeight: CGFloat = 208
  var onChipActivate: (RichAtom, ChipAction) -> Void = { _, _ in }

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = ComposerTextView.make()
    textView.composerDelegate = context.coordinator
    context.coordinator.textView = textView
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.borderType = .noBorder
    scroll.documentView = textView
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = context.coordinator.textView else { return }
    let coordinator = context.coordinator
    coordinator.onChipActivate = onChipActivate
    textView.composerStyle = style
    textView.richTextEnabled = richTextEnabled
    textView.placeholder = placeholder
    textView.isInteractionDisabled = isDisabled
    textView.chipPresentation = model.makeChipPresentationProvider()
    textView.skillMeta = model.skillMeta
    if coordinator.appliedRevision != sync.revision {
      coordinator.appliedRevision = sync.revision
      coordinator.lastChipSignature = chipSignature
      textView.load(markdown: sync.markdown, cursor: sync.cursor, undoable: sync.undoable)
    } else if coordinator.lastChipSignature != chipSignature {
      coordinator.lastChipSignature = chipSignature
      textView.refreshChips()
    }
    if coordinator.appliedFocus != focusRequest {
      coordinator.appliedFocus = focusRequest
      DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
    guard let textView = context.coordinator.textView else { return nil }
    let width = proposal.width ?? 400
    return CGSize(width: width, height: min(maxHeight, max(minHeight, textView.contentHeight(forWidth: width))))
  }

  @MainActor
  final class Coordinator: ComposerTextViewDelegate {
    let model: ComposerModel
    weak var textView: ComposerTextView?
    var appliedRevision = -1
    var appliedFocus = 0
    var lastChipSignature = 0
    var onChipActivate: (RichAtom, ChipAction) -> Void = { _, _ in }

    init(model: ComposerModel) { self.model = model }

    func composerTextView(_ view: ComposerTextView, didChange snapshot: EditorSnapshot) { model.editorDidChange(snapshot) }
    func composerTextView(_ view: ComposerTextView, didChangeSelection snapshot: EditorSnapshot) { model.editorSelectionDidChange(snapshot) }

    func composerTextView(_ view: ComposerTextView, handle key: ComposerCommandKey, event: NSEvent, isTaskItem: Bool) -> Bool {
      let flags = event.modifierFlags
      let press = ComposerKeyPress(
        keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, command: flags.contains(.command), control: flags.contains(.control),
        shift: flags.contains(.shift), option: flags.contains(.option))
      let context = ComposerKeyContext(
        shift: flags.contains(.shift), modifier: flags.contains(.command) || flags.contains(.control), option: flags.contains(.option),
        isComposing: view.hasMarkedText(), caretOnFirstLine: view.isCaretOnVisualEdge(start: true), caretOnLastLine: view.isCaretOnVisualEdge(start: false),
        command: key == .enter ? model.keybindingResolver?(press) : nil)
      return model.handleCommandKey(key, context: context, isTaskItem: isTaskItem)
    }

    func composerTextView(_ view: ComposerTextView, paste pasteboard: NSPasteboard) -> Bool { model.handlePaste(pasteboard) }
    func composerTextView(_ view: ComposerTextView, clipboardFragmentFor contextIds: [String]) -> ComposerContextClipboardFragment? { model.clipboardFragment(contextIds: contextIds) }
    func composerTextView(_ view: ComposerTextView, importFragment fragment: ComposerContextClipboardFragment) -> [String: String] { model.importClipboardFragment(fragment) }

    func composerTextView(_ view: ComposerTextView, dropFiles urls: [URL]) -> Bool {
      guard !urls.isEmpty else { return false }
      let model = model
      Task { _ = await model.handleDrop(urls: urls) }
      return true
    }

    func composerTextView(_ view: ComposerTextView, didActivate atom: RichAtom, action: ChipAction, rect: NSRect) { onChipActivate(atom, action) }
    func composerTextViewFocusChanged(_ view: ComposerTextView, isFocused: Bool) { model.editorFocusDidChange(isFocused) }
  }
}
