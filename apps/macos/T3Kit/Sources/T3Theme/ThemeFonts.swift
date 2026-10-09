import Foundation

/// Font preference rules from `apps/web/src/appearanceFonts.ts`: size ranges from the contract and the family-list syntax
/// (one name or a comma-separated list, optionally quoted). Resolving a name to an installed font is the app's job.
public enum ThemeFonts {
  public static let interfaceSize = 12...20, promptSize = 12...20, codeSize = 10...18, terminalSize = 8...20
  public static let defaultInterfaceSize = 16, defaultPromptSize = 14, defaultCodeSize = 13, defaultTerminalSize = 12

  public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int { min(range.upperBound, max(range.lowerBound, value)) }

  /// `cssFontFamilies` without the CSS: each name trimmed and unquoted, empties dropped.
  public static func families(_ input: String) -> [String] {
    input.split(separator: ",").map { raw in
      var name = raw.trimmingCharacters(in: .whitespaces)
      if name.count >= 2, let first = name.first, first == "\"" || first == "'", name.last == first { name = String(name.dropFirst().dropLast()) }
      return name.replacingOccurrences(of: "\"", with: "")
    }.filter { !$0.isEmpty }
  }

  /// Simple typography treats the terminal as another monospace surface; Advanced gives it its own family and size.
  public static func terminalFamily(advanced: Bool, code: String, terminal: String) -> String { advanced ? terminal : code }
  public static func terminalSize(advanced: Bool, code: Int, terminal: Int) -> Int { advanced ? terminal : code }
}
