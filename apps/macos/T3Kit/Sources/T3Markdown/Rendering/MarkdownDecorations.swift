import AppKit

extension NSAttributedString.Key {
  /// `ParagraphDecoration` drawn behind a paragraph by `DecoratedLayoutFragment`.
  static let t3Decoration = NSAttributedString.Key("t3md.decoration")
  /// Text that is chrome (code-block header): drawn, but left out of copied text.
  static let t3Chrome = NSAttributedString.Key("t3md.chrome")
  /// Replacement used when copying the run (attachments, list markers, rules).
  static let t3PlainText = NSAttributedString.Key("t3md.plainText")
  /// Marks a code header paragraph; the value is its horizontal padding. The right-aligned
  /// "Copy" tab stop depends on the container width, so the view re-applies it on resize.
  static let t3CodeHeader = NSAttributedString.Key("t3md.codeHeader")
  /// Value: the code block's id. Set on the body slices; used by copy-block and tests.
  static let t3CodeID = NSAttributedString.Key("t3md.codeID")
}

/// What to draw behind one paragraph. A reference type so a run keeps one identity and the
/// builder can finish a quote's last paragraph after the fact (`endsBars`).
final class ParagraphDecoration: NSObject {
  struct Bar {
    var id: Int
    var x: CGFloat
    var color: NSColor
    var width: CGFloat
  }
  struct Box {
    var left: CGFloat
    var fill: NSColor
    var stroke: NSColor?
    var radius: CGFloat
    var roundTop: Bool
    var roundBottom: Bool
    var padTop: CGFloat
    var padBottom: CGFloat
  }

  var bars: [Bar] = []
  /// Bars that end with this paragraph (so they do not run through the block gap after it).
  var endsBars: Set<Int> = []
  var box: Box?
  /// Horizontal rule: x of its left end and colour.
  var rule: (x: CGFloat, color: NSColor)?
}

/// Layout fragment that paints a `ParagraphDecoration` under the paragraph's text.
///
/// TextKit 2 sizes a fragment to its text, so the fragment widens its rendering surface to
/// the container and draws in fragment-local coordinates. Selection, copy and accessibility
/// keep working because everything underneath is ordinary text.
final class DecoratedLayoutFragment: NSTextLayoutFragment {
  let decoration: ParagraphDecoration

  init(textElement: NSTextElement, range: NSTextRange?, decoration: ParagraphDecoration) {
    self.decoration = decoration
    super.init(textElement: textElement, range: range)
  }

  required init?(coder: NSCoder) { fatalError("not archived") }

  private var containerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width }

  override var renderingSurfaceBounds: CGRect {
    let frame = layoutFragmentFrame
    let full = CGRect(x: -frame.origin.x, y: 0, width: max(containerWidth, frame.width), height: frame.height)
    return super.renderingSurfaceBounds.union(full)
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    let originX = layoutFragmentFrame.origin.x
    let left = point.x - originX  // container's left edge in context coordinates
    let width = containerWidth
    let fragmentBottom = point.y + layoutFragmentFrame.height
    let textTop = point.y + (textLineFragments.first?.typographicBounds.minY ?? 0)
    let textBottom = point.y + (textLineFragments.last?.typographicBounds.maxY ?? layoutFragmentFrame.height)

    context.saveGState()
    for bar in decoration.bars {
      let bottom = decoration.endsBars.contains(bar.id) ? textBottom : fragmentBottom
      context.setFillColor(bar.color.cgColor)
      context.fill(CGRect(x: left + bar.x, y: point.y, width: bar.width, height: bottom - point.y))
    }
    if let rule = decoration.rule {
      context.setFillColor(rule.color.cgColor)
      let y = (textTop + textBottom) / 2
      context.fill(CGRect(x: left + rule.x, y: y - 0.5, width: width - rule.x, height: 1))
    }
    if let box = decoration.box {
      drawBox(
        box, left: left, width: width, textTop: textTop, textBottom: textBottom, fragmentTop: point.y,
        fragmentBottom: fragmentBottom, in: context)
    }
    context.restoreGState()
    super.draw(at: point, in: context)
  }

  /// Boxes may span several paragraphs. Each paragraph clips to its own rows and draws the
  /// whole rounded rect extended past any square end, so seams between slices vanish and
  /// the border continues down both sides.
  private func drawBox(
    _ box: ParagraphDecoration.Box, left: CGFloat, width: CGFloat, textTop: CGFloat, textBottom: CGFloat,
    fragmentTop: CGFloat, fragmentBottom: CGFloat, in context: CGContext
  ) {
    // Square ends run to the fragment edge so stacked paragraphs of one box meet exactly.
    let top = box.roundTop ? textTop - box.padTop : fragmentTop
    let bottom = box.roundBottom ? textBottom + box.padBottom : fragmentBottom
    let x = left + box.left
    let w = width - box.left
    let clip = CGRect(x: x - 1, y: top - (box.roundTop ? 1 : 0), width: w + 2, height: bottom - top + (box.roundBottom ? 1 : 0))
    let extend: CGFloat = 40
    let rect = CGRect(
      x: x + 0.5, y: top - (box.roundTop ? 0 : extend), width: w - 1,
      height: (bottom - top) + (box.roundTop ? 0 : extend) + (box.roundBottom ? 0 : extend))
    context.saveGState()
    context.clip(to: clip)
    let path = CGPath(roundedRect: rect, cornerWidth: box.radius, cornerHeight: box.radius, transform: nil)
    context.addPath(path)
    context.setFillColor(box.fill.cgColor)
    context.fillPath()
    if let stroke = box.stroke {
      context.addPath(path)
      context.setStrokeColor(stroke.cgColor)
      context.setLineWidth(1)
      context.strokePath()
    }
    context.restoreGState()
  }
}

/// Supplies decorated fragments for paragraphs that carry a `ParagraphDecoration`.
final class MarkdownLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
      let decoration = paragraph.attributedString.attribute(.t3Decoration, at: 0, effectiveRange: nil)
        as? ParagraphDecoration
    {
      return DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
    }
    return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
  }
}
