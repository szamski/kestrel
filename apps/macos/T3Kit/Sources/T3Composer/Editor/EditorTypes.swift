import AppKit
import SwiftUI
import Foundation

extension NSAttributedString.Key {
  /// Bit set of `RichTextMark`s on a run (the Markdown truth; fonts and underlines are just paint).
  static let t3Marks = NSAttributedString.Key("t3.composer.marks")
  /// What a whole paragraph is when it is not plain prose: a list item, heading, quote line, code line
  /// or rule, with the source spacing its Markdown is written with.
  static let t3Block = NSAttributedString.Key("t3.composer.block")
}

/// The block attributes of one paragraph (never a plain paragraph: those carry none).
final class BlockAttrs: NSObject {
  let kind: RichLine.Kind

  init(_ kind: RichLine.Kind) { self.kind = kind }

  /// An unchecked-by-default task item, as the `- [ ] ` typing rule makes one.
  static func task(checked: Bool, indent: String = "", markerSpace: String = " ", contentSpace: String = "") -> BlockAttrs {
    BlockAttrs(.list(.task(checked: checked, indent: indent, markerSpace: markerSpace, contentSpace: contentSpace)))
  }

  /// The checkbox state of a task item; nil for every other block.
  var checked: Bool? {
    if case .list(.task(let checked, _, _, _)) = kind { checked } else { nil }
  }

  func with(checked: Bool) -> BlockAttrs {
    guard case .list(.task(_, let indent, let markerSpace, let contentSpace)) = kind else { return self }
    return .task(checked: checked, indent: indent, markerSpace: markerSpace, contentSpace: contentSpace)
  }

  var isListItem: Bool {
    if case .list = kind { true } else { false }
  }

  /// Nesting depth shown as indentation: two columns per level, like the Markdown source.
  var depth: Int {
    guard case .list(let prefix) = kind else { return 0 }
    return prefix.indent.utf16.reduce(0) { $0 + ($1 == 0x09 ? 2 : 1) } / 2
  }

  /// The attributes of the paragraph a new line after this one starts with, nil for a plain paragraph:
  /// a task starts unchecked, an ordered item counts on, a quote keeps its prefix, code stays code.
  var continued: BlockAttrs? {
    switch kind {
    case .list(.task(_, let indent, let markerSpace, _)): return .task(checked: false, indent: indent, markerSpace: markerSpace)
    case .list(.marker(let indent, let marker, let space)):
      return BlockAttrs(.list(.marker(indent: indent, marker: ComposerListContinuation.nextOrderedMarker(marker), space: space)))
    case .quote, .code: return self
    case .heading, .rule, .paragraph: return nil
    }
  }

  override func isEqual(_ object: Any?) -> Bool { (object as? BlockAttrs)?.kind == kind }

  override var hash: Int { kind.hashValue }
}

extension RichTextMark {
  var bit: Int {
    switch self {
    case .bold: 1
    case .italic: 2
    case .strike: 4
    case .code: 8
    }
  }

  static func mask(_ marks: [RichTextMark]) -> Int { marks.reduce(0) { $0 | $1.bit } }

  static func marks(fromMask mask: Int) -> [RichTextMark] { RichTextMark.nestingOrder.filter { mask & $0.bit != 0 } }
}

/// Fonts and colors of the editor text.
public struct ComposerEditorStyle: Sendable {
  public var fontSize: CGFloat
  public var lineSpacing: CGFloat
  /// The prompt font family (Settings › Appearance); nil keeps the system font.
  public var fontFamily: String?
  /// Theme colors; nil keeps the system's.
  public var textColor: NSColor?
  public var fill: Color?
  public var stroke: Color?

  public init(
    fontSize: CGFloat = 13.5, lineSpacing: CGFloat = 2.5, fontFamily: String? = nil, textColor: NSColor? = nil, fill: Color? = nil, stroke: Color? = nil
  ) {
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.fontFamily = fontFamily
    self.textColor = textColor
    self.fill = fill
    self.stroke = stroke
  }

  var baseFont: NSFont { systemOrCustomFont(size: fontSize) }

  /// The font for a run with the given marks inside `block`: headings are bold and larger, code is
  /// monospaced and ignores marks.
  func font(for marks: Int, block: BlockAttrs? = nil) -> NSFont {
    var size = fontSize
    var heading = false
    switch block?.kind {
    case .code?:
      return NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
    case .heading(let level, _)?:
      size = fontSize * Self.headingScale[min(level, Self.headingScale.count) - 1]
      heading = true
    default: break
    }
    var font: NSFont = marks & RichTextMark.code.bit != 0 ? NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular) : systemOrCustomFont(size: size)
    var traits: NSFontDescriptor.SymbolicTraits = heading ? [.bold] : []
    if marks & RichTextMark.bold.bit != 0 { traits.insert(.bold) }
    if marks & RichTextMark.italic.bit != 0 { traits.insert(.italic) }
    if !traits.isEmpty {
      let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
      font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    return font
  }

  private func systemOrCustomFont(size: CGFloat) -> NSFont {
    if let fontFamily, let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) { return font }
    return NSFont.systemFont(ofSize: size)
  }

  func paragraphStyle(block: BlockAttrs?) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.paragraphSpacing = 0
    let indent = Self.indent(of: block)
    style.firstLineHeadIndent = indent
    style.headIndent = indent
    if case .code? = block?.kind { style.tailIndent = -Self.codeInset }
    return style
  }

  /// How far a block's text is indented: past a list's gutter and nesting, a quote's bar, a code block's padding.
  static func indent(of block: BlockAttrs?) -> CGFloat {
    switch block?.kind {
    case .list?: CGFloat(block?.depth ?? 0) * 18 + listGutter
    case .quote?: quoteIndent
    case .code?: codeInset
    default: 0
    }
  }

  /// Width reserved left of a list item's text for its checkbox or marker.
  static let listGutter: CGFloat = 22
  /// Text indent of a quote line, which holds the quote bar.
  static let quoteIndent: CGFloat = 14
  /// Padding inside a code block's background.
  static let codeInset: CGFloat = 10
  /// Heading sizes relative to the body: `#` is the largest.
  private static let headingScale: [CGFloat] = [1.4, 1.25, 1.12, 1.05, 1, 1]
}

// MARK: - Chip presentation

/// What a chip looks like and says. Pure data so rendering, tooltips and accessibility agree.
public struct ChipPresentation: Sendable, Hashable {
  public enum Kind: String, Sendable, Hashable {
    case neutral, image, video, file, mention, terminal, element
    case previewAnnotation = "preview-annotation"
    case reviewComment = "review-comment"
    case pullRequest = "pull-request"
    case prOpen = "pr-open", prDraft = "pr-draft", prMerged = "pr-merged", prClosed = "pr-closed"
    case skill, citation
  }

  public var kind: Kind
  /// SF Symbol name.
  public var symbol: String
  public var label: String
  /// Upload progress or state shown after the label (`42%`, `upload failed`, `attach again`).
  public var suffix: String?
  public var accessibilityLabel: String
  public var tooltip: String?
  /// Dashed outline: the context behind the chip is not available.
  public var isUnresolved: Bool
  public var isError: Bool
  /// Citations can carry the user's comment; the chip offers a pencil to edit it.
  public var editableComment: Bool

  public init(
    kind: Kind, symbol: String, label: String, suffix: String? = nil, accessibilityLabel: String? = nil, tooltip: String? = nil, isUnresolved: Bool = false,
    isError: Bool = false, editableComment: Bool = false
  ) {
    self.kind = kind
    self.symbol = symbol
    self.label = label
    self.suffix = suffix
    self.accessibilityLabel = accessibilityLabel ?? label
    self.tooltip = tooltip
    self.isUnresolved = isUnresolved
    self.isError = isError
    self.editableComment = editableComment
  }
}

/// Looks up how a chip should present itself; the model implements it from drafts and uploads.
public typealias ChipPresentationProvider = @MainActor @Sendable (RichAtom) -> ChipPresentation
