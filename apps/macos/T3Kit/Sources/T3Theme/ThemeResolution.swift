import Foundation

public enum ThemeMode: String, Sendable, Codable, CaseIterable, Hashable {
  case system, light, dark
}

/// What the user picked: the appearance mode plus one theme per appearance (nil is the standard T3 Code look). The web's
/// "halves"; picking a whole theme sets both.
public struct ThemePreference: Sendable, Codable, Hashable {
  public var mode: ThemeMode = .system
  public var light: String?
  public var dark: String?
  public init(mode: ThemeMode = .system, light: String? = nil, dark: String? = nil) { (self.mode, self.light, self.dark) = (mode, light, dark) }

  public func owner(of appearance: ThemeAppearance) -> String? { appearance == .light ? light : dark }

  public mutating func setOwner(_ id: String?, of appearance: ThemeAppearance) {
    if appearance == .light { light = id } else { dark = id }
  }
}

/// The palette the app wears right now.
public struct ResolvedTheme: Sendable, Hashable {
  public var appearance: ThemeAppearance
  /// Nil for the standard T3 Code look.
  public var themeId: String?
  public var colors: ThemeColors
  public var sidebarArtwork: Bool
  public var isStandard: Bool { themeId == nil }

  public init(appearance: ThemeAppearance, themeId: String?, colors: ThemeColors, sidebarArtwork: Bool) {
    (self.appearance, self.themeId, self.colors, self.sidebarArtwork) = (appearance, themeId, colors, sidebarArtwork)
  }
}

public enum ThemeResolver {
  /// Built-ins win over saved themes, which win over themes the environment publishes (`getThemeDefinition`).
  public static func definition(_ id: String, library: [ThemeDefinition]) -> ThemeDefinition? {
    let id = ThemeIds.normalize(id)
    return library.first { $0.id == id }
  }

  public static func resolve(_ preference: ThemePreference, systemDark: Bool, library: [ThemeDefinition], contrast: Int = 100) -> ResolvedTheme {
    var appearance: ThemeAppearance = preference.mode == .dark || (preference.mode == .system && systemDark) ? .dark : .light
    let definition = preference.owner(of: appearance).flatMap { Self.definition($0, library: library) }
    var colors: ThemeColors
    if let definition {
      if let half = definition.colors(for: appearance) {
        colors = half
      } else {
        // A single-appearance theme renders its own half whatever was asked for.
        appearance = definition.appearance
        colors = definition.colors
      }
    } else {
      colors = ThemePalette.standardColors(appearance)
    }
    colors = ThemeFile.canonicalized(colors)
    if contrast != 100 { colors = ThemeContrast.apply(colors, percent: contrast, appearance: appearance) }
    return ResolvedTheme(appearance: appearance, themeId: definition?.id, colors: colors, sidebarArtwork: definition?.sidebarArtwork ?? false)
  }
}

/// The Contrast slider (50...200): foregrounds mix toward their surface below 100 and toward black/white above it, borders gain
/// or lose strength. Mirrors the `--contrast-*` custom properties in `apps/web/src/index.css`.
public enum ThemeContrast {
  private static let foregrounds: [(ThemeRole, ThemeRole)] = [
    (.text, .canvas), (.textMuted, .canvas), (.mutedForeground, .canvas), (.placeholder, .canvas), (.secondaryLabel, .canvas),
    (.iconMuted, .canvas), (.toolbarForeground, .toolbar), (.toolbarControlForeground, .toolbarControl), (.sidebarForeground, .sidebar),
    (.sidebarMutedForeground, .sidebar), (.messageForeground, .messageSurface), (.codeForeground, .codeBackground),
    (.accentSurfaceForeground, .accentSurface), (.secondaryForeground, .secondary),
  ]
  private static let borders: [(ThemeRole, ThemeRole)] = [(.border, .text), (.input, .text), (.toolbarBorder, .toolbarForeground), (.sidebarBorder, .text)]

  private struct Lab { var l: Double, a: Double, b: Double }

  private static func lab(_ c: ThemeRGB) -> Lab {
    let o = ThemeColorMath.toOKLCH(c)
    let h = o.h * .pi / 180
    return Lab(l: o.L, a: o.C * cos(h), b: o.C * sin(h))
  }

  private static func mixLab(_ a: ThemeRGB, _ b: ThemeRGB, weightOfB: Double) -> ThemeRGB {
    let x = lab(a), y = lab(b)
    let l = x.l + (y.l - x.l) * weightOfB, aa = x.a + (y.a - x.a) * weightOfB, bb = x.b + (y.b - x.b) * weightOfB
    return ThemeColorMath.toRGB(ThemeOKLCH(L: l, C: hypot(aa, bb), h: atan2(bb, aa) * 180 / .pi))
  }

  public static func apply(_ colors: ThemeColors, percent: Int, appearance: ThemeAppearance) -> ThemeColors {
    let base = Double(min(percent, 100)) / 100
    let boost = Double(max(percent - 100, 0)) / 100
    let borderBoost = boost / 4
    let target = appearance == .dark ? ThemeColorMath.white : ThemeColorMath.black
    func rgb(_ role: ThemeRole) -> ThemeRGB { ThemeColorMath.rgb(colors[role], fallback: ThemeColorMath.black) }
    var next = colors
    for (role, surface) in foregrounds {
      let mixed = mixLab(rgb(surface), rgb(role), weightOfB: base)
      next[role] = ThemeColorMath.themeColor(boost > 0 ? mixLab(mixed, target, weightOfB: boost) : mixed)
    }
    for (role, foreground) in borders {
      // color-mix in srgb of (border at `base` alpha) and (foreground), premultiplied.
      let c = rgb(role), f = rgb(foreground)
      let alpha = (1 - borderBoost) * base + borderBoost
      guard alpha > 0 else { continue }
      let premultiplied = ThemeRGB(
        r: (1 - borderBoost) * base * c.r + borderBoost * f.r, g: (1 - borderBoost) * base * c.g + borderBoost * f.g,
        b: (1 - borderBoost) * base * c.b + borderBoost * f.b)
      let out = ThemeRGB(r: premultiplied.r / alpha, g: premultiplied.g / alpha, b: premultiplied.b / alpha)
      next[role] = ThemeColorMath.format(ThemeColorMath.toOKLCH(out), alpha: alpha)
    }
    return next
  }
}
