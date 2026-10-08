import AppKit

/// Paints the checkbox of a task-list paragraph in its left gutter. The checkbox owns no document
/// character: it is drawn by the layout fragment and hit-tested by the text view.
final class TaskLayoutFragment: NSTextLayoutFragment {
  var task: TaskAttrsBox?

  static let boxSize: CGFloat = 14

  /// Checkbox rect in the fragment's own coordinate space. The fragment's frame starts at the item's
  /// text (the paragraph's head indent has already moved it right), so the box sits left of x = 0, in
  /// the gutter the indent reserved.
  func checkboxRect() -> CGRect {
    let line = textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: 0, height: 18)
    return CGRect(x: 2 - ComposerEditorStyle.taskGutter, y: line.minY + (line.height - Self.boxSize) / 2, width: Self.boxSize, height: Self.boxSize)
  }

  override var renderingSurfaceBounds: CGRect {
    super.renderingSurfaceBounds.union(checkboxRect())
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    super.draw(at: point, in: context)
    guard let task else { return }
    let rect = checkboxRect().offsetBy(dx: point.x, dy: point.y)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
    if task.checked {
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
  }
}

extension ComposerTextView {
  public func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    guard richTextEnabled, let paragraph = textElement as? NSTextParagraph else {
      return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
    var task: TaskAttrsBox?
    if paragraph.attributedString.length > 0 {
      task = paragraph.attributedString.attribute(.t3Task, at: 0, effectiveRange: nil) as? TaskAttrsBox
    } else if let end = textElement.elementRange?.endLocation, let contentManager = textLayoutManager.textContentManager,
      contentManager.offset(from: contentManager.documentRange.location, to: end) >= (textStorage?.length ?? 0)
    {
      task = trailingTask
    }
    guard let task else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
    let fragment = TaskLayoutFragment(textElement: textElement, range: textElement.elementRange)
    fragment.task = task
    return fragment
  }

  /// The checkbox under `point` (view coordinates) with the paragraph's document location.
  func taskCheckboxHit(at point: NSPoint) -> (location: Int, rect: NSRect)? {
    guard richTextEnabled, let layoutManager = textLayoutManager, let contentManager = layoutManager.textContentManager else { return nil }
    let origin = textContainerOrigin
    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard let fragment = layoutManager.textLayoutFragment(for: local) as? TaskLayoutFragment else { return nil }
    let frame = fragment.layoutFragmentFrame
    let box = fragment.checkboxRect().offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -3, dy: -3)
    guard box.contains(local) else { return nil }
    let location = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
    return (location, box.offsetBy(dx: origin.x, dy: origin.y))
  }
}
