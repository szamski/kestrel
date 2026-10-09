import AppKit
import T3Markdown

/// Draws one diff row by hand. Cells are recycled by the table, so `configure` only repoints the cell at a
/// row; all drawing reads the shared `DiffRenderContext`.
@MainActor
final class DiffRowCell: NSView {
  private var render: DiffRenderContext?
  private var index = 0
  private var didDrag = false
  private var wasOnlySelected = false

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  private var row: DiffRow? { render.flatMap { index < $0.rows.count ? $0.rows[index] : nil } }

  func configure(_ render: DiffRenderContext, index: Int) {
    self.render = render
    self.index = index
    guard let row else { return }
    switch row.kind {
    case .fileHeader:
      let file = render.files[row.file]
      let collapsed = !render.rows.indices.contains(index + 1) || render.rows[index + 1].file != row.file
      setAccessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions, \(collapsed ? "collapsed" : "expanded")")
    case .hunk(let h):
      setAccessibilityLabel(render.files[row.file].hunks[h].header)
    case .line(let l):
      setAccessibilityLabel(Self.describe(render.files[row.file].lines[l]))
    case .pair(let l, let r):
      let lines = render.files[row.file].lines
      setAccessibilityLabel([l, r].filter { $0 >= 0 }.map { Self.describe(lines[$0]) }.joined(separator: ", "))
    case .notice(let text):
      setAccessibilityLabel(text)
    }
    setAccessibilityElement(true)
    switch row.kind {
    case .line(let l): render.requestHighlight(file: row.file); _ = l
    case .pair: render.requestHighlight(file: row.file)
    default: break
    }
    needsDisplay = true
  }

  private static func describe(_ line: DiffLine) -> String {
    switch line.kind {
    case .addition: "Added line \(line.newNumber): \(line.text)"
    case .deletion: "Removed line \(line.oldNumber): \(line.text)"
    case .context: "Line \(line.newNumber): \(line.text)"
    case .noNewline: line.text
    }
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let render, let row else { return }
    let theme = render.theme(for: effectiveAppearance)
    let isDark = theme.isDark
    switch row.kind {
    case .fileHeader: drawHeader(render, row, theme)
    case .hunk(let h): drawHunk(render, row, h, theme)
    case .notice(let text): drawNotice(text, theme)
    case .line(let l): drawStacked(render, row, l, theme, isDark)
    case .pair(let l, let r): drawSplit(render, row, l, r, theme, isDark)
    }
  }

  private func drawNotice(_ text: String, _ theme: MarkdownTheme) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.muted]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(at: NSPoint(x: 40, y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }

  private static func headerButtonRect(_ bounds: NSRect) -> NSRect { NSRect(x: bounds.maxX - 34, y: (bounds.height - 24) / 2, width: 26, height: 24) }

  private func drawHeader(_ render: DiffRenderContext, _ row: DiffRow, _ theme: MarkdownTheme) {
    let file = render.files[row.file]
    theme.codeBackground.setFill()
    bounds.fill()
    theme.border.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

    let collapsed = !render.rows.indices.contains(index + 1) || render.rows[index + 1].file != row.file
    drawSymbol(collapsed ? "chevron.right" : "chevron.down", color: theme.muted, at: NSRect(x: 10, y: (bounds.height - 12) / 2, width: 12, height: 12), size: 10)

    // Right side first, so the path knows how much room it has.
    var right = Self.headerButtonRect(bounds).minX - 8
    let stat = NSMutableAttributedString()
    let monospaced = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    stat.append(NSAttributedString(string: "+\(file.additions)", attributes: [.font: monospaced, .foregroundColor: NSColor.systemGreen]))
    stat.append(NSAttributedString(string: "  \u{2212}\(file.deletions)", attributes: [.font: monospaced, .foregroundColor: NSColor.systemRed]))
    let statSize = stat.size()
    right -= statSize.width
    stat.draw(at: NSPoint(x: right, y: (bounds.height - statSize.height) / 2))
    right -= 10

    if let badge = badge(for: file) {
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: theme.muted]
      let size = (badge as NSString).size(withAttributes: attributes)
      let rect = NSRect(x: right - size.width - 10, y: (bounds.height - 16) / 2, width: size.width + 10, height: 16)
      theme.border.withAlphaComponent(0.7).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
      (badge as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + (16 - size.height) / 2), withAttributes: attributes)
      right = rect.minX - 8
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingHead
    let title = NSMutableAttributedString()
    if file.changeType == .renamed || file.changeType == .copied, let old = file.oldPath, let new = file.newPath {
      title.append(NSAttributedString(string: "\(old) \u{2192} ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.muted]))
      title.append(NSAttributedString(string: new, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: theme.foreground]))
    } else {
      title.append(NSAttributedString(string: file.directory, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.muted]))
      title.append(NSAttributedString(string: file.fileName, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: theme.foreground]))
    }
    title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
    let height = title.size().height
    title.draw(in: NSRect(x: 30, y: (bounds.height - height) / 2, width: max(40, right - 30), height: height))

    drawSymbol("ellipsis", color: theme.muted, at: Self.headerButtonRect(bounds).insetBy(dx: 5, dy: 6), size: 12)
  }

  private func badge(for file: DiffFile) -> String? {
    if file.isBinary { return "binary" }
    switch file.changeType {
    case .added: return "new"
    case .deleted: return "deleted"
    case .renamed: return "renamed"
    case .copied: return "copied"
    case .modified: return file.modeChange.map { "mode \($0.old) \u{2192} \($0.new)" }
    }
  }

  private func drawSymbol(_ name: String, color: NSColor, at rect: NSRect, size: CGFloat) {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
    let aspect = image.size.width / max(image.size.height, 1)
    let target = NSRect(x: rect.midX - rect.height * aspect / 2, y: rect.minY, width: rect.height * aspect, height: rect.height)
    image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  private func drawHunk(_ render: DiffRenderContext, _ row: DiffRow, _ hunk: Int, _ theme: MarkdownTheme) {
    theme.codeBackground.withAlphaComponent(0.55).setFill()
    bounds.fill()
    let header = render.files[row.file].hunks[hunk].header
    let attributes: [NSAttributedString.Key: Any] = [.font: render.font, .foregroundColor: theme.muted]
    let x = render.layout == .stacked ? 2 * render.numberWidth + DiffRenderContext.signWidth : render.numberWidth + DiffRenderContext.signWidth
    let size = (header as NSString).size(withAttributes: attributes)
    (header as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
  }

  private func tintColor(_ kind: DiffLine.Kind, strong: Bool) -> NSColor? {
    switch kind {
    case .addition: NSColor.systemGreen.withAlphaComponent(strong ? 0.22 : 0.12)
    case .deletion: NSColor.systemRed.withAlphaComponent(strong ? 0.22 : 0.12)
    default: nil
    }
  }

  private func drawNumber(_ number: Int, in rect: NSRect, theme: MarkdownTheme, render: DiffRenderContext) {
    guard number > 0 else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    NSAttributedString(string: String(number), attributes: [.font: render.font, .foregroundColor: theme.muted, .paragraphStyle: paragraph])
      .draw(in: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width - 6, height: render.lineHeight))
  }

  private func drawText(
    _ render: DiffRenderContext, file: Int, line: Int, x: CGFloat, width: CGFloat, columns: Int, theme: MarkdownTheme, isDark: Bool
  ) {
    let text = render.attributed(file: file, line: line, theme: theme, isDark: isDark)
    let chunks = render.chunks(of: text, columns: columns)
    for (k, range) in chunks.enumerated() {
      let piece = chunks.count == 1 ? text : text.attributedSubstring(from: range)
      piece.draw(at: NSPoint(x: x, y: 1 + CGFloat(k) * render.lineHeight))
    }
    _ = width
  }

  private func drawMarker(_ render: DiffRenderContext, file: String, line: Int, at x: CGFloat) {
    guard render.isMarked(file: file, line: line) else { return }
    NSColor.controlAccentColor.setFill()
    NSRect(x: x, y: 0, width: 2, height: bounds.height).fill()
    drawSymbol("text.bubble.fill", color: .controlAccentColor, at: NSRect(x: x + 3, y: 2, width: 11, height: 11), size: 9)
  }

  private func drawStacked(_ render: DiffRenderContext, _ row: DiffRow, _ lineIndex: Int, _ theme: MarkdownTheme, _ isDark: Bool) {
    let file = render.files[row.file]
    let line = file.lines[lineIndex]
    let g = render.geometry
    let nw = render.numberWidth
    if let base = tintColor(line.kind, strong: false) {
      base.setFill()
      bounds.fill()
      tintColor(line.kind, strong: true)?.setFill()
      NSRect(x: 0, y: 0, width: 2 * nw, height: bounds.height).fill()
    }
    if render.selection?.contains(file: file.id, line: lineIndex) == true {
      NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
      bounds.fill()
    }
    drawNumber(line.oldNumber, in: NSRect(x: 0, y: 0, width: nw, height: bounds.height), theme: theme, render: render)
    drawNumber(line.newNumber, in: NSRect(x: nw, y: 0, width: nw, height: bounds.height), theme: theme, render: render)
    drawSign(line.kind, x: 2 * nw, render: render)
    drawMarker(render, file: file.id, line: lineIndex, at: 0)
    drawText(render, file: row.file, line: lineIndex, x: g.stackedTextX, width: g.stackedTextWidth, columns: g.stackedColumns, theme: theme, isDark: isDark)
  }

  private func drawSign(_ kind: DiffLine.Kind, x: CGFloat, render: DiffRenderContext) {
    let sign: String, color: NSColor
    switch kind {
    case .addition: (sign, color) = ("+", .systemGreen)
    case .deletion: (sign, color) = ("\u{2212}", .systemRed)
    default: return
    }
    (sign as NSString).draw(at: NSPoint(x: x + 3, y: 1), withAttributes: [.font: render.font, .foregroundColor: color])
  }

  private func drawSplit(_ render: DiffRenderContext, _ row: DiffRow, _ left: Int, _ right: Int, _ theme: MarkdownTheme, _ isDark: Bool) {
    let file = render.files[row.file]
    let g = render.geometry
    theme.border.setFill()
    NSRect(x: g.half, y: 0, width: 1, height: bounds.height).fill()
    for (index, side) in [left, right].enumerated() where side >= 0 {
      let line = file.lines[side]
      let originX = index == 0 ? 0 : g.half + 1
      let width = index == 0 ? g.half : bounds.width - g.half - 1
      let sideRect = NSRect(x: originX, y: 0, width: width, height: bounds.height)
      if line.kind != .noNewline {
        tintColor(line.kind, strong: false)?.setFill()
        if tintColor(line.kind, strong: false) != nil {
          sideRect.fill()
          tintColor(line.kind, strong: true)?.setFill()
          NSRect(x: originX, y: 0, width: render.numberWidth, height: bounds.height).fill()
        }
        if render.selection?.contains(file: file.id, line: side) == true {
          NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
          sideRect.fill()
        }
        drawNumber(index == 0 ? line.oldNumber : line.newNumber, in: NSRect(x: originX, y: 0, width: render.numberWidth, height: bounds.height), theme: theme, render: render)
        drawSign(line.kind, x: originX + render.numberWidth, render: render)
        drawMarker(render, file: file.id, line: side, at: originX)
      }
      NSGraphicsContext.saveGraphicsState()
      sideRect.clip()
      NSGraphicsContext.current?.cgContext.translateBy(x: originX, y: 0)
      drawText(render, file: row.file, line: side, x: g.splitTextX, width: g.splitTextWidth, columns: g.splitColumns, theme: theme, isDark: isDark)
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    guard let render, let row else { return }
    window?.makeFirstResponder(render.table)
    let point = convert(event.locationInWindow, from: nil)
    didDrag = false
    switch row.kind {
    case .fileHeader:
      if Self.headerButtonRect(bounds).contains(point) {
        showMenu(for: render.files[row.file], at: point, event: event)
      } else {
        render.actions.toggleCollapse(render.files[row.file].id)
      }
    case .line, .pair:
      let file = render.files[row.file]
      let line = render.lineIndex(row: index, x: point.x)
      wasOnlySelected = line != nil && render.selection == DiffSelection(fileId: file.id, lo: line!, hi: line!)
      render.beginSelection(row: index, x: point.x, extend: event.modifierFlags.contains(.shift))
    default:
      break
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let render, let table = render.table else { return }
    switch row?.kind {
    case .line?, .pair?:
      didDrag = true
      table.autoscroll(with: event)
      let point = table.convert(event.locationInWindow, from: nil)
      render.extendSelection(row: table.row(at: point), x: point.x)
    default: break
    }
  }

  override func mouseUp(with event: NSEvent) {
    // A second click on the only selected line clears it.
    if !didDrag, wasOnlySelected { render?.clearSelection() }
    wasOnlySelected = false
  }

  // MARK: Menu

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let render, let row, row.kind == .fileHeader else { return nil }
    return fileMenu(for: render.files[row.file])
  }

  private func fileMenu(for file: DiffFile) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ symbol: String, _ handler: @escaping @MainActor () -> Void) {
      let item = ClosureMenuItem(title: title, handler: handler)
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      menu.addItem(item)
    }
    guard let render else { return menu }
    let isCollapsed = !(render.rows.indices.contains(index + 1) && render.rows[index + 1].file == row?.file)
    add(isCollapsed ? "Expand File" : "Collapse File", isCollapsed ? "chevron.down" : "chevron.right") { render.actions.toggleCollapse(file.id) }
    menu.addItem(.separator())
    add("Copy Path", "doc.on.doc") { render.actions.copyPath(file) }
    add("Open in Editor", "square.and.pencil") { render.actions.openInEditor(file) }
    add("Reveal in Finder", "folder") { render.actions.reveal(file) }
    return menu
  }

  private func showMenu(for file: DiffFile, at point: NSPoint, event: NSEvent) {
    let menu = fileMenu(for: file)
    menu.popUp(positioning: nil, at: NSPoint(x: Self.headerButtonRect(bounds).minX, y: Self.headerButtonRect(bounds).maxY), in: self)
  }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  init(title: String, handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}
