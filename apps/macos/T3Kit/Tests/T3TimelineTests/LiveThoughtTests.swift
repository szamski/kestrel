import Testing

@testable import T3Timeline

/// Expected values come from `liveThoughtLine` of presentation.ts (see scripts/timeline-oracle).
@Suite struct LiveThoughtTests {
  @Test(arguments: [
    ("**Reading the code**\nFirst look at the module.", "Reading the code"),
    ("Now run the tests and check. Then fix.", "Now run the tests and check."),
    ("# Heading\n- item one is here. Second.", "Heading item one is here."),
    ("See [the docs](http://x.y/z) for `code` and **bold** text. Next sentence.", "See the docs for code and bold text."),
    ("plain without end", "plain without end"),
    ("He said \"stop.\" Then left.", "He said \"stop.\""),
    ("_italic_ start and *more* text! Done", "italic start and more text!"),
    ("  **Title with spaces**   \nbody", "Title with spaces"),
  ])
  func matchesTheWeb(input: String, expected: String) {
    #expect(liveThoughtLine(input) == expected)
  }
}
