import Testing

@testable import T3Diff

private let multiFile = """
  diff --git a/src/app.ts b/src/app.ts
  index 111..222 100644
  --- a/src/app.ts
  +++ b/src/app.ts
  @@ -1,4 +1,4 @@ function main() {
   one
  -two
  +TWO
   three
   four
  @@ -20,2 +20,3 @@
   tail
  +added
   end
  \\ No newline at end of file
  diff --git a/old name.txt b/new name.txt
  similarity index 90%
  rename from old name.txt
  rename to new name.txt
  index 333..444 100644
  --- a/old name.txt
  +++ b/new name.txt
  @@ -1 +1 @@
  -a
  +b
  diff --git a/bin.png b/bin.png
  new file mode 100644
  index 0000000..555
  Binary files /dev/null and b/bin.png differ
  diff --git a/run.sh b/run.sh
  old mode 100644
  new mode 100755
  diff --git a/gone.txt b/gone.txt
  deleted file mode 100644
  index 666..0000000
  --- a/gone.txt
  +++ /dev/null
  @@ -1,2 +0,0 @@
  -x
  -y
  """

@Suite("Unified diff parser")
struct ParserTests {
  @Test func parsesFilesKindsAndStats() {
    let files = UnifiedDiffParser.parse(multiFile)
    #expect(files.map(\.path) == ["src/app.ts", "new name.txt", "bin.png", "run.sh", "gone.txt"])
    #expect(files.map(\.changeType) == [.modified, .renamed, .added, .modified, .deleted])
    #expect(files[1].oldPath == "old name.txt")
    #expect(files[2].isBinary && files[2].hunks.isEmpty)
    #expect(files[3].modeChange?.new == "100755" && files[3].hunks.isEmpty)
    #expect(files[4].newPath == nil && files[4].deletions == 2)
    #expect(files[0].additions == 2 && files[0].deletions == 1 && files[0].hunks.count == 2)
  }

  @Test func numbersLinesAndKeepsNoNewlineMarker() {
    let file = UnifiedDiffParser.parse(multiFile)[0]
    let first = file.hunks[0]
    #expect(first.header == "@@ -1,4 +1,4 @@ function main() {")
    let lines = file.lines[first.lines]
    #expect(lines.map(\.kind) == [.context, .deletion, .addition, .context, .context])
    #expect(lines.map(\.oldNumber) == [1, 2, 0, 3, 4])
    #expect(lines.map(\.newNumber) == [1, 0, 2, 3, 4])
    let last = file.lines[file.hunks[1].lines]
    #expect(last.map(\.kind) == [.context, .addition, .context, .noNewline])
    #expect(last.last?.ordinal == -1)
    // Ordinals skip the marker and continue across hunks.
    #expect(file.lines.filter { $0.kind != .noNewline }.map(\.ordinal) == Array(0..<8))
  }

  @Test func pairsDeletionsWithAdditions() {
    let file = UnifiedDiffParser.parse(multiFile)[0]
    #expect(file.lines[1].pair == 2 && file.lines[2].pair == 1)
  }

  @Test func contentLookingLikeHeadersStaysInTheHunk() {
    let patch = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,2 +1,2 @@\n--- not a header\n+++ nor this\n"
    let files = UnifiedDiffParser.parse(patch)
    #expect(files.count == 1 && files[0].lines.map(\.text) == ["-- not a header", "++ nor this"])
  }

  @Test func decodesQuotedPathsAndPlainUnifiedDiffs() {
    let quoted = "diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\n--- \"a/caf\\303\\251.txt\"\n+++ \"b/caf\\303\\251.txt\"\n@@ -1 +1 @@\n-a\n+b\n"
    #expect(UnifiedDiffParser.parse(quoted).first?.path == "café.txt")
    let plain = "--- a/x.txt\t2020-01-01\n+++ b/x.txt\t2020-01-02\n@@ -1 +1 @@\n-a\n+b\n--- a/y.txt\n+++ b/y.txt\n@@ -1 +1 @@\n-c\n+d\n"
    #expect(UnifiedDiffParser.parse(plain).map(\.path) == ["x.txt", "y.txt"])
  }

  @Test func truncatedHunkIsKept() {
    // The server cuts big diffs mid-hunk; what arrived still renders.
    let patch = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,50 +1,50 @@\n one\n-two\n+TWO\n"
    let files = UnifiedDiffParser.parse(patch)
    #expect(files[0].hunks.count == 1 && files[0].lines.count == 3)
  }

  @Test func largeDiffParsesQuickly() {
    var patch = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1,10000 +1,10000 @@\n"
    for i in 0..<10_000 { patch += i % 3 == 0 ? "-old \(i)\n+new \(i)\n" : " same \(i)\n" }
    let files = UnifiedDiffParser.parse(patch)
    #expect(files.count == 1 && files[0].lines.count > 10_000)
  }
}

@Suite("Word diff")
struct WordDiffTests {
  @Test func marksOnlyTheChangedWord() {
    let result = WordDiff.changedRanges(old: "let value = compute(a, b)", new: "let value = compute(a, c)")
    #expect(result.old == [23..<24] && result.new == [23..<24])
  }

  @Test func insertedWordsOnOneSide() {
    let result = WordDiff.changedRanges(old: "return total", new: "return total + tax")
    #expect(result.old.isEmpty)
    #expect(result.new == [12..<18])
  }

  @Test func unrelatedLinesStayWholeLine() {
    #expect(WordDiff.changedRanges(old: "alpha beta gamma", new: "zzzzzzzz yyyyyyy") == .init(old: [], new: []))
  }
}

@Suite("Review comment mapping")
struct ReviewCommentTests {
  private func file(_ patch: [String]) -> DiffFile { UnifiedDiffParser.parse(patch.joined(separator: "\n"))[0] }

  // Ported from apps/web/src/reviewCommentContext.test.ts.
  @Test func formatsMixedSideSelections() {
    let file = file([
      "diff --git a/src/app.ts b/src/app.ts", "--- a/src/app.ts", "+++ b/src/app.ts", "@@ -1,4 +1,4 @@", " one", "-two", "+TWO", " three", " four",
    ])
    let comment = ReviewComment.build(id: "comment-2", sectionId: "turn:2", sectionTitle: "Turn 2", file: file, lo: 1, hi: 2, text: "  Keep this compatible. ")
    #expect(comment?.startIndex == 1 && comment?.endIndex == 2)
    #expect(comment?.rangeLabel == "2")
    #expect(comment?.text == "Keep this compatible.")
    #expect(comment?.diff == "@@ -2,1 +2,1 @@\n-two\n+TWO")
    #expect(comment?.fenceLanguage == "diff" && comment?.filePath == "src/app.ts")
  }

  @Test func labelsSingleSideRanges() {
    let file = file(["diff --git a/a b/a", "--- a/a", "+++ b/a", "@@ -1,2 +1,4 @@", " keep", "+x", "+y", "+z", " end"])
    #expect(ReviewComment.build(id: "c", sectionId: "s", sectionTitle: "t", file: file, lo: 1, hi: 3, text: "")?.rangeLabel == "+2 to +4")
    #expect(ReviewComment.build(id: "c", sectionId: "s", sectionTitle: "t", file: file, lo: 2, hi: 2, text: "")?.rangeLabel == "+3")
  }

  @Test func restoresSelectionFromPersistedIndexes() {
    let file = file(["diff --git a/src/app.ts b/src/app.ts", "--- a/src/app.ts", "+++ b/src/app.ts", "@@ -1,3 +1,3 @@", " one", "-two", "+TWO", " three"])
    let comment = ReviewComment.build(id: "comment-6", sectionId: "turn:6", sectionTitle: "Turn 6", file: file, lo: 1, hi: 2, text: "Keep both sides.")!
    #expect(ReviewComment.lineRange(in: file, startIndex: comment.startIndex, endIndex: comment.endIndex) == 1...2)
  }
}

@Suite("Rows")
struct RowTests {
  @Test func splitPairsBlocksAndCollapsedFilesKeepOnlyTheirHeader() {
    let files = UnifiedDiffParser.parse(multiFile)
    let split = DiffRows.build(files: files, collapsed: [], layout: .split)
    let first = split.filter { $0.file == 0 }
    // header, hunk, context, (-two | +TWO), context, context, hunk, context, +added, context, marker
    #expect(first.count == 11)
    #expect(first[3].kind == .pair(1, 2))
    let stacked = DiffRows.build(files: files, collapsed: [files[0].id], layout: .stacked)
    #expect(stacked.filter { $0.file == 0 }.count == 1)
  }
}
