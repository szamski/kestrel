import AppKit
import Foundation
import Testing

@testable import T3Markdown

private let artifacts = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78/stageD-markdown"

private let longLine = "let veryLongLine = \"" + String(repeating: "abcdefghij", count: 30) + "\""

private func parse(_ s: String, _ options: MarkdownOptions = MarkdownOptions()) -> [MarkdownBlock] {
  MarkdownParser.parse(s, options: options)
}

private func plain(_ blocks: [MarkdownBlock]) -> [MarkdownInline] {
  blocks.flatMap { b -> [MarkdownInline] in if case .paragraph(let i, _) = b { i } else { [] } }
}

@MainActor
@Suite("Code blocks")
struct CodeBlockTests {
  init() { _ = NSApplication.shared }

  @Test func longLinesDoNotWrapAndTheBlockScrollsSideways() async throws {
    let view = try await liveView("intro\n\n```swift\n\(longLine)\nne\ned\n```\n\nafter", width: 300)
    let block = try #require(view.codeBlockViews.first, "viewport created no code block view")
    // One paragraph per source line, each laid out as a single line: nothing wrapped mid-token.
    #expect(CodeBlockContent.code(fromStorageText: block.textView.string) == "\(longLine)\nne\ned")
    var lines = 0
    block.textView.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
      lines += fragment.textLineFragments.count
      return true
    }
    #expect(lines == 3)
    #expect(block.documentWidth > block.bounds.width * 2)
    #expect(abs(block.frame.width - 300) < 1)
    block.scroll(toX: 120)
    #expect(block.scrollView.contentView.bounds.origin.x == 120)
    block.scroll(toX: 1_000_000)
    #expect(block.scrollView.contentView.bounds.origin.x == block.documentWidth - block.bounds.width)
  }

  @Test func heightDoesNotDependOnWidthAndMeasurementMatchesTheLiveView() async throws {
    let rendered = await render("```swift\n\(longLine)\nne\ned\n```")
    let narrow = MarkdownLayout.height(of: rendered, width: 280)
    let wide = MarkdownLayout.height(of: rendered, width: 900)
    #expect(narrow == wide, "code never wraps, so width cannot change its height")
    let content = try #require(codeAttachmentsOf(rendered).first?.content)
    #expect(narrow >= content.height && narrow < content.height + 30)
    let view = try await liveView("```swift\n\(longLine)\nne\ned\n```", width: 280)
    #expect(view.fittingHeight(forWidth: 280) == narrow)
    let block = try #require(view.codeBlockViews.first)
    #expect(abs(block.frame.height - content.height) < 0.5)
  }

  @Test func wholeMessageCopyKeepsTheFullCodeInOrder() async throws {
    let view = MarkdownTextView()
    view.setContent(await render("before\n\n```swift\n\(longLine)\nne\ned\n```\n\nafter"))
    _ = view.fittingHeight(forWidth: 300)
    view.setSelectedRange(NSRange(location: 0, length: view.textContentStorage!.textStorage!.length))
    let copied = try #require(view.selectedPlainText())
    #expect(copied == "before\n\(longLine)\nne\ned\nafter")
  }

  @Test func blocksInsideListsAndQuotesStayInsideTheContainer() async throws {
    let md = "- item\n\n  ```\n  \(longLine)\n  ```\n\n> quote\n>\n> ```\n> x\n> ```"
    let view = try await liveView(md, width: 320)
    let blocks = view.codeBlockViews
    #expect(blocks.count == 2)
    for block in blocks {
      let frame = view.convert(block.bounds, from: block)
      #expect(frame.minX > 10 && frame.maxX <= 320.5, "block spans \(frame.minX)…\(frame.maxX)")
    }
  }

  @Test func onlyOneSelectionIsShown() async throws {
    let view = try await liveView("hello world\n\n```\ncode here\n```", width: 300)
    let block = try #require(view.codeBlockViews.first)
    view.setSelectedRange(NSRange(location: 0, length: 5))
    block.textView.setSelectedRange(NSRange(location: 0, length: 4))
    view.clearSelections(except: block.textView)
    #expect(view.selectedRange().length == 0)
    #expect(block.textView.selectedRange().length == 4)
    view.clearSelections(except: view)
    #expect(block.textView.selectedRange().length == 0)
  }

  @Test func screenshots() async throws {
    let md = "Long lines scroll inside the block; the message keeps wrapping.\n\n```swift\n\(longLine)\nne\ned\nfunc short() {}\n```\n\nAfter the block."
    for (theme, name) in [(MarkdownTheme.light, "light"), (.dark, "dark")] {
      for width in [420.0, 900] {
        let initial = try #require(await MarkdownDemo.png(of: md, width: width, theme: theme))
        try initial.write(to: URL(fileURLWithPath: "\(artifacts)/code-initial-\(name)-\(Int(width)).png"))
        let scrolled = try #require(await MarkdownDemo.png(of: md, width: width, theme: theme, codeScroll: 260))
        try scrolled.write(to: URL(fileURLWithPath: "\(artifacts)/code-scrolled-\(name)-\(Int(width)).png"))
        // A one-line block is tight: header, one line, padding.
        let single = "A single long line:\n\n```swift\n\(longLine)\n```\n\nAfter the block."
        let tightInitial = try #require(await MarkdownDemo.png(of: single, width: width, theme: theme))
        try tightInitial.write(to: URL(fileURLWithPath: "\(artifacts)/code-single-line-initial-\(name)-\(Int(width)).png"))
        let tightScrolled = try #require(await MarkdownDemo.png(of: single, width: width, theme: theme, codeScroll: 260))
        try tightScrolled.write(to: URL(fileURLWithPath: "\(artifacts)/code-single-line-scrolled-\(name)-\(Int(width)).png"))
      }
    }
  }
}


@MainActor
@Suite("Code block views")
struct CodeBlockViewTests {
  init() { _ = NSApplication.shared }

  @Test func storageTextKeepsLengthAndMapsBackToTheCode() {
    let code = (1...120).map { "line \($0)" }.joined(separator: "\n")
    let stored = CodeBlockContent.storageText(code)
    #expect(stored.utf16.count == code.utf16.count, "spans are offsets into the code: lengths must agree")
    #expect(stored.components(separatedBy: "\n").count == 3, "120 lines in paragraphs of 50")
    #expect(CodeBlockContent.code(fromStorageText: stored) == code)
    // An appended tail continues the pattern from the line it starts in.
    let head = (1...49).map { "l\($0)" }.joined(separator: "\n")
    let grown = head + "\nmore\nand more"
    let tail = CodeBlockContent.storageText(String(grown.dropFirst(head.count)), firstLine: 48)
    #expect(CodeBlockContent.storageText(head) + tail == CodeBlockContent.storageText(grown))
  }

  private func code(_ lines: Int) -> String { (1...lines).map { "let v\($0) = \($0)" }.joined(separator: "\n") }

  @Test func heightIsHeaderPlusLinesPlusPaddingAndNothingElse() async throws {
    for lines in [1, 2, 10] {
      let md = "```swift\n\(code(lines))\n```"
      let rendered = await render(md)
      let content = try #require(codeAttachmentsOf(rendered).first?.content)
      let expected = content.headerHeight + CGFloat(lines) * content.lineHeight + content.bottomPad
      #expect(content.height == expected)
      #expect(MarkdownLayout.height(of: rendered, width: 500) == expected, "\(lines) lines: the row is the block, nothing more")

      let view = try await liveView(md, width: 500)
      let block = try #require(view.codeBlockViews.first)
      #expect(abs(block.frame.height - expected) < 0.5)
      // TextKit's own height of the code is exactly one fixed-height line per source line,
      // and the overlay scroller takes no room from the body.
      let layout = try #require(block.textView.textLayoutManager)
      layout.ensureLayout(for: layout.documentRange)
      #expect(layout.usageBoundsForTextContainer.height == CGFloat(lines) * content.lineHeight)
      #expect(block.scrollView.frame.height == CGFloat(lines) * content.lineHeight + content.bottomPad)
      #expect(block.scrollView.contentView.frame.height == block.scrollView.frame.height)
    }
  }

  @Test func streamingDeltasAppendToTheSameViewAndKeepItsScroll() async throws {
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    var stream = MarkdownStream()
    var text = "intro\n\n```swift\n\(longLine)\nlet a = 1"
    let view = MarkdownTextView()
    view.setContent(renderer.render(stream.update(text), theme: .light))
    let height = view.fittingHeight(forWidth: 400)
    view.frame = NSRect(x: 0, y: 0, width: 400, height: height)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderBack(nil)
    try await settle(view)
    let first = try #require(view.codeBlockViews.first)
    first.scroll(toX: 150)
    for i in 0..<12 {
      text += i % 3 == 0 ? "\nline \(i)" : " more"
      view.setContent(renderer.render(stream.update(text), theme: .light))
      view.frame.size.height = view.fittingHeight(forWidth: 400)
      try await settle(view)
    }
    #expect(view.codeViewsCreated == 1, "built \(view.codeViewsCreated) views for 13 states of one block")
    #expect(view.codeBlockViews.first === first && first.superview != nil)
    #expect(CodeBlockContent.code(fromStorageText: first.textView.string) == (text.components(separatedBy: "```swift\n")[1]))
    #expect(first.scrollView.contentView.bounds.origin.x == 150)
    #expect(abs(first.frame.height - first.content.height) < 0.5)

    // Closing the fence and highlighting recolours the same view, scroll intact.
    text += "\n```\n\nafter"
    view.setContent(renderer.render(stream.update(text), theme: .light))
    let closed = view.rendered!
    await renderer.resolveHighlights(of: closed)
    view.setContent(renderer.render(stream.update(text), theme: .light))
    view.frame.size.height = view.fittingHeight(forWidth: 400)
    try await settle(view)
    #expect(view.codeViewsCreated == 1)
    #expect(view.codeBlockViews.first === first)
    #expect(first.scrollView.contentView.bounds.origin.x == 150)
    // Colours arrive in slices on later run-loop turns.
    var keyword: NSColor?
    for _ in 0..<100 where keyword != MarkdownTheme.light.color(for: .keyword) {
      try await Task.sleep(for: .milliseconds(20))
      keyword = first.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    #expect(keyword == MarkdownTheme.light.color(for: .keyword))
  }

  /// Characters TextKit has laid out in the block (its viewport), against all of them.
  private func laidOut(_ block: CodeBlockView) -> (viewport: Int, total: Int) {
    let layout = block.textView.textLayoutManager!
    let viewport = layout.textViewportLayoutController.viewportRange.map { layout.offset(from: $0.location, to: $0.endLocation) } ?? 0
    return (viewport, block.textView.string.utf16.count)
  }

  @Test func onlyTheVisibleLinesOfALongBlockAreLaidOut() async throws {
    let source = (1...2_000).map { "let value\($0) = compute(\($0)) // a comment that is reasonably long to be realistic" }.joined(separator: "\n")
    let rendered = MarkdownRenderer.shared.render(MarkdownDocument(parsing: "```swift\n\(source)\n```"), theme: .light)
    let clock = ContinuousClock()
    for clipped in [true, false] {
      let view = MarkdownTextView()
      view.setContent(rendered)
      let full = view.fittingHeight(forWidth: 640)
      view.frame = NSRect(x: 0, y: 0, width: 640, height: full)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
      if clipped {
        // Timeline row inside a scroll view.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 700))
        scroll.documentView = view
        window.contentView = scroll
      } else {
        // A host that sizes the row to its content and clips nothing.
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 700))
        window.contentView!.addSubview(view)
      }
      window.orderBack(nil)
      keepAliveWindows.append(window)
      let start = clock.now
      view.textLayoutManager?.textViewportLayoutController.layoutViewport()
      try await Task.sleep(for: .milliseconds(30))
      try await settle(view)
      let elapsed = start.duration(to: clock.now)
      let block = try #require(view.codeBlockViews.first)
      let (viewport, total) = laidOut(block)
      // Main-thread cost of drawing the window once the block exists: its visible lines are
      // laid out and painted here.
      let draw = clock.now
      window.contentView?.displayIfNeeded()
      block.textView.displayIfNeeded()
      let drawn = draw.duration(to: clock.now)
      print("2k-line block, \(clipped ? "in a scroll view" : "unclipped"): viewport \(viewport) of \(total) chars; displayIfNeeded \(drawn); create + settle (incl. ~150 ms of sleeps) \(elapsed)")
      #expect(viewport > 0 && viewport < total / 10, "\(viewport) of \(total) characters laid out")
      if clipped, let scroll = view.enclosingScrollView {
        // Scrolling the timeline moves the viewport inside the block without laying out the rest.
        let t = clock.now
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20_000))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(60))
        let layout = try #require(block.textView.textLayoutManager)
        let range = try #require(layout.textViewportLayoutController.viewportRange)
        let start = layout.offset(from: layout.documentRange.location, to: range.location)
        let length = layout.offset(from: range.location, to: range.endLocation)
        print("  after scrolling to y=20000: viewport starts at char \(start) (\(length) long), \(t.duration(to: clock.now)) incl. 60 ms sleep")
        #expect(start > total / 3 && length < total / 10, "viewport \(start)+\(length) of \(total)")
      }
      #expect(abs(block.frame.height - block.content.height) < 0.5)
    }
  }

  @Test func creatingAndUpdatingALongBlockIsCheapOnTheMainThread() async throws {
    let source = (1...2_000).map { "let value\($0) = compute(\($0)) // a comment that is reasonably long to be realistic" }.joined(separator: "\n")
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    let doc = MarkdownDocument(parsing: "```swift\n\(source)\n```")
    let first = renderer.render(doc, theme: .light)
    await renderer.resolveHighlights(of: first)
    let content = try #require(codeAttachmentsOf(renderer.render(doc, theme: .light)).first?.content)
    let clock = ContinuousClock()
    let t0 = clock.now
    let block = CodeBlockView(content: content)
    block.frame = NSRect(x: 0, y: 0, width: 640, height: content.height)
    let firstCreate = t0.duration(to: clock.now)  // includes TextKit's one-time warm-up in this process
    var create = Duration.seconds(1)
    for _ in 0..<4 {
      let t = clock.now
      let again = CodeBlockView(content: content)
      again.frame = NSRect(x: 0, y: 0, width: 640, height: content.height)
      create = min(create, t.duration(to: clock.now))
    }
    // Colours go on in slices, not all at once: most are still waiting right after creation.
    let slices = (content.code.utf16.count + 5_999) / 6_000
    #expect(block.unstyledSlices >= slices - 2, "\(block.unstyledSlices) of \(slices) slices pending")
    var waits = 0
    while block.unstyledSlices > 0, waits < 500 {
      try await Task.sleep(for: .milliseconds(10))
      waits += 1
    }
    #expect(block.unstyledSlices == 0)
    let storage = try #require(block.textView.textStorage)
    let lastKeyword = (storage.string as NSString).range(of: "let", options: .backwards).location
    #expect(storage.attribute(.foregroundColor, at: lastKeyword, effectiveRange: nil) as? NSColor == MarkdownTheme.light.color(for: .keyword))
    // A streaming block (open fence, no colours yet) gaining a line, and finished highlighting
    // recolouring the same view.
    func open(_ extra: Int) throws -> CodeBlockContent {
      var stream = MarkdownStream()
      let text = "```swift\n\(source)" + (0..<extra).map { "\nlet extra\($0) = 1" }.joined()
      return try #require(codeAttachmentsOf(MarkdownRenderer(highlighter: SyntaxHighlighter()).render(stream.update(text), theme: .light)).first?.content)
    }
    let streaming = CodeBlockView(content: try open(0))
    streaming.frame = NSRect(x: 0, y: 0, width: 640, height: content.height)
    var append = Duration.seconds(1)
    for extra in 1...5 {
      let next = try open(extra)
      let t = clock.now
      streaming.update(to: next)
      append = min(append, t.duration(to: clock.now))
    }
    #expect(streaming.textView.string.hasSuffix("let extra4 = 1"))
    #expect(CodeBlockContent.code(fromStorageText: streaming.textView.string) == (try open(5)).code)
    let plain = try open(0)
    let t2 = clock.now
    streaming.update(to: content)  // closed and highlighted: same view, new colours
    let recolour = t2.duration(to: clock.now)
    _ = plain
    print("2k-line block on the main thread (this build): first create \(firstCreate), later creates \(create) (incl. first colour slice), append one line \(append), switch to highlighted \(recolour) (first slice only; the rest follows in ~75-line slices)")
    #expect(firstCreate < .milliseconds(150) && create < .milliseconds(50) && append < .milliseconds(10), "create \(create), append \(append)")
  }
}

@MainActor private var keepAliveWindows: [NSWindow] = []

@MainActor
private func codeAttachmentsOf(_ rendered: RenderedMarkdown) -> [CodeBlockAttachment] {
  var found: [CodeBlockAttachment] = []
  for segment in rendered.segments {
    segment.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: segment.text.length)) { value, _, _ in
      if let a = value as? CodeBlockAttachment { found.append(a) }
    }
  }
  return found
}

@Suite("Details parsing")
struct DetailsParsingTests {
  @Test func bodyBetweenTheTagsIsNested() {
    let blocks = parse("before\n\n<details>\n<summary>Why</summary>\n\nBody **bold**\n\n- a\n- b\n\n</details>\n\nafter")
    #expect(blocks.count == 3)
    guard case .details(let summary, let open, let body) = blocks[1] else { return bail("no details in \(blocks)") }
    #expect(summary == [.text("Why")])
    #expect(!open)
    #expect(body.count == 2)
  }

  @Test func openAttributeAndNesting() {
    let blocks = parse("<details open>\n<summary>Outer</summary>\n\n<details>\n<summary>Inner</summary>\n\ntext\n\n</details>\n\n</details>")
    guard case .details(_, let open, let body) = blocks.first, case .details(let inner, _, _)? = body.first else {
      return bail("\(blocks)")
    }
    #expect(open)
    #expect(inner == [.text("Inner")])
  }

  @Test func missingSummaryIsDetailsAndAnUnclosedSectionRunsToTheEnd() {
    let blocks = parse("<details>\n\nstill streaming")
    #expect(blocks == [.details(summary: [.text("Details")], isOpen: false, blocks: [.paragraph([.text("still streaming")])])])
  }

  @Test func sameLineAndNoBlankLineForms() {
    #expect(parse("<details><summary>One</summary>\n\nx\n\n</details>").count == 1)
    let compact = parse("<details>\n<summary>Two</summary>\nbody text\n</details>")
    guard case .details(let s, _, let body)? = compact.first else { return bail("\(compact)") }
    #expect(s == [.text("Two")])
    #expect(plain(body) == [.text("body text")])
  }

  @Test func htmlOffLeavesTheTagsLiteral() {
    let blocks = parse("<details>\n<summary>x</summary>\n\nbody\n\n</details>", MarkdownOptions(parsesHTML: false))
    #expect(!blocks.contains { if case .details = $0 { true } else { false } })
  }

  @Test func streamingKeepsASectionInOneChunkUntilItCloses() {
    var stream = MarkdownStream()
    let open = "intro\n\n<details>\n<summary>S</summary>\n\nfirst\n\nsecond\n\n"
    let during = stream.update(open + "third")
    #expect(during.chunks.count == 2, "intro, then the whole open section")
    #expect(during.chunks[1].detailsCount == 1)
    let closed = stream.update(open + "</details>\n\nafter")
    #expect(closed.chunks.count == 3)
    #expect(closed.chunks[1].detailsCount == 1)
    #expect(closed.chunks[2].detailsCount == 0)
  }
}

@MainActor
@Suite("Details rendering")
struct DetailsRenderingTests {
  init() { _ = NSApplication.shared }

  private func toggleURL(in view: MarkdownTextView) -> (URL, Int)? {
    let storage = view.textContentStorage!.textStorage!
    var found: (URL, Int)?
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      if found == nil, let url = value as? URL, url.host == "toggle" { found = (url, range.location) }
    }
    return found
  }

  @Test func collapsedByDefaultAndTheSummaryTogglesIt() async throws {
    let md = "Intro line\n\n<details>\n<summary>Toggle A</summary>\n\nSecret body A\n\nMore body A\n\n</details>\n\nOutro"
    let view = MarkdownTextView()
    var invalidations = 0
    view.onContentSizeInvalidated = { invalidations += 1 }
    view.setContent(await render(md))
    let collapsed = view.textContentStorage!.textStorage!.string
    #expect(collapsed.contains("Toggle A") && !collapsed.contains("Secret body A"))
    let collapsedHeight = view.fittingHeight(forWidth: 400)

    let (url, index) = try #require(toggleURL(in: view))
    #expect(view.textView(view, clickedOnLink: url, at: index))
    #expect(invalidations == 1)
    #expect(view.textContentStorage!.textStorage!.string.contains("Secret body A"))
    let expandedHeight = view.fittingHeight(forWidth: 400)
    #expect(expandedHeight > collapsedHeight + 30)

    let (again, againIndex) = try #require(toggleURL(in: view))
    #expect(view.textView(view, clickedOnLink: again, at: againIndex))
    #expect(!view.textContentStorage!.textStorage!.string.contains("Secret body A"))
    #expect(view.fittingHeight(forWidth: 400) == collapsedHeight)
  }

  @Test func heightCacheKeepsOneEntryPerToggleState() throws {
    let md = "<details>\n<summary>Toggle B</summary>\n\nSecret body B\n\n</details>"
    // No awaits between the counter reads: other tests share the main actor and the counter.
    func fresh() -> RenderedMarkdown { MarkdownRenderer.shared.render(MarkdownDocument(parsing: md), theme: .light) }
    let view = MarkdownTextView()
    let collapsed = fresh()
    view.setContent(collapsed)
    let before = MarkdownLayout.measurements
    let h1 = MarkdownLayout.height(of: collapsed, width: 360)
    #expect(MarkdownLayout.measurements == before + 1)

    let (url, index) = try #require(toggleURL(in: view))
    _ = view.textView(view, clickedOnLink: url, at: index)
    let expanded = try #require(view.rendered)
    #expect(expanded.contentID != collapsed.contentID)
    let h2 = MarkdownLayout.height(of: expanded, width: 360)
    #expect(h2 > h1)
    #expect(MarkdownLayout.measurements == before + 2)
    #expect(MarkdownLayout.height(of: expanded, width: 360) == h2)
    #expect(MarkdownLayout.measurements == before + 2)
    // A fresh render of the same text reflects the remembered choice (recycled rows).
    let recycled = fresh()
    #expect(recycled.contentID == expanded.contentID)
    #expect(MarkdownLayout.height(of: recycled, width: 360) == h2)
    #expect(MarkdownLayout.measurements == before + 2)
  }

  @Test func authoredOpenStartsOpenAndNestedKeysDoNotDependOnExpansion() async throws {
    let md = "<details open>\n<summary>Outer C</summary>\n\nBody C\n\n<details>\n<summary>Inner C</summary>\n\nDeep C\n\n</details>\n\n</details>\n\n<details>\n<summary>Sibling C</summary>\n\nSibling body C\n\n</details>"
    let view = MarkdownTextView()
    view.setContent(await render(md))
    let text = view.textContentStorage!.textStorage!.string
    #expect(text.contains("Body C") && text.contains("Inner C") && !text.contains("Deep C"))
    // Collapse the outer one: the sibling keeps its own state key.
    let (url, index) = try #require(toggleURL(in: view))
    _ = view.textView(view, clickedOnLink: url, at: index)
    let after = view.textContentStorage!.textStorage!.string
    #expect(!after.contains("Body C") && after.contains("Sibling C"))
  }

  @Test func screenshots() async throws {
    let md = """
      Details are collapsed like on the web; the summary row toggles them.

      <details>
      <summary>Collapsed by default</summary>

      Hidden body.

      </details>

      <details open>
      <summary>Authored open</summary>

      Body with **bold** text, `code` and a list:

      - one
      - two

      ```swift
      let a = 1
      ```

      </details>

      After the sections.
      """
    for (theme, name) in [(MarkdownTheme.light, "light"), (.dark, "dark")] {
      for width in [420.0, 900] {
        let png = try #require(await MarkdownDemo.png(of: md, width: width, theme: theme))
        try png.write(to: URL(fileURLWithPath: "\(artifacts)/details-\(name)-\(Int(width)).png"))
      }
    }
  }
}

@Suite("Pull-request references")
struct ReferenceTests {
  private let options = MarkdownOptions(pullRequestRepositoryURL: "https://github.com/acme/app/")

  private func links(_ blocks: [MarkdownBlock]) -> [(String, URL)] {
    plain(blocks).compactMap {
      if case .link(.web(let url), let label) = $0 { (MarkdownInline.plainText(label), url) } else { nil }
    }
  }

  @Test func issueAndCommitReferencesLinkLikeThePullRequestBody() {
    let sha = "0123456789abcdef0123456789abcdef01234567"
    let found = links(parse("Fixes #123, see (#45) and \(sha).", options))
    #expect(found.map(\.0) == ["#123", "#45", "0123456"])
    #expect(found.map(\.1.absoluteString) == [
      "https://github.com/acme/app/issues/123", "https://github.com/acme/app/issues/45",
      "https://github.com/acme/app/commit/\(sha)",
    ])
  }

  @Test func onlyWhereTheWebDoes() {
    let off = links(parse("Fixes #123"))
    #expect(off.isEmpty, "chat messages do not autolink")
    for text in ["abc#12", "owner/repo#9", "#0", "#12abc", "a#1", "`#5`", "[x](https://e.com) #", "[#7](https://e.com/p)"] {
      let blocks = parse(text, options)
      let issueLinks = links(blocks).filter { $0.1.absoluteString.contains("acme/app") }
      #expect(issueLinks.isEmpty, "\(text) -> \(issueLinks)")
    }
    // A SHA glued to a word is not a commit; one after "(" is.
    let sha = String(repeating: "a", count: 40)
    #expect(links(parse("x\(sha)", options)).isEmpty)
    #expect(links(parse("(\(sha))", options)).count == 1)
  }

  @Test func autolinkedUrlsKeepTheirFragment() {
    let found = links(parse("see https://example.com/a#12 and #12", options))
    #expect(found.map(\.1.absoluteString) == ["https://example.com/a#12", "https://github.com/acme/app/issues/12"])
  }
}

@Suite("Skill chips")
struct SkillChipTests {
  private let options = MarkdownOptions(
    softBreaksAsNewlines: true, parsesHTML: false,
    skills: [MarkdownSkill(name: "review-pr"), MarkdownSkill(name: "deploy", displayName: "Ship it")])

  private func chips(_ text: String) -> [String] {
    var found: [String] = []
    func walk(_ inlines: [MarkdownInline]) {
      for i in inlines {
        switch i {
        case .context("skill", let id, let label): found.append("\(id)=\(label)")
        case .emphasis(let c), .strong(let c), .strikethrough(let c), .styled(_, let c), .link(_, let c): walk(c)
        default: break
        }
      }
    }
    func visit(_ block: MarkdownBlock) {
      switch block {
      case .paragraph(let i, _), .heading(_, let i): walk(i)
      case .quote(let c), .alert(_, let c): c.forEach(visit)
      case .list(let l): l.items.forEach { $0.blocks.forEach(visit) }
      default: break
      }
    }
    parse(text, options).forEach(visit)
    return found
  }

  @Test func knownSkillsBecomeChipsWithTheWebLabel() {
    #expect(chips("Run $review-pr then $deploy now") == ["review-pr=Review Pr", "deploy=Ship it"])
    #expect(chips("$review-pr at the start\n$deploy on a new line") == ["review-pr=Review Pr", "deploy=Ship it"])
  }

  @Test func theWebTokenRulesApply() {
    #expect(chips("costs $5 or $1k or $2e9").isEmpty)
    #expect(chips("$unknown-skill and a$review-pr and $review-pr, and $review-pr.").isEmpty)
    #expect(chips("`$review-pr` and [$review-pr](https://e.com)").isEmpty)
    #expect(chips("**bold $review-pr** and _em $deploy_") == ["review-pr=Review Pr", "deploy=Ship it"])
    #expect(chips("- item $review-pr\n- [ ] task $deploy") == ["review-pr=Review Pr", "deploy=Ship it"])
    #expect(chips("> quoted $deploy") == ["deploy=Ship it"])
    #expect(chips("# Heading $deploy").isEmpty, "web only rewrites paragraphs and list items")
    #expect(parse("$review-pr", MarkdownOptions()) == [.paragraph([.text("$review-pr")])])
  }

  @Test func optionsAreAPartOfTheChunkIdentity() {
    var a = MarkdownStream(options: options)
    var b = MarkdownStream(options: MarkdownOptions(softBreaksAsNewlines: true, parsesHTML: false))
    #expect(a.update("$review-pr").contentID != b.update("$review-pr").contentID)
  }
}

@MainActor
@Suite("Chips and task lists")
struct ChipRenderingTests {
  init() { _ = NSApplication.shared }

  @Test func skillChipCopiesAsItsRawToken() async throws {
    let options = MarkdownOptions(softBreaksAsNewlines: true, skills: [MarkdownSkill(name: "review-pr")])
    let view = MarkdownTextView()
    view.setContent(await render("please $review-pr this", options: options))
    _ = view.fittingHeight(forWidth: 400)
    let storage = view.textContentStorage!.textStorage!
    #expect(storage.string.contains("\u{FFFC}"))
    view.setSelectedRange(NSRange(location: 0, length: storage.length))
    #expect(view.selectedPlainText() == "please $review-pr this")
    // A skill chip is not interactive.
    var linked = false
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { linked = true } }
    #expect(!linked)
  }

  @Test func partialSelectionCopiesAsMarkdown() async throws {
    let md = "Intro **bold** and *em* with `code` and [site](https://example.com/a) done.\n\n- alpha\n- beta ~~gone~~\n\n```ts\nconst a = 1\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |"
    let view = MarkdownTextView()
    view.setContent(await render(md))
    _ = view.fittingHeight(forWidth: 500)
    let storage = view.textContentStorage!.textStorage!
    let ns = storage.string as NSString
    view.setSelectedRange(NSRange(location: ns.range(of: "bold").location, length: ns.range(of: "done").location - ns.range(of: "bold").location))
    #expect(view.selectedMarkdown() == "**bold** and *em* with `code` and [site](https://example.com/a) ")
    view.setSelectedRange(NSRange(location: ns.range(of: "alpha").location, length: storage.length - ns.range(of: "alpha").location))
    let rest = try #require(view.selectedMarkdown())
    #expect(rest.hasPrefix("alpha\n- beta ~~gone~~\n"))
    #expect(rest.contains("```ts\nconst a = 1\n```\n"))
    #expect(rest.contains("| a | b |\n| --- | --- |\n| 1 | 2 |"))
    view.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(view.selectedMarkdown() == nil)
  }

  @Test func taskMarkersHangLeftOfTheTextAndNeverReachIt() async throws {
    for size in [12.0, 14, 20, 32] {
      let theme = MarkdownTheme.t3ChatLight(bodySize: size)
      let rendered = await render("- [x] a long task line that wraps around the edge of the container\n- [ ] open\n  - [ ] nested", theme: theme)
      let storage = NSMutableAttributedString()
      rendered.segments.forEach { storage.append($0.text) }
      var checked = 0
      storage.enumerateAttribute(.t3MarkerWidth, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
        guard let column = value as? CGFloat,
          let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        else { return }
        let glyph = (storage.attributedSubstring(from: range).string.dropLast() as Substring)
        let glyphWidth = (String(glyph) as NSString).size(withAttributes: [.font: theme.bodyFont]).width
        #expect(glyphWidth < column, "size \(size): box \(glyphWidth) must fit its \(column) column")
        // The text starts at the hanging indent: the marker's tab stop and the wrapped lines agree.
        #expect(style.tabStops.first?.location == style.headIndent)
        #expect(style.firstLineHeadIndent + column == style.headIndent)
        checked += 1
      }
      #expect(checked == 3)
    }
  }

  @Test func screenshots() async throws {
    let md = """
      Here is a message with a skill: please run $review-pr on the branch, then $deploy now.
      Second line mentions an unknown $nothing and an amount of $5.

      Also [shot.png](t3-context://v1/image/ctx_1) and [notes](t3-context://v1/file/ctx_2).

      Fixes #123 and the regression from abcdef0123456789abcdef0123456789abcdef01.

      - [x] Write the parser
      - [ ] Wire the host and the line is long enough that it wraps onto a second line to show the hanging indent
        - [ ] Nested task
        - [x] Nested done
      - A plain bullet
      """
    let options = MarkdownOptions(
      softBreaksAsNewlines: true,
      skills: [MarkdownSkill(name: "review-pr"), MarkdownSkill(name: "deploy", displayName: "Deploy")],
      pullRequestRepositoryURL: "https://github.com/acme/app")
    for (theme, name) in [(MarkdownTheme.light, "light"), (.dark, "dark")] {
      for width in [420.0, 900] {
        let png = try #require(await MarkdownDemo.png(of: md, width: width, theme: theme, options: options))
        try png.write(to: URL(fileURLWithPath: "\(artifacts)/chips-tasks-refs-\(name)-\(Int(width)).png"))
      }
    }
  }
}

@MainActor
@Suite("Large messages")
struct LargeMessageTests {
  init() { _ = NSApplication.shared }

  @Test func twoThousandLinesLayOutQuickly() async throws {
    let clock = ContinuousClock()
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    let text = mixedMarkdown(lines: 2_000)
    let t0 = clock.now
    let document = MarkdownDocument(parsing: text)
    let rendered = renderer.render(document, theme: .light)
    let t1 = clock.now
    let height = MarkdownLayout.height(of: rendered, width: 640)
    let t2 = clock.now
    let again = MarkdownLayout.height(of: rendered, width: 640)
    let t3 = clock.now
    print("2k-line mixed message: parse+render \(t0.duration(to: t1)), first layout \(t1.duration(to: t2)), cached \(t2.duration(to: t3))")
    #expect(height == again && height > 1_000)
    #expect(t1.duration(to: t2) < .seconds(2))
  }

  @Test func aTwoThousandLineCodeBlockIsOneAttachmentAndItsViewIsLazy() async throws {
    let code = (1...2_000).map { "let value\($0) = compute(\($0)) // a comment that is reasonably long to be realistic" }.joined(separator: "\n")
    let md = "```swift\n\(code)\n```"
    let clock = ContinuousClock()
    let rendered = MarkdownRenderer.shared.render(MarkdownDocument(parsing: md), theme: .light)
    let t0 = clock.now
    let height = MarkdownLayout.height(of: rendered, width: 640)
    let t1 = clock.now
    let content = try #require(codeAttachmentsOf(rendered).first?.content)
    #expect(content.lineCount == 2_000)
    #expect(height >= content.height)
    // The text view itself only holds one character for the whole block.
    let view = MarkdownTextView()
    view.setContent(rendered)
    #expect(view.textContentStorage!.textStorage!.length == 1)
  }
}

