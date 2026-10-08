import AppKit
import Testing

@testable import T3Markdown

private let artifacts = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78/stageD-markdown"

private let stress = #"""
> Quote level one with **bold**
> > Nested quote
> > - list in quote
>
> ```ts
> const inQuote = true
> ```

1. Item with code

   ```bash
   echo "inside list"
   ```

2. Item with a table

   | A | B |
   |---|---|
   | 1 | 2 |

<p align="center">
  <b>Centered</b> html paragraph
</p>

```swift
\#((1...70).map { "let line\($0) = \($0) // long enough to need some width to be interesting here" }.joined(separator: "\n"))
```

| Column with a long heading that wants lots of room | Another very long heading text that wraps | Third |
| --- | --- | --- |
| A cell with quite a lot of text inside it so the column has to wrap when narrow | `code` and [link](https://example.com) | x |

Streaming tail with an open fence:

```python
def partial():
    return 1
"""#

@MainActor
@Suite("Stress screenshots")
struct StressRenderTests {
  init() { _ = NSApplication.shared }

  @Test func nestedAndNarrowLayouts() async throws {
    let wide = try #require(await MarkdownDemo.png(of: stress, width: 640, theme: .light))
    try wide.write(to: URL(fileURLWithPath: "\(artifacts)/stress-light.png"))
    let narrow = try #require(await MarkdownDemo.png(of: stress, width: 360, theme: .dark))
    try narrow.write(to: URL(fileURLWithPath: "\(artifacts)/stress-dark-narrow.png"))
  }
}
