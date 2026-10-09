import AppKit
import SwiftUI
import Foundation

extension NSAttributedString.Key {
  /// Bit set of `RichTextMark`s on a run (the Markdown truth; fonts and underlines are just paint).
  static let t3Marks = NSAttributedString.Key("t3.composer.marks")
  /// Task-list attributes on a whole paragraph (checkbox, indent, source spacing).
  static let t3Task = NSAttributedString.Key("t3.composer.task")
}

/// Task item attributes of one paragraph.
final class TaskAttrsBox: NSObject {
  let checked: Bool
  let indent: String
  let markerSpace: String
  let contentSpace: String

  init(checked: Bool, indent: String = "", markerSpace: String = " ", contentSpace: String = "") {
    self.checked = checked
    self.indent = indent
    self.markerSpace = markerSpace
    self.contentSpace = contentSpace
  }

  func with(checked: Bool) -> TaskAttrsBox { TaskAttrsBox(checked: checked, indent: indent, markerSpace: markerSpace, contentSpace: contentSpace) }

  /// Nesting depth shown as indentation: two columns per level, like the Markdown source.
  var depth: Int { indent.utf16.reduce(0) { $0 + ($1 == 0x09 ? 2 : 1) } / 2 }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TaskAttrsBox else { return false }
    return checked == other.checked && indent == other.indent && markerSpace == other.markerSpace && contentSpace == other.contentSpace
  }

  override var hash: Int { var hasher = Hasher(); hasher.combine(checked); hasher.combine(indent); return hasher.finalize() }
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

  var baseFont: NSFont {
    if let fontFamily, let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize) { return font }
    return NSFont.systemFont(ofSize: fontSize)
  }

  /// The font for a run with the given marks.
  func font(for marks: Int) -> NSFont {
    var font: NSFont = marks & RichTextMark.code.bit != 0 ? NSFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular) : baseFont
    var traits: NSFontDescriptor.SymbolicTraits = []
    if marks & RichTextMark.bold.bit != 0 { traits.insert(.bold) }
    if marks & RichTextMark.italic.bit != 0 { traits.insert(.italic) }
    if !traits.isEmpty {
      let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
      font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    return font
  }

  func paragraphStyle(task: TaskAttrsBox?) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.paragraphSpacing = 0
    if let task {
      let indent = CGFloat(task.depth) * 18 + Self.taskGutter
      style.firstLineHeadIndent = indent
      style.headIndent = indent
    }
    return style
  }

  /// Width reserved left of a task item's text for its checkbox.
  static let taskGutter: CGFloat = 22
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
