import Foundation

/// sRGB channels in 0...255 (fractional while mixing), as `ThemeRgbColor` in `apps/web/src/themePalette.ts`.
public struct ThemeRGB: Sendable, Hashable {
  public var r: Double, g: Double, b: Double
  public init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }
}

public struct ThemeOKLCH: Sendable, Hashable {
  public var L: Double, C: Double, h: Double
  public init(L: Double, C: Double, h: Double) { (self.L, self.C, self.h) = (L, C, h) }
}

public struct ParsedThemeColor: Sendable, Hashable {
  public var color: ThemeOKLCH
  public var alpha: Double
}

/// Color parsing, conversion and contrast math shared by the palette derivation, the codec and the VS Code importer.
/// A port of the helpers in `themePalette.ts`; CSS parsing follows culori (what the web uses) for the notations a theme file
/// can carry: hex, `rgb()`, `hsl()`, `oklch()`, `oklab()`, `black`, `white`, `transparent`.
public enum ThemeColorMath {
  // MARK: Parsing

  /// `parseThemeColor`: any literal CSS color to clamped OKLCH plus alpha, nil when it is not one.
  public static func parse(_ value: String) -> ParsedThemeColor? {
    let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = parseCSS(input) else { return nil }
    let alpha = input.range(of: #"/\s*none\s*\)$"#, options: [.regularExpression, .caseInsensitive]) != nil ? 0 : parsed.alpha
    guard [parsed.L, parsed.C, parsed.h, alpha].allSatisfy(\.isFinite) else { return nil }
    return ParsedThemeColor(
      color: ThemeOKLCH(L: min(1, max(0, parsed.L)), C: max(0, parsed.C), h: parsed.h), alpha: min(1, max(0, alpha)))
  }

  private static func parseCSS(_ input: String) -> (L: Double, C: Double, h: Double, alpha: Double)? {
    let lower = input.lowercased()
    // ponytail: only the three names a theme tool is likely to emit; add the CSS table if one turns up.
    switch lower {
    case "transparent": return fromRGB(0, 0, 0, alpha: 0)
    case "black": return fromRGB(0, 0, 0, alpha: 1)
    case "white": return fromRGB(1, 1, 1, alpha: 1)
    default: break
    }
    if let hex = parseHex(lower) { return fromRGB(hex.r, hex.g, hex.b, alpha: hex.a) }
    guard let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
    let name = String(lower[..<open]).trimmingCharacters(in: .whitespaces)
    let body = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
    let slash = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    var parts = slash[0].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    var alphaToken: String? = slash.count > 1 ? slash[1].trimmingCharacters(in: .whitespaces) : nil
    if alphaToken == nil, parts.count == 4 { alphaToken = parts.removeLast() }
    guard parts.count == 3 else { return nil }
    var alpha = 1.0
    if let alphaToken {
      guard let a = number(alphaToken, percentScale: 1) else { return nil }
      alpha = min(1, max(0, a))
    }
    switch name {
    case "rgb", "rgba":
      guard let r = rgbChannel(parts[0]), let g = rgbChannel(parts[1]), let b = rgbChannel(parts[2]) else { return nil }
      return fromRGB(r, g, b, alpha: alpha)
    case "hsl", "hsla":
      guard let h = hue(parts[0]), let s = number(parts[1], percentScale: 1), let l = number(parts[2], percentScale: 1) else { return nil }
      let s01 = parts[1].hasSuffix("%") ? s : s / 100, l01 = parts[2].hasSuffix("%") ? l : l / 100
      let rgb = hslToRGB(h: h, s: s01, l: l01)
      return fromRGB(rgb.0, rgb.1, rgb.2, alpha: alpha)
    case "oklch":
      guard let L = number(parts[0], percentScale: 1), let C = number(parts[1], percentScale: 0.4), let h = hue(parts[2]) else { return nil }
      return (min(max(0, L), 1), max(0, C), h, alpha)
    case "oklab":
      guard let L = number(parts[0], percentScale: 1), let a = number(parts[1], percentScale: 0.4), let b = number(parts[2], percentScale: 0.4)
      else { return nil }
      let (c, h) = labToLch(a: a, b: b)
      return (min(max(0, L), 1), c, h, alpha)
    default:
      return nil
    }
  }

  private static func parseHex(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
    let digits = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
    let nibbles = digits.compactMap { Int(String($0), radix: 16) }
    func byte(_ i: Int) -> Double {
      digits.count <= 4 ? Double(nibbles[i] * 17) : Double(nibbles[2 * i] * 16 + nibbles[2 * i + 1])
    }
    let hasAlpha = digits.count == 4 || digits.count == 8
    return (byte(0) / 255, byte(1) / 255, byte(2) / 255, hasAlpha ? byte(3) / 255 : 1)
  }

  /// A number, or a percentage mapped to `percentScale` x value/100 (so `percentScale: 1` makes 50% = 0.5).
  private static func number(_ token: String, percentScale: Double) -> Double? {
    if token == "none" { return 0 }
    if token.hasSuffix("%") { return Double(token.dropLast()).map { $0 * percentScale / 100 } }
    return Double(token)
  }

  private static func rgbChannel(_ token: String) -> Double? {
    if token == "none" { return 0 }
    if token.hasSuffix("%") { return Double(token.dropLast()).map { $0 / 100 } }
    return Double(token).map { $0 / 255 }
  }

  private static func hue(_ token: String) -> Double? {
    if token == "none" { return 0 }
    for (unit, scale) in [("deg", 1.0), ("grad", 0.9), ("rad", 180 / Double.pi), ("turn", 360.0)] where token.hasSuffix(unit) {
      return Double(token.dropLast(unit.count)).map { $0 * scale }
    }
    return Double(token)
  }

  private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
    let hh = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    let m1 = l + s * (l < 0.5 ? l : 1 - l)
    let m2 = m1 - (m1 - l) * 2 * abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1)
    let m0 = 2 * l - m1
    switch Int(floor(hh / 60)) {
    case 0: return (m1, m2, m0)
    case 1: return (m2, m1, m0)
    case 2: return (m0, m1, m2)
    case 3: return (m0, m2, m1)
    case 4: return (m2, m0, m1)
    case 5: return (m1, m0, m2)
    default: return (m0, m0, m0)
    }
  }

  /// culori's matrices (more digits than the web's own palette math uses; the two differ below 1e-8).
  private static func fromRGB(_ r: Double, _ g: Double, _ b: Double, alpha: Double) -> (L: Double, C: Double, h: Double, alpha: Double) {
    func lin(_ c: Double) -> Double {
      let a = abs(c)
      return a <= 0.04045 ? c / 12.92 : (c < 0 ? -1 : 1) * pow((a + 0.055) / 1.055, 2.4)
    }
    let (lr, lg, lb) = (lin(r), lin(g), lin(b))
    let l = cbrt(0.412221469470763 * lr + 0.5363325372617348 * lg + 0.0514459932675022 * lb)
    let m = cbrt(0.2119034958178252 * lr + 0.6806995506452344 * lg + 0.1073969535369406 * lb)
    let s = cbrt(0.0883024591900564 * lr + 0.2817188391361215 * lg + 0.6299787016738222 * lb)
    let L = 0.210454268309314 * l + 0.7936177747023054 * m - 0.0040720430116193 * s
    let a = 1.9779985324311684 * l - 2.42859224204858 * m + 0.450593709617411 * s
    let bb = 0.0259040424655478 * l + 0.7827717124575296 * m - 0.8086757549230774 * s
    let (c, h) = labToLch(a: a, b: bb)
    return (L, c, h, alpha)
  }

  private static func labToLch(a: Double, b: Double) -> (Double, Double) {
    let c = (a * a + b * b).squareRoot()
    guard c != 0 else { return (0, 0) }
    let h = atan2(b, a) * 180 / .pi
    return (c, ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360))
  }

  // MARK: Formatting

  /// JS `Number.prototype.toFixed` (ties round away from zero, unlike printf's ties-to-even).
  static func toFixed(_ value: Double, _ digits: Int) -> String {
    let probe = String(format: "%.\(digits + 30)f", value)
    if let dot = probe.firstIndex(of: ".") {
      let tail = probe[probe.index(after: dot)...].dropFirst(digits)
      if tail.first == "5", tail.dropFirst().allSatisfy({ $0 == "0" }) {
        let nudged = value + (value < 0 ? -value.ulp : value.ulp)
        return String(format: "%.\(digits)f", nudged)
      }
    }
    return String(format: "%.\(digits)f", value)
  }

  /// `formatThemeColorNumber`: fixed precision with trailing zeros removed.
  static func formatNumber(_ value: Double, _ precision: Int) -> String {
    let rounded = abs(value) < pow(10, -Double(precision)) / 2 ? 0 : value
    var text = toFixed(rounded, precision)
    if text.contains(".") {
      while text.hasSuffix("0") { text.removeLast() }
      if text.hasSuffix(".") { text.removeLast() }
    }
    return text == "-0" ? "0" : text
  }

  /// `formatOklchThemeColor`: the canonical `oklch(L C h)` / `oklch(L C h / a)` string.
  public static func format(_ color: ThemeOKLCH, alpha: Double = 1) -> String {
    let hue = color.C < 0.0000005 ? 0 : ((color.h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    let body = "\(formatNumber(color.L, 6)) \(formatNumber(color.C, 6)) \(formatNumber(hue, 3))"
    return alpha < 1 ? "oklch(\(body) / \(formatNumber(alpha, 4)))" : "oklch(\(body))"
  }

  /// `toCanonicalThemeColor`.
  public static func canonical(_ value: String) -> String? {
    parse(value).map { format($0.color, alpha: $0.alpha) }
  }

  public static func isThemeColor(_ value: String) -> Bool { canonical(value) != nil }

  /// `themeColorToHex`: `#rrggbb`, or `#rrggbbaa` when translucent.
  public static func hex(_ value: String) -> String? {
    guard let parsed = parse(value) else { return nil }
    let opaque = hex(toRGB(parsed.color))
    if parsed.alpha >= 1 { return opaque }
    let alpha = Int((parsed.alpha * 255).rounded(.toNearestOrAwayFromZero))
    return opaque + String(format: "%02x", alpha)
  }

  public static func hex(_ color: ThemeRGB) -> String {
    "#" + [color.r, color.g, color.b].map { String(format: "%02x", Int(min(255, max(0, $0)).rounded(.toNearestOrAwayFromZero))) }.joined()
  }

  // MARK: sRGB / OKLCH

  static func srgbToLinear(_ channel: Double) -> Double {
    let c = channel / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  static func linearToSRGB(_ channel: Double) -> Double {
    let c = channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    return (min(1, max(0, c)) * 255).rounded(.toNearestOrAwayFromZero)
  }

  /// `themeRgbToOklch`.
  public static func toOKLCH(_ color: ThemeRGB) -> ThemeOKLCH {
    let r = srgbToLinear(color.r), g = srgbToLinear(color.g), b = srgbToLinear(color.b)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    let L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
    let a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
    let bb = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
    return ThemeOKLCH(L: L, C: hypot(a, bb), h: atan2(bb, a) * 180 / .pi)
  }

  static func toLinearUnclamped(_ c: ThemeOKLCH) -> (r: Double, g: Double, b: Double) {
    let hr = c.h * .pi / 180
    let a = c.C * cos(hr), bb = c.C * sin(hr)
    let l = pow(c.L + 0.3963377774 * a + 0.2158037573 * bb, 3)
    let m = pow(c.L - 0.1055613458 * a - 0.0638541728 * bb, 3)
    let s = pow(c.L - 0.0894841775 * a - 1.291485548 * bb, 3)
    return (
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
    )
  }

  /// `mapThemeOklchToSrgbGamut`: the greatest chroma at the same lightness and hue that fits sRGB.
  public static func gamutMapped(_ color: ThemeOKLCH) -> ThemeOKLCH {
    func inGamut(_ chroma: Double) -> Bool {
      var probe = color
      probe.C = chroma
      let linear = toLinearUnclamped(probe)
      return [linear.r, linear.g, linear.b].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }
    if inGamut(color.C) { return color }
    var low = 0.0, high = color.C
    let resolution = 0.000001
    let steps = max(1, Int(ceil(log2(max(color.C, resolution)) - log2(resolution))))
    for _ in 0..<steps {
      let mid = (low + high) / 2
      if inGamut(mid) { low = mid } else { high = mid }
    }
    var mapped = color
    mapped.C = low
    return mapped
  }

  /// `themeOklchToRgb`: gamut-mapped, rounded to 8-bit channels.
  public static func toRGB(_ color: ThemeOKLCH) -> ThemeRGB {
    let linear = toLinearUnclamped(gamutMapped(color))
    return ThemeRGB(r: linearToSRGB(linear.r), g: linearToSRGB(linear.g), b: linearToSRGB(linear.b))
  }

  /// Gamut-mapped sRGB components in 0...1 without 8-bit rounding, for painting.
  public static func srgbComponents(_ color: ThemeOKLCH) -> (r: Double, g: Double, b: Double) {
    func encode(_ c: Double) -> Double {
      let x = min(1, max(0, c))
      return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    let linear = toLinearUnclamped(gamutMapped(color))
    return (encode(linear.r), encode(linear.g), encode(linear.b))
  }

  /// `themeOklchToThemeColor`.
  public static func themeColor(_ color: ThemeOKLCH) -> String { format(gamutMapped(color)) }

  /// `themeRgbToThemeColor`.
  public static func themeColor(_ color: ThemeRGB) -> String { format(toOKLCH(color)) }

  /// `parseThemeRgbColor`: the color as 8-bit sRGB, or `fallback` when it does not parse.
  public static func rgb(_ value: String, fallback: ThemeRGB) -> ThemeRGB {
    parse(value).map { toRGB($0.color) } ?? fallback
  }

  // MARK: Contrast

  public static func mix(_ base: ThemeRGB, _ overlay: ThemeRGB, _ amount: Double) -> ThemeRGB {
    ThemeRGB(r: base.r + (overlay.r - base.r) * amount, g: base.g + (overlay.g - base.g) * amount, b: base.b + (overlay.b - base.b) * amount)
  }

  public static func luminance(_ color: ThemeRGB) -> Double {
    func lin(_ channel: Double) -> Double {
      let n = channel / 255
      return n <= 0.03928 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(color.r) + 0.7152 * lin(color.g) + 0.0722 * lin(color.b)
  }

  public static func contrastRatio(_ first: ThemeRGB, _ second: ThemeRGB) -> Double {
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  public enum Direction: Sendable { case lighter, darker }

  /// `solveOklchLightness`: binary-search the lightness that reaches the contrast target against a background.
  public static func solveLightness(_ base: ThemeOKLCH, against: ThemeRGB, minContrast: Double, direction: Direction) -> ThemeOKLCH {
    var low = direction == .lighter ? base.L : 0
    var high = direction == .lighter ? 1 : base.L
    var candidate = base
    if contrastRatio(toRGB(candidate), against) >= minContrast { return candidate }
    for _ in 0..<18 {
      let mid = (low + high) / 2
      candidate = base
      candidate.L = mid
      if contrastRatio(toRGB(candidate), against) >= minContrast {
        if direction == .lighter { high = mid } else { low = mid }
      } else {
        if direction == .lighter { low = mid } else { high = mid }
      }
    }
    var solved = base
    solved.L = direction == .lighter ? high : low
    return solved
  }

  static let lightForeground = ThemeRGB(r: 255, g: 250, b: 255)
  static let darkForeground = ThemeRGB(r: 36, g: 21, b: 35)
  static let white = ThemeRGB(r: 255, g: 255, b: 255)
  static let black = ThemeRGB(r: 0, g: 0, b: 0)

  /// `readableThemeForeground`.
  public static func readableForeground(on background: ThemeRGB) -> ThemeRGB {
    let light = contrastRatio(background, lightForeground), dark = contrastRatio(background, darkForeground)
    if max(light, dark) >= 4.5 { return light >= dark ? lightForeground : darkForeground }
    return contrastRatio(background, white) >= contrastRatio(background, black) ? white : black
  }

  /// `readableThemeText`: the quietest mix of `foreground` into `background` that still clears `minimumRatio`.
  public static func readableText(on background: ThemeRGB, foreground: ThemeRGB, amount: Double, minimumRatio: Double) -> ThemeRGB {
    let softened = mix(foreground, background, amount)
    if contrastRatio(softened, background) >= minimumRatio { return softened }
    var readable = foreground
    var lower = 0.0, upper = amount
    for _ in 0..<12 {
      let candidateAmount = (lower + upper) / 2
      let candidate = mix(foreground, background, candidateAmount)
      if contrastRatio(candidate, background) >= minimumRatio {
        readable = candidate
        lower = candidateAmount
      } else {
        upper = candidateAmount
      }
    }
    return readable
  }

  /// `standardMutedThemeText`: matches the stock palettes' muted-text strength.
  public static func standardMutedText(on background: ThemeRGB, foreground: ThemeRGB) -> ThemeRGB {
    let target = luminance(background) < 0.179 ? 5.082 : 4.705
    return readableText(on: background, foreground: foreground, amount: 1, minimumRatio: target)
  }
}
