import Foundation

/// Palette derivation: the "vivid" engine behind user-created themes (two seed colors to a full, contrast-solved palette) and
/// the editor's family updates. A port of `createVividThemeColors` / `updateThemeColorFamily` in `apps/web/src/themePalette.ts`.
public enum ThemePalette {
  typealias M = ThemeColorMath

  /// Theme-file defaults follow the flagship (T3 Chat) palette for the requested mode.
  public static func defaultColors(_ appearance: ThemeAppearance) -> ThemeColors {
    appearance == .dark ? ThemeDefinition.t3Chat.variants[.dark]! : ThemeDefinition.t3Chat.colors
  }

  /// The standard T3 Code look as a palette (canonical colors), for seeding a draft when no theme is installed.
  public static func standardColors(_ appearance: ThemeAppearance) -> ThemeColors {
    ThemeFile.canonicalized(appearance == .dark ? ThemeDefinition.standardDarkColors : ThemeDefinition.standardLightColors)
  }

  private static let standardStatus: [ThemeAppearance: (error: String, errorForeground: String, warning: String, warningForeground: String)] = [
    .light: ("#fb2c36", "#c10007", "#fe9a00", "#bb4d00"),
    .dark: ("#fb414a", "#ff6467", "#fe9a00", "#ffb900"),
  ]

  /// The standard signal colors laid over the theme's canvas, so alerts sit on the palette while the signal stays standard.
  static func standardStatusColors(canvas: ThemeRGB) -> [ThemeRole: String] {
    let appearance: ThemeAppearance = M.luminance(canvas) < 0.179 ? .dark : .light
    let standard = standardStatus[appearance]!
    let surfaceMix = appearance == .dark ? 0.16 : 0.08
    func surface(of value: String) -> ThemeRGB { M.mix(canvas, M.rgb(value, fallback: canvas), surfaceMix) }
    func readable(_ foreground: String, on surface: ThemeRGB) -> String {
      M.themeColor(
        M.solveLightness(
          M.toOKLCH(M.rgb(foreground, fallback: canvas)), against: surface, minContrast: 4.6, direction: appearance == .dark ? .lighter : .darker))
    }
    let errorSurface = surface(of: standard.error), warningSurface = surface(of: standard.warning)
    return [
      .error: M.canonical(standard.error)!,
      .errorForeground: readable(standard.errorForeground, on: errorSurface),
      .errorSurface: M.themeColor(errorSurface),
      .warning: M.canonical(standard.warning)!,
      .warningForeground: readable(standard.warningForeground, on: warningSurface),
      .warningSurface: M.themeColor(warningSurface),
    ]
  }

  /// Two exact seed colors to a full palette, in OKLCH. Surfaces climb a perceptually even lightness ramp carrying the accent
  /// hue at low chroma, a companion action color rotates off the accent, and every foreground is contrast-solved.
  public static func vivid(_ appearance: ThemeAppearance, background: String, accent accentValue: String) -> ThemeColors {
    let defaults = defaultColors(appearance)
    let canvasRgb = M.rgb(background, fallback: appearance == .dark ? ThemeRGB(r: 24, g: 15, b: 27) : ThemeRGB(r: 250, g: 245, b: 250))
    let accentRgb = M.rgb(accentValue, fallback: ThemeRGB(r: 168, g: 67, b: 112))
    let canvas = M.toOKLCH(canvasRgb), accent = M.toOKLCH(accentRgb)
    // The ramp and every contrast search follow the canvas the user picked, not the appearance slot.
    let dark = M.luminance(canvasRgb) < 0.179
    let hue = accent.C < 0.02 ? canvas.h : accent.h
    let tintC = min(0.045, max(0.008, accent.C * 0.22))
    let step = dark ? 1.0 : -1.0

    func surfaceAt(_ deltaL: Double, _ chroma: Double? = nil) -> ThemeOKLCH {
      ThemeOKLCH(L: min(0.98, max(0.05, canvas.L + step * deltaL)), C: chroma ?? tintC, h: hue)
    }
    func color(_ c: ThemeOKLCH) -> String { M.themeColor(c) }
    func pick(_ lightValue: Double, _ darkValue: Double) -> Double { dark ? darkValue : lightValue }

    let textBase = ThemeOKLCH(L: dark ? 0.95 : 0.2, C: min(0.035, accent.C * 0.25), h: hue)
    let text = M.solveLightness(textBase, against: canvasRgb, minContrast: 7, direction: dark ? .lighter : .darker)
    let textRgb = M.toRGB(text)
    let textMutedRgb = M.standardMutedText(on: canvasRgb, foreground: textRgb)

    let action = ThemeOKLCH(
      L: min(0.85, max(0.35, accent.L + (dark ? 0.06 : -0.02))), C: max(accent.C * 0.9, 0.06), h: (hue + 50).truncatingRemainder(dividingBy: 360))
    let actionRgb = M.toRGB(action)
    let actionForeground = M.readableForeground(on: actionRgb)
    let accentForeground = M.readableForeground(on: accentRgb)

    let sidebar = surfaceAt(0.045, tintC * 1.4)
    let sidebarRgb = M.toRGB(sidebar)
    let surface = surfaceAt(0.015)
    let surfaceRaised = surfaceAt(0.05)
    let surfaceRaisedRgb = M.toRGB(surfaceRaised)
    let surfaceOverlay = surfaceAt(0.075)
    let border = surfaceAt(pick(0.12, 0.16), min(0.07, accent.C * 0.35))
    let input = surfaceAt(pick(0.16, 0.21), min(0.08, accent.C * 0.4))
    let secondary = surfaceAt(pick(0.06, 0.1), min(0.09, accent.C * 0.5))
    let secondaryRgb = M.toRGB(secondary)
    let muted = surfaceAt(pick(0.04, 0.06), min(0.06, accent.C * 0.35))
    let mutedRgb = M.toRGB(muted)
    let accentSurface = surfaceAt(pick(0.08, 0.13), min(0.11, accent.C * 0.55))
    let accentSurfaceRgb = M.toRGB(accentSurface)
    let messageSurface = surfaceAt(pick(0.1, 0.16), min(0.13, accent.C * 0.6))
    let messageSurfaceRgb = M.toRGB(messageSurface)
    let codeBackground = surfaceAt(0.035, tintC * 0.8)
    let updateSurface = surfaceAt(pick(0.09, 0.14), min(0.12, accent.C * 0.55))

    func foregroundOn(_ surfaceRgb: ThemeRGB) -> String {
      M.themeColor(M.solveLightness(textBase, against: surfaceRgb, minContrast: 4.6, direction: dark ? .lighter : .darker))
    }
    let mutedForeground = M.themeColor(M.readableText(on: mutedRgb, foreground: textRgb, amount: 1, minimumRatio: 4.6))
    let placeholder = M.themeColor(M.readableText(on: surfaceRaisedRgb, foreground: textRgb, amount: 1, minimumRatio: 4.6))
    var actionHover = action
    actionHover.L = action.L + (dark ? 0.06 : -0.06)

    var colors = defaults.values
    colors.merge(standardStatusColors(canvas: canvasRgb)) { _, new in new }
    let canvasColor = M.themeColor(canvasRgb), textColor = M.themeColor(textRgb), accentColor = M.themeColor(accentRgb)
    let mutedTextColor = M.themeColor(textMutedRgb)
    let derived: [ThemeRole: String] = [
      .canvas: canvasColor,
      .chrome: canvasColor,
      .toolbar: canvasColor,
      .toolbarForeground: textColor,
      .toolbarBorder: color(surfaceAt(pick(0.1, 0.14), min(0.08, accent.C * 0.4))),
      .toolbarControl: color(surfaceAt(pick(0.05, 0.09), tintC * 1.3)),
      .toolbarControlForeground: textColor,
      .toolbarControlHover: color(surfaceAt(pick(0.09, 0.14), tintC * 1.6)),
      .surface: color(surface),
      .surfaceRaised: color(surfaceRaised),
      .surfaceOverlay: color(surfaceOverlay),
      .text: textColor,
      .textMuted: mutedTextColor,
      .border: color(border),
      .input: color(input),
      .focus: accentColor,
      .accent: accentColor,
      .accentForeground: M.themeColor(accentForeground),
      .secondary: color(secondary),
      .secondaryForeground: foregroundOn(secondaryRgb),
      .muted: color(muted),
      .mutedForeground: mutedForeground,
      .placeholder: placeholder,
      .secondaryLabel: mutedTextColor,
      .iconMuted: mutedTextColor,
      .update: accentColor,
      .updateForeground: foregroundOn(M.toRGB(updateSurface)),
      .updateSurface: color(updateSurface),
      .accentSurface: color(accentSurface),
      .accentSurfaceForeground: foregroundOn(accentSurfaceRgb),
      .messageSurface: color(messageSurface),
      .messageForeground: foregroundOn(messageSurfaceRgb),
      .messageAction: M.themeColor(actionRgb),
      .messageActionForeground: M.themeColor(actionForeground),
      .messageActionHover: color(actionHover),
      .codeBackground: color(codeBackground),
      .codeForeground: textColor,
      .sidebar: color(sidebar),
      .sidebarForeground: foregroundOn(sidebarRgb),
      .sidebarMutedForeground: M.themeColor(M.standardMutedText(on: sidebarRgb, foreground: textRgb)),
      .sidebarControlSurface: color(surfaceAt(pick(0.07, 0.1), tintC * 1.5)),
      .sidebarRowHover: color(surfaceAt(pick(0.06, 0.08), min(0.08, accent.C * 0.45))),
      .sidebarRowActive: color(surfaceAt(pick(0.09, 0.12), min(0.1, accent.C * 0.55))),
      .sidebarRowSelected: color(surfaceAt(pick(0.1, 0.14), min(0.11, accent.C * 0.6))),
      .sidebarBorder: color(surfaceAt(pick(0.12, 0.17), min(0.08, accent.C * 0.4))),
      .terminalBackground: canvasColor,
      .terminalForeground: textColor,
      .terminalCursor: accentColor,
      .terminalSelection: color(surfaceAt(pick(0.12, 0.18), min(0.12, accent.C * 0.55))),
      .terminalScrollbar: color(surfaceAt(pick(0.16, 0.22), tintC)),
      .terminalScrollbarHover: color(surfaceAt(pick(0.22, 0.3), tintC)),
    ]
    colors.merge(derived) { _, new in new }
    return ThemeColors(colors, over: defaults)
  }

  /// Update one Advanced-editor color family without normalizing the rest of an imported or hand-tuned palette: paired
  /// foregrounds and nearby states are derived only when the family's representative role changes.
  public static func updateFamily(_ appearance: ThemeAppearance, _ colors: ThemeColors, role: ThemeRole, value: String) -> ThemeColors {
    guard let parsedSelected = M.parse(value) else {
      var unchanged = colors
      unchanged[role] = value
      return unchanged
    }
    let normalized = M.format(parsedSelected.color, alpha: parsedSelected.alpha)
    let canvas = M.rgb(colors[.canvas], fallback: appearance == .dark ? ThemeRGB(r: 24, g: 15, b: 27) : ThemeRGB(r: 250, g: 245, b: 250))
    let selected = M.toRGB(parsedSelected.color)
    func selectedOn(_ background: ThemeRGB) -> ThemeRGB { M.mix(background, selected, parsedSelected.alpha) }
    let selectedOnCanvas = selectedOn(canvas)
    let accent = M.rgb(colors[.accent], fallback: ThemeRGB(r: 168, g: 67, b: 112))
    let canvasIsDark = M.luminance(canvas) < 0.179
    let terminalIsDark = M.luminance(selectedOnCanvas) < 0.179
    func colorOf(_ c: ThemeRGB) -> String { M.themeColor(c) }
    func foregroundOn(_ background: ThemeRGB) -> String { colorOf(M.readableForeground(on: background)) }
    func selectedTone(on background: ThemeRGB) -> String {
      M.themeColor(
        M.solveLightness(parsedSelected.color, against: background, minContrast: 4.6, direction: M.luminance(background) < 0.179 ? .lighter : .darker))
    }
    func status() -> (foreground: String, surface: String) {
      let surface = M.mix(canvas, selectedOnCanvas, canvasIsDark ? 0.16 : 0.08)
      return (selectedTone(on: surface), colorOf(surface))
    }

    var next = colors
    func set(_ roles: [ThemeRole], _ color: String) { for role in roles { next[role] = color } }
    switch role {
    case .canvas: set([.canvas, .chrome, .toolbar], normalized)
    case .surface, .surfaceRaised, .surfaceOverlay, .input, .sidebarControlSurface: next[role] = normalized
    case .text: set([.text, .toolbarForeground, .toolbarControlForeground], normalized)
    case .mutedForeground: set([.textMuted, .mutedForeground, .placeholder, .secondaryLabel, .iconMuted, .sidebarMutedForeground], normalized)
    case .border: set([.border, .toolbarBorder, .sidebarBorder], normalized)
    case .secondary:
      set([.secondary, .muted, .toolbarControl], normalized)
      next[.secondaryForeground] = foregroundOn(selectedOnCanvas)
    case .accentSurface:
      set([.accentSurface, .toolbarControlHover], normalized)
      next[.accentSurfaceForeground] = foregroundOn(selectedOnCanvas)
    case .accent:
      let updateSurface = M.mix(canvas, selectedOnCanvas, canvasIsDark ? 0.32 : 0.16)
      set([.accent, .focus, .update, .terminalCursor], normalized)
      next[.accentForeground] = foregroundOn(selectedOnCanvas)
      next[.updateForeground] = selectedTone(on: updateSurface)
      next[.updateSurface] = colorOf(updateSurface)
    case .messageAction:
      let actionForeground = M.readableForeground(on: selectedOnCanvas)
      let towardOpposite = (actionForeground == M.lightForeground || actionForeground == M.white) ? M.black : M.white
      let actionHover = M.mix(selected, towardOpposite, 0.12)
      next[.messageAction] = normalized
      next[.messageActionForeground] = colorOf(actionForeground)
      next[.messageActionHover] = M.format(M.toOKLCH(actionHover), alpha: parsedSelected.alpha)
    case .messageSurface:
      next[.messageSurface] = normalized
      next[.messageForeground] = foregroundOn(selectedOnCanvas)
    case .codeBackground:
      next[.codeBackground] = normalized
      next[.codeForeground] = foregroundOn(selectedOnCanvas)
    case .sidebar:
      next[.sidebar] = normalized
      next[.sidebarForeground] = foregroundOn(selectedOnCanvas)
    case .sidebarRowSelected:
      let sidebar = M.rgb(colors[.sidebar], fallback: canvas)
      let onSidebar = selectedOn(sidebar)
      next[.sidebarRowHover] = colorOf(M.mix(sidebar, onSidebar, 0.5))
      next[.sidebarRowActive] = colorOf(M.mix(sidebar, onSidebar, 0.8))
      next[.sidebarRowSelected] = normalized
    case .terminalBackground:
      let foreground = M.readableForeground(on: selectedOnCanvas)
      next[.terminalBackground] = normalized
      next[.terminalForeground] = colorOf(foreground)
      next[.terminalSelection] = colorOf(M.mix(selectedOnCanvas, accent, terminalIsDark ? 0.35 : 0.18))
      next[.terminalScrollbar] = colorOf(M.mix(selectedOnCanvas, foreground, terminalIsDark ? 0.42 : 0.22))
      next[.terminalScrollbarHover] = colorOf(M.mix(selectedOnCanvas, foreground, terminalIsDark ? 0.55 : 0.32))
    case .error:
      let s = status()
      next[.error] = normalized
      next[.errorForeground] = s.foreground
      next[.errorSurface] = s.surface
    case .warning:
      let s = status()
      next[.warning] = normalized
      next[.warningForeground] = s.foreground
      next[.warningSurface] = s.surface
    default: next[role] = normalized
    }
    return next
  }
}
