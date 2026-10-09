import AppKit
import T3Theme

/// Turns the family preferences (one name or a comma-separated list, as in the web settings) into installed fonts.
enum AppearanceFonts {
  /// Every installed family a person can pick, without macOS-internal (dot-prefixed) faces.
  static func installedFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private static func probe(_ family: String, size: CGFloat) -> NSFont? {
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
  }

  /// The first family of `preference` that is installed, nil when the preference is empty or names nothing installed.
  static func resolvedFamily(_ preference: String) -> String? {
    ThemeFonts.families(preference).first { probe($0, size: 12) != nil }
  }

  static func font(_ preference: String, size: CGFloat, monospaced: Bool) -> NSFont {
    if let family = resolvedFamily(preference), let font = probe(family, size: size) { return font }
    return monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
  }

  /// Families whose letters share one advance: the only ones a terminal or code surface can use.
  static func isMonospaced(_ family: String) -> Bool {
    guard let font = probe(family, size: 12) else { return false }
    if font.isFixedPitch { return true }
    let advances = ["i", "M", "W", ".", " "].map { ($0 as NSString).size(withAttributes: [.font: font]).width }
    return advances.allSatisfy { abs($0 - advances[0]) < 0.01 }
  }

  /// What "Default" means on this Mac, for the picker's first row.
  static func defaultLabel(monospaced: Bool) -> String { monospaced ? "SF Mono" : "SF Pro" }
}
