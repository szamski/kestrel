import Foundation

/// Light or dark half of a theme.
public enum ThemeAppearance: String, Sendable, Hashable, Codable, CaseIterable {
  case light, dark

  public var other: ThemeAppearance { self == .light ? .dark : .light }
}

/// The semantic color roles of `packages/shared/src/themePalettes.ts` (`THEME_COLOR_ROLES`), in the same order.
/// Raw values are the names theme files use.
public enum ThemeRole: String, Sendable, Hashable, CaseIterable, Codable {
  case canvas, chrome, toolbar, toolbarForeground, toolbarBorder, toolbarControl, toolbarControlForeground, toolbarControlHover
  case surface, surfaceRaised, surfaceOverlay
  case text, textMuted, border, input, focus
  case accent, accentForeground, secondary, secondaryForeground, muted, mutedForeground
  case placeholder, secondaryLabel, iconMuted
  case error, errorForeground, errorSurface, warning, warningForeground, warningSurface
  case update, updateForeground, updateSurface
  case accentSurface, accentSurfaceForeground
  case messageSurface, messageForeground, messageAction, messageActionForeground, messageActionHover
  case codeBackground, codeForeground
  case sidebar, sidebarForeground, sidebarMutedForeground, sidebarControlSurface
  case sidebarRowHover, sidebarRowActive, sidebarRowSelected, sidebarBorder
  case terminalBackground, terminalForeground, terminalCursor, terminalSelection, terminalScrollbar, terminalScrollbarHover
}

/// A full palette: one CSS color string per role (canonical `oklch(...)` once it went through the codec).
public struct ThemeColors: Sendable, Hashable {
  public private(set) var values: [ThemeRole: String]

  /// `ordered` lists one color per role in `ThemeRole.allCases` order.
  public init(ordered: [String]) {
    precondition(ordered.count == ThemeRole.allCases.count, "a palette needs \(ThemeRole.allCases.count) colors")
    values = Dictionary(uniqueKeysWithValues: zip(ThemeRole.allCases, ordered))
  }

  public init(_ overrides: [ThemeRole: String], over base: ThemeColors) {
    values = base.values.merging(overrides) { _, new in new }
  }

  public subscript(role: ThemeRole) -> String {
    get { values[role]! }
    set { values[role] = newValue }
  }
}

/// A theme as the library renders it (`ThemeDefinition`): a base palette for `appearance`, optionally another for the
/// other appearance.
public struct ThemeDefinition: Sendable, Hashable, Identifiable {
  public struct Collection: Sendable, Hashable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { (self.id, self.label) = (id, label) }
  }

  public var id: String
  public var label: String
  public var appearance: ThemeAppearance
  public var colors: ThemeColors
  public var variants: [ThemeAppearance: ThemeColors]
  /// Groups related imported variants into one library card.
  public var collection: Collection?
  /// Reviewed built-ins render product artwork over their sidebar.
  public var sidebarArtwork: Bool
  /// Generated from the guided editor's canvas and accent roles.
  public var managed: Bool

  public init(
    id: String, label: String, appearance: ThemeAppearance, colors: ThemeColors, variants: [ThemeAppearance: ThemeColors] = [:],
    collection: Collection? = nil, sidebarArtwork: Bool = false, managed: Bool = false
  ) {
    self.id = id
    self.label = label
    self.appearance = appearance
    self.colors = colors
    self.variants = variants
    self.collection = collection
    self.sidebarArtwork = sidebarArtwork
    self.managed = managed
  }

  /// The palette for `mode`, or nil when the theme cannot render it.
  public func colors(for mode: ThemeAppearance) -> ThemeColors? {
    mode == appearance ? colors : variants[mode]
  }

  /// The appearances the theme can render.
  public var modes: [ThemeAppearance] { ThemeAppearance.allCases.filter { colors(for: $0) != nil } }

  /// The one appearance a single-mode theme can claim, nil when it renders both.
  public var singleAppearance: ThemeAppearance? { modes.count == 1 ? modes[0] : nil }
}

public enum ThemeIds {
  public static let builtIn = ["t3-chat", "grove", "ocean", "ember", "iris"]
  /// Ids a theme may not take: appearance keywords, every built-in and the legacy aliases older saves carry.
  public static let reserved: Set<String> = Set(["system", "light", "dark"] + builtIn + ["t3-chat-dark", "t3-grove", "t3-ocean", "t3-ember", "t3-iris"])
  /// Legacy aliases resolve to the built-in they were renamed to.
  public static let legacyAliases = ["t3-chat-dark": "t3-chat", "t3-grove": "grove", "t3-ocean": "ocean", "t3-ember": "ember", "t3-iris": "iris"]

  public static func normalize(_ id: String) -> String { legacyAliases[id] ?? id }

  /// `[a-z0-9][a-z0-9-]{0,47}`.
  public static func isValid(_ id: String) -> Bool {
    guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 48 else { return false }
    let alnum = { (s: Unicode.Scalar) in (s >= "a" && s <= "z") || (s >= "0" && s <= "9") }
    return alnum(first) && id.unicodeScalars.allSatisfy { alnum($0) || $0 == "-" }
  }

  /// `themeIdFromName`: lower-case, runs of anything else become one hyphen (none at the ends), 48 characters at most.
  public static func fromName(_ name: String) -> String {
    var out = ""
    var pendingHyphen = false
    for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
      if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
        if pendingHyphen, !out.isEmpty { out.append("-") }
        pendingHyphen = false
        out.unicodeScalars.append(scalar)
      } else {
        pendingHyphen = true
      }
    }
    let sliced = String(out.prefix(48))
    return sliced.isEmpty ? "custom-theme" : sliced
  }
}
