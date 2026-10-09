import AppKit
import SwiftUI

/// SwiftUI host for one terminal session.
public struct TerminalView: NSViewRepresentable {
  public var session: TerminalSession
  public var theme: TerminalTheme
  public var font: TerminalFont
  /// Increment to move keyboard focus into the terminal.
  public var focusRequest: Int
  public var onOpenLink: ((TerminalLinkTarget) -> Void)?
  public var onAddSelectionToChat: ((String) -> Void)?

  public init(
    session: TerminalSession, theme: TerminalTheme = .dark, font: TerminalFont = TerminalFont(), focusRequest: Int = 0,
    onOpenLink: ((TerminalLinkTarget) -> Void)? = nil, onAddSelectionToChat: ((String) -> Void)? = nil
  ) {
    self.session = session
    self.theme = theme
    self.font = font
    self.focusRequest = focusRequest
    self.onOpenLink = onOpenLink
    self.onAddSelectionToChat = onAddSelectionToChat
  }

  public final class Coordinator { var focusRequest = 0 }
  public func makeCoordinator() -> Coordinator { Coordinator() }

  public func makeNSView(context: Context) -> TerminalSurfaceView {
    let view = TerminalSurfaceView(theme: theme, font: font)
    view.bind(to: session)
    session.start()
    return view
  }

  public func updateNSView(_ view: TerminalSurfaceView, context: Context) {
    view.theme = theme
    view.font = font
    view.onOpenLink = onOpenLink
    view.onAddSelectionToChat = onAddSelectionToChat
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      Self.focus(view)
    }
  }

  /// A view created by the same update that asks for focus is not in a window yet; retry a few runloop turns.
  private static func focus(_ view: TerminalSurfaceView, attempts: Int = 8) {
    DispatchQueue.main.async {
      if let window = view.window { window.makeFirstResponder(view) } else if attempts > 0 { focus(view, attempts: attempts - 1) }
    }
  }

  public static func dismantleNSView(_ view: TerminalSurfaceView, coordinator: Coordinator) { view.unbind() }
}
