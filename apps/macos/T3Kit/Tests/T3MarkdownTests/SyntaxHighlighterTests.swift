import Foundation
import Testing

@testable import T3Markdown

/// The text a span covers.
private func covered(_ code: String, _ spans: [HighlightSpan], _ role: SyntaxRole) -> [String] {
  let u = Array(code.utf16)
  return spans.filter { $0.role == role }.map {
    String(decoding: u[$0.location..<($0.location + $0.length)], as: UTF16.self)
  }
}

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
  @Test func swiftKeywordsAndStrings() {
    let code = "let greeting = \"héllo\" // hi\nfunc run() -> Int { 1 }"
    let result = SyntaxHighlighter().highlight(code: code, language: "swift")
    #expect(result.language == "swift")
    #expect(covered(code, result.spans, .keyword).contains("let"))
    #expect(covered(code, result.spans, .keyword).contains("func"))
    #expect(covered(code, result.spans, .string) == ["\"héllo\""])
    #expect(covered(code, result.spans, .comment) == ["// hi"])
  }

  @Test func entitiesAndSurrogatePairsKeepOffsetsAligned() {
    let code = "if (a < b && c > 1) { return \"😀 x&y\"; } // done"
    let result = SyntaxHighlighter().highlight(code: code, language: "ts")
    #expect(covered(code, result.spans, .string) == ["\"😀 x&y\""])
    #expect(covered(code, result.spans, .comment) == ["// done"])
    #expect(covered(code, result.spans, .keyword).contains("return"))
  }

  @Test func spansNeverOverlapOrLeaveTheText() {
    let code = "const re = /a+b/g;\nclass A extends B { m(x: number): string { return `v=${x}` } }"
    let result = SyntaxHighlighter().highlight(code: code, language: "typescript")
    var end = 0
    for s in result.spans {
      #expect(s.location >= end)
      #expect(s.length > 0)
      end = s.location + s.length
    }
    #expect(end <= code.utf16.count)
  }

  @Test(arguments: [
    ("swift", "let x = 1"), ("ts", "const x: number = 1"), ("tsx", "const a = <div/>"), ("js", "const x = 1"),
    ("json", "{\"a\": 1}"), ("bash", "echo $HOME"), ("sh", "ls -la"), ("python", "def f(): pass"), ("rust", "fn main() {}"),
    ("go", "func main() {}"), ("diff", "+ added\n- removed"), ("yaml", "a: 1"), ("toml", "a = 1"), ("css", "a { color: red }"),
    ("html", "<div class=\"a\"></div>"), ("sql", "SELECT 1 FROM t"), ("markdown", "# Title"), ("c", "int main() {}"),
    ("cpp", "int main() {}"), ("java", "class A {}"), ("kotlin", "fun main() {}"), ("ruby", "def a; end"),
    ("php", "<?php echo 1;"),
  ])
  func commonAgentLanguagesHighlight(language: String, code: String) {
    let result = SyntaxHighlighter().highlight(code: code, language: language)
    #expect(result.language != nil, "\(language) not supported")
    #expect(!result.spans.isEmpty, "\(language) produced no tokens")
  }

  @Test func everyListedLanguageExistsInTheBundle() {
    let h = SyntaxHighlighter()
    for name in SyntaxHighlighter.supported { #expect(h.bundleKnows(name), "\(name)") }
  }

  @Test func unknownAndPlainLanguagesStayPlain() {
    let h = SyntaxHighlighter()
    for name in [nil, "", "text", "plaintext", "dockerfile", "no-such-lang"] {
      let r = h.highlight(code: "let x = 1", language: name)
      #expect(r.spans.isEmpty && r.language == nil, "\(String(describing: name))")
    }
  }

  @Test func resultsAreCachedByContentAndLanguage() async {
    let h = SyntaxHighlighter()
    let code = "let a = 1"
    _ = h.highlight(code: code, language: "swift")
    _ = await h.highlightAsync(code: code, language: "swift")
    _ = h.highlight(code: code, language: "swift")
    #expect(h.highlightCalls == 1)
    #expect(h.cached(code: code, language: "swift") != nil)
    #expect(h.cached(code: code, language: "ts") == nil)
    _ = h.highlight(code: code + "1", language: "swift")
    #expect(h.highlightCalls == 2)
  }

  @Test func largeBlockIsOffMainAndAcceptable() async {
    let line = "func handler(_ r: Request, n: Int = 42) throws -> [String: Any] { [\"k\": \"v\"] } // note"
    let code = Array(repeating: line, count: 2_000).joined(separator: "\n")
    let h = SyntaxHighlighter()
    let clock = ContinuousClock()
    let start = clock.now
    let result = await h.highlightAsync(code: code, language: "swift")
    let elapsed = start.duration(to: clock.now)
    print("highlight 2k-line swift block: \(elapsed)")  // informational; correctness is asserted below
    #expect(result.spans.count > 2_000)
    let again = clock.now
    _ = h.cached(code: code, language: "swift")
    #expect(again.duration(to: clock.now) < .milliseconds(200))
  }

  @Test func oversizedBlocksAreLeftPlain() {
    let code = String(repeating: "a", count: SyntaxHighlighter.maxHighlightedUTF16 + 1)
    #expect(SyntaxHighlighter().highlight(code: code, language: "swift").spans.isEmpty)
  }
}
