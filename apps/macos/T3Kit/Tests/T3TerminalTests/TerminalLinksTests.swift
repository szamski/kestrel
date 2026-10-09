import Foundation
import Testing

@testable import T3Terminal

// Oracle: apps/web/src/terminal-links.test.ts.

private struct Line: TerminalBufferLine {
  let text: String
  var isWrapped = false
  func translateToString(trimRight: Bool) -> String {
    trimRight ? text.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) : text
  }
}

private func link(_ kind: TerminalLinkKind, _ text: String, _ start: Int) -> TerminalLinkMatch {
  TerminalLinkMatch(kind: kind, text: text, start: start, end: start + (text as NSString).length)
}

@Suite struct TerminalLinksTests {
  @Test func findsHttpUrlsAndPathTokens() {
    let line = "failed at https://example.com/docs and src/components/ThreadTerminalDrawer.tsx:42"
    #expect(TerminalLinks.extract(from: line) == [
      link(.url, "https://example.com/docs", 10),
      link(.path, "src/components/ThreadTerminalDrawer.tsx:42", 39),
    ])
  }

  @Test func classifiesUppercaseSchemesAsUrls() {
    #expect(TerminalLinks.isURL("HTTPS://example.com/docs"))
    #expect(TerminalLinks.isURL("Http://example.com"))
    #expect(!TerminalLinks.isURL("src/components/main.ts"))
    #expect(!TerminalLinks.isURL("httpsdocs/readme.md"))
    #expect(TerminalLinks.extract(from: "open HTTPS://example.com/docs") == [link(.url, "HTTPS://example.com/docs", 5)])
  }

  @Test func trimsTrailingPunctuation() {
    #expect(TerminalLinks.extract(from: "(https://example.com/docs), ./src/main.ts:12.") == [
      link(.url, "https://example.com/docs", 1),
      link(.path, "./src/main.ts:12", 28),
    ])
  }

  @Test func findsWindowsAbsolutePathsWithForwardSlashes() {
    let line = "see C:/Users/someone/project/src/file.ts:42 for details"
    let path = "C:/Users/someone/project/src/file.ts:42"
    #expect(TerminalLinks.extract(from: line) == [link(.path, path, (line as NSString).range(of: path).location)])
    #expect(TerminalLinks.extract(from: "(C:/tmp/x.ts).") == [link(.path, "C:/tmp/x.ts", 1)])
  }

  @Test func keepsATrailingColonOnUrls() {
    #expect(TerminalLinks.extract(from: "GET https://example.test/items/foo:") == [link(.url, "https://example.test/items/foo:", 4)])
  }

  @Test(arguments: [
    ("./main.go:10:5: undefined: x", "./main.go:10:5"),
    ("/home/dev/app/src/main.c:10:5: error: expected ';'", "/home/dev/app/src/main.c:10:5"),
    ("C:\\dev\\app\\src\\main.c:10:5: error: expected ';'", "C:\\dev\\app\\src\\main.c:10:5"),
    ("wrote ./out/report.txt:", "./out/report.txt"),
  ])
  func dropsTheColonThatEndsACompilerDiagnosticLocation(line: String, text: String) {
    #expect(TerminalLinks.extract(from: line) == [link(.path, text, (line as NSString).range(of: text).location)])
  }

  @Test func offsetsStayInUtf16UnitsAfterWideCharacters() {
    let line = "🙂 see https://example.com"
    let match = TerminalLinks.extract(from: line)
    #expect(match == [link(.url, "https://example.com", 7)])
    #expect(TerminalLinks.link(in: line, atUTF16Offset: 8)?.kind == .url)
    #expect(TerminalLinks.link(in: line, atUTF16Offset: 3) == nil)
  }

  @Test func reconstructsAWrappedLineFromAnyPhysicalRow() {
    let first = "see https://example.com/a"
    let second = "/bc?x=1"
    let lines = [Line(text: "prompt> "), Line(text: first), Line(text: second, isWrapped: true), Line(text: "done")]
    let fromFirst = TerminalLinks.collectWrappedLine(bufferLineNumber: 2) { lines.indices.contains($0) ? lines[$0] : nil }
    let fromWrapped = TerminalLinks.collectWrappedLine(bufferLineNumber: 3) { lines.indices.contains($0) ? lines[$0] : nil }
    #expect(fromFirst == WrappedTerminalLinkLine(text: first + second, segments: [
      .init(bufferLineNumber: 2, text: first, startIndex: 0, endIndex: first.count),
      .init(bufferLineNumber: 3, text: second, startIndex: first.count, endIndex: first.count + second.count),
    ]))
    #expect(fromWrapped == fromFirst)
  }

  @Test func preservesTrailingSpacesOnContinuedSegmentsForDownstreamOffsets() {
    let first = "prefix   "
    let second = "https://example.com/path"
    let lines = [Line(text: first), Line(text: second, isWrapped: true)]
    let wrapped = TerminalLinks.collectWrappedLine(bufferLineNumber: 2) { lines.indices.contains($0) ? lines[$0] : nil }
    #expect(wrapped?.text == first + second)
    #expect(TerminalLinks.extract(from: wrapped?.text ?? "") == [link(.url, second, first.count)])
  }

  @Test func resolvesRelativePathsAgainstCwd() {
    #expect(TerminalLinks.resolvePathTarget("src/components/ThreadTerminalDrawer.tsx:42:7", cwd: "/Users/julius/project") == "/Users/julius/project/src/components/ThreadTerminalDrawer.tsx:42:7")
    #expect(TerminalLinks.resolvePathTarget("~/notes.md:3", cwd: "/Users/julius/project") == "/Users/julius/notes.md:3")
  }

  @Test func keepsAbsolutePathsUnchanged() {
    #expect(TerminalLinks.resolvePathTarget("/Users/julius/project/src/main.ts:12", cwd: "/Users/julius/project") == "/Users/julius/project/src/main.ts:12")
    #expect(TerminalLinks.resolvePathTarget("C:/Users/julius/project/src/main.ts:12", cwd: "C:\\Users\\julius\\project") == "C:/Users/julius/project/src/main.ts:12")
  }

  @Test func keepsTheLineAndColumnOfACompilerDiagnostic() {
    let match = TerminalLinks.extract(from: "/Users/julius/project/main.c:10:5: error: expected ';'").first
    #expect(TerminalLinks.resolvePathTarget(match?.text ?? "", cwd: "/Users/julius/project") == "/Users/julius/project/main.c:10:5")
  }

  @Test func activationRequiresCommandWithoutControl() {
    #expect(TerminalLinks.isActivation(command: true, control: false))
    #expect(!TerminalLinks.isActivation(command: false, control: true))
    #expect(!TerminalLinks.isActivation(command: false, control: false))
  }
}
