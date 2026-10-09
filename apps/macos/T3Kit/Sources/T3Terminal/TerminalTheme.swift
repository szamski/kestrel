import AppKit
import CryptoKit
import Foundation

public struct TerminalColor: Sendable, Hashable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// `#rrggbb`, the form Ghostty's config takes.
  public var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }

  /// sRGB components of `color`; `.clear` and unresolvable colors fall back to black.
  public init(_ color: NSColor) {
    let srgb = color.usingColorSpace(.sRGB) ?? .black
    red = UInt8((srgb.redComponent * 255).rounded())
    green = UInt8((srgb.greenComponent * 255).rounded())
    blue = UInt8((srgb.blueComponent * 255).rounded())
  }

  func blended(over base: TerminalColor, alpha: Double) -> TerminalColor {
    func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 { UInt8((Double(top) * alpha + Double(bottom) * (1 - alpha)).rounded()) }
    return TerminalColor(red: mix(red, base.red), green: mix(green, base.green), blue: mix(blue, base.blue))
  }
}

/// Background, foreground, cursor and selection of a terminal, mapped from the app palette. The
/// 16 ANSI colors stay Ghostty's defaults, as in the web client.
public struct TerminalTheme: Sendable, Hashable {
  public var background: TerminalColor
  public var foreground: TerminalColor
  public var cursor: TerminalColor
  /// Opaque: Ghostty cannot draw a translucent selection, so alpha is blended in up front.
  public var selectionBackground: TerminalColor
  public var isDark: Bool

  public init(background: TerminalColor, foreground: TerminalColor, cursor: TerminalColor, selectionBackground: TerminalColor, isDark: Bool) {
    self.background = background
    self.foreground = foreground
    self.cursor = cursor
    self.selectionBackground = selectionBackground
    self.isDark = isDark
  }

  /// Maps app palette colors; `selection` may carry alpha (blended over `background`).
  public init(background: NSColor, foreground: NSColor, cursor: NSColor, selection: NSColor, isDark: Bool) {
    let bg = TerminalColor(background)
    self.init(
      background: bg, foreground: TerminalColor(foreground), cursor: TerminalColor(cursor),
      selectionBackground: TerminalColor(selection).blended(over: bg, alpha: Double(selection.alphaComponent)), isDark: isDark)
  }

  // Same fallbacks as the web client's terminalThemeFromApp.
  public static let dark = TerminalTheme(
    background: .init(red: 14, green: 18, blue: 24), foreground: .init(red: 237, green: 241, blue: 247),
    cursor: .init(red: 180, green: 203, blue: 255),
    selectionBackground: TerminalColor(red: 180, green: 203, blue: 255).blended(over: .init(red: 14, green: 18, blue: 24), alpha: 0.25), isDark: true)
  public static let light = TerminalTheme(
    background: .init(red: 255, green: 255, blue: 255), foreground: .init(red: 28, green: 33, blue: 41),
    cursor: .init(red: 38, green: 56, blue: 78),
    selectionBackground: TerminalColor(red: 37, green: 63, blue: 99).blended(over: .init(red: 255, green: 255, blue: 255), alpha: 0.2), isDark: false)
}

public struct TerminalFont: Sendable, Hashable {
  /// Empty uses Ghostty's built-in default (JetBrains Mono, with system fallbacks).
  public var family: String
  public var size: Int

  public init(family: String = "", size: Int = 12) {
    self.family = family.trimmingCharacters(in: .whitespacesAndNewlines)
    self.size = min(max(size, 6), 72)
  }
}

/// The Ghostty config file a surface is built from. Ghostty only loads configs from files, so the
/// text is written once per distinct content into the temporary directory.
enum TerminalGhosttyConfig {
  static let padding = (x: 8.0, y: 6.0)

  static func contents(theme: TerminalTheme, font: TerminalFont) -> String {
    var lines = [
      "background = \(theme.background.hex)",
      "foreground = \(theme.foreground.hex)",
      "cursor-color = \(theme.cursor.hex)",
      "selection-background = \(theme.selectionBackground.hex)",
      "selection-foreground = \(theme.foreground.hex)",
      "font-size = \(font.size)",
      "window-padding-x = \(Int(padding.x))",
      "window-padding-y = \(Int(padding.y))",
      "window-padding-balance = false",
      "window-padding-color = background",
      // The server owns the PTY: no shell, no title/notification/clipboard side channels beyond
      // what the web client honors. Remote programs may write the clipboard (OSC 52) but never read it.
      "link-url = false",
      "clipboard-read = deny",
      "clipboard-write = allow",
      "clipboard-paste-protection = false",
      "copy-on-select = false",
      "desktop-notifications = false",
      "confirm-close-surface = false",
      "shell-integration = none",
      "resize-overlay = never",
      // Only the bindings a terminal pane owns; everything else (⌘T, ⌘W, ...) stays with the app.
      "keybind = clear",
      "keybind = super+c=copy_to_clipboard",
      "keybind = super+v=paste_from_clipboard",
      "keybind = super+a=select_all",
      "keybind = shift+page_up=scroll_page_up",
      "keybind = shift+page_down=scroll_page_down",
      "keybind = super+left=text:\\x01",
      "keybind = super+right=text:\\x05",
      "keybind = super+backspace=text:\\x15",
      "keybind = alt+left=esc:b",
      "keybind = alt+right=esc:f",
    ]
    if !font.family.isEmpty { lines.insert("font-family = \"\(font.family.replacingOccurrences(of: "\"", with: ""))\"", at: 0) }
    return lines.joined(separator: "\n") + "\n"
  }

  static func write(theme: TerminalTheme, font: TerminalFont) -> URL? {
    let text = contents(theme: theme, font: font)
    let digest = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-terminal", isDirectory: true)
    let url = directory.appendingPathComponent("config-\(digest).ghostty")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if (try? String(contentsOf: url, encoding: .utf8)) != text { try text.write(to: url, atomically: true, encoding: .utf8) }
      return url
    } catch {
      return nil
    }
  }
}
