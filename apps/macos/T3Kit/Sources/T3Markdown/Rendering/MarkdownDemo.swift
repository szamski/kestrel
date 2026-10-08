import AppKit
import SwiftUI

/// Sample content and an offscreen renderer, for previews, screenshots and tests.
public enum MarkdownDemo {
  public static let sample = #"""
  # Native Markdown

  Assistant text with **bold**, *italic*, ~~strike~~, `inline code`, a [web link](https://example.com), a file
  reference [`MarkdownView.swift:42`](apps/macos/T3Kit/Sources/T3Markdown/Rendering/MarkdownView.swift#L42) and
  H<sub>2</sub>O with x<sup>2</sup>. Bare URLs link too: https://example.com/docs.
  Context chip [shot.png](t3-context://v1/image/ctx_1) and a quote chip
  [Assistant quote](t3-citation://v1/env/thread/msg?text=The+answer+is+42&start=3&end=21&prefix=&suffix=).

  > [!NOTE]
  > Alerts keep GitHub's five kinds. They render with a coloured bar and title.

  > [!WARNING]
  > Careful: this one is **amber**.

  ## Lists

  - First item with a long line that wraps around so the hanging indent is visible across more than one line of text
  - [x] Done task
  - [ ] Open task
    1. Nested ordered
    2. Second

  ## Code

  ```swift
  struct Greeter {
    let name: String
    func greet() -> String { "Hello, \(name)!" } // comment
  }
  ```

  ```diff
  - old line
  + new line
  ```

  | File | Lines | Status |
  | :--- | ---: | :---: |
  | `Package.swift` | 42 | ok |
  | [MarkdownView.swift](apps/macos/T3Kit/Sources/T3Markdown/Rendering/MarkdownView.swift) | 118 | changed |

  ---

  ![Screenshot](https://example.com/shot.png)

  :codex-file-citation{path="outputs/report.xlsx" line_range_start="7"}

  ::artifact-template{skill_name="artifact-template-hello-world" skill_directory="/Users/test/.codex/skills/artifact-template-hello-world" display_name="Hello World" artifact_kind="document"}

  <details>
  <summary>HTML subset</summary>

  Press <kbd>⌘</kbd><kbd>C</kbd> to copy. <script>alert(1)</script> stays literal.

  </details>
  """#

  /// Renders `text` offscreen at `width` and returns PNG data; `codeScroll` is how far every
  /// code block is scrolled sideways.
  @MainActor
  public static func png(
    of text: String = sample, width: CGFloat = 640, theme: MarkdownTheme = .light, options: MarkdownOptions = MarkdownOptions(),
    scale: CGFloat = 2, settle: Bool = true, codeScroll: CGFloat = 0
  ) async -> Data? {
    let rendered = MarkdownRenderer.shared.render(MarkdownDocument(parsing: text, options: options), theme: theme)
    if settle, await MarkdownRenderer.shared.resolveHighlights(of: rendered) {}
    let final = MarkdownRenderer.shared.render(MarkdownDocument(parsing: text, options: options), theme: theme)
    let view = MarkdownTextView()
    view.setContent(final)
    let inset: CGFloat = 24
    let height = view.fittingHeight(forWidth: width - inset * 2)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + inset * 2))
    container.wantsLayer = true
    view.frame = NSRect(x: inset, y: inset, width: width - inset * 2, height: height)
    container.addSubview(view)
    let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    window.contentView = container
    container.layer?.backgroundColor = (theme.isDark ? NSColor(srgbRed: 0.122, green: 0.102, blue: 0.141, alpha: 1) : NSColor(srgbRed: 0.992, green: 0.969, blue: 0.992, alpha: 1)).cgColor
    container.layoutSubtreeIfNeeded()
    view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
    // Code blocks are live views the viewport pass creates a run-loop turn after layout;
    // wait for them, then scroll them before drawing.
    for _ in 0..<4 {
      view.textLayoutManager?.textViewportLayoutController.layoutViewport()
      container.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(40))
    }
    for block in view.codeBlockViews { block.scroll(toX: codeScroll) }
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return nil }
    rep.size = container.bounds.size
    container.cacheDisplay(in: container.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}

#Preview("Markdown (light)") {
  ScrollView { MarkdownView(MarkdownDemo.sample, theme: .light).padding(24) }
    .frame(width: 680, height: 800)
}

#Preview("Markdown (dark)") {
  ScrollView { MarkdownView(MarkdownDemo.sample, theme: .dark).padding(24) }
    .frame(width: 680, height: 800)
    .preferredColorScheme(.dark)
}
