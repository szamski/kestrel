import AppKit
import SwiftUI
import T3Markdown

/// The web "t3-chat" palette (packages/shared/src/themePalettes.ts, OKLCH) for the app chrome the
/// system does not provide. Sidebar, toolbar and controls stay native; only the reading canvas,
/// bubbles and cards take these colours so the text matches `MarkdownTheme.light/.dark`.
enum Palette {
  static let canvas = dynamic(light: (0.982446, 0.010114, 325.653), dark: (0.22813, 0.020366, 307.469))
  static let surface = dynamic(light: (0.971835, 0.012884, 321.894), dark: (0.267101, 0.02016, 311.799))
  static let border = dynamic(light: (0.923531, 0.021247, 328.096), dark: (0.266943, 0.015262, 302.425))
  static let bubble = dynamic(light: (0.926746, 0.037898, 332.6), dark: (0.273791, 0.025541, 309.079))
  static let bubbleText = dynamic(light: (0.354591, 0.093575, 307.568), dark: (0.949872, 0.021269, 306.838))
  /// Same text colours as the Markdown theme so a message and its chrome never disagree.
  static let text = Color(nsColor: .init(name: nil) { MarkdownTheme.default(for: $0).foreground })
  static let muted = Color(nsColor: .init(name: nil) { MarkdownTheme.default(for: $0).muted })
  static let link = Color(nsColor: .init(name: nil) { MarkdownTheme.default(for: $0).link })

  private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (l, c, h) = isDark ? dark : light
        return .oklch(l, c, h)
      })
  }
}

extension NSColor {
  /// OKLCH to sRGB (Björn Ottosson's OKLab matrices), clamped to the gamut.
  static func oklch(_ l: Double, _ c: Double, _ hDegrees: Double) -> NSColor {
    let h = hDegrees * .pi / 180
    let a = c * cos(h), b = c * sin(h)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
    let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
    let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
    func encode(_ v: Double) -> CGFloat {
      let x = min(max(v, 0), 1)
      return CGFloat(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }
    return NSColor(srgbRed: encode(r), green: encode(g), blue: encode(bl), alpha: 1)
  }
}
