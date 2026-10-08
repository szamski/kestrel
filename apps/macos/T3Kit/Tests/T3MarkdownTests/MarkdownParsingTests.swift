import Foundation
import Testing

@testable import T3Markdown

private func parse(_ s: String, _ options: MarkdownOptions = MarkdownOptions()) -> [MarkdownBlock] {
  MarkdownDocument(parsing: s, options: options).blocks
}

private func text(_ s: String) -> MarkdownInline { .text(s) }


@Suite("GitHub alerts")
struct AlertTests {
  @Test(arguments: [("NOTE", MarkdownAlertKind.note), ("tip", .tip), ("Important", .important), ("WARNING", .warning), ("caution", .caution)])
  func recognisesMarkers(marker: String, kind: MarkdownAlertKind) {
    #expect(parse("> [!\(marker)]\n> Body text") == [.alert(kind, [.paragraph([text("Body text")])])])
  }

  @Test func markerOnlyParagraphIsAnEmptyAlert() {
    #expect(parse("> [!WARNING]") == [.alert(.warning, [])])
  }

  @Test func nextLineInlineSiblingKeepsItsParagraph() {
    #expect(parse("> [!NOTE]\n> **bold** rest") == [.alert(.note, [.paragraph([.strong([text("bold")]), text(" rest")])])])
  }

  @Test(arguments: ["> [!NOTE] aside", "> [!NOTE]*aside*", "> [!INFO]\n> x", "> plain quote"])
  func nonAlertsStayQuotes(source: String) {
    guard case .quote = parse(source).first else {
      Issue.record("expected a plain quote for \(source)")
      return
    }
  }

  @Test func alertKeepsFurtherBlocks() {
    let blocks = parse("> [!TIP]\n> one\n>\n> - item")
    guard case .alert(.tip, let inner) = blocks.first, inner.count == 2, case .list = inner[1] else {
      Issue.record("unexpected \(blocks)")
      return
    }
  }
}

@Suite("Codex directives")
struct DirectiveTests {
  static let citation = #":codex-file-citation{path="outputs/report.xlsx" purpose="output"}"#
  static let template =
    #"::artifact-template{skill_name="artifact-template-hello-world" skill_directory="/Users/test/.codex/skills/artifact-template-hello-world" display_name="Hello World" artifact_kind="document"}"#

  @Test func citationBecomesFileLink() {
    #expect(
      parse("Created \(Self.citation).") == [
        .paragraph([
          text("Created "),
          .link(.file(MarkdownFileTarget(path: "outputs/report.xlsx")), [text("report.xlsx")]),
          text("."),
        ])
      ])
  }

  @Test func citationCarriesLine() {
    let blocks = parse(#":codex-file-citation{path="src/main.ts" line_range_start="42"}"#)
    #expect(blocks == [.paragraph([.link(.file(MarkdownFileTarget(path: "src/main.ts", line: 42)), [text("main.ts")])])])
  }

  @Test(arguments: [
    "C:\\Users\\test\\[draft]\\report.md", "\\\\server\\share\\report.md", "outputs/report.md", "/tmp/report%5C.md",
  ])
  func citationPreservesLiteralPath(path: String) {
    let blocks = parse(#":codex-file-citation{path="\#(path)" line_range_start="7"}"#)
    guard let inl = inlines(blocks.first), case .link(.file(let target), _)? = inl.first else {
      Issue.record("not a file link: \(blocks)")
      return
    }
    #expect(target.path == path)
    #expect(target.line == 7)
  }

  @Test(arguments: [
    "\\\(DirectiveTests.citation)", "`\(DirectiveTests.citation)`", "```text\n\(DirectiveTests.citation)\n```",
    "[See \(DirectiveTests.citation)](https://example.com)",
  ])
  func excludedSyntaxStaysLiteral(source: String) {
    let blocks = parse(source)
    func hasFileLink(_ inl: [MarkdownInline]) -> Bool {
      inl.contains { i in
        if case .link(.file, _) = i { return true }
        if case .link(_, let c) = i { return hasFileLink(c) }
        return false
      }
    }
    for b in blocks { if let inl = inlines(b) { #expect(!hasFileLink(inl) || source.hasPrefix("[See")) } }
    if source.hasPrefix("[See"), let inl = inlines(blocks.first), case .link(.web, let label)? = inl.first {
      #expect(MarkdownInline.plainText(label).contains(":codex-file-citation"))
    }
    if source.hasPrefix("```"), case .code(let c)? = blocks.first { #expect(c.code.contains(":codex-file-citation")) }
  }

  @Test func artifactTemplateIsItsOwnBlock() {
    let blocks = parse("Before\n\n\(Self.template)\n\nAfter")
    #expect(blocks.count == 3)
    guard case .artifactTemplate(let t) = blocks[1] else {
      Issue.record("no card: \(blocks)")
      return
    }
    #expect(t.kind == .document)
    #expect(t.displayName == "Hello World")
    #expect(t.skillName == "artifact-template-hello-world")
    #expect(t.kind.presentationLabel == "Document template")
    #expect(t.usePrompt == "Create a document using this $artifact-template-hello-world about…")
  }

  @Test func artifactTemplateInterruptsAParagraph() {
    #expect(parse("Before\n\(Self.template)").count == 2)
  }

  @Test(arguments: [
    "Meeting at 10:30", "Use :hover and :tada:", "::note", ":::note\ncontent\n:::",
    #":codex-file-citation-extra{path="outputs/report.xlsx"}"#,
    #":codex-file-citation{purpose="output"}"#,
    #"::artifact-template{skill_name="artifact-template-hello-world"}"#,
    #"::artifact-template{display_name="Hello World"}"#,
  ])
  func unrelatedOrMalformedSyntaxIsLiteral(source: String) {
    let blocks = parse(source)
    for b in blocks {
      if case .artifactTemplate = b { Issue.record("must not become a card: \(source)") }
      if let inl = inlines(b), inl.contains(where: { if case .link = $0 { true } else { false } }) {
        Issue.record("must not become a link: \(source)")
      }
    }
    #expect(!blocks.isEmpty)
  }

  @Test func templateInsideInlineCodeStaysCode() {
    #expect(parse("`\(Self.template)`") == [.paragraph([.code(Self.template, file: nil)])])
  }
}

@Suite("Markdown features")
struct FeatureTests {
  @Test func tablesCarryAlignment() {
    let blocks = parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
    guard case .table(let t)? = blocks.first else { return bail("no table: \(blocks)") }
    #expect(t.alignments == [.left, .center, .right])
    #expect(t.header.map { MarkdownInline.plainText($0.inlines) } == ["a", "b", "c"])
    #expect(t.rows.count == 1)
  }

  @Test func taskListsAndStrikethrough() {
    let blocks = parse("- [x] done\n- [ ] ~~todo~~")
    guard case .list(let l)? = blocks.first else { return bail("no list") }
    #expect(l.items.map(\.checked) == [true, false])
    #expect(l.isTight)
  }

  @Test func looseListIsDetected() {
    guard case .list(let l)? = parse("1. one\n\n2. two").first else { return bail("no list") }
    #expect(!l.isTight)
    #expect(l.isOrdered)
  }

  @Test func orderedListKeepsStart() {
    guard case .list(let l)? = parse("3. a\n4. b").first else { return bail("no list") }
    #expect(l.start == 3)
  }

  @Test func bareUrlsAreAutolinked() {
    let blocks = parse("See https://example.com/a_b_c, and www.example.org. mail me@x.dev")
    guard let inl = inlines(blocks.first) else { return bail("no paragraph") }
    let links = inl.compactMap { i -> URL? in if case .link(.web(let u), _) = i { u } else { nil } }
    #expect(links.map(\.absoluteString) == ["https://example.com/a_b_c", "http://www.example.org", "mailto:me@x.dev"])
  }

  @Test func autolinkDoesNotSwallowTrailingPunctuationOrParens() {
    let blocks = parse("(see https://example.com/x). Also https://e.com/a_(b)")
    guard let inl = inlines(blocks.first) else { return bail("no paragraph") }
    let links = inl.compactMap { i -> String? in if case .link(.web(let u), _) = i { u.absoluteString } else { nil } }
    #expect(links == ["https://example.com/x", "https://e.com/a_(b)"])
  }

  @Test func angleBracketAutolink() {
    guard let inl = inlines(parse("<https://example.com>").first), case .link(.web(let u), _)? = inl.first else {
      return bail("no link")
    }
    #expect(u.absoluteString == "https://example.com")
  }

  @Test func codeFenceLanguageAndMeta() {
    guard case .code(let c)? = parse("```Swift title=\"a.swift\"\nlet x = 1\n```").first else { return bail("no code") }
    #expect(c.language == "swift")
    #expect(c.meta == "title=\"a.swift\"")
    #expect(c.code == "let x = 1")
    #expect(!c.isOpen)
  }

  @Test func unclosedFenceIsOpen() {
    var stream = MarkdownStream()
    guard case .code(let c)? = stream.update("text\n\n```ts\nconst a = 1").blocks.last else { return bail("no code") }
    #expect(c.isOpen)
  }

  @Test func softBreakFlag() {
    #expect(parse("a\nb") == [.paragraph([text("a"), .softBreak, text("b")])])
    #expect(parse("a\nb", MarkdownOptions(softBreaksAsNewlines: true)) == [.paragraph([text("a"), .lineBreak, text("b")])])
  }

  @Test func smartPunctuationIsOff() {
    #expect(parse("\"quoted\" -- dash...") == [.paragraph([text("\"quoted\" -- dash...")])])
  }

  @Test func standaloneImageIsABlock() {
    guard case .image(let img)? = parse("![shot](https://example.com/a.png)").first else { return bail("no image") }
    #expect(img.source == .direct("https://example.com/a.png"))
    #expect(img.alt == "shot")
  }

  @Test func contextAndCitationChips() {
    let blocks = parse("see [a.png](t3-context://v1/image/ctx_1) and ![shot](t3-context://v1/image/ctx_2)")
    guard let inl = inlines(blocks.first) else { return bail("no paragraph") }
    #expect(inl.contains(.context(kind: "image", id: "ctx_1", label: "a.png")))
    #expect(inl.contains(.context(kind: "image", id: "ctx_2", label: "shot")))
  }

  @Test func contextWithoutLabelFallsBackToId() {
    guard let inl = inlines(parse("[](t3-context://v1/file/abc)").first) else { return bail("no p") }
    #expect(inl == [.context(kind: "file", id: "abc", label: "abc")])
  }

  @Test func overIndentedListTextIsNotACodeCard() {
    let blocks = parse("-       aligned text\n-       second")
    guard case .list(let l)? = blocks.first else { return bail("no list") }
    for item in l.items {
      guard case .paragraph? = item.blocks.first else { return bail("item became \(item.blocks)") }
    }
    #expect(MarkdownInline.plainText({ if case .paragraph(let i, _)? = l.items[0].blocks.first { i } else { [] } }()) == "aligned text")
  }

  @Test func fencedAndConventionalCodeInListsStayCode() {
    guard case .list(let l)? = parse("- item\n\n  ```swift\n  let a = 1\n  ```").first else { return bail("no list") }
    #expect(l.items[0].blocks.contains { if case .code = $0 { true } else { false } })
    guard case .list(let l2)? = parse("-     code").first else { return bail("no list") }
    #expect(l2.items[0].blocks.contains { if case .code = $0 { true } else { false } })
  }
}

@Suite("Inline HTML subset")
struct HTMLTests {
  @Test func allowedTagsRenderNatively() {
    #expect(
      parse("H<sub>2</sub>O and x<sup>2</sup> and <kbd>⌘</kbd> and <mark>hi</mark>")
        == [
          .paragraph([
            text("H"), .styled(.subscripted, [text("2")]), text("O and x"), .styled(.superscripted, [text("2")]),
            text(" and "), .styled(.keyboard, [text("⌘")]), text(" and "), .styled(.highlighted, [text("hi")]),
          ])
        ])
  }

  @Test func boldAndLinkTags() {
    let blocks = parse(#"<b>bold</b> <a href="https://example.com">site</a>"#)
    #expect(blocks == [.paragraph([.strong([text("bold")]), text(" "), .link(.web(URL(string: "https://example.com")!), [text("site")])])])
  }

  @Test func scriptAndHandlersStayLiteral() {
    let blocks = parse("<script>alert(1)</script> x <img src=\"javascript:alert(1)\" onerror=\"x()\"> <iframe src=\"https://e.com\"></iframe>")
    let plain = blocks.map { b -> String in if case .paragraph(let i, _) = b { MarkdownInline.plainText(i) } else { "" } }.joined()
    #expect(plain.contains("<script>alert(1)</script>"))
    #expect(plain.contains("<iframe"))
    for b in blocks {
      if case .paragraph(let inl, _) = b {
        for i in inl { if case .image(let img) = i { #expect(img.source == .blocked) } }
      }
    }
  }

  @Test func unclosedTagFallsBackToLiteral() {
    #expect(parse("a <b>bold") == [.paragraph([text("a <b>bold")])])
  }

  @Test func parsingCanBeDisabled() {
    let blocks = parse("a <b>x</b>", MarkdownOptions(parsesHTML: false))
    #expect(blocks == [.paragraph([text("a <b>x</b>")])])
  }

  @Test func htmlBlockWithAlignAndImage() {
    let blocks = parse("<p align=\"center\">\n  <img src=\"logo.png\" width=\"200\">\n</p>", MarkdownOptions(baseDirectory: "/repo"))
    guard case .image(let img)? = blocks.first else { return bail("blocks: \(blocks)") }
    #expect(img.source == .workspaceFile("/repo/logo.png"))
    #expect(img.width == 200)
  }

  @Test func detailsSummaryAndComments() {
    let blocks = parse("<details>\n<summary>More</summary>\n\nBody\n\n</details>\n\n<!-- hidden -->")
    #expect(blocks == [.details(summary: [text("More")], isOpen: false, blocks: [.paragraph([text("Body")])])])
  }

  @Test func htmlBlockScriptIsLiteral() {
    let blocks = parse("<script>\nalert(1)\n</script>")
    let plain = blocks.map { b -> String in if case .paragraph(let i, _) = b { MarkdownInline.plainText(i) } else { "" } }.joined()
    #expect(plain.contains("<script>"))
  }
}

@Suite("Open fences")
struct OpenFenceTests {
  @Test func openFenceInsideAListItemIsMarkedOpen() {
    var stream = MarkdownStream()
    let blocks = stream.update("- step\n\n  ```swift\n  let a = 1").blocks
    guard case .list(let l)? = blocks.last, case .code(let c)? = l.items.last?.blocks.last else {
      return bail("no nested code in \(blocks)")
    }
    #expect(c.isOpen)
  }

  @Test func closedFenceIsNotOpen() {
    var stream = MarkdownStream()
    guard case .code(let c)? = stream.update("```swift\nlet a = 1\n```").blocks.last else { return bail("no code") }
    #expect(!c.isOpen)
  }
}
