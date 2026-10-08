import Foundation

// The render model: what the parser produces and the attributed-string builder consumes.
// Plain value types; theme- and width-independent, so a parsed chunk can be cached and
// rendered under any theme.

public enum MarkdownAlertKind: String, CaseIterable, Hashable, Sendable {
  case note, tip, important, warning, caution

  public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public enum MarkdownAlignment: Hashable, Sendable {
  case natural, left, center, right
}

/// Inline styling that comes from the sanitizer's HTML tag allow-list.
public enum MarkdownInlineStyle: Hashable, Sendable {
  case subscripted, superscripted, highlighted, underlined, keyboard, small, monospace, quoted
}

public struct MarkdownImage: Hashable, Sendable {
  public var source: MarkdownImageSource
  /// Destination exactly as authored.
  public var destination: String
  public var alt: String
  public var title: String?
  public var width: Int?
  public var height: Int?

  public init(
    source: MarkdownImageSource, destination: String, alt: String, title: String? = nil, width: Int? = nil,
    height: Int? = nil
  ) {
    self.source = source
    self.destination = destination
    self.alt = alt
    self.title = title
    self.width = width
    self.height = height
  }
}

public indirect enum MarkdownInline: Hashable, Sendable {
  case text(String)
  case softBreak
  case lineBreak
  /// Inline code; `file` is set when the span looks like a path (`src/a.ts:12`).
  case code(String, file: MarkdownFileTarget?)
  case emphasis([MarkdownInline])
  case strong([MarkdownInline])
  case strikethrough([MarkdownInline])
  case styled(MarkdownInlineStyle, [MarkdownInline])
  /// Only `.web`, `.file`, `.anchor`; citations and contexts are chips.
  case link(MarkdownLink, [MarkdownInline])
  case image(MarkdownImage)
  case citation(MarkdownCitation)
  case context(kind: String, id: String, label: String)
}

public struct MarkdownCodeBlock: Hashable, Sendable {
  /// Lower-cased first word of the info string, if any.
  public var language: String?
  public var meta: String?
  /// Source without the trailing newline.
  public var code: String
  /// True while the closing fence has not arrived (streaming tail): not highlighted yet.
  public var isOpen: Bool
}

public struct MarkdownListItem: Hashable, Sendable {
  /// nil: not a task item.
  public var checked: Bool?
  public var blocks: [MarkdownBlock]
}

public struct MarkdownList: Hashable, Sendable {
  public var isOrdered: Bool
  public var start: Int
  public var isTight: Bool
  public var items: [MarkdownListItem]
}

public struct MarkdownTableCell: Hashable, Sendable {
  public var inlines: [MarkdownInline]
  public var colspan: Int
}

public struct MarkdownTable: Hashable, Sendable {
  public var alignments: [MarkdownAlignment]
  public var header: [MarkdownTableCell]
  public var rows: [[MarkdownTableCell]]

  public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

public indirect enum MarkdownBlock: Hashable, Sendable {
  case paragraph([MarkdownInline], alignment: MarkdownAlignment = .natural)
  case heading(level: Int, [MarkdownInline])
  case code(MarkdownCodeBlock)
  case quote([MarkdownBlock])
  case alert(MarkdownAlertKind, [MarkdownBlock])
  case list(MarkdownList)
  case table(MarkdownTable)
  case thematicBreak
  /// A paragraph that holds only an image (web `dataStandalone`).
  case image(MarkdownImage)
  /// `::artifact-template{…}` result card.
  case artifactTemplate(MarkdownArtifactTemplate)
  /// `<details><summary>`: collapsed unless `isOpen` (the authored `open` attribute); the
  /// reader's toggle is view state (`MarkdownDetailsStore`), not part of the model.
  case details(summary: [MarkdownInline], isOpen: Bool, blocks: [MarkdownBlock])
}

public struct MarkdownArtifactTemplate: Hashable, Sendable {
  public enum Kind: String, CaseIterable, Hashable, Sendable {
    case document, presentation, spreadsheet, site
    case googleDocs = "google-docs"
    case googleSlides = "google-slides"
    case googleSheets = "google-sheets"
    case image, email, slack

    public var presentationLabel: String {
      switch self {
      case .document: "Document template"
      case .presentation: "Presentation template"
      case .spreadsheet: "Spreadsheet template"
      case .site: "Site template"
      case .googleDocs: "Google Doc template"
      case .googleSlides: "Google Slides template"
      case .googleSheets: "Google Sheet template"
      case .image: "Image template"
      case .email: "Email template"
      case .slack: "Slack template"
      }
    }

    public var symbolName: String {
      switch self {
      case .document, .googleDocs: "doc.text"
      case .presentation, .googleSlides: "rectangle.on.rectangle.angled"
      case .spreadsheet, .googleSheets: "tablecells"
      case .site: "globe"
      case .image: "photo"
      case .email: "envelope"
      case .slack: "bubble.left"
      }
    }
  }

  public enum GalleryKind: String, Hashable, Sendable {
    case imagegen
    case productDesign = "product-design"
  }

  public var kind: Kind
  public var displayName: String
  public var galleryKind: GalleryKind?
  public var skillDirectory: String
  public var skillName: String

  /// Mirrors the Codex result-card schema so malformed directives stay literal Markdown.
  public init?(attributes: [String: String]) {
    guard let kind = attributes["artifact_kind"].flatMap(Kind.init(rawValue:)),
      let name = attributes["display_name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
      let directory = attributes["skill_directory"], Self.isAbsolute(directory),
      let skill = attributes["skill_name"], skill.hasPrefix("artifact-template-")
    else { return nil }
    var gallery: GalleryKind?
    if let raw = attributes["gallery_kind"] {
      guard let parsed = GalleryKind(rawValue: raw) else { return nil }
      gallery = parsed
    }
    self.kind = kind
    self.displayName = name
    self.galleryKind = gallery
    self.skillDirectory = directory
    self.skillName = skill
  }

  private static func isAbsolute(_ v: String) -> Bool {
    (v.hasPrefix("/") && !v.hasPrefix("//")) || MarkdownPaths.isWindowsDrive(v)
      || v.hasPrefix("\\\\") || v.hasPrefix("//")
  }

  /// `$skill-name` composer prompt that invokes the template (web `codexArtifactTemplateUsePrompt`).
  public var usePrompt: String {
    let skill = "$\(skillName)"
    switch kind {
    case .document: return "Create a document using this \(skill) about…"
    case .presentation: return "Create a presentation using the \(skill) template about…"
    case .spreadsheet: return "Create a spreadsheet using this \(skill) about…"
    case .site: return "Create a Site using this \(skill) about…"
    case .googleDocs: return "Create a Google Doc using this \(skill) about…"
    case .googleSlides: return "Create a Google Slides presentation using this \(skill) about…"
    case .googleSheets: return "Create a Google Sheet using this \(skill) about…"
    case .image: return "Create an image using this \(skill) of…"
    case .email: return "Draft an email using this \(skill) about…"
    case .slack: return "Draft a Slack message using this \(skill) about…"
    }
  }
}

// MARK: - Plain text

extension MarkdownInline {
  /// Readable text of an inline run (alt text, accessibility, copy).
  static func plainText(_ inlines: [MarkdownInline]) -> String {
    var out = ""
    for inline in inlines {
      switch inline {
      case .text(let s): out += s
      case .softBreak: out += " "
      case .lineBreak: out += "\n"
      case .code(let s, _): out += s
      case .emphasis(let c), .strong(let c), .strikethrough(let c), .styled(_, let c), .link(_, let c):
        out += plainText(c)
      case .image(let i): out += i.alt
      case .citation(let c): out += c.text
      case .context(_, _, let label): out += label
      }
    }
    return out
  }
}
