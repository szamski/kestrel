import AppKit
import SwiftUI
import Testing

@testable import T3Markdown

@MainActor
@Suite("SwiftUI wrapper")
struct SwiftUITests {
  init() { _ = NSApplication.shared }

  private func textView(in root: NSView) -> MarkdownTextView? {
    if let v = root as? MarkdownTextView { return v }
    for s in root.subviews { if let v = textView(in: s) { return v } }
    return nil
  }

  @Test func sizesItselfFromTheCachedLayoutAndHighlightsAfterwards() async throws {
    let text = "Intro paragraph.\n\n```swift\nlet a = 1\n```\n\n- one\n- two"
    let host = NSHostingView(rootView: MarkdownView(text, theme: .light).frame(width: 420))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let view = try #require(textView(in: host))
    let expected = MarkdownLayout.height(of: text, width: 420, theme: .light)
    #expect(abs(host.fittingSize.height - expected) < 1, "hosting \(host.fittingSize.height) vs \(expected)")

    // Highlight.js finishes off the main thread and the block is rebuilt with coloured tokens.
    var keyword: NSColor?
    for _ in 0..<100 where keyword != MarkdownTheme.light.color(for: .keyword) {
      try await Task.sleep(for: .milliseconds(50))
      keyword = codeAttachments(in: view).first?.content.bodyText().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    #expect(keyword == MarkdownTheme.light.color(for: .keyword))
  }

  @Test func growingTextUpdatesTheSameView() throws {
    var text = "First"
    let host = NSHostingView(rootView: MarkdownView(text).frame(width: 300))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let view = try #require(textView(in: host))
    let h1 = host.fittingSize.height
    text += "\n\n" + String(repeating: "More words that wrap. ", count: 30)
    host.rootView = MarkdownView(text).frame(width: 300)
    host.layoutSubtreeIfNeeded()
    #expect(textView(in: host) === view)
    #expect(host.fittingSize.height > h1 + 40)
    #expect(view.markdown == text)
  }
}
