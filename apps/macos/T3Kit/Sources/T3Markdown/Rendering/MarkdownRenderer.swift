import AppKit

/// A rendered message: one attributed-string segment per parsed chunk. Segments are
/// immutable and shared, so reusing a stable chunk costs nothing.
public struct RenderedMarkdown: @unchecked Sendable {
  struct Segment {
    /// Chunk content hash combined with the theme: equal ids mean equal text *and* styling
    /// except for highlighting, which `highlighted` tracks.
    var id: UInt64
    var text: NSAttributedString
    var highlighted: Int
    var pending: [PendingHighlight]
    var codeBlocks: [String: String]
    var images: [MarkdownImage]
  }

  let segments: [Segment]
  public let source: String
  /// What was rendered, so a view can re-render after a `<details>` toggle.
  let document: MarkdownDocument
  public let theme: MarkdownTheme
  /// Hash of the chunk contents (theme excluded): the document half of cache keys.
  public let contentID: UInt64
  let themeKey: UInt64

  /// Code blocks waiting for syntax highlighting.
  var pendingHighlights: [PendingHighlight] { segments.flatMap(\.pending) }

  /// All chunks, concatenated: what a plain-text view of the message would show.
  public var string: String { segments.map { $0.text.string }.joined() }

  public var codeBlocks: [String: String] {
    segments.reduce(into: [:]) { $0.merge($1.codeBlocks) { a, _ in a } }
  }
  var images: [MarkdownImage] { segments.flatMap(\.images) }
}

/// Renders documents. Rendering a chunk is cached by (chunk content, theme), so a stream
/// that appends text re-renders only its tail.
public final class MarkdownRenderer: @unchecked Sendable {
  public static let shared = MarkdownRenderer()

  private let highlighter: SyntaxHighlighter
  private let imageStore: MarkdownImageStore
  private let cache = NSCache<NSString, SegmentBox>()
  private let counterLock = NSLock()
  private var _chunksBuilt = 0

  final class SegmentBox {
    let segment: RenderedMarkdown.Segment
    init(_ s: RenderedMarkdown.Segment) { segment = s }
  }

  public init(highlighter: SyntaxHighlighter = .shared, imageStore: MarkdownImageStore = .shared) {
    self.highlighter = highlighter
    self.imageStore = imageStore
    cache.countLimit = 600
  }

  /// How many chunks were actually built (cache misses). For tests.
  public var chunksBuilt: Int {
    counterLock.lock()
    defer { counterLock.unlock() }
    return _chunksBuilt
  }

  public func render(_ document: MarkdownDocument, theme: MarkdownTheme) -> RenderedMarkdown {
    let themeKey = UInt64(truncatingIfNeeded: theme.hashValue)
    var segments: [RenderedMarkdown.Segment] = []
    segments.reserveCapacity(document.chunks.count)
    // Toggled `<details>` sections change both the text and the height, so their state is
    // part of the segment id and of the content id the layout cache keys on.
    var contentID = document.contentID
    for chunk in document.chunks {
      var id = FNV.combine(chunk.id, themeKey)
      let details = MarkdownDetailsStore.shared.stateHash(chunk: chunk.id, count: chunk.detailsCount)
      if details != 0 {
        id = FNV.combine(id, details)
        contentID = FNV.combine(contentID, details)
      }
      let key = "\(id)" as NSString
      if let hit = cache.object(forKey: key)?.segment, !hasNewHighlights(hit) {
        segments.append(hit)
        continue
      }
      let built = MarkdownAttributedBuilder(theme: theme, highlighter: highlighter, imageStore: imageStore)
        .build(chunk.blocks, chunkID: chunk.id)
      counterLock.lock()
      _chunksBuilt += 1
      counterLock.unlock()
      let segment = RenderedMarkdown.Segment(
        id: id, text: built.text, highlighted: built.highlightedBlockCount, pending: built.pendingHighlights,
        codeBlocks: built.codeBlocks, images: built.images)
      cache.setObject(SegmentBox(segment), forKey: key, cost: built.text.length * 2 + 256)
      segments.append(segment)
    }
    return RenderedMarkdown(
      segments: segments, source: document.source, document: document, theme: theme, contentID: contentID,
      themeKey: themeKey)
  }

  private func hasNewHighlights(_ segment: RenderedMarkdown.Segment) -> Bool {
    segment.pending.contains { highlighter.cached(code: $0.code, language: $0.language) != nil }
  }

  /// Runs highlight.js (off the main thread) for every pending code block. After this,
  /// `render` of the same document returns coloured code. Returns whether anything ran.
  @discardableResult
  public func resolveHighlights(of rendered: RenderedMarkdown) async -> Bool {
    var ran = false
    var seen = Set<PendingHighlight>()
    for p in rendered.pendingHighlights where seen.insert(p).inserted {
      if highlighter.cached(code: p.code, language: p.language) == nil {
        _ = await highlighter.highlightAsync(code: p.code, language: p.language)
        ran = true
      }
    }
    return ran
  }
}
