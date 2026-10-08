import AppKit

/// What a chunk renders to, besides its attributed string.
struct BuiltChunk {
  var text: NSAttributedString
  /// Code by id, for the copy buttons.
  var codeBlocks: [String: String]
  /// Code blocks that were not in the highlight cache when this chunk was built.
  var pendingHighlights: [PendingHighlight]
  var highlightedBlockCount: Int
  var images: [MarkdownImage]
}

struct PendingHighlight: Hashable, Sendable {
  var code: String
  var language: String
}

/// Model → attributed string. Pure: the same blocks and theme always give the same string,
/// independent of width (width-dependent pieces are attachments sized at layout time).
final class MarkdownAttributedBuilder {
  let theme: MarkdownTheme
  let highlighter: SyntaxHighlighter
  let imageStore: MarkdownImageStore

  private let out = NSMutableAttributedString()
  private var codeBlocks: [String: String] = [:]
  private var pending: [PendingHighlight] = []
  private var highlighted = 0
  private var images: [MarkdownImage] = []
  private var nextBarID = 0
  /// Identity of the chunk being built and how many `<details>` it has already numbered.
  private var chunkID: UInt64 = 0
  private var detailsOrdinal = 0
  /// Start of the paragraph being written last, so a quote can mark where its bar ends.
  private var lastParagraphStart = 0

  init(theme: MarkdownTheme, highlighter: SyntaxHighlighter, imageStore: MarkdownImageStore) {
    self.theme = theme
    self.highlighter = highlighter
    self.imageStore = imageStore
  }

  func build(_ blocks: [MarkdownBlock], chunkID: UInt64 = 0) -> BuiltChunk {
    self.chunkID = chunkID
    emit(blocks, Context(), lastSpacing: theme.blockSpacing, innerSpacing: theme.blockSpacing)
    return BuiltChunk(
      text: out, codeBlocks: codeBlocks, pendingHighlights: pending, highlightedBlockCount: highlighted, images: images)
  }

  // MARK: context

  struct Context {
    var indent: CGFloat = 0
    var bars: [ParagraphDecoration.Bar] = []
    var listDepth = 0
  }

  private var body: NSFont { theme.bodyFont }

  private func paragraphStyle(
    _ ctx: Context, first: CGFloat? = nil, head: CGFloat? = nil, before: CGFloat = 0, after: CGFloat,
    alignment: NSTextAlignment = .natural, tabs: [NSTextTab] = [], tail: CGFloat = 0
  ) -> NSMutableParagraphStyle {
    let s = NSMutableParagraphStyle()
    s.firstLineHeadIndent = first ?? ctx.indent
    s.headIndent = head ?? ctx.indent
    s.tailIndent = tail
    s.lineSpacing = theme.lineSpacing
    s.paragraphSpacingBefore = before
    s.paragraphSpacing = after
    s.alignment = alignment
    s.tabStops = tabs
    s.lineBreakMode = .byWordWrapping
    return s
  }

  private func decoration(_ ctx: Context) -> ParagraphDecoration? {
    guard !ctx.bars.isEmpty else { return nil }
    let d = ParagraphDecoration()
    d.bars = ctx.bars
    return d
  }

  /// Appends one paragraph and returns its range.
  @discardableResult
  private func appendParagraph(
    _ content: NSAttributedString, style: NSParagraphStyle, decoration: ParagraphDecoration?,
    extra: [NSAttributedString.Key: Any] = [:]
  ) -> NSRange {
    let start = out.length
    let m = NSMutableAttributedString(attributedString: content)
    m.append(NSAttributedString(string: "\n", attributes: newlineAttributes(after: content)))
    let full = NSRange(location: 0, length: m.length)
    m.addAttribute(.paragraphStyle, value: style, range: full)
    if let decoration { m.addAttribute(.t3Decoration, value: decoration, range: full) }
    if !extra.isEmpty { m.addAttributes(extra, range: full) }
    out.append(m)
    lastParagraphStart = start
    return NSRange(location: start, length: m.length)
  }

  /// The paragraph's newline looks like the text before it but is not part of what that text
  /// stands for: an attachment, a link, or a copy replacement (kept only when it is "", which
  /// makes a hairline vanish from copied text entirely).
  private func newlineAttributes(after content: NSAttributedString) -> [NSAttributedString.Key: Any] {
    guard content.length > 0 else { return [.font: body] }
    var attrs = content.attributes(at: content.length - 1, effectiveRange: nil)
    for key: NSAttributedString.Key in [.attachment, .link, .toolTip, .t3CodeID, .backgroundColor] { attrs[key] = nil }
    if (attrs[.t3PlainText] as? String)?.isEmpty != true { attrs[.t3PlainText] = nil }
    return attrs
  }

  // MARK: blocks

  private func emit(_ blocks: [MarkdownBlock], _ ctx: Context, lastSpacing: CGFloat, innerSpacing: CGFloat) {
    for (i, block) in blocks.enumerated() {
      let spacing = i == blocks.count - 1 ? lastSpacing : innerSpacing
      emit(block, ctx, spacing: spacing, firstInItem: nil)
    }
  }

  private func emit(_ block: MarkdownBlock, _ ctx: Context, spacing: CGFloat, firstInItem prefix: NSAttributedString?) {
    switch block {
    case .paragraph(let inlines, let alignment):
      let text = NSMutableAttributedString()
      if let prefix { text.append(prefix) }
      text.append(inline(inlines, InlineStyle(font: body, color: theme.foreground)))
      appendParagraph(
        text, style: contentStyle(ctx, prefix: prefix, after: spacing, alignment: alignment.nsAlignment),
        decoration: decoration(ctx))
    case .heading(let level, let inlines):
      let font = theme.headingFont(level: level)
      let text = NSMutableAttributedString()
      if let prefix { text.append(prefix) }
      text.append(inline(inlines, InlineStyle(font: font, color: theme.foreground)))
      appendParagraph(
        text, style: contentStyle(ctx, prefix: prefix, before: theme.blockSpacing * 0.6, after: max(spacing * 0.6, 4)),
        decoration: decoration(ctx))
    case .code(let code):
      emitCode(code, ctx, spacing: spacing)
    case .quote(let children):
      emitQuote(children, ctx, color: theme.quoteBar, title: nil, spacing: spacing)
    case .alert(let kind, let children):
      emitQuote(children, ctx, color: theme.color(for: kind), title: kind, spacing: spacing)
    case .list(let list):
      emitList(list, ctx, spacing: spacing)
    case .table(let table):
      emitTable(table, ctx, spacing: spacing)
    case .thematicBreak:
      let d = decoration(ctx) ?? ParagraphDecoration()
      d.rule = (ctx.indent, theme.border)
      appendParagraph(
        NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 6), .t3PlainText: "---"]),
        style: paragraphStyle(ctx, before: 4, after: spacing), decoration: d)
    case .image(let image):
      images.append(image)
      let attachment = ContentAttachment(content: ImageContent(image: image, theme: theme, store: imageStore), indent: ctx.indent)
      let text = NSMutableAttributedString(attachment: attachment)
      let link = MarkdownLinkCoding.url(for: .image(image))
      text.addAttributes([.link: link, .t3PlainText: attachment.content.plainText], range: NSRange(location: 0, length: text.length))
      appendParagraph(text, style: paragraphStyle(ctx, after: spacing), decoration: decoration(ctx))
    case .artifactTemplate(let template):
      emitArtifact(template, ctx, spacing: spacing)
    case .details(let summary, let isOpen, let children):
      emitDetails(summary, isOpen: isOpen, children, ctx, spacing: spacing)
    }
  }

  // MARK: details

  /// Rule, summary row (chevron + title, one link that toggles), the body when open, rule.
  /// Ordinals count every section of the chunk, open or not, so a section's key never
  /// depends on whether an earlier one is expanded.
  private func emitDetails(
    _ summary: [MarkdownInline], isOpen authored: Bool, _ children: [MarkdownBlock], _ ctx: Context, spacing: CGFloat
  ) {
    let ordinal = detailsOrdinal
    detailsOrdinal += 1
    let key = MarkdownDetailsStore.key(chunk: chunkID, ordinal: ordinal)
    let open = MarkdownDetailsStore.shared.state(for: key) ?? authored
    if !open { detailsOrdinal += MarkdownStream.detailsCount(in: children) }

    appendRule(ctx, before: 0, after: 1)
    let title = NSMutableAttributedString()
    if let symbol = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: body.pointSize - 2, weight: .semibold))
    {
      let a = NSTextAttachment()
      a.image = symbol.tinted(with: theme.muted)
      a.bounds = CGRect(x: 0, y: -1, width: symbol.size.width, height: symbol.size.height)
      title.append(NSAttributedString(attachment: a))
    }
    title.append(NSAttributedString(string: "\t"))
    title.addAttribute(.t3PlainText, value: "", range: NSRange(location: 0, length: title.length))
    let font = NSFont.systemFont(ofSize: body.pointSize, weight: .semibold)
    title.append(inline(summary, InlineStyle(font: font, color: theme.foreground)))
    title.addAttributes(
      [
        .link: MarkdownLinkCoding.toggleURL(key: key, open: open), .toolTip: open ? "Collapse" : "Expand",
      ], range: NSRange(location: 0, length: title.length))
    let indent = theme.listIndent
    appendParagraph(
      title,
      style: paragraphStyle(
        ctx, first: ctx.indent, head: ctx.indent + indent, before: 4, after: open ? 4 : 3,
        tabs: [NSTextTab(textAlignment: .left, location: ctx.indent + indent)]),
      decoration: decoration(ctx))
    if open {
      var inner = ctx
      inner.indent = ctx.indent + indent
      emit(children, inner, lastSpacing: 4, innerSpacing: theme.blockSpacing)
    }
    appendRule(ctx, before: 0, after: spacing)
  }

  /// A hairline across the block, empty in copied text.
  private func appendRule(_ ctx: Context, before: CGFloat, after: CGFloat) {
    let d = decoration(ctx) ?? ParagraphDecoration()
    d.rule = (ctx.indent, theme.border)
    appendParagraph(
      NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 6), .t3PlainText: ""]),
      style: paragraphStyle(ctx, before: before, after: after), decoration: d)
  }

  /// Style for a text paragraph; with a list marker the first line hangs left of the content
  /// indent and the marker's tab lands exactly on it.
  private func contentStyle(
    _ ctx: Context, prefix: NSAttributedString?, before: CGFloat = 0, after: CGFloat, alignment: NSTextAlignment = .natural
  ) -> NSParagraphStyle {
    guard let width = prefix?.attribute(.t3MarkerWidth, at: 0, effectiveRange: nil) as? CGFloat else {
      return paragraphStyle(ctx, before: before, after: after, alignment: alignment)
    }
    return paragraphStyle(
      ctx, first: ctx.indent - width, before: before, after: after, alignment: alignment,
      tabs: [NSTextTab(textAlignment: .left, location: ctx.indent)])
  }

  // MARK: quote / alert

  private func emitQuote(
    _ children: [MarkdownBlock], _ ctx: Context, color: NSColor, title: MarkdownAlertKind?, spacing: CGFloat
  ) {
    var inner = ctx
    nextBarID += 1
    let barID = nextBarID
    inner.bars.append(.init(id: barID, x: ctx.indent, color: color, width: 3))
    inner.indent = ctx.indent + 14
    let startLength = out.length
    if let title {
      let symbol = NSImage(systemSymbolName: Self.symbol(for: title), accessibilityDescription: title.title)?
        .withSymbolConfiguration(.init(pointSize: body.pointSize - 1, weight: .semibold))
      let text = NSMutableAttributedString()
      if let symbol {
        let a = NSTextAttachment()
        a.image = symbol.tinted(with: color)
        a.bounds = CGRect(x: 0, y: -2, width: symbol.size.width, height: symbol.size.height)
        text.append(NSAttributedString(attachment: a))
        text.append(NSAttributedString(string: " "))
      }
      text.append(NSAttributedString(string: title.title))
      text.addAttributes(
        [.font: NSFont.systemFont(ofSize: body.pointSize, weight: .semibold), .foregroundColor: color],
        range: NSRange(location: 0, length: text.length))
      text.addAttribute(.t3PlainText, value: "", range: NSRange(location: 0, length: min(text.length, symbol == nil ? 0 : 2)))
      let d = decoration(inner)!
      appendParagraph(text, style: paragraphStyle(inner, after: children.isEmpty ? 0 : 3), decoration: d)
    }
    emit(children, inner, lastSpacing: spacing, innerSpacing: max(theme.blockSpacing * 0.6, 4))
    // The bar stops with the last paragraph instead of running through the gap after it.
    if out.length > startLength, let d = out.attribute(.t3Decoration, at: lastParagraphStart, effectiveRange: nil) as? ParagraphDecoration {
      d.endsBars.insert(barID)
    }
  }

  private static func symbol(for kind: MarkdownAlertKind) -> String {
    switch kind {
    case .note: "info.circle"
    case .tip: "lightbulb"
    case .important: "exclamationmark.bubble"
    case .warning: "exclamationmark.triangle"
    case .caution: "exclamationmark.octagon"
    }
  }

  // MARK: lists

  private func emitList(_ list: MarkdownList, _ ctx: Context, spacing: CGFloat) {
    let gap = list.isTight ? theme.listItemSpacing : theme.blockSpacing * 0.6
    let lastNumber = list.start + list.items.count - 1
    let numberWidth = list.isOrdered ? CGFloat(String(max(lastNumber, 1)).count) * body.pointSize * 0.6 + body.pointSize * 0.9 : 0
    // A task box is a symbol glyph that grows with the font: the marker column must outgrow it
    // or the tab skips to the next default stop and the text starts past the hanging indent.
    let taskWidth = list.items.contains { $0.checked != nil } ? Self.taskBoxWidth(body) : 0
    let width = max(theme.listIndent, numberWidth, taskWidth)
    for (index, item) in list.items.enumerated() {
      let isLast = index == list.items.count - 1
      let after = isLast ? spacing : gap
      var inner = ctx
      inner.indent = ctx.indent + width
      inner.listDepth = ctx.listDepth + 1
      let marker = markerText(list, item, index: index, width: width, depth: ctx.listDepth)
      if item.blocks.isEmpty {
        appendParagraph(marker, style: markerStyle(ctx, width: width, after: after), decoration: decoration(ctx))
        continue
      }
      for (i, block) in item.blocks.enumerated() {
        let blockSpacing = i == item.blocks.count - 1 ? after : (list.isTight ? theme.listItemSpacing : theme.blockSpacing * 0.6)
        if i == 0 {
          switch block {
          case .paragraph, .heading:
            emit(block, inner, spacing: blockSpacing, firstInItem: marker)
          default:
            appendParagraph(marker, style: markerStyle(ctx, width: width, after: 2), decoration: decoration(ctx))
            emit(block, inner, spacing: blockSpacing, firstInItem: nil)
          }
        } else {
          emit(block, inner, spacing: blockSpacing, firstInItem: nil)
        }
      }
    }
  }

  static func taskBoxWidth(_ font: NSFont) -> CGFloat {
    ceil(max(("\u{2611}" as NSString).size(withAttributes: [.font: font]).width, ("\u{2610}" as NSString).size(withAttributes: [.font: font]).width)) + 8
  }

  private func markerStyle(_ ctx: Context, width: CGFloat, after: CGFloat) -> NSParagraphStyle {
    paragraphStyle(
      ctx, first: ctx.indent, head: ctx.indent + width, after: after,
      tabs: [NSTextTab(textAlignment: .left, location: ctx.indent + width)])
  }

  /// "•\t", "12.\t" or a task box. The tab lands on the item's content indent.
  private func markerText(_ list: MarkdownList, _ item: MarkdownListItem, index: Int, width: CGFloat, depth: Int) -> NSAttributedString {
    let plain: String
    let shown: String
    var color = theme.muted
    if let checked = item.checked {
      shown = checked ? "\u{2611}" : "\u{2610}"
      plain = checked ? "[x] " : "[ ] "
      color = checked ? theme.link : theme.muted
    } else if list.isOrdered {
      shown = "\(list.start + index)."
      plain = "\(list.start + index). "
    } else {
      shown = ["\u{2022}", "\u{25E6}", "\u{25AA}"][min(depth, 2)]
      plain = "• "
    }
    let m = NSMutableAttributedString(
      string: shown + "\t", attributes: [.font: body, .foregroundColor: color, .t3PlainText: plain, .t3MarkerWidth: width])
    // Only the first character carries the replacement, the tab is dropped from copies.
    m.addAttribute(.t3PlainText, value: "", range: NSRange(location: shown.utf16.count, length: 1))
    return m
  }

  // MARK: code

  static let copyLabel = "  Copy"
  static let copiedLabel = "Copied"

  /// One attachment character per block (see `CodeBlockAttachment`): the box, header and
  /// scrolling body live in its view, so lines never wrap and the text view's own layout is
  /// a single line however long the code is.
  private func emitCode(_ code: MarkdownCodeBlock, _ ctx: Context, spacing: CGFloat) {
    let id = String(FNV.hash((code.language ?? "").utf8, seed: FNV.hash(code.code.utf8)), radix: 36)
    codeBlocks[id] = code.code
    let content = CodeBlockContent(
      id: id, language: code.language, code: code.code, spans: bodySpans(code), theme: theme)
    let text = NSMutableAttributedString(attachment: CodeBlockAttachment(content: content, indent: ctx.indent))
    text.addAttributes(
      [.t3PlainText: code.code, .t3CodeID: id, .font: CodeBlockAttachment.anchorFont],
      range: NSRange(location: 0, length: text.length))
    // The block is exactly its own height: no line spacing, no room below the baseline.
    let style = paragraphStyle(ctx, after: spacing)
    style.lineSpacing = 0
    style.minimumLineHeight = content.height
    style.maximumLineHeight = content.height
    appendParagraph(text, style: style, decoration: decoration(ctx))
  }

  /// Highlight spans for the code body, or none (plain) when not cached yet or still streaming.
  private func bodySpans(_ code: MarkdownCodeBlock) -> [HighlightSpan] {
    guard !code.isOpen, let language = code.language, SyntaxHighlighter.canonicalLanguage(language) != nil else {
      return []
    }
    if let hit = highlighter.cached(code: code.code, language: language) {
      highlighted += 1
      return hit.spans
    }
    pending.append(PendingHighlight(code: code.code, language: language))
    return []
  }

  // MARK: tables

  private func emitTable(_ table: MarkdownTable, _ ctx: Context, spacing: CGFloat) {
    let align: (Int) -> NSTextAlignment = { col in
      col < table.alignments.count ? table.alignments[col].nsAlignment : .natural
    }
    func cellText(_ cell: MarkdownTableCell, col: Int, header: Bool) -> TableContent.Cell {
      let font = header ? NSFont.systemFont(ofSize: body.pointSize, weight: .semibold) : body
      let text = NSMutableAttributedString(
        attributedString: inline(cell.inlines, InlineStyle(font: font, color: theme.foreground), textOnly: true))
      let style = NSMutableParagraphStyle()
      style.alignment = align(col)
      style.lineSpacing = 2
      text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
      return .init(text: text, colspan: cell.colspan)
    }
    var rows: [[TableContent.Cell]] = []
    rows.append(table.header.enumerated().map { cellText($1, col: $0, header: true) })
    for row in table.rows { rows.append(row.enumerated().map { cellText($1, col: $0, header: false) }) }
    // Markdown pipe table for copy and VoiceOver.
    func plain(_ cells: [MarkdownTableCell]) -> String {
      "| " + cells.map { MarkdownInline.plainText($0.inlines).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
    }
    var lines = [plain(table.header), "| " + Array(repeating: "---", count: max(table.header.count, 1)).joined(separator: " | ") + " |"]
    lines += table.rows.map(plain)
    let content = TableContent(rows: rows, columnCount: table.columnCount, theme: theme, plainText: lines.joined(separator: "\n"))
    let attachment = ContentAttachment(content: content, indent: ctx.indent)
    let text = NSMutableAttributedString(attachment: attachment)
    text.addAttribute(.t3PlainText, value: content.plainText, range: NSRange(location: 0, length: text.length))
    appendParagraph(text, style: paragraphStyle(ctx, after: spacing), decoration: decoration(ctx))
  }

  // MARK: artifact card

  private func emitArtifact(_ template: MarkdownArtifactTemplate, _ ctx: Context, spacing: CGFloat) {
    let pad = theme.codePadding
    let boxOf: (Bool, Bool) -> ParagraphDecoration = { top, bottom in
      let d = self.decoration(ctx) ?? ParagraphDecoration()
      d.box = .init(
        left: ctx.indent, fill: self.theme.codeBackground, stroke: self.theme.border, radius: self.theme.cornerRadius,
        roundTop: top, roundBottom: bottom, padTop: pad, padBottom: pad)
      return d
    }
    let title = NSMutableAttributedString()
    if let symbol = NSImage(systemSymbolName: template.kind.symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: body.pointSize + 2, weight: .regular))
    {
      let a = NSTextAttachment()
      a.image = symbol.tinted(with: theme.muted)
      a.bounds = CGRect(x: 0, y: -3, width: symbol.size.width, height: symbol.size.height)
      title.append(NSAttributedString(attachment: a))
      title.append(NSAttributedString(string: "  "))
      title.addAttribute(.t3PlainText, value: "", range: NSRange(location: 0, length: title.length))
    }
    title.append(NSAttributedString(string: template.displayName))
    title.addAttributes(
      [.font: NSFont.systemFont(ofSize: body.pointSize, weight: .semibold), .foregroundColor: theme.foreground],
      range: NSRange(location: 0, length: title.length))
    appendParagraph(
      title, style: paragraphStyle(ctx, first: ctx.indent + pad, head: ctx.indent + pad, before: pad, after: 2, tail: -pad),
      decoration: boxOf(true, false))

    let detail = NSMutableAttributedString(
      string: template.kind.presentationLabel + "  \u{00B7}  ",
      attributes: [.font: NSFont.systemFont(ofSize: body.pointSize - 1), .foregroundColor: theme.muted])
    detail.append(
      NSAttributedString(
        string: "Use template",
        attributes: [
          .font: NSFont.systemFont(ofSize: body.pointSize - 1, weight: .medium), .foregroundColor: theme.link,
          .link: MarkdownLinkCoding.url(for: .artifactTemplate(template)), .toolTip: template.usePrompt,
        ]))
    detail.addAttribute(.t3PlainText, value: "", range: NSRange(location: detail.length - 12, length: 12))
    appendParagraph(
      detail, style: paragraphStyle(ctx, first: ctx.indent + pad, head: ctx.indent + pad, after: pad + spacing, tail: -pad),
      decoration: boxOf(false, true))
  }

  // MARK: inlines

  struct InlineStyle {
    var font: NSFont
    var color: NSColor
    var bold = false
    var italic = false
    var strike = false
    var underline = false
    var baselineOffset: CGFloat = 0
    var background: NSColor?
    var link: MarkdownLink?
    var monospaced = false
    var sizeScale: CGFloat = 1
    var textOnly = false
  }

  func inline(_ inlines: [MarkdownInline], _ style: InlineStyle, textOnly: Bool = false) -> NSAttributedString {
    var style = style
    style.textOnly = textOnly
    let result = NSMutableAttributedString()
    for i in inlines { append(i, style, to: result, textOnly: textOnly) }
    return result
  }

  private func resolvedFont(_ s: InlineStyle) -> NSFont {
    var font = s.font
    if s.monospaced { font = NSFont.monospacedSystemFont(ofSize: max((s.font.pointSize * 0.9).rounded(.up), 9), weight: .regular) }
    if s.sizeScale != 1 { font = font.withSize(font.pointSize * s.sizeScale) }
    var traits = font.fontDescriptor.symbolicTraits
    if s.bold { traits.insert(.bold) }
    if s.italic { traits.insert(.italic) }
    if traits != font.fontDescriptor.symbolicTraits {
      let d = font.fontDescriptor.withSymbolicTraits(traits)
      font = NSFont(descriptor: d, size: font.pointSize) ?? font
    }
    return font
  }

  private func attributes(_ s: InlineStyle) -> [NSAttributedString.Key: Any] {
    var a: [NSAttributedString.Key: Any] = [.font: resolvedFont(s), .foregroundColor: s.color]
    let linkKey: NSAttributedString.Key = s.textOnly ? .t3CellLink : .link
    if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if s.baselineOffset != 0 { a[.baselineOffset] = s.baselineOffset }
    if let bg = s.background { a[.backgroundColor] = bg }
    if let link = s.link {
      // Text drawn outside a text view (table cells) must not carry `.link`: AppKit would paint it blue.
      a[linkKey] = MarkdownLinkCoding.url(for: link)
      a[.foregroundColor] = theme.link
      if let tip = MarkdownLinkCoding.tooltip(for: link), !s.textOnly { a[.toolTip] = tip }
      if case .file = link {} else { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    }
    return a
  }

  private func append(_ node: MarkdownInline, _ style: InlineStyle, to out: NSMutableAttributedString, textOnly: Bool) {
    switch node {
    case .text(let s):
      out.append(NSAttributedString(string: s, attributes: attributes(style)))
    case .softBreak:
      out.append(NSAttributedString(string: " ", attributes: attributes(style)))
    case .lineBreak:
      out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
    case .code(let code, let file):
      var s = style
      s.monospaced = true
      s.background = theme.codeBackground
      s.color = theme.codeForeground
      if let file { s.link = .file(file) }
      out.append(NSAttributedString(string: code, attributes: attributes(s)))
    case .emphasis(let c):
      var s = style
      s.italic = true
      for i in c { append(i, s, to: out, textOnly: textOnly) }
    case .strong(let c):
      var s = style
      s.bold = true
      for i in c { append(i, s, to: out, textOnly: textOnly) }
    case .strikethrough(let c):
      var s = style
      s.strike = true
      for i in c { append(i, s, to: out, textOnly: textOnly) }
    case .styled(let kind, let c):
      var s = style
      switch kind {
      case .subscripted:
        s.sizeScale *= 0.75
        s.baselineOffset = -style.font.pointSize * 0.25
      case .superscripted:
        s.sizeScale *= 0.75
        s.baselineOffset = style.font.pointSize * 0.35
      case .highlighted: s.background = theme.highlightBackground
      case .underlined: s.underline = true
      case .keyboard:
        s.monospaced = true
        s.background = theme.codeBackground
      case .small: s.sizeScale *= 0.85
      case .monospace: s.monospaced = true
      case .quoted:
        out.append(NSAttributedString(string: "\u{201C}", attributes: attributes(style)))
        for i in c { append(i, s, to: out, textOnly: textOnly) }
        out.append(NSAttributedString(string: "\u{201D}", attributes: attributes(style)))
        return
      }
      for i in c { append(i, s, to: out, textOnly: textOnly) }
    case .link(let link, let c):
      var s = style
      s.link = link
      for i in c { append(i, s, to: out, textOnly: textOnly) }
    case .image(let image):
      // Inline images are labels; the UI opens them through the typed link.
      var s = style
      s.link = .image(image)
      let label = image.alt.isEmpty ? "image" : image.alt
      out.append(NSAttributedString(string: "\u{25A3} " + label, attributes: attributes(s)))
    case .citation(let c):
      let label = c.text.replacingOccurrences(of: "\n", with: " ")
      chip(label: label, symbol: "quote.opening", link: .citation(c), plain: label, accessibility: "Quote: \(label)", style: style, to: out, textOnly: textOnly)
    case .context(let kind, let id, let label):
      let symbol: String =
        switch kind {
        case "image": "photo"
        case "file": "doc"
        case "terminal": "terminal"
        case "skill": "sparkles"
        case "mention": "at"
        case "review-comment": "text.bubble"
        default: "paperclip"
        }
      // A skill chip is a rendering of the `$name` the user typed: copied as that token, not clickable.
      chip(
        label: label, symbol: symbol, link: kind == "skill" ? nil : .context(kind: kind, id: id),
        plain: kind == "skill" ? "$\(id)" : label, accessibility: "\(kind): \(label)", style: style, to: out,
        textOnly: textOnly)
    }
  }

  private func chip(
    label: String, symbol: String, link: MarkdownLink?, plain: String, accessibility: String, style: InlineStyle,
    to out: NSMutableAttributedString, textOnly: Bool
  ) {
    var attrs = attributes(style)
    if let link {
      attrs[textOnly ? .t3CellLink : .link] = MarkdownLinkCoding.url(for: link)
      if let tip = MarkdownLinkCoding.tooltip(for: link), !textOnly { attrs[.toolTip] = String(tip.prefix(300)) }
    }
    if textOnly {
      attrs[.foregroundColor] = theme.chipForeground
      attrs[.backgroundColor] = theme.chipBackground
      out.append(NSAttributedString(string: " \(label) ", attributes: attrs))
      return
    }
    let content = ChipContent(label: label, symbol: symbol, theme: theme, accessibility: accessibility)
    let m = NSMutableAttributedString(attachment: ContentAttachment(content: content))
    attrs[.t3PlainText] = plain
    m.addAttributes(attrs, range: NSRange(location: 0, length: m.length))
    out.append(m)
  }
}

extension MarkdownAlignment {
  var nsAlignment: NSTextAlignment {
    switch self {
    case .natural: .natural
    case .left: .left
    case .center: .center
    case .right: .right
    }
  }
}

extension NSAttributedString.Key {
  /// Link payload in text that is drawn outside a text view (table cells).
  static let t3CellLink = NSAttributedString.Key("t3md.cellLink")
  /// Width of a list marker column, read back when its paragraph is styled.
  static let t3MarkerWidth = NSAttributedString.Key("t3md.markerWidth")
}
