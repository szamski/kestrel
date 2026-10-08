import Foundation
import Testing

@testable import T3Markdown

/// A message shaped like real agent output: headings, prose, lists, tables, quotes and
/// closed code fences, repeated until it is about `lines` long.
func mixedMarkdown(lines target: Int) -> String {
  var out: [String] = []
  var n = 0
  while out.count < target {
    n += 1
    out.append("## Section \(n)")
    out.append("")
    out.append("Paragraph \(n) with **bold**, `code` and a [link](https://example.com/\(n)). It continues for a while so the")
    out.append("line count grows like a real answer would.")
    out.append("")
    out.append("- item \(n).1")
    out.append("- item \(n).2 with `src/file\(n).swift:\(n)`")
    out.append("  - nested")
    out.append("")
    out.append("```swift")
    for i in 0..<12 { out.append("let value\(n)_\(i) = compute(\(i)) // step \(i)") }
    out.append("```")
    out.append("")
    out.append("| a | b |")
    out.append("|---|---|")
    out.append("| \(n) | x |")
    out.append("")
    out.append("> quote \(n)")
    out.append("")
  }
  return out.joined(separator: "\n") + "\n"
}

@Suite("Incremental parsing")
struct StreamTests {
  @Test func everyPrefixParsesLikeAFullParse() {
    let source = mixedMarkdown(lines: 140) + "\n1. one\n\n2. two\n\n```ts\nconst a = 1\n"
    var stream = MarkdownStream()
    var mismatches: [Int] = []
    var length = 0
    let chars = Array(source)
    while length < chars.count {
      length = min(length + 37, chars.count)
      let prefix = String(chars[0..<length])
      let incremental = stream.update(prefix).blocks
      let full = MarkdownParser.parse(prefix, endsInOpenFence: MarkdownStream.scan(Array(prefix.utf8), from: 0).endsInOpenFence)
      if incremental != full { mismatches.append(length) }
    }
    #expect(mismatches.isEmpty, "differs at prefix lengths \(mismatches.prefix(5))")
    #expect(stream.stats.chunksReused > 0)
  }

  @Test func stableChunksAreReusedWhileAppending() {
    let base = mixedMarkdown(lines: 3_000)
    var stream = MarkdownStream()
    let initial = stream.update(base)
    let initialBlocks = initial.blocks.count
    #expect(initial.chunks.count > 100)
    let statsBefore = stream.stats

    // 500 deltas of a few characters, like a model streaming a new section.
    var text = base
    let deltas = Array("## Streaming\n\nSome new words arrive one delta at a time, ".utf8CharactersChunked(500, size: 7))
    for d in deltas {
      text += d
      _ = stream.update(text)
    }
    let parsed = stream.stats.blocksParsed - statsBefore.blocksParsed
    let chunksParsed = stream.stats.chunksParsed - statsBefore.chunksParsed
    // A full re-parse per delta would build `initialBlocks` blocks 500 times.
    #expect(parsed * 100 < initialBlocks * 500, "parsed \(parsed) blocks for 500 deltas; full re-parse would be \(initialBlocks * 500)")
    #expect(chunksParsed <= 520, "parsed \(chunksParsed) chunks")
    // The parsed tail never spans more than the section being written.
    #expect(parsed <= 500 * 3)
  }

  @Test func appendingAfterAnOpenFenceNeverReparsesEarlierChunks() {
    var stream = MarkdownStream()
    var text = mixedMarkdown(lines: 600) + "\n```swift\n"
    _ = stream.update(text)
    let before = stream.stats.blocksParsed
    for i in 0..<200 {
      text += "let x\(i) = \(i)\n"
      _ = stream.update(text)
    }
    // Each delta re-parses only the open fence (one block).
    #expect(stream.stats.blocksParsed - before <= 200 * 2)
  }

  @Test func editingEarlierTextResetsSafely() {
    var stream = MarkdownStream()
    _ = stream.update(mixedMarkdown(lines: 200))
    let edited = "# Different\n\n" + mixedMarkdown(lines: 60)
    #expect(stream.update(edited).blocks == MarkdownParser.parse(edited))
  }

  @Test func linkDefinitionsForceAFullParse() {
    var stream = MarkdownStream()
    let text = "See [the docs][d].\n\n## Next\n\nMore text.\n\n[d]: https://example.com/docs\n"
    let blocks = stream.update(text).blocks
    #expect(blocks == MarkdownParser.parse(text))
    guard case .paragraph(let inl, _)? = blocks.first, inl.contains(where: { if case .link(.web, _) = $0 { true } else { false } }) else {
      return bail("reference link was not resolved: \(blocks)")
    }
  }

  @Test func htmlCommentsSpanningBlankLinesAreNotSplit() {
    var stream = MarkdownStream()
    let text = "intro\n\n<!--\nhidden\n\n## Not a heading\n-->\n\nafter\n"
    #expect(stream.update(text).blocks == MarkdownParser.parse(text))
  }

  @Test func chunkIdsAreContentHashes() {
    var a = MarkdownStream()
    var b = MarkdownStream()
    let text = mixedMarkdown(lines: 80)
    #expect(a.update(text).chunks.map(\.id) == b.update(text).chunks.map(\.id))
    let grown = a.update(text + "tail").chunks.map(\.id)
    let original = b.update(text).chunks.map(\.id)
    #expect(grown.prefix(original.count - 1) == original.prefix(original.count - 1))
  }

  @Test func crlfInputFallsBackToAFullParse() {
    var stream = MarkdownStream()
    let text = "a\r\n\r\n## b\r\n\r\nc\r\n"
    #expect(stream.update(text).blocks == MarkdownParser.parse(text))
  }
}

extension String {
  /// `count` successive slices of a repeating filler, each `size` characters.
  fileprivate func utf8CharactersChunked(_ count: Int, size: Int) -> [String] {
    let filler = Array("The quick brown fox jumps over the lazy dog and keeps going. ")
    return (0..<count).map { i in
      let start = (i * size) % filler.count
      return (i == 0 ? self : "") + String((0..<size).map { filler[(start + $0) % filler.count] })
    }
  }
}
