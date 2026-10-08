import AppKit

/// Something drawn in place of an attachment character: a table, a chip, an image card.
/// Coordinates are flipped (origin top-left), sized for the width the line offers.
protocol DrawableContent: AnyObject {
  func size(forWidth width: CGFloat) -> CGSize
  func draw(in rect: CGRect)
  /// Distance below the baseline the attachment extends (negative `bounds.origin.y`).
  var baselineDrop: CGFloat { get }
  var plainText: String { get }
  var accessibilityText: String { get }
}

extension DrawableContent {
  var baselineDrop: CGFloat { 0 }
}

/// TextKit 2 draws an attachment through `image(forBounds:…)`, but only when `image` is set,
/// so a 1×1 placeholder is installed and replaced with a resolution-independent drawing
/// handler sized to whatever the layout asks for.
final class ContentAttachment: NSTextAttachment {
  let content: DrawableContent
  /// Block attachments start at their paragraph's head indent, which the line's proposed
  /// width does not account for.
  private let indent: CGFloat
  private var drawnSize: CGSize = .zero

  init(content: DrawableContent, indent: CGFloat = 0) {
    self.content = content
    self.indent = indent
    super.init(data: nil, ofType: nil)
    image = NSImage(size: NSSize(width: 1, height: 1))
    image?.accessibilityDescription = content.accessibilityText
  }

  required init?(coder: NSCoder) { fatalError("not archived") }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
    proposedLineFragment: CGRect, position: CGPoint
  ) -> CGRect {
    let size = content.size(forWidth: proposedLineFragment.width - indent)
    installImage(size: size)
    return CGRect(x: 0, y: -content.baselineDrop, width: size.width, height: size.height)
  }

  override func image(
    forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int
  ) -> NSImage? {
    installImage(size: imageBounds.size)
    return image
  }

  /// Size of the last layout, for hit-testing clicks inside the content.
  var laidOutSize: CGSize { drawnSize }

  private func installImage(size: CGSize) {
    guard size != drawnSize, size.width > 0, size.height > 0 else { return }
    drawnSize = size
    let content = content
    let img = NSImage(size: size, flipped: true) { rect in
      content.draw(in: rect)
      return true
    }
    img.accessibilityDescription = content.accessibilityText
    image = img
  }
}

// MARK: - Chip

/// Inline token for `t3-citation` / `t3-context` links.
final class ChipContent: DrawableContent {
  private let label: NSAttributedString
  private let icon: NSImage?
  private let background: NSColor
  private let height: CGFloat
  private let textWidth: CGFloat
  private let iconWidth: CGFloat
  let plainText: String
  let accessibilityText: String
  let baselineDrop: CGFloat

  init(label text: String, symbol: String, theme: MarkdownTheme, accessibility: String) {
    let font = NSFont.systemFont(ofSize: max(theme.bodyFont.pointSize - 1.5, 10), weight: .medium)
    let truncated = text.count > 44 ? String(text.prefix(43)) + "…" : text
    label = NSAttributedString(
      string: truncated, attributes: [.font: font, .foregroundColor: theme.chipForeground])
    icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .medium))
    background = theme.chipBackground
    height = ceil(font.ascender - font.descender) + 6
    textWidth = ceil(label.size().width) + 3
    iconWidth = icon.map { ceil($0.size.width) + 4 } ?? 0
    baselineDrop = 4
    plainText = text
    accessibilityText = accessibility
  }

  func size(forWidth width: CGFloat) -> CGSize {
    CGSize(width: min(textWidth + iconWidth + 16, max(width, 40)), height: height)
  }

  func draw(in rect: CGRect) {
    background.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    var x = rect.minX + 7
    if let icon {
      let s = icon.size
      let tinted = icon.tinted(with: label.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .labelColor)
      tinted.draw(in: CGRect(x: x, y: rect.midY - s.height / 2, width: s.width, height: s.height))
      x += s.width + 4
    }
    let h = ceil(label.size().height)
    label.draw(in: CGRect(x: x, y: rect.midY - h / 2, width: max(rect.maxX - x - 4, textWidth), height: h))
  }
}

extension NSImage {
  /// A copy of a template symbol filled with `color`.
  func tinted(with color: NSColor) -> NSImage {
    let copy = NSImage(size: size, flipped: false) { rect in
      self.draw(in: rect)
      color.set()
      rect.fill(using: .sourceIn)
      return true
    }
    return copy
  }
}

// MARK: - Image card

/// Placeholder / loaded image for a standalone Markdown image. The renderer only resolves
/// what the image is; the UI supplies bytes through `MarkdownImageStore`.
final class ImageContent: DrawableContent {
  let image: MarkdownImage
  private let theme: MarkdownTheme
  private let store: MarkdownImageStore
  let accessibilityText: String

  init(image: MarkdownImage, theme: MarkdownTheme, store: MarkdownImageStore) {
    self.image = image
    self.theme = theme
    self.store = store
    accessibilityText = image.alt.isEmpty ? "Image" : "Image: \(image.alt)"
  }

  var plainText: String { image.alt.isEmpty ? "[image]" : "[image: \(image.alt)]" }

  func size(forWidth width: CGFloat) -> CGSize {
    let maxWidth = max(width, 40)
    if let loaded = store.loaded(for: image) {
      var w = CGFloat(image.width ?? Int(loaded.size.width))
      var h = CGFloat(image.height ?? Int(loaded.size.height))
      if image.width != nil, image.height == nil, loaded.size.width > 0 { h = w * loaded.size.height / loaded.size.width }
      let maxHeight: CGFloat = 480
      let scale = min(1, maxWidth / max(w, 1), maxHeight / max(h, 1))
      w *= scale
      h *= scale
      return CGSize(width: max(w, 1), height: max(h, 1))
    }
    return CGSize(width: min(maxWidth, 360), height: 72)
  }

  func draw(in rect: CGRect) {
    let radius = theme.cornerRadius
    if let loaded = store.loaded(for: image) {
      NSGraphicsContext.current?.saveGraphicsState()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
      loaded.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.current?.restoreGraphicsState()
      theme.border.setStroke()
      let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
      outline.lineWidth = 1
      outline.stroke()
      return
    }
    theme.codeBackground.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    theme.border.setStroke()
    NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).stroke()
    let name: String
    switch image.source {
    case .blocked: name = "photo.badge.exclamationmark"
    default: name = "photo"
    }
    let status: String
    switch image.source {
    case .blocked: status = "Image unavailable"
    default: status = store.isFailed(image) ? "Image failed to load" : "Loading image…"
    }
    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 22, weight: .light))
    {
      let tinted = symbol.tinted(with: theme.muted)
      tinted.draw(in: CGRect(x: rect.minX + 16, y: rect.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
    }
    let title = image.alt.isEmpty ? status : image.alt
    let text = NSMutableAttributedString(
      string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: theme.bodyFont.pointSize - 1, weight: .medium), .foregroundColor: theme.foreground])
    text.append(NSAttributedString(string: image.alt.isEmpty ? "" : status, attributes: [.font: NSFont.systemFont(ofSize: theme.bodyFont.pointSize - 2), .foregroundColor: theme.muted]))
    let tr = CGRect(x: rect.minX + 52, y: rect.minY + 12, width: rect.width - 64, height: rect.height - 24)
    text.draw(with: tr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }
}

/// Bytes for images. The renderer asks for nothing itself: the view hands every
/// `MarkdownImage` it lays out to its `imageLoader`, and loaded pictures land here so layout
/// (and cached heights) can pick up their real size.
public final class MarkdownImageStore: @unchecked Sendable {
  public static let shared = MarkdownImageStore()
  private let lock = NSLock()
  private var images: [MarkdownImage: NSImage] = [:]
  private var failed: Set<MarkdownImage> = []
  private var inFlight: Set<MarkdownImage> = []
  private var _version = 0

  /// Bumps whenever a load finishes; part of the cached-height key.
  public var version: Int {
    lock.lock()
    defer { lock.unlock() }
    return _version
  }

  func loaded(for image: MarkdownImage) -> NSImage? {
    lock.lock()
    defer { lock.unlock() }
    return images[image]
  }

  func isFailed(_ image: MarkdownImage) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failed.contains(image)
  }

  /// True when the caller should start loading (not loaded, failed or in flight).
  func beginLoading(_ image: MarkdownImage) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if images[image] != nil || failed.contains(image) || inFlight.contains(image) { return false }
    inFlight.insert(image)
    return true
  }

  func finish(_ image: MarkdownImage, result: NSImage?) {
    lock.lock()
    defer { lock.unlock() }
    inFlight.remove(image)
    if let result { images[image] = result } else { failed.insert(image) }
    _version += 1
  }
}
