import AppKit
import Foundation
import Observation

/// Everything the renderer needs to know about looks. Colours are keyed by semantic role;
/// the default light/dark themes approximate the web "t3-chat" palette
/// (packages/shared/src/themePalettes.ts, converted from OKLCH).
///
/// The struct is `Hashable`: its hash is the theme part of the layout-cache key, so two
/// equal themes share cached heights and attributed strings.
public struct MarkdownTheme: Hashable, @unchecked Sendable {
  public var isDark: Bool

  // Fonts
  public var bodyFont: NSFont
  public var codeFont: NSFont
  /// Heading size relative to the body font, h1…h6.
  public var headingScales: [CGFloat]

  // Metrics (points)
  public var lineSpacing: CGFloat
  /// Space after a block.
  public var blockSpacing: CGFloat
  /// Space between tight list items.
  public var listItemSpacing: CGFloat
  public var listIndent: CGFloat
  public var codePadding: CGFloat
  public var cornerRadius: CGFloat

  // Colours
  public var foreground: NSColor
  public var muted: NSColor
  public var link: NSColor
  public var codeBackground: NSColor
  public var codeForeground: NSColor
  public var border: NSColor
  public var quoteBar: NSColor
  public var tableHeaderBackground: NSColor
  public var chipBackground: NSColor
  public var chipForeground: NSColor
  public var highlightBackground: NSColor
  public var alertColors: [MarkdownAlertKind: NSColor]
  public var syntax: [SyntaxRole: NSColor]

  public func color(for alert: MarkdownAlertKind) -> NSColor { alertColors[alert] ?? link }
  public func color(for role: SyntaxRole) -> NSColor { syntax[role] ?? codeForeground }

  public func headingFont(level: Int) -> NSFont {
    let scale = headingScales[min(max(level, 1), headingScales.count) - 1]
    return NSFont.systemFont(ofSize: bodyFont.pointSize * scale, weight: level <= 2 ? .bold : .semibold)
  }
}

extension MarkdownTheme {
  /// One point above the system body size (14pt by default, like the web chat). macOS has no
  /// Dynamic Type, but `preferredFont` follows the user's text-size setting where it exists.
  public static var defaultBodySize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize + 1 }

  /// Code is smaller (monospaced, system design).
  private static func fonts(bodySize: CGFloat) -> (NSFont, NSFont) {
    (
      NSFont.systemFont(ofSize: bodySize),
      NSFont.monospacedSystemFont(ofSize: (bodySize - 1.5).rounded(.up), weight: .regular)
    )
  }

  private static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
  }

  public static func t3ChatLight(bodySize: CGFloat = defaultBodySize) -> MarkdownTheme {
    let (body, code) = fonts(bodySize: bodySize)
    return MarkdownTheme(
      isDark: false, bodyFont: body, codeFont: code, headingScales: [1.5, 1.3, 1.15, 1.05, 1.0, 0.95],
      lineSpacing: 3, blockSpacing: 10, listItemSpacing: 3, listIndent: 22, codePadding: 10, cornerRadius: 8,
      foreground: hex(0x501854), muted: hex(0x8E5A93), link: hex(0xDB2777), codeBackground: hex(0xF5ECF9),
      codeForeground: hex(0x673C8B), border: hex(0xE3CFE3), quoteBar: hex(0xD9B8DD),
      tableHeaderBackground: hex(0xF3E6F5), chipBackground: hex(0xF3E6F5), chipForeground: hex(0x501854),
      highlightBackground: hex(0xFDE68A, alpha: 0.7),
      alertColors: [
        .note: hex(0x2563EB), .tip: hex(0x059669), .important: hex(0x9333EA), .warning: hex(0xD97706),
        .caution: hex(0xDC2626),
      ],
      syntax: [
        .plain: hex(0x501854), .keyword: hex(0xCF222E), .string: hex(0x0A3069), .comment: hex(0x8A7A90),
        .number: hex(0x0550AE), .type: hex(0x953800), .function: hex(0x8250DF), .variable: hex(0x953800),
        .property: hex(0x0550AE), .attribute: hex(0x0550AE), .op: hex(0xCF222E), .punctuation: hex(0x673C8B),
        .meta: hex(0x8A7A90), .tag: hex(0x116329), .builtin: hex(0x0550AE), .literal: hex(0x0550AE),
        .symbol: hex(0x0A3069), .addition: hex(0x116329), .deletion: hex(0x82071E), .heading: hex(0x0550AE),
      ])
  }

  public static func t3ChatDark(bodySize: CGFloat = defaultBodySize) -> MarkdownTheme {
    let (body, code) = fonts(bodySize: bodySize)
    return MarkdownTheme(
      isDark: true, bodyFont: body, codeFont: code, headingScales: [1.5, 1.3, 1.15, 1.05, 1.0, 0.95],
      lineSpacing: 3, blockSpacing: 10, listItemSpacing: 3, listIndent: 22, codePadding: 10, cornerRadius: 8,
      foreground: hex(0xF9F8FB), muted: hex(0xBFA9C2), link: hex(0xF472B6), codeBackground: hex(0x1F1A24),
      codeForeground: hex(0xD8C3EF), border: hex(0x3A3342), quoteBar: hex(0x5A4A66),
      tableHeaderBackground: hex(0x2C2631), chipBackground: hex(0x463753), chipForeground: hex(0xF9F8FB),
      highlightBackground: hex(0x92400E, alpha: 0.6),
      alertColors: [
        .note: hex(0x60A5FA), .tip: hex(0x34D399), .important: hex(0xC084FC), .warning: hex(0xF59E0B),
        .caution: hex(0xF87171),
      ],
      syntax: [
        .plain: hex(0xD8C3EF), .keyword: hex(0xFF7B72), .string: hex(0xA5D6FF), .comment: hex(0x8B949E),
        .number: hex(0x79C0FF), .type: hex(0xFFA657), .function: hex(0xD2A8FF), .variable: hex(0xFFA657),
        .property: hex(0x79C0FF), .attribute: hex(0x79C0FF), .op: hex(0xFF7B72), .punctuation: hex(0xBFA9C2),
        .meta: hex(0x8B949E), .tag: hex(0x7EE787), .builtin: hex(0x79C0FF), .literal: hex(0x79C0FF),
        .symbol: hex(0xA5D6FF), .addition: hex(0x7EE787), .deletion: hex(0xFFA198), .heading: hex(0x79C0FF),
      ])
  }

  public static var light: MarkdownTheme { ThemeOverrides.shared.markdown ?? t3ChatLight() }
  public static var dark: MarkdownTheme { ThemeOverrides.shared.markdown ?? t3ChatDark() }

  /// The default theme for an appearance.
  public static func `default`(for appearance: NSAppearance) -> MarkdownTheme {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
  }
}

// MARK: - App theme hook

public extension Notification.Name {
  /// Posted on the main thread after `ThemeOverrides.install`; AppKit surfaces that cache colors redraw on it.
  static let t3ThemeDidChange = Notification.Name("T3ThemeDidChange")
}

/// Red/green or blue/orange for additions and deletions (Settings › Appearance › Diff colors).
public enum DiffColorScheme: Sendable, Hashable {
  case redGreen, blueOrange
}

/// What the app theme feeds the renderers: the Markdown theme every surface that shows chat, code or diffs uses, and the diff
/// color scheme. Reads register with Observation, so SwiftUI views that read `MarkdownTheme.light/.dark` or `DiffColors`
/// re-render when the theme changes; AppKit surfaces listen for `.t3ThemeDidChange`.
@Observable
public final class ThemeOverrides: @unchecked Sendable {
  public static let shared = ThemeOverrides()

  @ObservationIgnored private let lock = NSLock()
  @ObservationIgnored private var storedMarkdown: MarkdownTheme?
  @ObservationIgnored private var storedDiff = DiffColorScheme.redGreen
  @ObservationIgnored private var storedCodeFont: NSFont?
  public private(set) var revision = 0

  /// Nil until the app installs a theme, so the renderers' own defaults stay in force in tests and previews.
  public var markdown: MarkdownTheme? {
    _ = revision
    return lock.withLock { storedMarkdown }
  }

  public var diffScheme: DiffColorScheme {
    _ = revision
    return lock.withLock { storedDiff }
  }

  /// The user's code font, for surfaces that size their own monospace text (diff rows).
  public var codeFont: NSFont? {
    _ = revision
    return lock.withLock { storedCodeFont }
  }

  public func install(markdown: MarkdownTheme?, diff: DiffColorScheme, codeFont: NSFont?) {
    lock.withLock {
      storedMarkdown = markdown
      storedDiff = diff
      storedCodeFont = codeFont
    }
    revision += 1
    NotificationCenter.default.post(name: .t3ThemeDidChange, object: nil)
  }
}

public enum DiffColors {
  public static var addition: NSColor { ThemeOverrides.shared.diffScheme == .blueOrange ? .systemBlue : .systemGreen }
  public static var deletion: NSColor { ThemeOverrides.shared.diffScheme == .blueOrange ? .systemOrange : .systemRed }
}
