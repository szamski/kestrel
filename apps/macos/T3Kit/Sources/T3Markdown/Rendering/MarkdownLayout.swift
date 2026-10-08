import AppKit

/// Row sizing for a virtualized timeline: the height of a message at a width, without a
/// live view. Results are cached by (content, width, theme, loaded-image state), so
/// scrolling back to a row, or resizing back to an earlier width, never lays out twice.
@MainActor
public enum MarkdownLayout {
  private static let measurer = MarkdownTextView()
  private static let cache: NSCache<NSString, NSNumber> = {
    let c = NSCache<NSString, NSNumber>()
    c.countLimit = 20_000
    return c
  }()
  /// Real layouts performed (cache misses). For tests.
  public private(set) static var measurements = 0

  /// Text the shared measuring view replaced on its last update (tail-only while streaming).
  static var lastReplacedLength: Int { measurer.lastReplacedLength }

  public static func height(of rendered: RenderedMarkdown, width: CGFloat) -> CGFloat {
    let w = max(width.rounded(.down), 1)
    let key = "\(rendered.contentID)|\(Int(w))|\(rendered.themeKey)|\(MarkdownImageStore.shared.version)" as NSString
    if let hit = cache.object(forKey: key) { return CGFloat(hit.doubleValue) }
    measurer.setContent(rendered)
    let h = measurer.fittingHeight(forWidth: w)
    measurements += 1
    cache.setObject(NSNumber(value: Double(h)), forKey: key)
    return h
  }

  /// Parses and renders `text` for sizing in one call.
  public static func height(
    of text: String, width: CGFloat, options: MarkdownOptions = MarkdownOptions(), theme: MarkdownTheme
  ) -> CGFloat {
    height(of: MarkdownRenderer.shared.render(MarkdownDocument(parsing: text, options: options), theme: theme), width: width)
  }
}
