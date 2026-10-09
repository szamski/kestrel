import AppKit
import SwiftUI
import T3Theme

extension Color {
  /// A theme color (any CSS notation a theme file carries) as a SwiftUI color.
  init(css: String) {
    guard let parsed = ThemeColorMath.parse(css) else {
      self = .clear
      return
    }
    let rgb = ThemeColorMath.srgbComponents(parsed.color)
    self = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: parsed.alpha)
  }
}

/// A miniature of the app wearing one palette: sidebar, a conversation with a message bubble, the composer and the accent.
/// Static shapes only, so a grid of them costs nothing once drawn.
struct ThemeWireframe: View {
  let colors: ThemeColors

  var body: some View {
    GeometryReader { proxy in
      let w = proxy.size.width, h = proxy.size.height
      let side = w * 0.26
      ZStack(alignment: .topLeading) {
        Color(css: colors[.canvas])
        Color(css: colors[.sidebar]).frame(width: side).overlay(alignment: .trailing) { Color(css: colors[.sidebarBorder]).frame(width: 1) }
        // Sidebar rows: one selected.
        VStack(alignment: .leading, spacing: h * 0.045) {
          ForEach(0..<4, id: \.self) { index in
            RoundedRectangle(cornerRadius: 2)
              .fill(index == 1 ? Color(css: colors[.sidebarRowSelected]) : Color(css: colors[.sidebarMutedForeground]).opacity(0.35))
              .frame(width: side * 0.78, height: h * 0.06)
          }
        }
        .padding(.leading, side * 0.1).padding(.top, h * 0.14)
        // Conversation.
        VStack(alignment: .leading, spacing: h * 0.06) {
          RoundedRectangle(cornerRadius: 3).fill(Color(css: colors[.messageSurface])).frame(width: (w - side) * 0.5, height: h * 0.13)
            .frame(maxWidth: .infinity, alignment: .trailing)
          RoundedRectangle(cornerRadius: 2).fill(Color(css: colors[.text])).frame(width: (w - side) * 0.7, height: h * 0.04)
          RoundedRectangle(cornerRadius: 2).fill(Color(css: colors[.textMuted])).frame(width: (w - side) * 0.5, height: h * 0.04)
          RoundedRectangle(cornerRadius: 2).fill(Color(css: colors[.codeBackground])).frame(width: (w - side) * 0.62, height: h * 0.12)
        }
        .padding(.leading, side + w * 0.05).padding(.trailing, w * 0.05).padding(.top, h * 0.12)
        // Composer with the accent action.
        RoundedRectangle(cornerRadius: 4)
          .fill(Color(css: colors[.surface])).overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color(css: colors[.border])) }
          .overlay(alignment: .trailing) { Circle().fill(Color(css: colors[.accent])).frame(width: h * 0.09).padding(.trailing, 4) }
          .frame(width: w - side - w * 0.1, height: h * 0.15)
          .offset(x: side + w * 0.05, y: h * 0.8)
      }
      .clipped()
    }
  }
}

/// A theme's card artwork: its light and dark palettes side by side when it has both (split diagonally like the web's
/// two-ball cards would be fussy; a clean left/right split reads at a glance).
struct ThemeCardPreview: View {
  let light: ThemeColors?
  let dark: ThemeColors?

  var body: some View {
    ZStack {
      if let light, let dark {
        ThemeWireframe(colors: light)
        ThemeWireframe(colors: dark).mask(HStack(spacing: 0) { Color.clear; Color.black })
        Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
      } else if let only = light ?? dark {
        ThemeWireframe(colors: only)
      }
    }
    .aspectRatio(1.7, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
  }
}
