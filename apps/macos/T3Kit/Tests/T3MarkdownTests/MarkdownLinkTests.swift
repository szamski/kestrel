import Foundation
import Testing

@testable import T3Markdown

private let project = "/Users/julius/project"

private func file(_ href: String, base: String? = nil) -> MarkdownFileTarget? {
  MarkdownLink.fileTarget(href: href, baseDirectory: base)
}

@Suite("File links")
struct FileLinkTests {
  @Test func absolutePosixPath() {
    #expect(file("/Users/julius/project/AGENTS.md")?.pathWithPosition == "/Users/julius/project/AGENTS.md")
  }

  @Test func relativePathsResolveAgainstBase() {
    #expect(file("src/processRunner.ts:71", base: project)?.pathWithPosition == "\(project)/src/processRunner.ts:71")
    #expect(file("script.ts:10", base: project)?.pathWithPosition == "\(project)/script.ts:10")
    #expect(file("AGENTS.md", base: project)?.pathWithPosition == "\(project)/AGENTS.md")
    #expect(file("../shared/a.ts", base: project)?.path == "/Users/julius/shared/a.ts")
  }

  @Test func relativePathIsKeptWithoutBase() {
    #expect(file("src/main.ts#L3") == MarkdownFileTarget(path: "src/main.ts", line: 3))
  }

  @Test func hashAnchorsMapToPositions() {
    #expect(file("/Users/julius/project/src/main.ts#L42C7") == MarkdownFileTarget(path: "/Users/julius/project/src/main.ts", line: 42, column: 7))
    #expect(file("/a/b.ts#L12-L20") == MarkdownFileTarget(path: "/a/b.ts", line: 12, endLine: 20))
    #expect(file("/a/b.ts#L12") == MarkdownFileTarget(path: "/a/b.ts", line: 12))
  }

  @Test func externalUrlsAreNotFiles() {
    #expect(file("https://example.com/docs") == nil)
    #expect(file("//cdn.example.com/clip.mp4", base: "/workspace") == nil)
    #expect(file("mailto:a@b.co") == nil)
  }

  @Test func fileUrlsDecodeOnce() {
    #expect(file("file:///Users/julius/project/file%2520name.md")?.path == "/Users/julius/project/file%20name.md")
    #expect(file("file://localhost/home/me/notes.md")?.path == "/home/me/notes.md")
    #expect(file("file://server/share/workspace-image.svg")?.path == "\\\\server\\share\\workspace-image.svg")
    #expect(file("file:///c%3A/Users/x/shot.png")?.path == "c:/Users/x/shot.png")
    #expect(file("file:///D:/Programme/t3code/apps/web/src/components/chat/OpenInPicker.tsx#L69")
      == MarkdownFileTarget(path: "D:/Programme/t3code/apps/web/src/components/chat/OpenInPicker.tsx", line: 69))
    #expect(file(" <file:///D:/Programme/t3code/apps/web/src/components/ChatMarkdown.tsx#L1> ")?.pathWithPosition
      == "D:/Programme/t3code/apps/web/src/components/ChatMarkdown.tsx:1")
  }

  @Test func appRoutesAreNotFiles() {
    #expect(file("/chat/settings") == nil)
    #expect(file("/chat/settings#L3", base: "/repo") == nil)
  }

  @Test func encodedSpacesFromTheRenderer() {
    #expect(file("docs/My%20Folder", base: "/repo/project")?.path == "/repo/project/docs/My Folder")
    #expect(file("Updated%20cutover%20checklist.md", base: "/repo/project")?.basename == "Updated cutover checklist.md")
  }

  @Test func windowsPaths() {
    #expect(file("C:\\Users\\mike\\a.ts")?.path == "C:\\Users\\mike\\a.ts")
    #expect(file("C:%5CUsers%5Cmike%5Ca.ts:5")?.pathWithPosition == "C:\\Users\\mike\\a.ts:5")
    #expect(file("src/a.ts", base: "C:/Users/mike/p")?.path == "C:\\Users\\mike\\p\\src\\a.ts")
  }

  @Test func basenameKeepsFinalSegment() {
    #expect(MarkdownPaths.basename("/tmp/favicons/") == "favicons")
    #expect(MarkdownPaths.basename("C:\\Users\\x\\.claude\\") == ".claude")
    #expect(MarkdownPaths.basename("/") == "/")
  }
}

@Suite("Inline code paths")
struct InlineCodePathTests {
  private func code(_ s: String, base: String? = project) -> MarkdownFileTarget? {
    MarkdownLink.inlineCodeFile(s, baseDirectory: base)
  }

  @Test func linksPathShapedCode() {
    #expect(code("apps/web/src/a.ts")?.path == "\(project)/apps/web/src/a.ts")
    #expect(code("/Users/julius/project/AGENTS.md", base: nil)?.path == "/Users/julius/project/AGENTS.md")
    #expect(code("/usr/local/bin/tool", base: nil) != nil)
    #expect(code("/workspace/Makefile", base: nil) != nil)
    #expect(code("C:\\Users\\mike\\project\\src\\main.ts", base: nil)?.basename == "main.ts")
    #expect(code("src\\main.ts")?.path == "\(project)/src/main.ts")
    #expect(code("./scripts/run-tests")?.path == "\(project)/scripts/run-tests")
  }

  @Test func bareFilenamesNeedALineSuffix() {
    #expect(code("script.ts:10")?.line == 10)
    #expect(code("AGENTS.md") == nil)
    #expect(code("Makefile:12")?.line == 12)
    #expect(code("Dockerfile:8:2") == MarkdownFileTarget(path: "\(project)/Dockerfile", line: 8, column: 2))
    #expect(code("Makefile:12", base: nil) == nil)
  }

  @Test(arguments: [
    "error:1", "TODO:12", "exit:0", "port:3000", "http:80", "127.0.0.1:3000", "localhost:3000", "example.com:8080",
    "10.0.0.1:80:1", "git worktree list --porcelain", "node.meta", "pnpm install", "src/**/*.ts", "origin/main",
    "apps/web", "https://example.com/docs.html", "/chat/settings",
  ])
  func rejectsNonPaths(candidate: String) {
    #expect(code(candidate) == nil, "\(candidate)")
  }

  @Test(arguments: ["Makefile.in:12", "src/setup.sh:3", "script.pl:10", "model.pt:3"])
  func extensionsThatLookLikeTLDsStillLink(candidate: String) {
    #expect(code(candidate) != nil)
  }

  @Test func relativeWithoutBaseIsNotLinked() {
    #expect(code("docs/internals/workspace-layout.md", base: nil) == nil)
  }
}

@Suite("Link classification")
struct LinkClassificationTests {
  @Test func webSchemes() {
    #expect(MarkdownLink.resolve(destination: "https://e.com/a?b=1#c") == .web(URL(string: "https://e.com/a?b=1#c")!))
    #expect(MarkdownLink.resolve(destination: "mailto:a@b.co") == .web(URL(string: "mailto:a@b.co")!))
    #expect(MarkdownLink.resolve(destination: "//cdn.e.com/x") == .web(URL(string: "https://cdn.e.com/x")!))
  }

  @Test(arguments: ["javascript:alert(1)", "data:text/html,<b>x</b>", "ftp://e.com/a", "vbscript:x", ""])
  func blockedSchemes(destination: String) {
    #expect(MarkdownLink.resolve(destination: destination) == nil)
  }

  @Test func anchorAndFiles() {
    #expect(MarkdownLink.resolve(destination: "#section") == .anchor("section"))
    #expect(MarkdownLink.resolve(destination: "/Users/a/b.swift#L9") == .file(MarkdownFileTarget(path: "/Users/a/b.swift", line: 9)))
  }

  @Test func contextHrefs() {
    #expect(MarkdownLink.resolve(destination: "t3-context://v1/image/ctx_1") == .context(kind: "image", id: "ctx_1"))
    #expect(MarkdownLink.resolve(destination: "t3-context://v1/Image/x") == nil)
    #expect(MarkdownLink.resolve(destination: "t3-context://v1/a/b/c") == nil)
    #expect(MarkdownLink.resolve(destination: "t3-context://v1/a/") == nil)
  }
}

@Suite("Image sources")
struct ImageSourceTests {
  @Test func classification() {
    #expect(MarkdownImageSource.classify("https://e.com/a.png") == .direct("https://e.com/a.png"))
    #expect(MarkdownImageSource.classify("data:image/png;base64,AAA") == .direct("data:image/png;base64,AAA"))
    #expect(MarkdownImageSource.classify("//cdn.e.com/a.png") == .direct("//cdn.e.com/a.png"))
    #expect(MarkdownImageSource.classify("shots/a.png", workspaceRoot: "/repo") == .workspaceFile("/repo/shots/a.png"))
    #expect(MarkdownImageSource.classify("shots/a.png") == .blocked)
    #expect(MarkdownImageSource.classify("/abs/a.png") == .workspaceFile("/abs/a.png"))
    #expect(MarkdownImageSource.classify("file:///abs/a%20b.png") == .workspaceFile("/abs/a b.png"))
    #expect(MarkdownImageSource.classify("C:\\x\\a.png") == .workspaceFile("C:\\x\\a.png"))
    #expect(MarkdownImageSource.classify("~/a.png", workspaceRoot: "/repo") == .blocked)
    #expect(MarkdownImageSource.classify("#frag") == .blocked)
    #expect(MarkdownImageSource.classify("javascript:alert(1)", workspaceRoot: "/repo") == .blocked)
    #expect(MarkdownImageSource.classify(nil) == .blocked)
    #expect(MarkdownImageSource.classify("<my image.png>", workspaceRoot: "/repo") == .workspaceFile("/repo/my image.png"))
  }
}

@Suite("Assistant citations")
struct CitationTests {
  private func href(
    text: String = "quoted text", start: Int = 3, end: Int = 14, prefix: String = "pre", suffix: String = "suf",
    comment: String? = nil, path: String = "env-1/thread%2F2/msg-3"
  ) -> String {
    var c = URLComponents()
    var items = [
      URLQueryItem(name: "text", value: text), URLQueryItem(name: "start", value: String(start)),
      URLQueryItem(name: "end", value: String(end)), URLQueryItem(name: "prefix", value: prefix),
      URLQueryItem(name: "suffix", value: suffix),
    ]
    if let comment { items.append(URLQueryItem(name: "comment", value: comment)) }
    c.queryItems = items
    // URLSearchParams spells spaces as `+`.
    let query = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "%20", with: "+")
    return "t3-citation://v1/\(path)?\(query)"
  }

  @Test func roundTrip() {
    let link = MarkdownLink.resolve(destination: href(comment: "why?"))
    guard case .citation(let c)? = link else { return bail("not a citation: \(String(describing: link))") }
    #expect(c.environmentId == "env-1")
    #expect(c.threadId == "thread/2")
    #expect(c.messageId == "msg-3")
    #expect(c.text == "quoted text")
    #expect(c.comment == "why?")
    #expect(c.start == 3)
    #expect(c.end == 14)
  }

  @Test(arguments: [
    "t3-citation://v1/a/b?text=x&start=0&end=1&prefix=&suffix=",
    "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=&suffix=#frag",
    "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=&suffix=&extra=1",
    "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=&prefix=&suffix=",
    "t3-citation://v1/a/b/c?text=x&start=a&end=1&prefix=&suffix=",
    "t3-citation://v1/a/b/c?text=x&start=5&end=5&prefix=&suffix=",
    "t3-citation://v1/a/b/c?text=&start=0&end=1&prefix=&suffix=",
    "t3-citation://v1/a/b/c?text=%20%20&start=0&end=1&prefix=&suffix=",
    "t3-citation://user@v1/a/b/c?text=x&start=0&end=1&prefix=&suffix=",
  ])
  func rejectsMalformed(href: String) {
    guard case .citation? = MarkdownLink.resolve(destination: href) else { return }
    Issue.record("accepted \(href)")
  }

  @Test func rejectsOversizedContext() {
    guard case .citation? = MarkdownLink.resolve(destination: href(prefix: String(repeating: "p", count: 33))) else { return }
    Issue.record("accepted a 33-character prefix")
  }

  @Test func citationLinkBecomesAChip() {
    let blocks = MarkdownDocument(parsing: "see [Assistant quote](\(href()))").blocks
    guard case .paragraph(let inl, _)? = blocks.first, inl.contains(where: { if case .citation = $0 { true } else { false } }) else {
      return bail("no chip in \(blocks)")
    }
  }
}
