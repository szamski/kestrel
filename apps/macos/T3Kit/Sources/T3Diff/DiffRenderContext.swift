import AppKit
import T3Markdown

/// Everything the table's row views read to draw: parsed files, rows, highlighting, selection and metrics.
/// One instance per table; row views hold it by reference so a selection or highlight change is a redraw,
/// not a reload.
@MainActor
final class DiffRenderContext {
  var files: [DiffFile] = []
  var rows: [DiffRow] = []
  var layout: DiffLayoutMode = .stacked
  var wordWrap = true
  var selection: DiffSelection?
  /// File id to the line ranges that already carry a comment chip in the draft.
  var markers: [String: [ClosedRange<Int>]] = [:]
  var actions = DiffTableActions()
  weak var table: DiffNSTableView?

  private(set) var highlights: [String: [[DiffSpan]]] = [:]
  private var pendingHighlights: Set<String> = []
  private var wordCache: [Int: [Range<Int>]] = [:]
  private let attributedCache = NSCache<NSNumber, NSAttributedString>()
  private var themes: [Bool: MarkdownTheme] = [:]
  private var themesRevision = -1
  private var anchor: Int?
  private var anchorFile: String?

  private(set) var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private(set) var charWidth: CGFloat = 0
  private(set) var lineHeight: CGFloat = 0
  var viewportWidth: CGFloat = 400
  private(set) var numberWidth: CGFloat = 40
  private var maxColumns = 0

  static let headerHeight: CGFloat = 34
  static let signWidth: CGFloat = 16
  static let textInset: CGFloat = 8

  init() {
    refreshFont()
    attributedCache.countLimit = 4_000
  }

  /// The user's code font (Settings › Appearance) or 12pt system monospace; true when the metrics changed.
  @discardableResult
  func refreshFont() -> Bool {
    let next = ThemeOverrides.shared.codeFont ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    guard next != font || charWidth == 0 else { return false }
    font = next
    charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    lineHeight = ceil(font.boundingRectForFont.height) + 3
    return true
  }

  // MARK: Data

  func setContent(files: [DiffFile], rows: [DiffRow], layout: DiffLayoutMode, wordWrap: Bool) {
    self.files = files
    self.rows = rows
    self.layout = layout
    self.wordWrap = wordWrap
    wordCache.removeAll(keepingCapacity: true)
    attributedCache.removeAllObjects()
    var maxNumber = 0
    maxColumns = 0
    for file in files {
      if let last = file.lines.last(where: { $0.kind != .noNewline }) { maxNumber = max(maxNumber, last.oldNumber, last.newNumber) }
      for line in file.lines { maxColumns = max(maxColumns, line.columns) }
    }
    let digits = max(3, String(maxNumber).count)
    numberWidth = ceil(CGFloat(digits) * charWidth) + 14
    highlights = highlights.filter { key, _ in files.contains { $0.id == key } }
  }

  func theme(for appearance: NSAppearance) -> MarkdownTheme {
    let revision = ThemeOverrides.shared.revision
    if themesRevision != revision {
      themes.removeAll()
      themesRevision = revision
    }
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if let cached = themes[dark] { return cached }
    let theme = MarkdownTheme.default(for: appearance)
    themes[dark] = theme
    return theme
  }

  func clearCaches() {
    attributedCache.removeAllObjects()
  }

  func requestHighlight(file index: Int) {
    guard index < files.count else { return }
    let file = files[index]
    guard highlights[file.id] == nil, pendingHighlights.insert(file.id).inserted else { return }
    Task { [weak self] in
      let spans = await DiffHighlighter.spans(for: file)
      guard let self else { return }
      self.pendingHighlights.remove(file.id)
      self.highlights[file.id] = spans
      self.attributedCache.removeAllObjects()
      self.table?.redrawVisibleRows()
    }
  }

  // MARK: Geometry

  struct Geometry {
    var half: CGFloat
    var stackedTextX: CGFloat
    var stackedTextWidth: CGFloat
    var splitTextX: CGFloat
    var splitTextWidth: CGFloat
    var stackedColumns: Int
    var splitColumns: Int
  }

  var geometry: Geometry {
    let inset = Self.textInset
    let stackedX = 2 * numberWidth + Self.signWidth
    let stackedWidth = max(charWidth * 8, viewportWidth - stackedX - inset)
    let half = floor((viewportWidth - 1) / 2)
    let splitX = numberWidth + Self.signWidth
    let splitWidth = max(charWidth * 8, half - splitX - inset)
    return Geometry(
      half: half, stackedTextX: stackedX, stackedTextWidth: stackedWidth, splitTextX: splitX, splitTextWidth: splitWidth,
      stackedColumns: max(8, Int(stackedWidth / charWidth)), splitColumns: max(8, Int(splitWidth / charWidth)))
  }

  /// The table column's width: the viewport when lines wrap, else wide enough for the longest line.
  var contentWidth: CGFloat {
    guard !wordWrap else { return viewportWidth }
    let text = CGFloat(maxColumns) * charWidth + Self.textInset * 2
    switch layout {
    case .stacked: return max(viewportWidth, 2 * numberWidth + Self.signWidth + text)
    case .split: return max(viewportWidth, 2 * (numberWidth + Self.signWidth + text) + 1)
    }
  }

  func height(ofRow index: Int) -> CGFloat {
    guard index < rows.count else { return lineHeight }
    let row = rows[index]
    let g = geometry
    func wrapped(_ columns: Int, per: Int) -> Int { wordWrap ? max(1, (columns + per - 1) / per) : 1 }
    switch row.kind {
    case .fileHeader: return Self.headerHeight
    case .hunk: return lineHeight + 8
    case .notice: return 30
    case .line(let l):
      return CGFloat(wrapped(files[row.file].lines[l].columns, per: g.stackedColumns)) * lineHeight + 2
    case .pair(let l, let r):
      let lines = files[row.file].lines
      let left = l >= 0 ? wrapped(lines[l].columns, per: g.splitColumns) : 1
      let right = r >= 0 ? wrapped(lines[r].columns, per: g.splitColumns) : 1
      return CGFloat(max(left, right)) * lineHeight + 2
    }
  }

  // MARK: Text

  func wordRanges(file: Int, line: Int) -> [Range<Int>] {
    let lines = files[file].lines
    let l = lines[line]
    guard l.pair >= 0 else { return [] }
    let key = file << 32 | line
    if let cached = wordCache[key] { return cached }
    let other = lines[l.pair]
    let result = l.kind == .deletion ? WordDiff.changedRanges(old: l.text, new: other.text).old : WordDiff.changedRanges(old: other.text, new: l.text).new
    wordCache[key] = result
    return result
  }

  /// The line's text with tabs expanded, syntax colours and word highlights applied.
  func attributed(file: Int, line: Int, theme: MarkdownTheme, isDark: Bool) -> NSAttributedString {
    let key = NSNumber(value: (file << 32 | line) << 1 | (isDark ? 1 : 0))
    if let cached = attributedCache.object(forKey: key) { return cached }
    let source = files[file].lines[line]
    let hasTabs = source.text.utf8.contains(0x09)
    let text = hasTabs ? source.text.replacingOccurrences(of: "\t", with: "    ") : source.text
    var extra: [Int] = []
    if hasTabs {
      var running = 0
      for unit in source.text.utf16 { extra.append(running); if unit == 0x09 { running += 3 } }
      extra.append(running)
    }
    func mapped(_ offset: Int) -> Int { hasTabs ? offset + extra[min(offset, extra.count - 1)] : offset }

    let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: source.kind == .noNewline ? theme.muted : theme.foreground])
    let length = result.length
    if source.kind != .noNewline {
      if let spans = highlights[files[file].id], line < spans.count {
        for span in spans[line] {
          let start = mapped(span.location), end = min(length, mapped(span.location + span.length))
          if end > start { result.addAttribute(.foregroundColor, value: theme.color(for: span.role), range: NSRange(location: start, length: end - start)) }
        }
      }
      let word = (source.kind == .addition ? DiffColors.addition : DiffColors.deletion).withAlphaComponent(0.34)
      for range in wordRanges(file: file, line: line) {
        let start = mapped(range.lowerBound), end = min(length, mapped(range.upperBound))
        if end > start { result.addAttribute(.backgroundColor, value: word, range: NSRange(location: start, length: end - start)) }
      }
    }
    attributedCache.setObject(result, forKey: key)
    return result
  }

  /// UTF-16 chunk ranges of a wrapped line, never splitting a surrogate pair.
  func chunks(of attributed: NSAttributedString, columns: Int) -> [NSRange] {
    let length = attributed.length
    guard wordWrap, length > columns else { return [NSRange(location: 0, length: length)] }
    let string = attributed.string as NSString
    var out: [NSRange] = []
    var start = 0
    while start < length {
      var end = min(length, start + columns)
      if end < length, UTF16.isTrailSurrogate(string.character(at: end)) { end -= 1 }
      if end <= start { end = min(length, start + columns) }
      out.append(NSRange(location: start, length: end - start))
      start = end
    }
    return out
  }

  // MARK: Selection

  func lineIndex(row index: Int, x: CGFloat) -> Int? {
    guard index >= 0, index < rows.count else { return nil }
    let row = rows[index]
    let lines = files[row.file].lines
    switch row.kind {
    case .line(let l): return lines[l].kind == .noNewline ? nil : l
    case .pair(let l, let r):
      let preferred = x < geometry.half ? l : r
      let pick = preferred >= 0 ? preferred : (x < geometry.half ? r : l)
      return pick >= 0 && lines[pick].kind != .noNewline ? pick : nil
    default: return nil
    }
  }

  func beginSelection(row: Int, x: CGFloat, extend: Bool) {
    guard let line = lineIndex(row: row, x: x) else { return }
    let file = files[rows[row].file]
    if extend, let anchor, anchorFile == file.id {
      setSelection(DiffSelection(fileId: file.id, lo: min(anchor, line), hi: max(anchor, line)))
    } else {
      anchor = line
      anchorFile = file.id
      setSelection(DiffSelection(fileId: file.id, lo: line, hi: line))
    }
  }

  func extendSelection(row: Int, x: CGFloat) {
    guard let anchor, let line = lineIndex(row: row, x: x), files[rows[row].file].id == anchorFile else { return }
    let next = DiffSelection(fileId: anchorFile!, lo: min(anchor, line), hi: max(anchor, line))
    if next != selection { setSelection(next) }
  }

  func clearSelection() {
    anchor = nil
    anchorFile = nil
    if selection != nil { setSelection(nil) }
  }

  private func setSelection(_ next: DiffSelection?) {
    selection = next
    table?.redrawVisibleRows()
    actions.select(next)
  }

  func selectedText() -> String? {
    guard let selection, let file = files.first(where: { $0.id == selection.fileId }), selection.hi < file.lines.count else { return nil }
    return file.lines[selection.lo...selection.hi].filter { $0.kind != .noNewline }.map(\.text).joined(separator: "\n")
  }

  func isMarked(file id: String, line: Int) -> Bool { markers[id]?.contains { $0.contains(line) } ?? false }
}
