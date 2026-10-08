import AppKit

/// Draws a chip as an image sized to the text around it. The drawing handler runs at paint time,
/// so dynamic colors follow light and dark appearance without re-rendering.
@MainActor
enum ChipRenderer {
  /// `oklch(0.62 C H)` accents of the web chips, as (chroma, hue).
  private static let accents: [ChipPresentation.Kind: (CGFloat, CGFloat)] = [
    .image: (0.16, 16), .video: (0.16, 48), .file: (0.136, 237), .mention: (0.11, 215), .terminal: (0.134, 163), .element: (0.134, 70),
    .previewAnnotation: (0.134, 70), .reviewComment: (0.16, 292), .pullRequest: (0.16, 277), .prOpen: (0.134, 163), .prDraft: (0.02, 259),
    .prMerged: (0.16, 292), .prClosed: (0.16, 16), .skill: (0.16, 322), .citation: (0.16, 259),
  ]

  /// `oklch` to sRGB (OKLab matrix path).
  static func color(lightness: CGFloat, chroma: CGFloat, hue: CGFloat) -> NSColor {
    let h = hue * .pi / 180
    let a = chroma * cos(h)
    let b = chroma * sin(h)
    let l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
    let m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
    let s_ = lightness - 0.0894841775 * a - 1.2914855480 * b
    let l = l_ * l_ * l_
    let m = m_ * m_ * m_
    let s = s_ * s_ * s_
    func gamma(_ value: CGFloat) -> CGFloat {
      let clamped = max(0, min(1, value))
      return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
    return NSColor(
      srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
  }

  static func accent(for kind: ChipPresentation.Kind) -> NSColor {
    guard let (chroma, hue) = accents[kind] else { return .secondaryLabelColor }
    return color(lightness: 0.62, chroma: chroma, hue: hue)
  }

  /// Chip metrics scale with the text: em-relative like the web chips.
  struct Metrics {
    var height: CGFloat
    var corner: CGFloat
    var horizontalPadding: CGFloat
    var gap: CGFloat
    var iconSize: CGFloat
    var font: NSFont

    init(textFont: NSFont) {
      let em = textFont.pointSize
      font = NSFont.systemFont(ofSize: em * 0.86, weight: .medium)
      height = (em * 1.41).rounded()
      corner = em * 0.5
      horizontalPadding = em * 0.5
      gap = em * 0.33
      iconSize = em * 1.0
    }
  }

  static func size(for presentation: ChipPresentation, textFont: NSFont) -> CGSize {
    let metrics = Metrics(textFont: textFont)
    var width = metrics.horizontalPadding * 2 + metrics.iconSize + metrics.gap
    width += (displayLabel(presentation) as NSString).size(withAttributes: [.font: metrics.font]).width.rounded(.up)
    if presentation.editableComment { width += metrics.gap + metrics.iconSize * 0.85 }
    return CGSize(width: min(width, 360), height: metrics.height)
  }

  static func displayLabel(_ presentation: ChipPresentation) -> String {
    presentation.suffix.map { "\(presentation.label) · \($0)" } ?? presentation.label
  }

  static func image(for presentation: ChipPresentation, textFont: NSFont, isSelected: Bool = false) -> NSImage {
    let metrics = Metrics(textFont: textFont)
    let size = size(for: presentation, textFont: textFont)
    let image = NSImage(size: size, flipped: false) { rect in
      draw(presentation, in: rect, metrics: metrics)
      return true
    }
    image.accessibilityDescription = presentation.accessibilityLabel
    return image
  }

  private static func draw(_ presentation: ChipPresentation, in rect: CGRect, metrics: Metrics) {
    let accent: NSColor = presentation.isError ? .systemRed : accent(for: presentation.kind)
    let foreground = presentation.isError ? NSColor.systemRed : accent.blended(withFraction: 0.78, of: .labelColor) ?? .labelColor
    let inset = rect.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: inset, xRadius: metrics.corner, yRadius: metrics.corner)
    accent.withAlphaComponent(0.11).setFill()
    path.fill()
    (accent.blended(withFraction: 0.66, of: .separatorColor) ?? accent).withAlphaComponent(0.55).setStroke()
    path.lineWidth = 1
    if presentation.isUnresolved { path.setLineDash([3, 2], count: 2, phase: 0) }
    path.stroke()

    var x = metrics.horizontalPadding
    if let symbol = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil) {
      let configuration = NSImage.SymbolConfiguration(pointSize: metrics.iconSize * 0.82, weight: .semibold)
      let tinted = symbol.withSymbolConfiguration(configuration)?.tinted(foreground)
      if let tinted {
        let iconRect = CGRect(x: x, y: (rect.height - metrics.iconSize) / 2, width: metrics.iconSize, height: metrics.iconSize)
        let fitted = aspectFit(tinted.size, in: iconRect)
        tinted.draw(in: fitted)
      }
    }
    x += metrics.iconSize + metrics.gap
    let label = displayLabel(presentation) as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: metrics.font, .foregroundColor: foreground]
    let labelSize = label.size(withAttributes: attributes)
    let available = rect.width - x - metrics.horizontalPadding - (presentation.editableComment ? metrics.gap + metrics.iconSize * 0.85 : 0)
    let labelRect = CGRect(x: x, y: (rect.height - labelSize.height) / 2, width: max(0, available), height: labelSize.height)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    label.draw(in: labelRect, withAttributes: attributes.merging([.paragraphStyle: paragraph]) { $1 })
    if presentation.editableComment, let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil) {
      let configuration = NSImage.SymbolConfiguration(pointSize: metrics.iconSize * 0.7, weight: .semibold)
      if let tinted = pencil.withSymbolConfiguration(configuration)?.tinted(foreground) {
        let side = metrics.iconSize * 0.85
        tinted.draw(in: aspectFit(tinted.size, in: CGRect(x: rect.width - metrics.horizontalPadding - side, y: (rect.height - side) / 2, width: side, height: side)))
      }
    }
  }

  private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let scale = min(rect.width / size.width, rect.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
  }
}

extension NSImage {
  /// A copy filled with `color` (SF Symbols are template images).
  func tinted(_ color: NSColor) -> NSImage {
    let copy = NSImage(size: size, flipped: false) { rect in
      self.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    return copy
  }
}
