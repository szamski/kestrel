import AppKit
import Foundation
import Testing

@testable import T3Markdown

private let artifacts = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78/stageD-markdown"

@MainActor
func render(_ text: String, theme: MarkdownTheme = .light, renderer: MarkdownRenderer = .shared, options: MarkdownOptions = MarkdownOptions()) async -> RenderedMarkdown {
  let doc = MarkdownDocument(parsing: text, options: options)
  let first = renderer.render(doc, theme: theme)
  await renderer.resolveHighlights(of: first)
  return renderer.render(doc, theme: theme)
}

@MainActor
@Suite("Text view")
struct ViewTests {
  init() { _ = NSApplication.shared }

  @Test func measuredHeightMatchesTheLiveView() async {
    let rendered = await render(MarkdownDemo.sample)
    for width in [320.0, 480, 640, 900] {
      let measured = MarkdownLayout.height(of: rendered, width: width)
      let view = MarkdownTextView()
      view.setContent(rendered)
      let live = view.fittingHeight(forWidth: width)
      #expect(abs(measured - live) < 0.5, "width \(width): measured \(measured), live \(live)")
      #expect(measured > 100)
    }
  }

  /// Reference: lay out everything from scratch and read TextKit's own usage bounds.
  private func referenceHeight(_ rendered: RenderedMarkdown, width: CGFloat) -> CGFloat {
    let view = MarkdownTextView()
    view.setContent(rendered)
    view.setFrameSize(NSSize(width: width, height: 10))
    let layout = view.textLayoutManager!
    layout.ensureLayout(for: layout.documentRange)
    return ceil(layout.usageBoundsForTextContainer.height)
  }

  @Test func fastHeightEqualsAFullLayoutAcrossStreamingEdits() async {
    var stream = MarkdownStream()
    var text = mixedMarkdown(lines: 300) + "\n```python\ndef partial():\n"
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    let view = MarkdownTextView()
    for step in 0..<12 {
      text += step % 4 == 0 ? "    return \(step)\n" : "# more words that wrap around at narrow widths \(step)\n"
      let rendered = renderer.render(stream.update(text), theme: .light)
      view.setContent(rendered)
      for width in [280.0, 640] {
        let fast = view.fittingHeight(forWidth: width)
        #expect(fast == referenceHeight(rendered, width: width), "step \(step) width \(width)")
      }
    }
  }

  @Test func heightIsCachedByContentWidthAndTheme() async {
    // No awaits between the counter reads: other tests share the main actor and the counter.
    let rendered = await render("Hello **world**\n\n- a\n- b")
    let dark = await render("Hello **world**\n\n- a\n- b", theme: .dark)
    let before = MarkdownLayout.measurements
    let h1 = MarkdownLayout.height(of: rendered, width: 400)
    let h2 = MarkdownLayout.height(of: rendered, width: 400)
    #expect(h1 == h2)
    #expect(MarkdownLayout.measurements == before + 1)
    _ = MarkdownLayout.height(of: rendered, width: 300)
    #expect(MarkdownLayout.measurements == before + 2)
    // Same content again at a width already seen: no layout.
    _ = MarkdownLayout.height(of: rendered, width: 400)
    #expect(MarkdownLayout.measurements == before + 2)
    _ = MarkdownLayout.height(of: dark, width: 400)
    #expect(MarkdownLayout.measurements == before + 3)
  }

  @Test func narrowerWidthIsTaller() async {
    let rendered = await render(String(repeating: "A long sentence that has to wrap. ", count: 20))
    #expect(MarkdownLayout.height(of: rendered, width: 200) > MarkdownLayout.height(of: rendered, width: 600) * 2)
  }

  @Test func selectionAcrossBlocksCopiesSensiblePlainText() async throws {
    let text = """
      # Title

      First paragraph with `code`.

      - one
      - two

      ```swift
      let a = 1
      let b = 2
      ```

      | h1 | h2 |
      | -- | -- |
      | x | y |

      ---

      Last [link](https://example.com).
      """
    let rendered = await render(text)
    let view = MarkdownTextView()
    view.setContent(rendered)
    _ = view.fittingHeight(forWidth: 500)
    view.setSelectedRange(NSRange(location: 0, length: view.textContentStorage!.textStorage!.length))
    let copied = try #require(view.selectedPlainText())
    #expect(copied.contains("Title\nFirst paragraph with code.\n"))
    #expect(copied.contains("• one\n• two\n"))
    #expect(copied.contains("let a = 1\nlet b = 2\n"))
    #expect(!copied.contains("Copy"), "code header chrome must not be copied: \(copied)")
    #expect(!copied.contains("swift\n") || copied.contains("let a"))
    #expect(copied.contains("| h1 | h2 |\n| --- | --- |\n| x | y |"))
    #expect(copied.contains("---"))
    #expect(copied.hasSuffix("Last link."))
    #expect(!copied.contains("\u{2028}") && !copied.contains("\u{FFFC}") && !copied.contains("\u{200B}"))
  }

  @Test func partialSelectionInsideACodeBlockCopiesJustThoseLines() async throws {
    let view = try await liveView("```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```", width: 400)
    let block = try #require(view.codeBlockViews.first)
    let text = block.textView.string as NSString
    let start = text.range(of: "let b").location
    block.textView.setSelectedRange(NSRange(location: start, length: ("let b = 2\nlet c" as NSString).length))
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    block.textView.copy(nil)
    #expect(pasteboard.string(forType: .string) == "let b = 2\nlet c")
  }

  @Test func markdownSourceIsAvailableForWholeMessageCopy() async {
    let text = "# Hi\n\n**raw** `source`"
    let view = MarkdownTextView()
    view.setContent(await render(text))
    #expect(view.markdown == text)
  }

  @Test func typedLinksSurviveTheRoundTripThroughAttributedText() async {
    let md = """
      [web](https://example.com/a?b=1) [file](/Users/a/b.swift#L9) `src/x.ts:3` [anchor](#top)
      [chip](t3-context://v1/image/ctx_1) [Assistant quote](t3-citation://v1/e/t/m?text=hi&start=0&end=2&prefix=&suffix=)
      ::artifact-template{skill_name="artifact-template-x" skill_directory="/s" display_name="X" artifact_kind="site"}
      """
    let rendered = await render(md, options: MarkdownOptions(baseDirectory: "/repo"))
    var found: [MarkdownLink] = []
    for seg in rendered.segments {
      seg.text.enumerateAttribute(.link, in: NSRange(location: 0, length: seg.text.length)) { value, _, _ in
        if let value, case .link(let l)? = MarkdownLinkCoding.decode(value) { found.append(l) }
      }
    }
    #expect(found.contains(.web(URL(string: "https://example.com/a?b=1")!)))
    #expect(found.contains(.file(MarkdownFileTarget(path: "/Users/a/b.swift", line: 9))))
    #expect(found.contains(.file(MarkdownFileTarget(path: "/repo/src/x.ts", line: 3))))
    #expect(found.contains(.anchor("top")))
    #expect(found.contains(.context(kind: "image", id: "ctx_1")))
    #expect(found.contains { if case .citation(let c) = $0 { c.text == "hi" } else { false } })
    #expect(found.contains { if case .artifactTemplate(let t) = $0 { t.skillName == "artifact-template-x" } else { false } })
  }

  @Test func clickingALinkInsideATableReportsItsTypedLink() async throws {
    let md = "| File | Note |\n| --- | --- |\n| [main.swift](/Users/a/main.swift#L5) | plain |"
    let rendered = await render(md)
    let view = MarkdownTextView()
    var received: [MarkdownLink] = []
    view.onLink = { received.append($0) }
    view.setContent(rendered)
    let width: CGFloat = 500
    let height = view.fittingHeight(forWidth: width)
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
    // The link is in the first cell of the second row; find the table rect and aim there.
    let probe = try #require(view.attachmentContent(at: CGPoint(x: 20, y: height / 2)))
    let rect = probe.1
    let target = CGPoint(x: rect.minX + 24, y: rect.maxY - 12)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(target, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    // Aim check first: `mouseDown` would otherwise fall through to AppKit's tracking loop.
    let (content, _) = try #require(view.attachmentContent(at: target))
    let table = try #require(content as? TableContent)
    _ = try #require(table.link(at: CGPoint(x: target.x - rect.minX, y: target.y - rect.minY)), "no link under the click point")
    view.mouseDown(with: event)
    #expect(received == [.file(MarkdownFileTarget(path: "/Users/a/main.swift", line: 5))])
  }

  @Test func copyButtonCopiesTheCodeNotTheChrome() async throws {
    let view = try await liveView("```ts\nconst a = 1\nconst b = 2\n```", width: 400)
    let block = try #require(view.codeBlockViews.first)
    NSPasteboard.general.clearContents()
    block.copyCode()
    #expect(NSPasteboard.general.string(forType: .string) == "const a = 1\nconst b = 2")
  }

  @Test func streamingReplacesOnlyTheTail() async {
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    var stream = MarkdownStream()
    var text = mixedMarkdown(lines: 400)
    let view = MarkdownTextView()
    view.setContent(renderer.render(stream.update(text), theme: .light))
    let total = view.textContentStorage!.textStorage!.length
    var worst = 0
    var tail = 0
    for i in 0..<60 {
      text += i == 0 ? "## Live\n\nwords " : "more "
      let rendered = renderer.render(stream.update(text), theme: .light)
      view.setContent(rendered)
      worst = max(worst, view.lastReplacedLength)
      tail = max(tail, rendered.segments.suffix(2).reduce(0) { $0 + $1.text.length })
    }
    // Code blocks are one character each now, so "small" is the last chunks, not a fraction.
    #expect(worst <= tail && worst < total / 2, "replaced \(worst) of \(total) characters for one delta (tail \(tail))")
  }

  @Test func highlightingFinishingRestylesWithoutReplacingText() async throws {
    let renderer = MarkdownRenderer(highlighter: SyntaxHighlighter())
    let doc = MarkdownDocument(parsing: "intro\n\n```swift\nlet a = 1\n```")
    let first = renderer.render(doc, theme: .light)
    #expect(first.pendingHighlights.count == 1)
    let view = MarkdownTextView()
    view.setContent(first)
    view.setSelectedRange(NSRange(location: 1, length: 3))
    await renderer.resolveHighlights(of: first)
    let second = renderer.render(doc, theme: .light)
    #expect(second.pendingHighlights.isEmpty)
    view.setContent(second)
    #expect(view.lastReplacedLength == 0)
    #expect(view.selectedRange() == NSRange(location: 1, length: 3))
    // The block's own text carries the colours.
    let attachment = try #require(codeAttachments(in: view).first)
    let body = attachment.content.bodyText()
    let color = body.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color == MarkdownTheme.light.color(for: .keyword))
  }
}

@MainActor
func codeAttachments(in view: MarkdownTextView) -> [CodeBlockAttachment] {
  var found: [CodeBlockAttachment] = []
  let storage = view.textContentStorage!.textStorage!
  storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
    if let a = value as? CodeBlockAttachment { found.append(a) }
  }
  return found
}

/// A view in a window whose code blocks have been created by the viewport pass.
@MainActor
func liveView(_ markdown: String, width: CGFloat, theme: MarkdownTheme = .light, options: MarkdownOptions = MarkdownOptions()) async throws -> MarkdownTextView {
  let rendered = await render(markdown, theme: theme, options: options)
  let view = MarkdownTextView()
  view.setContent(rendered)
  let height = view.fittingHeight(forWidth: width)
  view.frame = NSRect(x: 0, y: 0, width: width, height: height)
  let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = view
  window.orderBack(nil)
  keepAlive.append(window)
  try await settle(view)
  return view
}

/// Code block views appear a run-loop turn after layout.
@MainActor
func settle(_ view: MarkdownTextView) async throws {
  for _ in 0..<4 {
    view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
  }
}

@MainActor private var keepAlive: [NSWindow] = []

@MainActor
@Suite("Streaming render budget")
struct StreamingRenderTests {
  init() { _ = NSApplication.shared }

  @Test func threeThousandLinesPlusFiveHundredDeltasDoesNotRework() async {
    let highlighter = SyntaxHighlighter()
    let renderer = MarkdownRenderer(highlighter: highlighter)
    var stream = MarkdownStream()
    var text = mixedMarkdown(lines: 3_000)
    let doc0 = stream.update(text)
    let first = renderer.render(doc0, theme: .light)
    await renderer.resolveHighlights(of: first)
    let codeBlocks = Set(first.pendingHighlights).count
    #expect(codeBlocks > 50)
    #expect(highlighter.highlightCalls == codeBlocks)

    let view = MarkdownTextView()
    let rendered0 = renderer.render(doc0, theme: .light)
    #expect(rendered0.pendingHighlights.isEmpty)
    view.setContent(rendered0)
    let total = view.textContentStorage!.textStorage!.length
    _ = MarkdownLayout.height(of: rendered0, width: 640)

    let built0 = renderer.chunksBuilt
    let parsed0 = stream.stats.blocksParsed
    let calls0 = highlighter.highlightCalls
    var worstReplaced = 0
    var worstMeasured = 0
    var tail = 0
    let clock = ContinuousClock()
    let start = clock.now
    var phases = [Duration](repeating: .zero, count: 4)
    let filler = Array("streaming words arrive a few characters at a time. ")
    for i in 0..<500 {
      if i == 0 { text += "## Live section\n\n" }
      if i == 200 { text += "\n\n```swift\n" }
      if i == 300 { text += "\n```\n\nAfter the fence " }
      text += String((0..<6).map { filler[(i * 6 + $0) % filler.count] })
      let t0 = clock.now
      let document = stream.update(text)
      let t1 = clock.now
      let rendered = renderer.render(document, theme: .light)
      let t2 = clock.now
      view.setContent(rendered)
      let t3 = clock.now
      _ = MarkdownLayout.height(of: rendered, width: 640)
      let t4 = clock.now
      phases[0] += t0.duration(to: t1); phases[1] += t1.duration(to: t2); phases[2] += t2.duration(to: t3); phases[3] += t3.duration(to: t4)
      worstReplaced = max(worstReplaced, view.lastReplacedLength)
      worstMeasured = max(worstMeasured, MarkdownLayout.lastReplacedLength)
      tail = max(tail, rendered.segments.suffix(2).reduce(0) { $0 + $1.text.length })
    }
    let elapsed = start.duration(to: clock.now)
    print("phases parse/render/apply/measure: \(phases)")
    print("3k-line message + 500 deltas (render + apply + measure): \(elapsed)")

    // Parsing: nothing stable was parsed again.
    #expect((stream.stats.blocksParsed - parsed0) <= 500 * 4)
    // Rendering: at most the tail chunk(s) per delta.
    #expect(renderer.chunksBuilt - built0 <= 500 * 2)
    // Highlighting: only the one new fence was highlighted, once, after it closed.
    #expect(highlighter.highlightCalls - calls0 <= 1)
    // The text view and the measuring view replace only the tail.
    #expect(worstReplaced <= tail && worstReplaced < total / 10, "replaced \(worstReplaced) of \(total) (tail \(tail))")
    #expect(worstMeasured <= tail && worstMeasured < total / 10, "measured replaced \(worstMeasured) of \(total) (tail \(tail))")
  }
}
