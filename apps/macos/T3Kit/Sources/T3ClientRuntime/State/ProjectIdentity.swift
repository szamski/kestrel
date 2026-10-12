import Foundation
import T3Contracts

extension ProjectIconColor {
  /// The icon colours in the order the web picker lists them (`PROJECT_ICON_COLORS`).
  public static let palette: [ProjectIconColor] = [
    .gray, .red, .orange, .amber, .yellow, .lime, .green, .emerald, .teal, .cyan, .sky, .blue, .indigo, .violet, .purple, .fuchsia, .pink, .rose,
  ]
}

/// Port of `deriveProjectIdentity` (apps/web/src/projectIdentity.ts): the monogram and colour a project shows when it has no icon.
public enum ProjectIdentity {
  public static func derive(_ name: String) -> (monogram: String, color: ProjectIconColor) { (monogram(name), color(name)) }

  private static func normalized(_ name: String) -> String { name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines) }

  public static func monogram(_ name: String) -> String {
    let words = normalized(name).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    guard let firstWord = words.first else { return "PR" }
    let glyphs = firstWord.unicodeScalars.map { String($0) }
    let first = glyphs.first ?? "P"
    let second =
      glyphs.dropFirst().first { $0.unicodeScalars.allSatisfy { $0.properties.numericType != nil } }
      ?? (words.count > 1 ? words.last.flatMap { $0.unicodeScalars.first.map { String($0) } } : glyphs.last) ?? first
    return String((first + second).uppercased().unicodeScalars.prefix(2).map { Character($0) })
  }

  public static func color(_ name: String) -> ProjectIconColor {
    let seed = normalized(name).lowercased()
    var index = 0
    for scalar in (seed.isEmpty ? "project" : seed).unicodeScalars { index = (index * 31 + Int(scalar.value)) % ProjectIconColor.palette.count }
    return ProjectIconColor.palette[index]
  }

  /// `ProjectMonogramText` plus the server's limit of two graphemes.
  public static func isValidMonogram(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= 2, text.utf8.count <= 32 else { return false }
    return text.range(of: #"^[\p{L}\p{N}][\p{L}\p{N}\p{M}‌‍]*$"#, options: .regularExpression) != nil
  }
}
