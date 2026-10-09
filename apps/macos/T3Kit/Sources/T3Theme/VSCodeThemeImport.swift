import Foundation

/// Best-effort import of a VS Code color theme (`*-color-theme.json`). VS Code themes describe editor chrome, not an app
/// palette, so the conversion derives a complete, contrast-solved palette from the editor background and accent and layers the
/// workbench colors the file did specify on top. A port of `apps/web/src/vscodeThemeImport.ts`.
public enum VSCodeThemeImport {
  typealias M = ThemeColorMath

  private struct RGBA { var r: Double, g: Double, b: Double, a: Double }

  private static func decodeGamma(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
  private static func encodeGamma(_ v: Double) -> Double {
    let c = max(0, min(1, v))
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }

  /// `color(display-p3 r g b / a)` and `color(srgb ...)`; out-of-gamut colors clip to the sRGB edge.
  private static func parseColorFunction(_ value: String) -> RGBA? {
    guard let regex = try? NSRegularExpression(pattern: #"^color\(\s*(display-p3|srgb)\s+([^)]+)\)$"#, options: .caseInsensitive),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let spaceRange = Range(match.range(at: 1), in: value), let bodyRange = Range(match.range(at: 2), in: value)
    else { return nil }
    let space = value[spaceRange].lowercased()
    let body = value[bodyRange].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    func component(_ token: Substring) -> Double? {
      let t = token.trimmingCharacters(in: .whitespaces)
      return t.hasSuffix("%") ? Double(t.dropLast()).map { $0 / 100 } : Double(t)
    }
    let channels = body[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(component)
    guard channels.count == 3, channels.allSatisfy({ $0 != nil }) else { return nil }
    var alpha = 1.0
    if body.count > 1 {
      guard let a = component(body[1]) else { return nil }
      alpha = a
    }
    let (red, green, blue) = (channels[0]!, channels[1]!, channels[2]!)
    let clampedAlpha = max(0, min(1, alpha))
    if space == "srgb" { return RGBA(r: red * 255, g: green * 255, b: blue * 255, a: clampedAlpha) }
    let (lr, lg, lb) = (decodeGamma(red), decodeGamma(green), decodeGamma(blue))
    return RGBA(
      r: encodeGamma(1.2249401762805 * lr - 0.2249401762805 * lg) * 255,
      g: encodeGamma(-0.042056961239 * lr + 1.042056961239 * lg) * 255,
      b: encodeGamma(-0.0196375547643 * lr - 0.0786360655012 * lg + 1.0982736202656 * lb) * 255, a: clampedAlpha)
  }

  /// VS Code accepts #RGB, #RGBA, #RRGGBB and #RRGGBBAA; some themes also use CSS `color()`.
  private static func parseColor(_ value: Any?) -> RGBA? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if text.hasPrefix("color(") { return parseColorFunction(text) }
    let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
    let n = hex.compactMap { Int(String($0), radix: 16) }
    func byte(_ i: Int) -> Double { hex.count <= 4 ? Double(n[i] * 17) : Double(n[2 * i] * 16 + n[2 * i + 1]) }
    let hasAlpha = hex.count == 4 || hex.count == 8
    return RGBA(r: byte(0), g: byte(1), b: byte(2), a: hasAlpha ? byte(3) / 255 : 1)
  }

  private static func hex(_ c: ThemeRGB) -> String { M.hex(c) }

  /// Overlays are semi-transparent in VS Code; palette roles are opaque, so they composite onto the surface they sit on.
  private static func flatten(_ c: RGBA, over base: ThemeRGB) -> String {
    if c.a >= 1 { return hex(ThemeRGB(r: c.r, g: c.g, b: c.b)) }
    return hex(ThemeRGB(r: c.r * c.a + base.r * (1 - c.a), g: c.g * c.a + base.g * (1 - c.a), b: c.b * c.a + base.b * (1 - c.a)))
  }

  private static func rgb(ofHex value: String) -> ThemeRGB {
    let parsed = parseColor(M.hex(value) ?? value)
    return parsed.map { ThemeRGB(r: $0.r, g: $0.g, b: $0.b) } ?? ThemeRGB(r: 0, g: 0, b: 0)
  }

  /// A VS Code theme is recognised by its dotted workbench color keys, which T3 Code's own files never use.
  public static func isVSCodeTheme(_ value: Any) -> Bool {
    guard let object = value as? [String: Any] else { return false }
    if object["version"] as? Int == ThemeFile.version { return false }
    let hasWorkbench = (object["colors"] as? [String: Any])?.keys.contains { $0.contains(".") } ?? false
    return hasWorkbench || object["tokenColors"] is [Any]
  }

  /// Extension `name` fields are often package slugs; read them as words.
  public static func humanizeName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "-_.")) == nil { return trimmed }
    return trimmed.split(whereSeparator: { "-_.".contains($0) }).map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
  }

  private static func resolveName(_ value: [String: Any]) -> String {
    for candidate in [value["displayName"], value["name"]] {
      guard let text = candidate as? String else { continue }
      let humanized = humanizeName(text)
      if !humanized.isEmpty { return String(humanized.prefix(48)) }
    }
    return "VS Code theme"
  }

  public static func parse(_ value: Any) throws -> ThemeDefinition {
    guard let object = value as? [String: Any] else { throw ThemeError("Theme files must contain a JSON object.") }
    let colors = object["colors"] as? [String: Any] ?? [:]
    func pick(_ keys: String...) -> RGBA? { keys.lazy.compactMap { parseColor(colors[$0]) }.first }
    func solidOver(_ base: ThemeRGB, _ keys: String...) -> String? {
      keys.lazy.compactMap { parseColor(colors[$0]) }.first.map { flatten($0, over: base) }
    }

    guard let canvasColor = pick("editor.background", "editorPane.background") else {
      throw ThemeError("That VS Code theme has no \"editor.background\" color, so there is nothing to build a palette from.")
    }
    let canvas = ThemeRGB(r: canvasColor.r, g: canvasColor.g, b: canvasColor.b)
    let appearance: ThemeAppearance
    switch (object["type"] as? String)?.lowercased() {
    case "light", "hc-light": appearance = .light
    case "dark", "hc-black": appearance = .dark
    default: appearance = M.luminance(canvas) < 0.179 ? .dark : .light
    }

    let accentColor = pick("focusBorder", "button.background", "textLink.foreground", "activityBarBadge.background", "progressBar.background", "badge.background")
    let canvasHex = hex(canvas)
    let accentHex = accentColor.map { flatten($0, over: canvas) }
    // The derived palette is the floor, built from a muted accent: the vivid engine carries the accent hue into every surface,
    // which would wash an imported neutral palette.
    let mutedAccentHex = accentColor.map { flatten(RGBA(r: $0.r, g: $0.g, b: $0.b, a: 0.2), over: canvas) }
    let derived = ThemePalette.vivid(appearance, background: canvasHex, accent: mutedAccentHex ?? canvasHex)
    let sidebarHex = solidOver(canvas, "sideBar.background", "activityBar.background") ?? derived[.sidebar]
    let sidebar = rgb(ofHex: sidebarHex)
    let terminalHex = solidOver(canvas, "terminal.background", "panel.background") ?? derived[.terminalBackground]
    let terminal = rgb(ofHex: terminalHex)

    /// Foregrounds only win when they stay readable on the surface they land on.
    func readableOn(_ surface: String, fallback: String, _ keys: String...) -> String {
      let surfaceRgb = rgb(ofHex: surface)
      func isReadable(_ candidate: String) -> Bool { M.contrastRatio(rgb(ofHex: candidate), surfaceRgb) >= 4.5 }
      if let specified = keys.lazy.compactMap({ parseColor(colors[$0]) }).first.map({ flatten($0, over: surfaceRgb) }), isReadable(specified) { return specified }
      if isReadable(fallback) { return fallback }
      return M.luminance(surfaceRgb) < 0.179 ? "#ffffff" : "#000000"
    }

    var o: [ThemeRole: String] = [
      .canvas: canvasHex,
      .text: readableOn(canvasHex, fallback: derived[.text], "editor.foreground", "foreground"),
      .textMuted: readableOn(canvasHex, fallback: derived[.textMuted], "descriptionForeground", "disabledForeground"),
      .surface: solidOver(canvas, "editorWidget.background") ?? derived[.surface],
      .surfaceRaised: solidOver(canvas, "editorWidget.background", "dropdown.background") ?? derived[.surfaceRaised],
      .surfaceOverlay: solidOver(canvas, "menu.background", "quickInput.background", "dropdown.background") ?? derived[.surfaceOverlay],
      .border: solidOver(canvas, "panel.border", "editorGroup.border", "contrastBorder") ?? derived[.border],
      .input: solidOver(canvas, "input.border", "dropdown.border") ?? derived[.input],
      .placeholder: readableOn(canvasHex, fallback: derived[.placeholder], "input.placeholderForeground"),
      .error: readableOn(canvasHex, fallback: derived[.error], "editorError.foreground", "errorForeground"),
      .warning: readableOn(canvasHex, fallback: derived[.warning], "editorWarning.foreground"),
      .accentSurface: solidOver(canvas, "list.activeSelectionBackground", "list.hoverBackground") ?? derived[.accentSurface],
      .codeBackground: solidOver(canvas, "textCodeBlock.background") ?? derived[.codeBackground],
      .sidebar: sidebarHex,
      .sidebarForeground: readableOn(sidebarHex, fallback: derived[.sidebarForeground], "sideBar.foreground"),
      .sidebarBorder: solidOver(sidebar, "sideBar.border") ?? derived[.sidebarBorder],
      .sidebarRowHover: solidOver(sidebar, "list.hoverBackground") ?? derived[.sidebarRowHover],
      .sidebarRowActive: solidOver(sidebar, "list.inactiveSelectionBackground", "list.hoverBackground") ?? derived[.sidebarRowActive],
      .sidebarRowSelected: solidOver(sidebar, "list.activeSelectionBackground") ?? derived[.sidebarRowSelected],
      .terminalBackground: terminalHex,
      .terminalForeground: readableOn(terminalHex, fallback: derived[.terminalForeground], "terminal.foreground"),
      .terminalCursor: solidOver(terminal, "terminalCursor.foreground", "editorCursor.foreground") ?? derived[.terminalCursor],
      .terminalSelection: solidOver(terminal, "terminal.selectionBackground", "editor.selectionBackground") ?? derived[.terminalSelection],
      .terminalScrollbar: solidOver(terminal, "scrollbarSlider.background") ?? derived[.terminalScrollbar],
    ]
    if let accentHex {
      o[.accent] = accentHex
      o[.focus] = accentHex
      // The button pair is the closest thing VS Code has to the action color.
      let actionHex = solidOver(canvas, "button.background") ?? accentHex
      o[.messageAction] = actionHex
      o[.messageActionForeground] = readableOn(actionHex, fallback: derived[.messageActionForeground], "button.foreground")
      o[.accentForeground] = readableOn(accentHex, fallback: derived[.accentForeground], "button.foreground")
    }
    // Reuse the theme-file parser so ids, names and color values go through the same validation as a hand-written file.
    return try ThemeFile.make(name: resolveName(object), appearance: appearance, colors: ThemeColors(o, over: derived))
  }

  // MARK: Batches

  /// A light and a dark file whose names differ only by the appearance word become one dual-mode theme.
  public static func pair(_ themes: [ThemeDefinition], pairedId: ((ThemeDefinition, ThemeDefinition) -> String)? = nil) -> [ThemeDefinition] {
    func strip(_ label: String) -> String {
      label.replacingOccurrences(of: #"\b(?:light|dark)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    struct Group { var light: [ThemeDefinition] = [], dark: [ThemeDefinition] = [], order: Int }
    var groups: [String: Group] = [:]
    var groupKeys: [String] = []
    var passthrough: [(theme: ThemeDefinition, order: Int)] = []
    for (order, theme) in themes.enumerated() {
      let key = strip(theme.label)
      if theme.modes.count != 1 || key == theme.label || key.isEmpty {
        passthrough.append((theme, order))
        continue
      }
      if groups[key] == nil {
        groups[key] = Group(order: order)
        groupKeys.append(key)
      }
      if theme.appearance == .light { groups[key]!.light.append(theme) } else { groups[key]!.dark.append(theme) }
    }
    var paired: [(theme: ThemeDefinition, order: Int)] = []
    for key in groupKeys {
      let group = groups[key]!
      if group.light.count == 1, group.dark.count == 1,
        let merged = try? ThemeFile.make(
          id: pairedId?(group.light[0], group.dark[0]), name: key, appearance: .light, colors: group.light[0].colors,
          variants: [.dark: group.dark[0].colors])
      {
        paired.append((merged, group.order))
        continue
      }
      for theme in group.light + group.dark { paired.append((theme, group.order)) }
    }
    let all = (passthrough + paired).enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
    return all.map(\.element.theme)
  }

  /// Extensions often reuse one display name across every file (Dracula and Dracula Soft both say "Dracula"). When a batch
  /// carries the same id twice, colliding entries are relabelled from their file name, then numbered.
  public static func resolveLabelCollisions(_ entries: [(theme: ThemeDefinition, sourceName: String?)]) -> [ThemeDefinition] {
    func rename(_ theme: ThemeDefinition, _ name: String) -> ThemeDefinition? {
      try? ThemeFile.make(name: String(name.prefix(48)), appearance: theme.appearance, colors: theme.colors, variants: theme.variants, managed: theme.managed)
    }
    var counts: [String: Int] = [:]
    for entry in entries { counts[entry.theme.id, default: 0] += 1 }
    let relabelled = entries.map { entry -> ThemeDefinition in
      let theme = entry.theme
      guard (counts[theme.id] ?? 0) >= 2 else { return theme }
      let stem = entry.sourceName.map { ($0 as NSString).deletingPathExtension }
      let fromFile = stem.map(humanizeName)
      if let fromFile, fromFile.lowercased() != theme.label.lowercased(), let renamed = rename(theme, fromFile) { return renamed }
      return theme
    }
    var seen = Set<String>()
    return relabelled.map { theme in
      if seen.insert(theme.id).inserted { return theme }
      for suffix in 2..<100 {
        if let candidate = rename(theme, "\(theme.label) \(suffix)"), !seen.contains(candidate.id) {
          seen.insert(candidate.id)
          return candidate
        }
      }
      return theme
    }
  }
}

extension ThemeFile {
  /// A definition built from palettes already in hand, routed through `parse` so it gets the same validation as a file.
  public static func make(
    id: String? = nil, name: String, appearance: ThemeAppearance, colors: ThemeColors, variants: [ThemeAppearance: ThemeColors] = [:],
    managed: Bool = false
  ) throws -> ThemeDefinition {
    func table(_ palette: ThemeColors) -> [String: Any] { Dictionary(uniqueKeysWithValues: ThemeRole.allCases.map { ($0.rawValue, palette[$0]) }) }
    var object: [String: Any] = ["version": version, "name": name, "appearance": appearance.rawValue, "colors": table(colors)]
    if let id { object["id"] = id }
    if !variants.isEmpty { object["variants"] = Dictionary(uniqueKeysWithValues: variants.map { ($0.key.rawValue, table($0.value)) }) }
    if managed { object["managed"] = true }
    return try parse(object)
  }
}
