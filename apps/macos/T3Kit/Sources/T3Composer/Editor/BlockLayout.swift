import AppKit

/// Paints what a block paragraph shows beside or behind its text: a task's checkbox, a list marker, a
/// quote's bar, a code block's background, a rule's line. Those owns no document characters: the
/// fragment draws them and the text view hit-tests the checkbox.
final class BlockLayoutFragment: NSTextLayoutFragment {
  var block: BlockAttrs?
  var font = NSFont.systemFont(ofSize: 13.5)

  static let boxSize: CGFloat = 14

  private var firstLine: CGRect { textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: 0, height: 18) }

  /// Checkbox rect in the fragment's own coordinate space. The fragment's frame starts at the item's
  /// text (the paragraph's head indent has already moved it right), so the box sits left of x = 0, in
  /// the gutter the indent reserved.
  func checkboxRect() -> CGRect {
    let line = firstLine
    return CGRect(x: 2 - ComposerEditorStyle.listGutter, y: line.minY + (line.height - Self.boxSize) / 2, width: Self.boxSize, height: Self.boxSize)
  }

  /// The text container's left and right edges in the fragment's drawing space. The fragment's origin
  /// sits at its paragraph's text, so the line starts one indent to the left of it.
  private func lineEdges(at point: CGPoint) -> (left: CGFloat, right: CGFloat) {
    let container = textLayoutManager?.textContainer
    let padding = container?.lineFragmentPadding ?? 0
    let left = point.x - ComposerEditorStyle.indent(of: block)
    return (left, left + max(0, (container?.size.width ?? layoutFragmentFrame.width) - padding * 2))
  }

  /// Everything drawn outside the text, so the fragment repaints it.
  private var decorationBounds: CGRect {
    let width = max(layoutFragmentFrame.width, textLayoutManager?.textContainer?.size.width ?? 0)
    return CGRect(x: -ComposerEditorStyle.listGutter - 2, y: 0, width: width + ComposerEditorStyle.listGutter + 4, height: layoutFragmentFrame.height)
  }

  override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(decorationBounds) }

  override func draw(at point: CGPoint, in context: CGContext) {
    guard let kind = block?.kind else { return super.draw(at: point, in: context) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let edges = lineEdges(at: point)
    let height = layoutFragmentFrame.height
    switch kind {
    case .code:
      // Lines of one fence abut, so their backgrounds read as one block.
      NSColor.labelColor.withAlphaComponent(0.06).setFill()
      NSRect(x: edges.left, y: point.y, width: edges.right - edges.left, height: height).fill()
    case .quote:
      NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
      NSBezierPath(roundedRect: NSRect(x: edges.left + 2, y: point.y + 1, width: 2.5, height: height - 2), xRadius: 1.25, yRadius: 1.25).fill()
    case .rule:
      NSColor.separatorColor.setFill()
      NSRect(x: edges.left, y: point.y + firstLine.midY, width: edges.right - edges.left, height: 1).fill()
    case .list(let prefix):
      drawListMarker(prefix, at: point)
    case .heading, .paragraph: break
    }
    super.draw(at: point, in: context)
  }

  private func drawListMarker(_ prefix: RichListItem.Prefix, at point: CGPoint) {
    let line = firstLine
    switch prefix {
    case .task(let checked, _, _, _):
      let rect = checkboxRect().offsetBy(dx: point.x, dy: point.y)
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
      if checked {
        NSColor.controlAccentColor.setFill()
        path.fill()
        let check = NSBezierPath()
        check.move(to: CGPoint(x: rect.minX + 3.5, y: rect.midY + 0.5))
        check.line(to: CGPoint(x: rect.minX + 6, y: rect.maxY - 4))
        check.line(to: CGPoint(x: rect.maxX - 3, y: rect.minY + 4))
        check.lineWidth = 1.6
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke()
        check.stroke()
      } else {
        NSColor.secondaryLabelColor.setStroke()
        path.lineWidth = 1.2
        path.stroke()
      }
    case .marker(_, let marker, _):
      if marker.last == "." || marker.last == ")" {
        // An ordered marker is drawn as written (`3)`, a nested `7.`), right-aligned in the gutter.
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let size = (marker as NSString).size(withAttributes: attributes)
        (marker as NSString).draw(at: CGPoint(x: point.x - 6 - size.width, y: point.y + line.minY + (line.height - size.height) / 2), withAttributes: attributes)
      } else {
        let dot = CGRect(x: point.x - 13, y: point.y + line.midY - 2.5, width: 5, height: 5)
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
      }
    }
  }
}

extension ComposerTextView {
  public func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    guard richTextEnabled, let paragraph = textElement as? NSTextParagraph else {
      return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
    var block: BlockAttrs?
    var font: NSFont?
    if paragraph.attributedString.length > 0 {
      block = paragraph.attributedString.attribute(.t3Block, at: 0, effectiveRange: nil) as? BlockAttrs
      font = paragraph.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    } else if let end = textElement.elementRange?.endLocation, let contentManager = textLayoutManager.textContentManager,
      contentManager.offset(from: contentManager.documentRange.location, to: end) >= (textStorage?.length ?? 0)
    {
      block = trailingBlock
    }
    guard let block else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
    let fragment = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
    fragment.block = block
    fragment.font = font ?? composerStyle.baseFont
    return fragment
  }

  /// The checkbox under `point` (view coordinates) with the paragraph's document location.
  func taskCheckboxHit(at point: NSPoint) -> (location: Int, rect: NSRect)? {
    guard richTextEnabled, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
    let origin = textContainerOrigin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard let fragment = layoutManager.textLayoutFragment(for: local) as? BlockLayoutFragment, fragment.block?.checked != nil else { return nil }
    let frame = fragment.layoutFragmentFrame
    let box = fragment.checkboxRect().offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -3, dy: -3)
    guard box.contains(local) else { return nil }
    let location = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
    return (location, box.offsetBy(dx: origin.x, dy: origin.y))
  }
}
