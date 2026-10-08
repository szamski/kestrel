import Foundation
import Testing

@testable import T3Composer

@Suite("Editor input rules") struct EditorRulesTests {
  private func spans(_ text: String) -> (mark: RichTextMark, content: String)? {
    guard let match = EditorRules.markMatch(textBeforeCaret: text) else { return nil }
    return (match.mark, text.jsSlice(match.contentRange.lowerBound, match.contentRange.upperBound))
  }

  @Test func closingDelimiterCompletesAMark() {
    #expect(spans("say **bold**")?.mark == .bold && spans("say **bold**")?.content == "bold")
    #expect(spans("**bold**")?.content == "bold")
    #expect(spans("__bold__")?.mark == .bold)
    #expect(spans("an *it*")?.mark == .italic && spans("an *it*")?.content == "it")
    #expect(spans("a _it_")?.mark == .italic)
    #expect(spans("so ~~gone~~")?.mark == .strike)
    #expect(spans("run `code`")?.mark == .code && spans("run `code`")?.content == "code")
    #expect(spans("`code`")?.content == "code")
  }

  @Test func halfFinishedAndSpacedDelimitersDoNothing() {
    #expect(spans("**bold*") == nil)  // the single `*` must not italicise `*bold*` out of `**bold*`
    #expect(spans("**bold") == nil)
    #expect(spans("a ** **") == nil)  // an opener followed by whitespace and another delimiter cannot open
    #expect(spans("snake_case_word") == nil)  // `_` not at a word start
    #expect(spans("``code``") == nil)
    #expect(spans("2*3*") == nil)
  }

  @Test func taskRule() {
    #expect(EditorRules.taskMatch(textBeforeCaret: "- [ ] ") == false)
    #expect(EditorRules.taskMatch(textBeforeCaret: "- [x] ") == true)
    #expect(EditorRules.taskMatch(textBeforeCaret: "- [X] ") == true)
    #expect(EditorRules.taskMatch(textBeforeCaret: "- [ ]") == nil)
    #expect(EditorRules.taskMatch(textBeforeCaret: " - [ ] ") == nil)
  }
}
