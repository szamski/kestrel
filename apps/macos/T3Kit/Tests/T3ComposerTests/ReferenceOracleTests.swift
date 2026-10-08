import Foundation
import Testing
import T3Contracts

@testable import T3Composer

private func occurrenceJSON(_ occurrence: ComposerContextReferenceOccurrence) -> [String: Any] {
  ["kind": occurrence.kind, "contextId": occurrence.contextId, "label": occurrence.label, "image": occurrence.image,
    "source": occurrence.source, "start": occurrence.start, "end": occurrence.end]
}

private func reference(_ any: Any?) -> ComposerContextReference {
  let object = any as! [String: Any]
  return ComposerContextReference(kind: object.string("kind"), contextId: object.string("contextId"), label: object.string("label"))
}

private func citation(_ any: Any) throws -> AssistantCitation {
  try JSONDecoder().decode(AssistantCitation.self, from: JSONSerialization.data(withJSONObject: any))
}

@Suite("Reference, citation, paste and clipboard oracle") struct ReferenceOracleTests {
  @Test func contextReferences() throws {
    try Oracle.check("contextCollect") { ComposerContextReferences.collect($0.string("text")).map(occurrenceJSON) }
    try Oracle.check("contextReplace") { input in
      ComposerContextReferences.replace(input.string("text")) { "<\($0.kind):\($0.contextId):\($0.label):\($0.image)>" }
    }
    try Oracle.check("contextIds") { input in
      let text = input.string("text")
      return ["ids": ComposerContextReferences.collectInlineContextIds(text), "stripped": ComposerContextReferences.stripInlineReferences(text)]
    }
    try Oracle.check("contextHref") { input in
      ComposerContextReferences.parseHref(input.string("href")).map { ["kind": $0.kind, "contextId": $0.contextId] }
    }
    try Oracle.check("contextLabel") { ComposerContextReferences.sanitizeLabel($0.string("label"), kind: $0.string("kind")) }
    try Oracle.check("contextFormat") { input in
      ComposerContextReferences.format(reference(input))
    }
    try Oracle.check("contextIdFold") { input in
      let id = input.string("id")
      return [
        "id": ComposerContextReferences.toContextId(id),
        "scopedTerminal": ComposerContextReferences.toKindScopedContextId(kind: "terminal", producerId: id),
        "producerTerminal": ComposerContextReferences.producerId(kind: "terminal", contextId: id),
        "producerImage": ComposerContextReferences.producerId(kind: "image", contextId: "image_\(id)"),
      ]
    }
    try Oracle.check("contextInsert") { input in
      let result = ComposerContextReferences.insert(prompt: input.string("prompt"), cursor: input.int("cursor"), reference: reference(input["reference"]))
      return ["prompt": result.prompt, "cursor": result.cursor]
    }
    try Oracle.check("contextReplacement") { input in
      let refs = (input["references"] as! [Any]).map(reference)
      let edit = ComposerContextReferences.inlineReplacement(prompt: input.string("prompt"), start: input.int("start"), end: input.int("end"), references: refs)
      return ["start": edit.start, "end": edit.end, "text": edit.text]
    }
    try Oracle.check("contextRemove") { input in
      let result = ComposerContextReferences.remove(prompt: input.string("prompt"), contextId: input.string("contextId"))
      return ["prompt": result.prompt, "cursor": result.cursor]
    }
    try Oracle.check("contextEnsure") { input in
      ComposerContextReferences.ensure(prompt: input.string("prompt"), references: (input["references"] as! [Any]).map(reference))
    }
    try Oracle.check("contextAppend") { input in
      ComposerContextReferences.append(prompt: input.string("prompt"), reference: reference(input["reference"]))
    }
  }

  @Test func citations() throws {
    try Oracle.check("citationFormat") { input in
      let value = try citation(input["citation"]!)
      return ["href": AssistantCitations.formatHref(value), "serialized": AssistantCitations.serialize(value),
        "parsed": try AssistantCitations.parseHref(AssistantCitations.formatHref(value)).map(json) as Any]
    }
    try Oracle.check("citationComment") { input in
      let value = try citation(input["citation"]!)
      let comment = input.string("comment")
      return ["next": try json(AssistantCitations.withComment(value, comment)), "composer": ComposerLogic.formatAssistantCitation(value, comment: comment)]
    }
    try Oracle.check("citationParse") { input in try AssistantCitations.parseHref(input.string("href")).map(json) }
    try Oracle.check("citationText") { input in
      let text = input.string("text")
      return [
        "collect": try AssistantCitations.collect(text).map { ["citation": try json($0.citation), "source": $0.source, "start": $0.start, "end": $0.end] as [String: Any] },
        "plain": AssistantCitations.toPlainText(text),
        "rendered": AssistantCitations.renderAsText(text),
      ]
    }
  }

  @Test func pasteRules() throws {
    try Oracle.check("pasteDisposition") { input in
      let repeatSpec = input["repeat"] as! [Any]
      let text = String(repeating: repeatSpec[0] as! String, count: (repeatSpec[1] as! NSNumber).intValue)
      return TextPaste.disposition(
        text: text, canAttach: input.bool("canAttach"), bypassAutoAttachment: input.bool("bypassAutoAttachment"),
        wouldExceedInputLimit: input.bool("wouldExceedInputLimit")).rawValue
    }
    try Oracle.check("pasteFileName") { TextPaste.nextFileName(existing: $0["existing"] as! [String]) }
    try Oracle.check("pasteReplace") { input in
      let result = TextPaste.replaceSelection(value: input.string("value"), start: input.int("start"), end: input.int("end"), text: input.string("text"))
      return ["value": result.value, "cursor": result.cursor]
    }
    try Oracle.check("pasteLimit") { input in
      TextPaste.wouldExceedLimit(valueLength: input.int("valueLength"), start: input.int("start"), end: input.int("end"), textLength: input.int("textLength"), maxLength: input.int("maxLength"))
    }
    try Oracle.check("attachmentName") { input in
      let name = input.string("name")
      return input["max"].map { AttachmentNames.middleTruncated(name, maxCharacters: ($0 as! NSNumber).intValue) } ?? AttachmentNames.middleTruncated(name)
    }
  }

  @Test func clipboard() throws {
    func fragmentJSON(_ fragment: ComposerContextClipboardFragment?) throws -> Any {
      guard let fragment else { return NSNull() }
      return try json(fragment)
    }
    try Oracle.check("clipboardDecode", nullEqualsMissing: true) { input in
      try fragmentJSON(ComposerContextClipboard.decode(input["raw"] as? String))
    }
    try Oracle.check("clipboardHtml", nullEqualsMissing: true) { input in
      if input["decodeOnly"] != nil { return ["decoded": try fragmentJSON(ComposerContextClipboard.decodeHTML(input["html"] as? String))] }
      let fragment = input.string("fragment")
      let html = ComposerContextClipboard.encodeHTML(text: input.string("text"), fragment: fragment, html: input.optionalString("html"))
      return ["html": html, "decoded": try fragmentJSON(ComposerContextClipboard.decodeHTML(html))]
    }
    try Oracle.check("clipboardRead", nullEqualsMissing: true) { input in
      let text = input.string("text")
      let raw = input["fragment"] as? String
      let html = input["html"] as? String
      let read = ComposerContextClipboard.readPasted(text: text, fragment: raw, html: html)
      var imported: [String: String] = [:]
      for record in read?.records ?? [] { imported[record.contextIdentifier] = "\(record.contextIdentifier)_x" }
      return [
        "read": try fragmentJSON(read),
        "imported": ComposerContextClipboard.rewriteIds(in: text, with: imported),
        "importedNone": text,
        "plain": text,
      ]
    }
  }
}
