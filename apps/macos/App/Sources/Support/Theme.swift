import AppKit
import SwiftUI
import T3Theme

/// Colors for the app chrome the system does not provide, read from the live theme (`AppTheme`). Sidebar, toolbar and
/// controls stay native unless a theme is chosen; the reading canvas, bubbles and cards always take these. Every read
/// registers with Observation, so a view that reads one repaints when the theme changes.
@MainActor
enum Palette {
  static var canvas: Color { AppTheme.shared.color(.canvas) }
  static var surface: Color { AppTheme.shared.color(.surface) }
  static var border: Color { AppTheme.shared.color(.border) }
  static var bubble: Color { AppTheme.shared.color(.messageSurface) }
  static var bubbleText: Color { AppTheme.shared.color(.messageForeground) }
  static var text: Color { AppTheme.shared.color(.text) }
  static var muted: Color { AppTheme.shared.color(.textMuted) }
  /// Same as the Markdown theme's link color, so a link in a message and one in the chrome never disagree.
  static var link: Color { AppTheme.shared.color(.updateForeground) }
  static var accent: Color { AppTheme.shared.color(.accent) }
  static var sidebar: Color { AppTheme.shared.color(.sidebar) }
  static var sidebarText: Color { AppTheme.shared.color(.sidebarForeground) }
  static var sidebarMuted: Color { AppTheme.shared.color(.sidebarMutedForeground) }
  static var sidebarRowSelected: Color { AppTheme.shared.color(.sidebarRowSelected) }
  /// Menus, dialogs and the composer: the overlay surface at the Glass opacity setting.
  static var overlay: Color { AppTheme.shared.color(.surfaceOverlay).opacity(AppTheme.shared.glassOpacity) }
}

extension View {
  /// Paints the sidebar column with the theme's sidebar colors when a theme is chosen; native glass otherwise.
  @ViewBuilder func themedSidebar() -> some View {
    if AppTheme.shared.paintsChrome {
      self.scrollContentBackground(.hidden).background(Palette.sidebar)
        .foregroundStyle(Palette.sidebarText)
    } else {
      self
    }
  }

  /// The sidebar footer's bar: the system's bar material, or the theme's sidebar color when a theme paints the chrome.
  @ViewBuilder func themedBarBackground() -> some View {
    if AppTheme.shared.paintsChrome { background(Palette.sidebar) } else { background(.bar) }
  }

  /// Everything the root view applies for the theme: accent tint and the interface font.
  func themed() -> some View {
    modifier(ThemedRoot())
  }
}

private struct ThemedRoot: ViewModifier {
  func body(content: Content) -> some View {
    content
      .tint(AppTheme.shared.paintsChrome ? Palette.link : nil)
      .font(AppTheme.shared.interfaceFont)
  }
}
