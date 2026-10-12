import Foundation
import Testing

@testable import T3Composer

extension RichDoc {
  /// ProseMirror `toJSON()` shape, so the document can be compared with the TypeScript oracle.
  func oracleJSON() throws -> Any {
    func marks(_ marks: [RichTextMark]) -> [String: Any] { marks.isEmpty ? [:] : ["marks": marks.map { ["type": $0.rawValue] }] }
    func inlineJSON(_ node: RichInline) throws -> [String: Any] {
      switch node {
      case .text(let text, let m): return ["type": "text", "text": text].merging(marks(m)) { $1 }
      case .atom(let atom, let m):
        var out: [String: Any]
        switch atom {
        case .mention(let path, let source): out = ["type": "composer-mention", "attrs": ["path": path, "source": source]]
        case .skill(let name, let label, let description):
          out = ["type": "composer-skill", "attrs": ["skillName": name, "skillLabel": label, "skillDescription": description as Any? ?? NSNull()]]
        case .citation(let citation, let source):
          out = ["type": "composer-citation", "attrs": ["citation": try json(citation), "source": source]]
        case .contextReference(let kind, let contextId, let label, let source):
          out = ["type": "composer-context-reference", "attrs": ["kind": kind, "contextId": contextId, "label": label, "source": source]]
        }
        return out.merging(marks(m)) { $1 }
      }
    }
    func paragraph(_ content: [RichInline]) throws -> [String: Any] {
      content.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": try content.map(inlineJSON)]
    }
    func listJSON(_ list: RichList) throws -> [String: Any] {
      let items = try list.items.map { item -> [String: Any] in
        var content: [Any] = [try paragraph(item.content)]
        content += try item.children.map(listJSON)
        switch item.prefix {
        case .task(let checked, let indent, let markerSpace, let contentSpace):
          return ["type": "taskItem", "attrs": ["checked": checked, "indent": indent, "markerSpace": markerSpace, "contentSpace": contentSpace], "content": content]
        case .marker(let indent, let marker, let space):
          return ["type": "listItem", "attrs": ["indent": indent, "marker": marker, "space": space], "content": content]
        }
      }
      switch list.kind {
      case .task: return ["type": "taskList", "content": items]
      case .bullet: return ["type": "bulletList", "content": items]
      case .ordered(let start): return ["type": "orderedList", "attrs": ["start": start, "type": NSNull()], "content": items]
      }
    }
    func withContent(_ node: [String: Any], _ inline: [RichInline]) throws -> [String: Any] {
      inline.isEmpty ? node : node.merging(["content": try inline.map(inlineJSON)]) { $1 }
    }
    return ["type": "doc", "content": try blocks.map { block -> [String: Any] in
      switch block {
      case .paragraph(let content): try paragraph(content)
      case .heading(let level, let space, let content): try withContent(["type": "heading", "attrs": ["level": level, "space": space]], content)
      case .quote(let prefix, let lines): ["type": "blockquote", "attrs": ["prefix": prefix], "content": try lines.map(paragraph)]
      case .codeBlock(let fence, let language, let close, let text):
        ["type": "codeBlock", "attrs": ["language": language, "fence": fence, "close": close]].merging(text.isEmpty ? [:] : ["content": [["type": "text", "text": text]]]) { $1 }
      case .rule(let source): ["type": "horizontalRule", "attrs": ["source": source]]
      case .list(let value): try listJSON(value)
      }
    }]
  }
}

extension RichDocMap {
  func oracleJSON() -> [String: Any] {
    let last = runs.last
    let collapsedLength = last.map { $0.collapsedStart + $0.collapsedLen } ?? 0
    return [
      "value": value, "docLength": docLength, "contextIds": contextIds,
      "runs": runs.map { run -> [String: Any] in
        var out: [String: Any] = [
          "kind": run.kind.rawValue, "flatStart": run.flatStart, "docLen": run.docLen, "collapsedLen": run.collapsedLen,
          "mdLen": run.mdLen, "openLen": run.openLen, "closeLen": run.closeLen, "mdStart": run.mdStart,
          "collapsedStart": run.collapsedStart,
        ]
        if let name = run.nodeName { out["nodeName"] = name }
        return out
      },
      "flatToCollapsed": (0..<(docLength + 2)).map(flatToCollapsed),
      "flatToMarkdown": (0..<(docLength + 2)).map(flatToMarkdown),
      "collapsedToFlat": (0..<(collapsedLength + 3)).map(collapsedToFlat),
    ]
  }
}

@Suite("Rich document oracle") struct RichDocOracleTests {
  @Test func markdownToDocumentAndBack() throws {
    try Oracle.check("richDoc") { input in
      let doc = RichDoc(markdown: input.string("text"), styling: input.bool("styling"), literalText: input["literalText"] as? Bool ?? false)
      var out = doc.serialize().oracleJSON()
      out["doc"] = try doc.oracleJSON()
      return out
    }
  }

  /// Serializing the document built from Markdown that is already canonical is the identity.
  @Test func canonicalMarkdownIsAFixedPoint() throws {
    for item in try Oracle.cases("richDoc") {
      guard item.input.bool("styling"), let output = item.output as? [String: Any] else { continue }
      let canonical = output.string("value")
      #expect(RichDoc(markdown: canonical).serialize().value == canonical, "not a fixed point: \(canonical.debugDescription)")
    }
  }
}
