import AppKit

/// A GFM table drawn as one attachment. Cell text is laid out with plain NSAttributedString
/// drawing; the column algorithm gives every column its natural width when the table fits
/// and shares the remainder fairly when it does not.
final class TableContent: DrawableContent {
  struct Cell {
    var text: NSAttributedString
    var colspan: Int
  }

  private let theme: MarkdownTheme
  private let rows: [[Cell]]  // rows[0] is the header
  private let columnCount: Int
  let plainText: String
  let accessibilityText: String

  private let padX: CGFloat = 10
  private let padY: CGFloat = 6

  struct Layout {
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var size: CGSize
  }
  private var cachedLayout: (width: CGFloat, layout: Layout)?

  init(rows: [[Cell]], columnCount: Int, theme: MarkdownTheme, plainText: String) {
    self.rows = rows
    self.columnCount = max(columnCount, 1)
    self.theme = theme
    self.plainText = plainText
    self.accessibilityText = "Table, \(rows.count) rows, \(max(columnCount, 1)) columns"
  }

  // MARK: layout

  func size(forWidth width: CGFloat) -> CGSize { layout(forWidth: width).size }

  func layout(forWidth available: CGFloat) -> Layout {
    let available = max(available, 80)
    if let c = cachedLayout, c.width == available { return c.layout }

    var natural = [CGFloat](repeating: 0, count: columnCount)
    for row in rows {
      var col = 0
      for cell in row where col < columnCount {
        if cell.colspan == 1 {
          let w = ceil(cell.text.boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).width) + padX * 2
          natural[col] = max(natural[col], w)
        }
        col += max(cell.colspan, 1)
      }
    }
    let widths = Self.distribute(natural: natural, available: available)
    var heights: [CGFloat] = []
    for row in rows {
      var col = 0
      var h: CGFloat = 0
      for cell in row where col < columnCount {
        let span = min(max(cell.colspan, 1), columnCount - col)
        let w = widths[col..<(col + span)].reduce(0, +) - padX * 2
        let ch = ceil(cell.text.boundingRect(
          with: CGSize(width: max(w, 10), height: 100_000), options: [.usesLineFragmentOrigin]).height)
        h = max(h, ch)
        col += span
      }
      heights.append(h + padY * 2)
    }
    let layout = Layout(
      columnWidths: widths, rowHeights: heights, size: CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +)))
    cachedLayout = (available, layout)
    return layout
  }

  /// Natural widths when they fit; otherwise columns narrower than their fair share keep
  /// their natural width and the rest split what is left.
  static func distribute(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
    if natural.reduce(0, +) <= available { return natural }
    var result = natural
    var open = Array(natural.indices)
    var remaining = available
    var changed = true
    while changed, !open.isEmpty {
      changed = false
      let share = remaining / CGFloat(open.count)
      for i in open where natural[i] <= share {
        result[i] = natural[i]
        remaining -= natural[i]
        open.removeAll { $0 == i }
        changed = true
      }
    }
    if !open.isEmpty {
      let share = max(remaining / CGFloat(open.count), 48)
      for i in open { result[i] = share }
    }
    return result
  }

  // MARK: drawing

  /// The layout of the last `size(forWidth:)` call, which is what is on screen; drawing and
  /// hit testing must agree with it rather than re-deriving a width from the drawn size.
  private func currentLayout(fallbackWidth: CGFloat) -> Layout {
    cachedLayout?.layout ?? layout(forWidth: fallbackWidth)
  }

  func draw(in rect: CGRect) {
    let layout = currentLayout(fallbackWidth: rect.width)
    let radius = theme.cornerRadius
    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.saveGraphicsState()
    outline.addClip()
    if let headerHeight = layout.rowHeights.first {
      theme.tableHeaderBackground.setFill()
      CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight).fill()
    }
    var y = rect.minY
    for (r, row) in rows.enumerated() {
      let height = layout.rowHeights[r]
      var x = rect.minX
      var col = 0
      for cell in row where col < columnCount {
        let span = min(max(cell.colspan, 1), columnCount - col)
        let w = layout.columnWidths[col..<(col + span)].reduce(0, +)
        cell.text.draw(
          with: CGRect(x: x + padX, y: y + padY, width: max(w - padX * 2, 1), height: height - padY * 2),
          options: [.usesLineFragmentOrigin])
        x += w
        col += span
        if col < columnCount {
          theme.border.setStroke()
          let line = NSBezierPath()
          line.move(to: CGPoint(x: x + 0.5, y: y))
          line.line(to: CGPoint(x: x + 0.5, y: y + height))
          line.lineWidth = 1
          line.stroke()
        }
      }
      y += height
      if r < rows.count - 1 {
        theme.border.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: rect.minX, y: y + 0.5))
        line.line(to: CGPoint(x: rect.maxX, y: y + 0.5))
        line.lineWidth = 1
        line.stroke()
      }
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    theme.border.setStroke()
    outline.lineWidth = 1
    outline.stroke()
  }

  // MARK: hit testing

  /// The `.link` value under `point` (table coordinates, origin top-left), if any.
  func link(at point: CGPoint) -> Any? {
    let layout = currentLayout(fallbackWidth: 10_000)
    var y: CGFloat = 0
    for (r, row) in rows.enumerated() {
      let height = layout.rowHeights[r]
      defer { y += height }
      guard point.y >= y, point.y < y + height else { continue }
      var x: CGFloat = 0
      var col = 0
      for cell in row where col < columnCount {
        let span = min(max(cell.colspan, 1), columnCount - col)
        let w = layout.columnWidths[col..<(col + span)].reduce(0, +)
        defer {
          x += w
          col += span
        }
        guard point.x >= x, point.x < x + w else { continue }
        return Self.link(in: cell.text, at: CGPoint(x: point.x - x - padX, y: point.y - y - padY), width: w - padX * 2)
      }
    }
    return nil
  }

  private static func link(in text: NSAttributedString, at point: CGPoint, width: CGFloat) -> Any? {
    guard text.length > 0, point.x >= 0, point.y >= 0 else { return nil }
    let storage = NSTextStorage(attributedString: text)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    var fraction: CGFloat = 0
    let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
    guard index < text.length else { return nil }
    let glyphRange = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
    guard manager.boundingRect(forGlyphRange: glyphRange, in: container).insetBy(dx: -1, dy: -1).contains(point) else {
      return nil
    }
    return text.attribute(.t3CellLink, at: index, effectiveRange: nil)
  }
}
