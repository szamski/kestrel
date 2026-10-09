import Foundation

public struct ThemeError: Error, LocalizedError, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// Theme file format v1: the same JSON the web exports and imports (`parseThemeFile` / `serializeThemeFile`).
public enum ThemeFile {
  public static let version = 1
  /// A full export is a few KB; anything larger is not a theme file.
  public static let maxBytes = 256 * 1024

  public static func isLabel(_ value: Any?) -> Bool {
    guard let text = value as? String else { return false }
    let count = text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    return count > 0 && count <= 48
  }

  static func parseCollection(_ value: Any?) -> ThemeDefinition.Collection? {
    guard let object = value as? [String: Any], let id = object["id"] as? String, isLabel(object["label"]),
      id.range(of: #"^[a-z0-9][a-z0-9.:-]{0,127}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    else { return nil }
    return .init(id: id, label: (object["label"] as! String).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Canonical colors for every role; a color that does not parse is kept as written (built-ins always parse).
  public static func canonicalized(_ colors: ThemeColors) -> ThemeColors {
    var next = colors
    for role in ThemeRole.allCases { if let canonical = ThemeColorMath.canonical(colors[role]) { next[role] = canonical } }
    return next
  }

  /// `lenientThemeColorOverrides`: unknown roles and malformed values are dropped, so themes written by other builds keep
  /// their remaining colors.
  public static func lenientOverrides(_ value: [String: Any]) -> [ThemeRole: String] {
    var overrides: [ThemeRole: String] = [:]
    for (name, color) in value {
      if let role = ThemeRole(rawValue: name), let text = color as? String, let canonical = ThemeColorMath.canonical(text) {
        overrides[role] = canonical
      }
    }
    return overrides
  }

  private static func strictOverrides(_ value: Any?) throws -> [ThemeRole: String] {
    guard let object = value as? [String: Any] else { throw ThemeError("Theme colors must be objects.") }
    var overrides: [ThemeRole: String] = [:]
    for (name, color) in object {
      guard let role = ThemeRole(rawValue: name) else { throw ThemeError("\"\(name)\" is not a supported theme color role.") }
      guard let text = color as? String, let canonical = ThemeColorMath.canonical(text) else {
        throw ThemeError("The color for \"\(name)\" must be a literal CSS color such as oklch(0.62 0.2 280).")
      }
      overrides[role] = canonical
    }
    if overrides.isEmpty { throw ThemeError("Add at least one color role to the theme file.") }
    return overrides
  }

  /// `parseThemeFile`. `lenient` drops unknown roles and bad colors instead of refusing the file (for files a server or
  /// another build wrote).
  public static func parse(_ value: Any, lenient: Bool = false) throws -> ThemeDefinition {
    guard let object = value as? [String: Any] else { throw ThemeError("Theme files must contain a JSON object.") }
    guard let version = object["version"] as? Int, version == Self.version else {
      throw ThemeError("This theme file uses an unsupported version. Expected \(Self.version).")
    }
    guard isLabel(object["name"]), let name = object["name"] as? String else { throw ThemeError("Theme files need a name (48 characters or fewer).") }
    guard let appearanceName = object["appearance"] as? String, let appearance = ThemeAppearance(rawValue: appearanceName) else {
      throw ThemeError("Theme files need an appearance of \"light\" or \"dark\".")
    }
    guard let rawColors = object["colors"] as? [String: Any] else { throw ThemeError("Theme files need a colors object.") }

    let id: String
    if let explicit = object["id"] {
      guard let text = explicit as? String, ThemeIds.isValid(text) else {
        throw ThemeError("Theme ids may only contain lowercase letters, numbers, and hyphens.")
      }
      id = text
    } else {
      id = ThemeIds.fromName(name)
    }
    if ThemeIds.reserved.contains(id) { throw ThemeError("The theme id \"\(id)\" is reserved.") }

    let overrides = lenient ? lenientOverrides(rawColors) : try strictOverrides(rawColors)
    let collection = parseCollection(object["collection"])
    if object["collection"] != nil, collection == nil { throw ThemeError("Theme collections need a valid id and label.") }

    var variants: [ThemeAppearance: ThemeColors] = [:]
    if let rawVariants = object["variants"] {
      guard let table = rawVariants as? [String: Any] else { throw ThemeError("Theme variants must be an object.") }
      for (key, colors) in table {
        guard let variantAppearance = ThemeAppearance(rawValue: key) else { throw ThemeError("Theme variants may only be named \"light\" or \"dark\".") }
        if variantAppearance == appearance { throw ThemeError("Theme variants must not repeat the base appearance \"\(appearance.rawValue)\".") }
        let variantOverrides = lenient ? lenientOverrides(colors as? [String: Any] ?? [:]) : try strictOverrides(colors)
        variants[variantAppearance] = ThemeColors(variantOverrides, over: ThemePalette.defaultColors(variantAppearance))
      }
    }
    return ThemeDefinition(
      id: id, label: name.trimmingCharacters(in: .whitespacesAndNewlines), appearance: appearance,
      colors: ThemeColors(overrides, over: ThemePalette.defaultColors(appearance)), variants: variants, collection: collection,
      managed: object["managed"] as? Bool == true)
  }

  public static func parse(data: Data, lenient: Bool = false) throws -> ThemeDefinition {
    guard data.count <= maxBytes else { throw ThemeError("That file is too large to be a theme (limit 256 KB).") }
    guard let value = try? JSONSerialization.jsonObject(with: data) else { throw ThemeError("That is not valid JSON.") }
    return try parse(value, lenient: lenient)
  }

  // MARK: Serialization

  private static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
      }
    }
    return out + "\""
  }

  private static func colorsBlock(_ colors: ThemeColors, indent: String) throws -> String {
    let rows = try ThemeRole.allCases.map { role -> String in
      guard let canonical = ThemeColorMath.canonical(colors[role]) else {
        throw ThemeError("The color for \"\(role.rawValue)\" must be a literal CSS color such as oklch(0.62 0.2 280).")
      }
      return "\(indent)  \(quote(role.rawValue)): \(quote(canonical))"
    }
    return "{\n" + rows.joined(separator: ",\n") + "\n\(indent)}"
  }

  /// `serializeThemeFile`: the exported JSON, two-space indented, trailing newline.
  public static func serialize(_ theme: ThemeDefinition) throws -> String {
    var fields = [
      "  \"version\": \(version)", "  \(quote("id")): \(quote(theme.id))", "  \(quote("name")): \(quote(theme.label))",
      "  \(quote("appearance")): \(quote(theme.appearance.rawValue))", "  \"colors\": \(try colorsBlock(theme.colors, indent: "  "))",
    ]
    if !theme.variants.isEmpty {
      let rows = try ThemeAppearance.allCases.compactMap { appearance in
        try theme.variants[appearance].map { "    \(quote(appearance.rawValue)): \(try colorsBlock($0, indent: "    "))" }
      }
      fields.append("  \"variants\": {\n" + rows.joined(separator: ",\n") + "\n  }")
    }
    if let collection = theme.collection {
      fields.append("  \"collection\": {\n    \"id\": \(quote(collection.id)),\n    \"label\": \(quote(collection.label))\n  }")
    }
    if theme.managed { fields.append("  \"managed\": true") }
    return "{\n" + fields.joined(separator: ",\n") + "\n}\n"
  }
}

/// Themes the server publishes (`EnvironmentTheme`): the seeded short form (canvas + accent) or a full exported file.
public struct PublishedTheme: Sendable, Hashable {
  public var id: String
  public var name: String
  public var appearance: ThemeAppearance
  public var canvas: String?
  public var accent: String?
  public var colors: [String: String]?
  public var variants: [ThemeAppearance: [String: String]]

  public init(
    id: String, name: String, appearance: ThemeAppearance, canvas: String? = nil, accent: String? = nil, colors: [String: String]? = nil,
    variants: [ThemeAppearance: [String: String]] = [:]
  ) {
    (self.id, self.name, self.appearance, self.canvas, self.accent, self.colors, self.variants) = (id, name, appearance, canvas, accent, colors, variants)
  }

  private func palette(_ mode: ThemeAppearance, overrides: [String: String]?) -> ThemeColors {
    // Seeds generate the base with the guided editor's generator, but only for the appearance they describe; a variant
    // builds on that appearance's stock defaults.
    let base =
      mode == appearance && canvas != nil && accent != nil
      ? ThemePalette.vivid(mode, background: canvas!, accent: accent!) : ThemePalette.defaultColors(mode)
    return ThemeColors(ThemeFile.lenientOverrides(overrides ?? [:]), over: base)
  }

  public var definition: ThemeDefinition {
    var halves: [ThemeAppearance: ThemeColors] = [:]
    for (mode, overrides) in variants where mode != appearance { halves[mode] = palette(mode, overrides: overrides) }
    return ThemeDefinition(
      id: id, label: name, appearance: appearance, colors: palette(appearance, overrides: colors), variants: halves,
      managed: canvas != nil && accent != nil && colors == nil && variants.isEmpty)
  }

  /// `publishedThemeDefinitions`: reserved ids are dropped, and a theme needs seeds or at least one usable color.
  public static func definitions(_ themes: [PublishedTheme]) -> [ThemeDefinition] {
    themes.filter { theme in
      if ThemeIds.reserved.contains(theme.id) { return false }
      if theme.canvas != nil, theme.accent != nil { return true }
      return [theme.colors, theme.variants[theme.appearance.other]].contains { colors in
        guard let colors else { return false }
        return !ThemeFile.lenientOverrides(colors).isEmpty
      }
    }.map(\.definition)
  }
}
