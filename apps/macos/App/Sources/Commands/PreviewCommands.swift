import SwiftUI
import T3ClientRuntime
import T3Contracts

extension CommandCenter {
  /// The browser's keybinding commands. They act on the open thread's browser: the toggle works wherever the environment hosts a
  /// server browser, the rest while the Preview tab is the one in view (`preview.refresh` and the others are bound with
  /// `when: previewFocus`, which holds while the page or the address field has the keyboard).
  func registerPreviewCommands() {
    provideContext("previewFocus") { PreviewStore.shared.isFocused }
    register(.previewToggle, isAvailable: { [self] in previewSupported }) { [self] in
      if let key = app.selection { RightPanelStore.live?.toggle(.preview, in: key) }
    }
    register(.previewRefresh, isAvailable: { [self] in visiblePreview != nil }) { [self] in visiblePreview?.reload() }
    register(.previewFocusUrl, isAvailable: { [self] in visiblePreview != nil }) { [self] in visiblePreview?.requestAddressFocus() }
    register(.previewZoomIn, isAvailable: { [self] in visiblePreview?.selectedTab != nil }) { [self] in visiblePreview?.adjust(zoomStep: 1) }
    register(.previewZoomOut, isAvailable: { [self] in visiblePreview?.selectedTab != nil }) { [self] in visiblePreview?.adjust(zoomStep: -1) }
    register(.previewResetZoom, isAvailable: { [self] in visiblePreview?.selectedTab != nil }) { [self] in visiblePreview?.adjust(resetZoom: true) }
  }

  /// Whether the open thread's environment hosts server browsers.
  private var previewSupported: Bool {
    guard let key = app.selection else { return false }
    return app.runtime.serverConfigs[key.environmentId]?.config.environment.capabilities.serverBrowser == true
  }

  /// The browser of the open thread while its panel shows the Preview tab.
  private var visiblePreview: PreviewThreadModel? {
    guard let key = app.selection, let panel = RightPanelStore.live, panel.state(key).isOpen, panel.state(key).active?.kind == .preview else { return nil }
    return PreviewStore.shared.existing(key)
  }
}
