import AppKit
import Foundation
import Testing

@testable import T3Composer

@MainActor
@Suite("Editor storage round trip") struct EditorContentTests {
  static let presentation: ChipPresentationProvider = { atom in
    ChipPresentation(kind: .file, symbol: "doc", label: atom.source)
  }

  /// Every oracle draft survives markdown -> attributed storage -> markdown, and the storage's
  /// own offsets are the flat offsets of the cursor maps.
  @Test func storageIsTheFlatCoordinateSpace() throws {
    let style = ComposerEditorStyle()
    for item in try Oracle.cases("richDoc") {
      let text = item.input.string("text")
      let styling = item.input.bool("styling")
      let output = item.output as! [String: Any]
      let doc = RichDoc(markdown: text, styling: styling, literalText: item.input["literalText"] as? Bool ?? false)
      let loaded = EditorContent.load(doc, style: style, presentation: Self.presentation)
      let storage = loaded.string
      let roundTrip = EditorContent.doc(from: storage, styling: styling, trailingBlock: loaded.trailingBlock).serialize()
      #expect(roundTrip.value == output.string("value"), "value for \(text.debugDescription) styling=\(styling)")
      #expect(storage.length == output.int("docLength"), "length for \(text.debugDescription)")
      #expect(roundTrip.docLength == storage.length)
      let expectedFlatToCollapsed = (output["flatToCollapsed"] as! [NSNumber]).map(\.intValue)
      #expect((0..<(roundTrip.docLength + 2)).map(roundTrip.flatToCollapsed) == expectedFlatToCollapsed, "collapsed map for \(text.debugDescription)")
    }
  }

  @Test func chipsAreSingleAttachmentCharactersCarryingTheirAtom() {
    let doc = RichDoc(markdown: "see [a.ts](a.ts) ok ![p.png](t3-context://v1/image/image_1) $skill ")
    let storage = EditorContent.attributedString(for: doc, style: ComposerEditorStyle(), presentation: Self.presentation)
    var atoms = 0
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard value is ChipAttachment else { return }
      atoms += 1
      #expect(range.length == 1)
    }
    #expect(atoms == 3)
  }
}
