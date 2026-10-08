import Foundation

/// A top-level slice of the message that parses independently of what follows it. Chunks are
/// the unit of reuse while streaming: their `id` is a content hash, so an unchanged chunk
/// keeps its parsed blocks, its attributed string and its highlighted code.
public struct MarkdownChunk: Hashable, Sendable, Identifiable {
  public let id: UInt64
  public let blocks: [MarkdownBlock]
  /// UTF-8 length of the source slice.
  public let sourceLength: Int
  /// `<details>` sections in `blocks`, nested ones included. Their open/closed state is view
  /// state keyed by (`id`, ordinal), so the renderer needs the count before it builds.
  let detailsCount: Int
}

public struct MarkdownDocument: Hashable, Sendable {
  public let source: String
  public let options: MarkdownOptions
  public let chunks: [MarkdownChunk]

  public var blocks: [MarkdownBlock] { chunks.flatMap(\.blocks) }

  /// Hash of everything that decides the rendered result (before theme and width).
  public var contentID: UInt64 {
    var h = FNV.offset
    for c in chunks { h = FNV.combine(h, c.id) }
    return h
  }

  public init(parsing source: String, options: MarkdownOptions = MarkdownOptions()) {
    var stream = MarkdownStream(options: options)
    self = stream.update(source)
  }

  init(source: String, options: MarkdownOptions, chunks: [MarkdownChunk]) {
    self.source = source
    self.options = options
    self.chunks = chunks
  }

  /// Copy as Markdown for a whole message is the raw source.
  public var markdown: String { source }
}

enum FNV {
  static let offset: UInt64 = 0xcbf2_9ce4_8422_2325
  static func hash<S: Sequence>(_ bytes: S, seed: UInt64 = offset) -> UInt64 where S.Element == UInt8 {
    var h = seed
    for b in bytes {
      h ^= UInt64(b)
      h = h &* 0x0000_0100_0000_01b3
    }
    return h
  }
  static func combine(_ a: UInt64, _ b: UInt64) -> UInt64 {
    var h = a
    for shift in stride(from: 0, to: 64, by: 8) {
      h ^= (b >> UInt64(shift)) & 0xff
      h = h &* 0x0000_0100_0000_01b3
    }
    return h
  }
}

/// Incremental parser for a growing message (port of markdown-incremental.ts, generalised).
///
/// Feed it the *full* text each time. Everything before the last safe boundary is parsed once
/// and reused; only the tail is re-parsed. A boundary is a blank line outside a fence whose
/// next line starts at column 0 with something that cannot continue a list or paragraph
/// (or any line after a closed top-level fence). Raw-HTML blocks that may span blank lines
/// and link reference definitions (document-wide) disable boundaries, exactly the cases the
/// web parser falls back to a full parse for.
public struct MarkdownStream: Sendable {
  public let options: MarkdownOptions

  /// Diagnostics: how much work `update` really did.
  public struct Stats: Sendable, Equatable {
    public var chunksParsed = 0
    public var chunksReused = 0
    public var blocksParsed = 0
  }
  public private(set) var stats = Stats()

  private var stableBytes: [UInt8] = []
  private var stableChunks: [MarkdownChunk] = []
  private var optionsHash: UInt64

  public init(options: MarkdownOptions = MarkdownOptions()) {
    self.options = options
    var h = FNV.offset
    h = FNV.hash([options.softBreaksAsNewlines ? 1 : 0, options.parsesHTML ? 1 : 0], seed: h)
    h = FNV.hash((options.baseDirectory ?? "").utf8, seed: h)
    h = FNV.hash((options.pullRequestRepositoryURL ?? "").utf8, seed: h)
    for skill in options.skills { h = FNV.hash("\(skill.name)\u{1}\(skill.label)\u{2}".utf8, seed: h) }
    self.optionsHash = h
  }

  public mutating func reset() {
    stableBytes = []
    stableChunks = []
  }

  @discardableResult
  public mutating func update(_ text: String) -> MarkdownDocument {
    var copy = text
    return copy.withUTF8 { update(text, $0) }
  }

  private mutating func update(_ text: String, _ bytes: UnsafeBufferPointer<UInt8>) -> MarkdownDocument {
    func slice(_ from: Int, _ to: Int) -> Substring {
      Substring(String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self))
    }
    // A streaming CR can become half of a CRLF and a BOM at a boundary is inside the full
    // document; both are rare, so take the simple full-parse path.
    let hasBOM = bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
    if hasBOM || memchr(bytes.baseAddress, 13, bytes.count) != nil {
      reset()
      let open = Self.scan(bytes, from: 0).endsInOpenFence
      return MarkdownDocument(source: text, options: options, chunks: [parseChunk(text[...], endsInOpenFence: open)])
    }
    let stable = stableBytes.count
    if stable > 0 {
      let isPrefix =
        bytes.count >= stable
        && stableBytes.withUnsafeBufferPointer { memcmp($0.baseAddress, bytes.baseAddress, stable) == 0 }
      if !isPrefix { reset() }
    }

    let scan = Self.scan(bytes, from: stableBytes.count)
    var chunks = stableChunks
    stats.chunksReused += stableChunks.count

    if scan.hasDefinition {
      // Reference definitions apply to the whole document: no reuse is safe.
      reset()
      return MarkdownDocument(
        source: text, options: options, chunks: [parseChunk(text[...], endsInOpenFence: scan.endsInOpenFence)])
    }

    var start = stableBytes.count
    for cut in scan.cuts {
      let chunk = parseChunk(slice(start, cut), endsInOpenFence: false)
      chunks.append(chunk)
      stableChunks.append(chunk)
      start = cut
    }
    if start != stableBytes.count { stableBytes = Array(bytes[0..<start]) }
    if start < bytes.count {
      chunks.append(parseChunk(slice(start, bytes.count), endsInOpenFence: scan.endsInOpenFence))
    }
    return MarkdownDocument(source: text, options: options, chunks: chunks)
  }

  private mutating func parseChunk(_ slice: Substring, endsInOpenFence: Bool) -> MarkdownChunk {
    let source = String(slice)
    let blocks = MarkdownParser.parse(source, options: options, endsInOpenFence: endsInOpenFence)
    stats.chunksParsed += 1
    stats.blocksParsed += blocks.count
    var h = FNV.hash(source.utf8, seed: optionsHash)
    h = FNV.hash([endsInOpenFence ? 1 : 0], seed: h)
    return MarkdownChunk(id: h, blocks: blocks, sourceLength: source.utf8.count, detailsCount: Self.detailsCount(in: blocks))
  }

  static func detailsCount(in blocks: [MarkdownBlock]) -> Int {
    blocks.reduce(0) { total, block in
      switch block {
      case .details(_, _, let inner): total + 1 + detailsCount(in: inner)
      case .quote(let inner), .alert(_, let inner): total + detailsCount(in: inner)
      case .list(let list): total + list.items.reduce(0) { $0 + detailsCount(in: $1.blocks) }
      default: total
      }
    }
  }

  // MARK: boundary scan

  struct Scan {
    var cuts: [Int] = []
    var endsInOpenFence = false
    var hasDefinition = false
  }

  /// Scans `bytes[from...]` (which starts outside a fence at a block boundary).
  static func scan(_ array: [UInt8], from: Int) -> Scan { array.withUnsafeBufferPointer { scan($0, from: from) } }

  static func scan(_ bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Scan {
    var result = Scan()
    var i = from
    var fence: (char: UInt8, length: Int)?
    var previousBlank = true  // start of a chunk counts as after-blank
    var firstLineOfChunk = true
    var htmlRisk = false
    var afterTopLevelFence = false
    // Inside `<details>` the body is separated from its tags by blank lines but belongs to them.
    var detailsDepth = 0
    let n = bytes.count
    while i < n {
      var end = i
      while end < n, bytes[end] != 10 { end += 1 }
      // line = bytes[i..<end]
      var indent = 0
      while i + indent < end, bytes[i + indent] == 32 { indent += 1 }
      let c: UInt8? = i + indent < end ? bytes[i + indent] : nil
      let blank = c == nil || (i + indent..<end).allSatisfy { bytes[$0] == 32 || bytes[$0] == 9 || bytes[$0] == 13 }

      if let open = fence {
        if !blank, let run = fenceRun(bytes, i + indent, end), run.char == open.char, run.length >= open.length,
          (i + indent + run.length..<end).allSatisfy({ bytes[$0] == 32 || bytes[$0] == 9 })
        {
          fence = nil
          afterTopLevelFence = indent == 0
        }
        previousBlank = false
        firstLineOfChunk = false
      } else if blank {
        previousBlank = true
      } else {
        // Candidate boundary before this line?
        if previousBlank, !firstLineOfChunk, !htmlRisk, detailsDepth == 0, i > from {
          let markerish = c.map { $0 == 45 || $0 == 43 || $0 == 42 || ($0 >= 48 && $0 <= 57) } ?? true
          let colZero = indent == 0 && c != 9
          if afterTopLevelFence || (colZero && !markerish) {
            result.cuts.append(i)
            htmlRisk = false
            firstLineOfChunk = true
          }
        }
        if indent <= 3, let c {
          if let run = fenceRun(bytes, i + indent, end) {
            fence = run
          } else if c == 60, riskyHTML(bytes, i + indent, end) {
            htmlRisk = true
          } else if c == 91, isDefinition(bytes, i + indent, end) {
            result.hasDefinition = true
          }
        }
        detailsDepth = max(detailsDepth + detailsDelta(bytes, i + indent, end), 0)
        afterTopLevelFence = false
        previousBlank = false
        firstLineOfChunk = false
      }
      i = end + 1
    }
    result.endsInOpenFence = fence != nil
    return result
  }

  private static func fenceRun(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int) -> (char: UInt8, length: Int)? {
    guard at < end, b[at] == 96 || b[at] == 126 else { return nil }
    let ch = b[at]
    var k = at
    while k < end, b[k] == ch { k += 1 }
    let len = k - at
    guard len >= 3 else { return nil }
    if ch == 96, (k..<end).contains(where: { b[$0] == 96 }) { return nil }
    return (ch, len)
  }

  /// `<details` opens minus `</details` closes on one line (case-insensitive).
  private static func detailsDelta(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int) -> Int {
    guard let first = b[at..<end].firstIndex(of: 60) else { return 0 }  // '<'
    let line = String(decoding: UnsafeBufferPointer(rebasing: b[first..<end]), as: UTF8.self).lowercased()
    guard line.contains("details") else { return 0 }
    return line.components(separatedBy: "<details").count - line.components(separatedBy: "</details").count
  }

  /// HTML blocks that continue across blank lines: `<pre`, `<script`, `<style`, `<textarea`,
  /// comments, processing instructions, declarations and CDATA.
  private static func riskyHTML(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int) -> Bool {
    let line = String(decoding: UnsafeBufferPointer(rebasing: b[at..<min(end, at + 12)]), as: UTF8.self).lowercased()
    return ["<pre", "<script", "<style", "<textarea", "<!", "<?"].contains { line.hasPrefix($0) }
  }

  /// `[label]: destination` at the start of a line.
  private static func isDefinition(_ b: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int) -> Bool {
    var k = at + 1
    while k < end, b[k] != 93 { k += 1 }
    return k + 1 < end && b[k] == 93 && b[k + 1] == 58
  }
}
