import Foundation
import Markdown

public struct MarkdownOptions: Hashable, Sendable {
  /// `remark-breaks` equivalent: a single newline inside a paragraph is a hard line break
  /// (chat-style user input).
  public var softBreaksAsNewlines: Bool
  /// Render the sanitizer's allowed HTML subset natively. When false, every HTML tag is
  /// shown as literal text (web `parseRawHtml: false`).
  public var parsesHTML: Bool
  /// Anchors relative file links and images, and enables path detection in inline code.
  public var baseDirectory: String?
  /// Skills that `$name` tokens in paragraphs and list items turn into chips for (web user
  /// messages pass the provider's skills; assistant text passes none).
  public var skills: [MarkdownSkill]
  /// `https://github.com/owner/repo`: turns `#123` and 40-character commit SHAs in prose into
  /// links, as web pull-request bodies do. nil (chat messages) leaves them as text.
  public var pullRequestRepositoryURL: String?

  public init(
    softBreaksAsNewlines: Bool = false, parsesHTML: Bool = true, baseDirectory: String? = nil,
    skills: [MarkdownSkill] = [], pullRequestRepositoryURL: String? = nil
  ) {
    self.softBreaksAsNewlines = softBreaksAsNewlines
    self.parsesHTML = parsesHTML
    self.baseDirectory = baseDirectory
    self.skills = skills
    self.pullRequestRepositoryURL = pullRequestRepositoryURL
  }
}

/// A provider skill a message may mention as `$name` (web `Pick<ServerProviderSkill, "name" | "displayName">`).
public struct MarkdownSkill: Hashable, Sendable {
  public var name: String
  public var displayName: String?

  public init(name: String, displayName: String? = nil) {
    self.name = name
    self.displayName = displayName
  }

  /// Chip label: the display name, else the name in title case (`formatProviderSkillDisplayName`).
  public var label: String {
    if let shown = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !shown.isEmpty { return shown }
    return name.split(whereSeparator: { " :_-".contains($0) || $0.isWhitespace })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }
}

public enum MarkdownParser {
  /// Parses a complete message into render blocks.
  public static func parse(
    _ source: String, options: MarkdownOptions = MarkdownOptions(), endsInOpenFence: Bool = false
  ) -> [MarkdownBlock] {
    let pre = MarkdownDirectivePreprocessor.process(source)
    let converter = MarkdownConverter(source: pre.source, options: options, templates: pre.templates)
    var blocks = converter.convertDocument()
    if endsInOpenFence { markLastCodeOpen(&blocks) }
    return blocks
  }

  /// The block a still-open fence belongs to is the last code block, however deeply nested
  /// (list item, quote): it is still being written, so it is not highlighted yet.
  private static func markLastCodeOpen(_ blocks: inout [MarkdownBlock]) {
    guard let last = blocks.indices.last else { return }
    switch blocks[last] {
    case .code(var code):
      code.isOpen = true
      blocks[last] = .code(code)
    case .quote(var inner):
      markLastCodeOpen(&inner)
      blocks[last] = .quote(inner)
    case .alert(let kind, var inner):
      markLastCodeOpen(&inner)
      blocks[last] = .alert(kind, inner)
    case .details(let summary, let open, var inner):
      markLastCodeOpen(&inner)
      blocks[last] = .details(summary: summary, isOpen: open, blocks: inner)
    case .list(var list):
      guard let item = list.items.indices.last else { return }
      markLastCodeOpen(&list.items[item].blocks)
      blocks[last] = .list(list)
    default: break
    }
  }
}

private let alertMarker = Rx(#"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]$"#, .caseInsensitive)
private let inlineParsePrefix = "t3-markdown-inline-prefix:"
private let urlLiteral = Rx(#"(?:https?://|www\.)[^\s<]+"#, .caseInsensitive)
private let emailLiteral = Rx(#"[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
/// Web `SKILL_TOKEN_REGEX` (SkillInlineText.tsx): a currency sign plus a name, standing alone
/// between whitespace; amounts such as `$5` or `$1k` are not skills.
private let skillToken = Rx(
  #"(^|\s)\p{Sc}(?![0-9][0-9_]*(?:[kKmMbBtT]|[eE][0-9]+)?(?:\s|$))(?=[a-zA-Z0-9:_-]*[a-zA-Z])([a-zA-Z0-9][a-zA-Z0-9:_-]*)(?=\s|$)"#)
/// Web `AUTOLINK_CANDIDATE_PATTERN` (pullRequestMarkdown.logic.ts).
private let referenceCandidate = Rx(#"#[1-9][0-9]*|[0-9a-f]{40}"#, .caseInsensitive)

struct MarkdownConverter {
  let lines: [Substring]
  let options: MarkdownOptions
  let templates: [MarkdownArtifactTemplate]
  private let html: HTMLInlineBuilder

  init(source: String, options: MarkdownOptions, templates: [MarkdownArtifactTemplate]) {
    self.lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    self.options = options
    self.templates = templates
    self.html = HTMLInlineBuilder(baseDirectory: options.baseDirectory)
    self.source = source
  }
  private let source: String

  func convertDocument() -> [MarkdownBlock] {
    let doc = Document(parsing: source, options: [.disableSmartOpts])
    return blocks(of: doc)
  }

  // MARK: blocks

  private func blocks(of parent: Markup) -> [MarkdownBlock] {
    var out: [Piece] = []
    for child in parent.children { out.append(contentsOf: pieces(of: child, parent: parent)) }
    return fold(out)
  }

  /// A converted block, or one end of a `<details>` that may be separated from the other by
  /// ordinary Markdown blocks (`<details>…</summary>` blank line, body, blank line `</details>`).
  private enum Piece {
    case block(MarkdownBlock)
    case open(isOpen: Bool)
    case summary([MarkdownInline])
    case close
  }

  private func pieces(of child: Markup, parent: Markup) -> [Piece] {
    if let h = child as? HTMLBlock, options.parsesHTML { return htmlPieces(h.rawHTML) }
    return convert(block: child, parent: parent).map(Piece.block)
  }

  /// Nests the blocks between a `<details>` and its `</details>` (an unclosed one runs to the
  /// end, like an HTML parser closing it). The first summary names the section, else "Details".
  private func fold(_ pieces: [Piece]) -> [MarkdownBlock] {
    struct Frame {
      var isOpen: Bool
      var summary: [MarkdownInline]?
      var blocks: [MarkdownBlock] = []
    }
    var stack = [Frame(isOpen: false)]
    func closeTop() {
      let frame = stack.removeLast()
      stack[stack.count - 1].blocks.append(
        .details(summary: frame.summary ?? [.text("Details")], isOpen: frame.isOpen, blocks: frame.blocks))
    }
    for piece in pieces {
      let top = stack.count - 1
      switch piece {
      case .block(let block): stack[top].blocks.append(block)
      case .open(let isOpen): stack.append(Frame(isOpen: isOpen))
      case .summary(let inlines):
        if top > 0, stack[top].summary == nil, stack[top].blocks.isEmpty {
          stack[top].summary = inlines
        } else {
          stack[top].blocks.append(.paragraph([.strong(inlines)]))
        }
      case .close: if top > 0 { closeTop() }
      }
    }
    while stack.count > 1 { closeTop() }
    return stack[0].blocks
  }

  private func convert(block: Markup, parent: Markup) -> [MarkdownBlock] {
    switch block {
    case let p as Paragraph:
      return [paragraph(p)]
    case let h as Heading:
      return [.heading(level: h.level, inlines(of: h))]
    case let c as CodeBlock:
      return [codeBlock(c)]
    case let q as BlockQuote:
      return [quote(q)]
    case let l as UnorderedList:
      return [list(l, ordered: false, start: 1)]
    case let l as OrderedList:
      return [list(l, ordered: true, start: Int(l.startIndex))]
    case let t as Markdown.Table:
      return [table(t)]
    case is ThematicBreak:
      return [.thematicBreak]
    case let h as HTMLBlock:
      guard options.parsesHTML else { return [.paragraph([.text(h.rawHTML.trimmingCharacters(in: .newlines))])] }
      return fold(htmlPieces(h.rawHTML))
    default:
      let text = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? [] : [.paragraph([.text(text)])]
    }
  }

  private func paragraph(_ p: Paragraph) -> MarkdownBlock {
    // Artifact-template sentinel (see MarkdownDirectivePreprocessor).
    if p.childCount == 1, let t = p.child(at: 0) as? Markdown.Text, t.string.hasPrefix(MarkdownDirectivePreprocessor.sentinelOpen),
      t.string.hasSuffix(MarkdownDirectivePreprocessor.sentinelClose)
    {
      let n = t.string.dropFirst(MarkdownDirectivePreprocessor.sentinelOpen.count)
        .dropLast(MarkdownDirectivePreprocessor.sentinelClose.count)
      if let index = Int(n), templates.indices.contains(index) { return .artifactTemplate(templates[index]) }
    }
    let content = skillChips(inlines(of: p))
    if content.count == 1, case .image(let image) = content[0] { return .image(image) }
    return .paragraph(content)
  }

  private func codeBlock(_ c: CodeBlock) -> MarkdownBlock {
    let info = (c.language ?? "").trimmingCharacters(in: .whitespaces)
    let words = info.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
    var code = c.code
    if code.hasSuffix("\n") { code.removeLast() }
    return .code(
      MarkdownCodeBlock(
        language: words.first.map { String($0).lowercased() },
        meta: words.count > 1 ? String(words[1]).trimmingCharacters(in: .whitespaces) : nil,
        code: code, isOpen: false))
  }

  private func quote(_ q: BlockQuote) -> MarkdownBlock {
    var children = blocks(of: q)
    if let kind = takeAlertMarker(from: q, children: &children) { return .alert(kind, children) }
    return .quote(children)
  }

  /// GitHub alert: the quote's first paragraph begins with a marker line `[!NOTE]` and
  /// nothing else on that line (`> [!NOTE] aside` is an ordinary quote).
  private func takeAlertMarker(from q: BlockQuote, children: inout [MarkdownBlock]) -> MarkdownAlertKind? {
    guard q.child(at: 0) is Paragraph, case .paragraph(var inlines, let align)? = children.first else { return nil }
    // The converter may have merged/autolinked text; read the first line from the model.
    var line = ""
    var index = 0
    while index < inlines.count, case .text(let s) = inlines[index] {
      line += s
      index += 1
    }
    // The marker must end its line: the next inline is a break (or there is none).
    if index < inlines.count {
      switch inlines[index] {
      case .softBreak, .lineBreak: break
      default: return nil
      }
    }
    guard let m = alertMarker.firstMatch(in: line), let name = m[1],
      let kind = MarkdownAlertKind(rawValue: name.lowercased())
    else { return nil }
    inlines.removeFirst(index)
    if let f = inlines.first {
      switch f {
      case .softBreak, .lineBreak: inlines.removeFirst()
      default: break
      }
    }
    if inlines.isEmpty { children.removeFirst() } else { children[0] = .paragraph(inlines, alignment: align) }
    return kind
  }

  private func list(_ list: Markup, ordered: Bool, start: Int) -> MarkdownBlock {
    var items: [MarkdownListItem] = []
    var loose = false
    var previousEnd: Int?
    for case let item as ListItem in list.children {
      // CommonMark: loose when items, or blocks inside one item, are separated by a blank line.
      if let prev = previousEnd, let begin = item.range?.lowerBound.line, begin - prev > 1 { loose = true }
      var lastLine = item.range?.lowerBound.line
      var content: [Piece] = []
      for child in item.children {
        if let begin = child.range?.lowerBound.line, let last = lastLine, child.indexInParent > 0, begin - last > 1 {
          loose = true
        }
        lastLine = child.range?.upperBound.line ?? lastLine
        if let code = child as? CodeBlock, let recovered = recoverOverIndentedCode(code, in: item) {
          content.append(contentsOf: recovered.map(Piece.block))
        } else {
          content.append(contentsOf: pieces(of: child, parent: item))
        }
      }
      previousEnd = lastLine
      items.append(MarkdownListItem(checked: item.checkbox.map { $0 == .checked }, blocks: fold(content)))
    }
    return .list(MarkdownList(isOrdered: ordered, start: start, isTight: !loose, items: items))
  }

  /// CommonMark treats four or more spaces after a list marker as an indented code block.
  /// In chat output that is usually accidental alignment (`-       text`), which would
  /// otherwise render a code card per bullet. Only code that keeps excess indentation and
  /// starts on the marker's own line is re-read as text; fences and conventional
  /// indented blocks remain code. Port of markdown-list-indentation.ts.
  private func recoverOverIndentedCode(_ code: CodeBlock, in item: ListItem) -> [MarkdownBlock]? {
    guard let first = code.code.first, first == " " || first == "\t",
      let codeStart = code.range?.lowerBound, let itemStart = item.range?.lowerBound,
      codeStart.line == itemStart.line, codeStart.line - 1 < lines.count
    else { return nil }
    let bytes = Array(lines[codeStart.line - 1].utf8)
    if codeStart.column - 1 < bytes.count {
      let ch = bytes[codeStart.column - 1]
      if ch == UInt8(ascii: "`") || ch == UInt8(ascii: "~") { return nil }
    }
    let value = code.code.trimmingCharacters(in: .whitespacesAndNewlines)
    // A text prefix forces block-looking input into a paragraph while keeping inline syntax.
    let doc = Document(parsing: inlineParsePrefix + value, options: [.disableSmartOpts])
    let sub = MarkdownConverter(source: inlineParsePrefix + value, options: options, templates: templates)
    var blocks = sub.blocks(of: doc)
    if case .paragraph(var inl, let align)? = blocks.first, case .text(let t)? = inl.first, t.hasPrefix(inlineParsePrefix) {
      let rest = String(t.dropFirst(inlineParsePrefix.count))
      if rest.isEmpty { inl.removeFirst() } else { inl[0] = .text(rest) }
      blocks[0] = .paragraph(inl, alignment: align)
    }
    return blocks
  }

  private func table(_ t: Markdown.Table) -> MarkdownBlock {
    func cells(_ row: Markup) -> [MarkdownTableCell] {
      row.children.compactMap { child in
        guard let cell = child as? Markdown.Table.Cell, cell.colspan != 0 else { return nil }
        return MarkdownTableCell(inlines: inlines(of: cell), colspan: Int(cell.colspan))
      }
    }
    let alignments: [MarkdownAlignment] = t.columnAlignments.map {
      switch $0 {
      case .left?: .left
      case .center?: .center
      case .right?: .right
      case nil: .natural
      }
    }
    return .table(
      MarkdownTable(alignments: alignments, header: cells(t.head), rows: t.body.rows.map { cells($0) }))
  }

  // MARK: inlines

  private func inlines(of parent: Markup) -> [MarkdownInline] {
    var items: [InlineItem] = []
    collect(parent.children, into: &items, insideLink: false)
    return foldHTML(items)
  }

  /// An inline or a not-yet-paired HTML tag.
  enum InlineItem {
    case inline(MarkdownInline)
    case open(name: String, attributes: [String: String], raw: String)
    case close(name: String, raw: String)
  }

  private func collect(_ children: some Sequence<Markup>, into items: inout [InlineItem], insideLink: Bool) {
    for child in children {
      switch child {
      case let t as Markdown.Text:
        items.append(contentsOf: textItems(t.string, insideLink: insideLink))
      case is SoftBreak:
        items.append(.inline(options.softBreaksAsNewlines ? .lineBreak : .softBreak))
      case is LineBreak:
        items.append(.inline(.lineBreak))
      case let c as InlineCode:
        let file = options.baseDirectory == nil && !c.code.hasPrefix("/") && !MarkdownPaths.isWindowsAbsolute(c.code)
          ? nil : MarkdownLink.inlineCodeFile(c.code, baseDirectory: options.baseDirectory)
        items.append(.inline(.code(c.code, file: insideLink ? nil : file)))
      case let e as Emphasis:
        items.append(.inline(.emphasis(sub(e, insideLink: insideLink))))
      case let s as Strong:
        items.append(.inline(.strong(sub(s, insideLink: insideLink))))
      case let s as Strikethrough:
        items.append(.inline(.strikethrough(sub(s, insideLink: insideLink))))
      case let l as Markdown.Link:
        items.append(contentsOf: link(l, insideLink: insideLink))
      case let i as Markdown.Image:
        items.append(.inline(image(i)))
      case let h as InlineHTML:
        if options.parsesHTML {
          items.append(contentsOf: htmlItems(h.rawHTML))
        } else {
          items.append(.inline(.text(h.rawHTML)))
        }
      default:
        let text = child.format()
        if !text.isEmpty { items.append(.inline(.text(text))) }
      }
    }
  }

  private func sub(_ parent: Markup, insideLink: Bool) -> [MarkdownInline] {
    var items: [InlineItem] = []
    collect(parent.children, into: &items, insideLink: insideLink)
    return foldHTML(items)
  }

  private func link(_ l: Markdown.Link, insideLink: Bool) -> [InlineItem] {
    let label = sub(l, insideLink: true)
    guard let destination = l.destination, !insideLink,
      let resolved = MarkdownLink.resolve(destination: destination, baseDirectory: options.baseDirectory)
    else { return label.map { .inline($0) } }
    switch resolved {
    case .citation(let c):
      return [.inline(.citation(c))]
    case .context(let kind, let id):
      let text = MarkdownInline.plainText(label).trimmingCharacters(in: .whitespacesAndNewlines)
      return [.inline(.context(kind: kind, id: id, label: text.isEmpty ? id : text))]
    default:
      return [.inline(.link(resolved, label))]
    }
  }

  private func image(_ i: Markdown.Image) -> MarkdownInline {
    let alt = i.plainText
    if let dest = i.source, let ctx = MarkdownLink.resolve(destination: dest), case .context(let kind, let id) = ctx {
      return .context(kind: kind, id: id, label: alt.isEmpty ? id : alt)
    }
    let dest = i.source ?? ""
    return .image(
      MarkdownImage(
        source: MarkdownImageSource.classify(dest, workspaceRoot: options.baseDirectory), destination: dest, alt: alt,
        title: i.title))
  }

  /// Text node → text plus GFM autolink literals (`https://…`, `www.…`, emails), then, for
  /// pull-request prose, `#123` and commit references in the text between them.
  private func textItems(_ s: String, insideLink: Bool) -> [InlineItem] {
    let items = autolinkLiterals(s, insideLink: insideLink)
    guard !insideLink, let repository = options.pullRequestRepositoryURL else { return items }
    return items.flatMap { item -> [InlineItem] in
      guard case .inline(.text(let text)) = item else { return [item] }
      return references(in: text, repository: repository).map { .inline($0) }
    }
  }

  /// Web `remarkPullRequestAutolinks`: same-repository `#123` → `…/issues/123` and a 40-digit
  /// SHA → `…/commit/<sha>` shown as its first seven characters. Not inside words, code or links.
  private func references(in s: String, repository: String) -> [MarkdownInline] {
    guard s.contains("#") || s.count >= 40 else { return [.text(s)] }
    let base = repository.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    let ns = s as NSString
    func isWord(_ unit: unichar) -> Bool {
      (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }
    var out: [MarkdownInline] = []
    var cursor = 0
    for m in referenceCandidate.re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
      let matched = ns.substring(with: m.range)
      let isReference = matched.hasPrefix("#")
      if m.range.location > 0 {
        let before = ns.character(at: m.range.location - 1)
        if isReference {
          if isWord(before) { continue }
        } else if !(Unicode.Scalar(before).map { CharacterSet.whitespacesAndNewlines.contains($0) || "([{".unicodeScalars.contains($0) } ?? false) {
          continue
        }
      }
      let end = m.range.location + m.range.length
      if end < ns.length, isWord(ns.character(at: end)) { continue }
      let target = isReference ? "\(base)/issues/\(matched.dropFirst())" : "\(base)/commit/\(matched)"
      guard let url = URL(string: target), url.scheme == "https" || url.scheme == "http" else { continue }
      if m.range.location > cursor {
        out.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
      }
      let label: MarkdownInline = isReference ? .text(matched) : .styled(.monospace, [.text(String(matched.prefix(7)))])
      out.append(.link(.web(url), [label]))
      cursor = end
    }
    if out.isEmpty { return [.text(s)] }
    if cursor < ns.length { out.append(.text(ns.substring(from: cursor))) }
    return out
  }

  /// Web `renderSkillInlineMarkdownChildren`: `$name` for a known skill becomes a chip, in
  /// plain and emphasised text but not in code or links.
  private func skillChips(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
    guard !options.skills.isEmpty else { return inlines }
    var out: [MarkdownInline] = []
    for inline in inlines {
      switch inline {
      case .text(let s): out.append(contentsOf: skillChips(in: s))
      case .emphasis(let c): out.append(.emphasis(skillChips(c)))
      case .strong(let c): out.append(.strong(skillChips(c)))
      case .strikethrough(let c): out.append(.strikethrough(skillChips(c)))
      case .styled(let kind, let c): out.append(.styled(kind, skillChips(c)))
      default: out.append(inline)
      }
    }
    return out
  }

  private func skillChips(in s: String) -> [MarkdownInline] {
    guard s.contains(where: \.isCurrencySymbol) else { return [.text(s)] }
    let ns = s as NSString
    var out: [MarkdownInline] = []
    var cursor = 0
    for m in skillToken.re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
      let name = ns.substring(with: m.range(at: 2))
      guard let skill = options.skills.first(where: { $0.name == name }) else { continue }
      let start = m.range.location + m.range(at: 1).length
      if start > cursor { out.append(.text(ns.substring(with: NSRange(location: cursor, length: start - cursor)))) }
      out.append(.context(kind: "skill", id: name, label: skill.label))
      cursor = m.range.location + m.range.length
    }
    if out.isEmpty { return [.text(s)] }
    if cursor < ns.length { out.append(.text(ns.substring(from: cursor))) }
    return out
  }

  private func autolinkLiterals(_ s: String, insideLink: Bool) -> [InlineItem] {
    guard !insideLink, s.contains("://") || s.contains("www.") || s.contains("@") else { return [.inline(.text(s))] }
    var out: [InlineItem] = []
    var cursor = s.startIndex
    var matches: [(Range<String.Index>, URL, String)] = []
    for m in urlLiteral.re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
      guard var range = Range(m.range, in: s) else { continue }
      // GFM extended autolink: boundary before, then trim trailing punctuation.
      if range.lowerBound > s.startIndex {
        let prev = s[s.index(before: range.lowerBound)]
        if !(prev.isWhitespace || "*_~(".contains(prev)) { continue }
      }
      var text = String(s[range])
      text = trimAutolinkTail(text)
      guard text.count > 4 else { continue }
      range = range.lowerBound..<s.index(range.lowerBound, offsetBy: text.count)
      let lower = text.lowercased()
      let href = lower.hasPrefix("www.") ? "http://" + text : text
      guard validDomainStart(lower.hasPrefix("www.") ? lower : String(lower.drop(while: { $0 != "/" }).dropFirst(2))),
        let url = URL(string: href)
      else { continue }
      matches.append((range, url, text))
    }
    for m in emailLiteral.re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
      guard let range = Range(m.range, in: s) else { continue }
      let text = String(s[range])
      if text.hasSuffix("-") || text.hasSuffix("_") { continue }
      if matches.contains(where: { $0.0.overlaps(range) }) { continue }
      if let url = URL(string: "mailto:" + text) { matches.append((range, url, text)) }
    }
    matches.sort { $0.0.lowerBound < $1.0.lowerBound }
    for (range, url, text) in matches {
      if range.lowerBound > cursor { out.append(.inline(.text(String(s[cursor..<range.lowerBound])))) }
      out.append(.inline(.link(.web(url), [.text(text)])))
      cursor = range.upperBound
    }
    if cursor < s.endIndex { out.append(.inline(.text(String(s[cursor...])))) }
    return out
  }

  private func validDomainStart(_ rest: String) -> Bool {
    guard let f = rest.unicodeScalars.first else { return false }
    return CharacterSet.alphanumerics.contains(f)
  }

  /// GFM: trailing `?!.,:*_~'"` are not part of the link; a `)` is only when balanced.
  private func trimAutolinkTail(_ input: String) -> String {
    var t = input
    while let last = t.last {
      if "?!.,:*_~'\"".contains(last) {
        t.removeLast()
      } else if last == ")" {
        let open = t.filter { $0 == "(" }.count
        let close = t.filter { $0 == ")" }.count
        if close > open { t.removeLast() } else { break }
      } else if last == ";", let amp = t.lastIndex(of: "&"), t[amp...].dropFirst().dropLast().allSatisfy({ $0.isLetter || $0.isNumber }) {
        t = String(t[..<amp])
      } else {
        break
      }
    }
    return t
  }

  // MARK: HTML

  private func htmlItems(_ raw: String) -> [InlineItem] {
    var out: [InlineItem] = []
    for token in HTMLTokenizer.tokenize(raw) {
      switch token {
      case .text(let s): out.append(.inline(.text(s)))
      case .comment: break
      case .open(let name, let attrs, let selfClosing, let rawTag):
        guard HTMLInlineBuilder.isAllowed(name) else {
          out.append(.inline(.text(rawTag)))
          continue
        }
        switch name {
        case "br": out.append(.inline(.lineBreak))
        case "img":
          if let img = html.image(attrs) { out.append(.inline(.image(img))) } else { out.append(.inline(.text(rawTag))) }
        case "hr", "input", "wbr": if name == "wbr" { break } else { out.append(.inline(.text(rawTag))) }
        default:
          if selfClosing { break }
          out.append(.open(name: name, attributes: attrs, raw: rawTag))
        }
      case .close(let name, let rawTag):
        if HTMLInlineBuilder.isAllowed(name), name != "br", name != "img" {
          out.append(.close(name: name, raw: rawTag))
        } else {
          out.append(.inline(.text(rawTag)))
        }
      }
    }
    return out
  }

  /// Pairs open/close HTML items into styled inlines; unpaired tags fall back to their
  /// literal source so nothing is silently dropped.
  private func foldHTML(_ items: [InlineItem]) -> [MarkdownInline] {
    var hasHTML = false
    for item in items {
      switch item {
      case .inline: continue
      default: hasHTML = true
      }
      break
    }
    if !hasHTML { return mergeText(items.compactMap { if case .inline(let i) = $0 { i } else { nil } }) }

    struct Frame {
      var name: String
      var attributes: [String: String]
      var raw: String
      var children: [MarkdownInline] = []
    }
    var stack: [Frame] = [Frame(name: "", attributes: [:], raw: "")]
    func append(_ i: MarkdownInline) { stack[stack.count - 1].children.append(i) }
    func unwind(to depth: Int) {  // unmatched opens become literal text + their children
      while stack.count > depth {
        let f = stack.removeLast()
        append(.text(f.raw))
        stack[stack.count - 1].children.append(contentsOf: f.children)
      }
    }
    for item in items {
      switch item {
      case .inline(let i): append(i)
      case .open(let name, let attrs, let raw):
        stack.append(Frame(name: name, attributes: attrs, raw: raw))
      case .close(let name, let raw):
        guard let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 else {
          append(.text(raw))
          continue
        }
        unwind(to: idx + 1)
        let frame = stack.removeLast()
        stack[stack.count - 1].children.append(contentsOf: wrap(frame.name, frame.attributes, frame.children))
      }
    }
    unwind(to: 1)
    return mergeText(stack[0].children)
  }

  private func wrap(_ name: String, _ attrs: [String: String], _ children: [MarkdownInline]) -> [MarkdownInline] {
    if let style = html.style(for: name) { return [style(children)] }
    if name == "a" {
      if let link = html.link(attrs) { return [.link(link, children)] }
      return children
    }
    // Structural tags inside a paragraph keep their text and separate it from neighbours.
    if HTMLInlineBuilder.blockTags.contains(name) { return children + [.lineBreak] }
    return children
  }

  private func mergeText(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
    var out: [MarkdownInline] = []
    for i in inlines {
      if case .text(let s) = i, case .text(let prev)? = out.last {
        out[out.count - 1] = .text(prev + s)
      } else {
        out.append(i)
      }
    }
    return out
  }

  // MARK: HTML blocks

  /// A raw HTML block, converted with the same allow-list. Structure tags (`p`, `div`, `h1`,
  /// `li`, `summary`, …) break paragraphs; `align` is honoured; everything else is inline.
  private func htmlPieces(_ raw: String) -> [Piece] {
    enum Mode { case paragraph, heading(Int), summary, listItem }
    var blocks: [Piece] = []
    var items: [InlineItem] = []
    var alignment = MarkdownAlignment.natural
    var mode = Mode.paragraph

    func flush() {
      var inl = foldHTML(items)
      items = []
      // Collapse HTML whitespace and trim the edges.
      inl = collapse(inl)
      guard !inl.isEmpty else { alignment = .natural; mode = .paragraph; return }
      switch mode {
      case .heading(let level): blocks.append(.block(.heading(level: level, inl)))
      case .summary: blocks.append(.summary(inl))
      case .listItem: blocks.append(.block(.paragraph([.text("•  ")] + inl, alignment: alignment)))
      case .paragraph:
        if inl.count == 1, case .image(let img) = inl[0] {
          blocks.append(.block(.image(img)))
        } else {
          blocks.append(.block(.paragraph(inl, alignment: alignment)))
        }
      }
      alignment = .natural
      mode = .paragraph
    }

    for token in HTMLTokenizer.tokenize(raw) {
      switch token {
      case .comment: continue
      case .text(let s):
        items.append(.inline(.text(HTMLEntities.decode(s))))
      case .open(let name, let attrs, let selfClosing, let rawTag):
        guard HTMLInlineBuilder.isAllowed(name) else {
          items.append(.inline(.text(rawTag)))
          continue
        }
        switch name {
        case "br": items.append(.inline(.lineBreak))
        case "hr":
          flush()
          blocks.append(.block(.thematicBreak))
        case "img":
          if let img = html.image(attrs) { items.append(.inline(.image(img))) } else { items.append(.inline(.text(rawTag))) }
        case "wbr", "input": break
        case "details":
          flush()
          blocks.append(.open(isOpen: attrs["open"] != nil))
        case "p", "div", "blockquote", "figure", "figcaption", "caption", "pre", "ul", "ol", "dl", "dd",
          "dt", "table", "thead", "tbody", "tfoot", "tr":
          flush()
          alignment = HTMLInlineBuilder.alignment(attrs)
        case "h1", "h2", "h3", "h4", "h5", "h6":
          flush()
          mode = .heading(Int(name.dropFirst()) ?? 1)
        case "summary":
          flush()
          mode = .summary
        case "li":
          flush()
          mode = .listItem
        case "td", "th":
          if !items.isEmpty { items.append(.inline(.text("  │  "))) }
        default:
          if !selfClosing { items.append(.open(name: name, attributes: attrs, raw: rawTag)) }
        }
      case .close(let name, let rawTag):
        switch name {
        case "details":
          flush()
          blocks.append(.close)
        case "p", "div", "blockquote", "figure", "figcaption", "caption", "pre", "ul", "ol", "dl", "dd",
          "dt", "table", "thead", "tbody", "tfoot", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "summary", "li":
          flush()
        case "td", "th", "br", "img": break
        default:
          if HTMLInlineBuilder.isAllowed(name) { items.append(.close(name: name, raw: rawTag)) } else { items.append(.inline(.text(rawTag))) }
        }
      }
    }
    flush()
    return blocks
  }

  /// HTML text rules: runs of whitespace (including newlines) collapse to one space and
  /// leading/trailing whitespace of a block is dropped.
  private func collapse(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
    var out: [MarkdownInline] = []
    var lastWasSpace = true
    for i in inlines {
      switch i {
      case .text(let s):
        var buf = ""
        for ch in s {
          if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
            if !lastWasSpace { buf.append(" ") }
            lastWasSpace = true
          } else {
            buf.append(ch)
            lastWasSpace = false
          }
        }
        if !buf.isEmpty { out.append(.text(buf)) }
      case .lineBreak:
        lastWasSpace = true
        out.append(i)
      default:
        lastWasSpace = false
        out.append(i)
      }
    }
    while case .text(let s)? = out.last, s.hasSuffix(" ") {
      let t = String(s.dropLast())
      if t.isEmpty { out.removeLast() } else { out[out.count - 1] = .text(t) }
    }
    while case .lineBreak? = out.last { out.removeLast() }
    return mergeText(out)
  }
}
