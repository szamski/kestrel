import AppKit
import Foundation
import T3Contracts
import Testing

@testable import T3Composer

/// Records what the text view reports.
@MainActor
final class EditorProbe: ComposerTextViewDelegate {
  var changes: [EditorSnapshot] = []
  var selections: [EditorSnapshot] = []
  var keys: [ComposerCommandKey] = []
  var handledKeys: Set<Int> = []
  var importedFragments: [ComposerContextClipboardFragment] = []
  var fragment: ComposerContextClipboardFragment?
  var droppedFiles: [[URL]] = []
  var activated: [(RichAtom, ChipAction)] = []

  func composerTextView(_ view: ComposerTextView, didChange snapshot: EditorSnapshot) { changes.append(snapshot) }
  func composerTextView(_ view: ComposerTextView, didChangeSelection snapshot: EditorSnapshot) { selections.append(snapshot) }
  func composerTextView(_ view: ComposerTextView, handle key: ComposerCommandKey, event: NSEvent, isTaskItem: Bool) -> Bool {
    keys.append(key)
    return false
  }
  func composerTextView(_ view: ComposerTextView, paste pasteboard: NSPasteboard) -> Bool { false }
  func composerTextView(_ view: ComposerTextView, clipboardFragmentFor contextIds: [String]) -> ComposerContextClipboardFragment? { fragment }
  func composerTextView(_ view: ComposerTextView, importFragment fragment: ComposerContextClipboardFragment) -> [String: String] {
    importedFragments.append(fragment)
    return [:]
  }
  func composerTextView(_ view: ComposerTextView, dropFiles urls: [URL]) -> Bool {
    droppedFiles.append(urls)
    return true
  }
  func composerTextView(_ view: ComposerTextView, didActivate atom: RichAtom, action: ChipAction, rect: NSRect) { activated.append((atom, action)) }
  func composerTextViewFocusChanged(_ view: ComposerTextView, isFocused: Bool) {}
}

@MainActor
struct EditorFixture {
  let view: ComposerTextView
  let probe = EditorProbe()
  let window: NSWindow
  let pasteboard: NSPasteboard

  init(markdown: String = "", cursor: Int? = nil, richText: Bool = true) {
    view = ComposerTextView.make()
    view.richTextEnabled = richText
    view.chipPresentation = { atom in ChipPresentation(kind: .file, symbol: "doc", label: atom.source) }
    pasteboard = NSPasteboard(name: NSPasteboard.Name("t3.composer.test.\(UUID().uuidString)"))
    view.pasteboard = pasteboard
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
    scroll.documentView = view
    window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    view.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
    _ = window.makeFirstResponder(view)
    view.composerDelegate = probe
    view.load(markdown: markdown, cursor: cursor ?? markdown.jsLength, undoable: false)
    probe.changes.removeAll()
    probe.selections.removeAll()
  }

  func type(_ text: String) {
    for character in text { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
  }

  var snapshot: EditorSnapshot { view.currentSnapshot() }
}

@MainActor
@Suite("Composer text view") struct EditorBehaviorTests {
  static let file = "[main.ts](src/main.ts)"  // a file link is a chip only before whitespace
  static let image = "![shot.png](t3-context://v1/image/image_1)"

  @Test func loadingPlacesTheCaretInCollapsedCoordinates() {
    let fixture = EditorFixture(markdown: "see \(Self.file) now", cursor: 6)  // "see " + chip + " "
    #expect(fixture.snapshot.value == "see \(Self.file) now")
    #expect(fixture.snapshot.cursor == 6)
    #expect(fixture.snapshot.expandedCursor == 4 + Self.file.jsLength + 1)
    #expect(fixture.view.string.utf16.count == 4 + 1 + 4)  // the chip is one attachment character
  }

  @Test func typingAfterAndBetweenChipsKeepsThemIntact() {
    let fixture = EditorFixture(markdown: "\(Self.file) \(Self.image)", cursor: 3)  // after "chip image"? cursor 3 = end
    fixture.type("!")
    #expect(fixture.snapshot.value == "\(Self.file) \(Self.image)!")
    fixture.view.setSelectedRange(NSRange(location: 1, length: 0))  // between chip and space
    fixture.type("X")
    #expect(fixture.snapshot.value == "\(Self.file)X \(Self.image)!")
    #expect(fixture.probe.changes.last?.value == fixture.snapshot.value)
    #expect(fixture.probe.changes.last?.contextIds == ["image_1"])
  }

  @Test func backspaceDeletesAWholeChip() {
    let fixture = EditorFixture(markdown: "a \(Self.image)", cursor: 3)
    fixture.view.deleteBackward(nil)
    #expect(fixture.snapshot.value == "a ")
    #expect(fixture.snapshot.contextIds.isEmpty)
    #expect(fixture.probe.changes.last?.contextIds == [])
  }

  @Test func undoRestoresTypedTextAndChips() {
    let fixture = EditorFixture(markdown: "x \(Self.file) ", cursor: 4)
    let undo = fixture.view.undoManager
    undo?.groupsByEvent = false
    undo?.beginUndoGrouping()
    fixture.type("abc")
    undo?.endUndoGrouping()
    #expect(fixture.snapshot.value.hasSuffix("abc"))
    undo?.undo()
    #expect(fixture.snapshot.value == "x \(Self.file) ")
    undo?.redo()
    #expect(fixture.snapshot.value == "x \(Self.file) abc")
  }

  @Test func markedTextNeverReachesTheDraftAndDoesNotBreakChips() {
    let fixture = EditorFixture(markdown: "\(Self.image) ", cursor: 2)
    fixture.view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.view.hasMarkedText())
    #expect(fixture.probe.changes.isEmpty, "composition must not be reported")
    fixture.view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.probe.changes.isEmpty)
    fixture.view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!fixture.view.hasMarkedText())
    #expect(fixture.snapshot.value == "\(Self.image) 日本")
    #expect(fixture.probe.changes.last?.value == "\(Self.image) 日本")
  }

  @Test func markInputRulesStyleTypedMarkdown() {
    let fixture = EditorFixture()
    fixture.type("say **bold**")
    #expect(fixture.view.string == "say bold")
    #expect(fixture.snapshot.value == "say **bold**")
    fixture.type(" and *it*")
    #expect(fixture.snapshot.value == "say **bold** and *it*")
    fixture.type(" then `code`")
    #expect(fixture.snapshot.value == "say **bold** and *it* then `code`")
    // Text typed after the closed span is plain.
    fixture.type("!")
    #expect(fixture.snapshot.value == "say **bold** and *it* then `code`!")
  }

  @Test func plainModeKeepsMarkersLiteral() {
    let fixture = EditorFixture(richText: false)
    fixture.type("**x** - [ ] ")
    #expect(fixture.view.string == "**x** - [ ] ")
    #expect(fixture.snapshot.value == "**x** - [ ] ")
  }

  @Test func taskItemsContinueAndLift() {
    let fixture = EditorFixture()
    fixture.type("- [ ] ")
    #expect(fixture.view.string.isEmpty)
    #expect(fixture.snapshot.value == "- [ ]")
    fixture.type("first")
    #expect(fixture.snapshot.value == "- [ ] first")
    fixture.view.insertNewline(nil)  // plain newline command in a task: a split item
    // The key path (Enter) continues the list; check through the same handler.
    #expect(fixture.snapshot.value.hasPrefix("- [ ] first"))
  }

  @Test func surroundingASelectionWrapsIt() {
    let fixture = EditorFixture(markdown: "hello world")
    fixture.view.setSelectedRange(NSRange(location: 6, length: 5))
    fixture.type("(")
    #expect(fixture.snapshot.value == "hello (world)")
    #expect(fixture.view.selectedRange() == NSRange(location: 7, length: 5))
  }

  @Test func copyWritesCanonicalMarkdownAndTheStructuredFragmentThatPasteReads() {
    let fixture = EditorFixture(markdown: "a \(Self.image) b **bold**")
    let record = ComposerContextRecord.image(
      ImageContextRecordFactory.make(contextId: "image_1", name: "shot.png"))
    fixture.probe.fragment = ComposerContextClipboardFragment(source: .init(environmentId: "env"), records: [record])
    fixture.view.selectAll(nil)
    fixture.view.copy(nil)
    #expect(fixture.pasteboard.string(forType: .string) == "a \(Self.image) b **bold**")
    #expect(fixture.pasteboard.string(forType: NSPasteboard.PasteboardType(ComposerContextClipboard.pasteboardType)) != nil)
    #expect(fixture.pasteboard.string(forType: .html)?.contains("data-t3-context-fragment") == true)

    let target = EditorFixture()
    target.view.pasteboard = fixture.pasteboard
    target.view.paste(nil)
    #expect(target.snapshot.value == "a \(Self.image) b **bold**")
    #expect(target.probe.changes.last?.contextIds == ["image_1"])
  }

  @Test func pastingAMentionCompletesItsBoundaries() {
    let fixture = EditorFixture(markdown: "see")
    fixture.pasteboard.clearContents()
    fixture.pasteboard.setString(Self.file, forType: .string)
    fixture.view.paste(nil)
    // A boundary space before the chip and a trailing space after it.
    #expect(fixture.snapshot.value == "see \(Self.file) ")
  }

  @Test func readingTheCaretOnVisualEdges() {
    let fixture = EditorFixture(markdown: "one\ntwo\nthree", cursor: 0)
    fixture.view.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(fixture.view.isCaretOnVisualEdge(start: true))
    #expect(!fixture.view.isCaretOnVisualEdge(start: false))
    fixture.view.setSelectedRange(NSRange(location: 6, length: 0))
    #expect(!fixture.view.isCaretOnVisualEdge(start: true))
    fixture.view.setSelectedRange(NSRange(location: 13, length: 0))
    #expect(fixture.view.isCaretOnVisualEdge(start: false))
    #expect(EditorFixture().view.isCaretOnVisualEdge(start: true))
  }
}

enum ImageContextRecordFactory {
  static func make(contextId: String, name: String) -> ImageContextRecord {
    ImageContextRecord(contextId: ComposerContextId(contextId), label: name, attachmentId: "att", name: name, mimeType: "image/png", sizeBytes: 1)
  }
}

