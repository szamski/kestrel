import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown

/// What timeline rows need from the window around them: thread identity, workspace paths, asset
/// loading and the few actions a row can trigger. Rows read it from the environment so their values
/// stay small and `Hashable`.
@MainActor
final class TimelineHost {
  let key: ScopedThreadKey
  let workspaceRoot: String?
  let assets: AssetStore
  var toggleTurn: (TurnId) -> Void = { _ in }
  var toggleWorkGroup: (String) -> Void = { _ in }
  var toggleLocal: (String) -> Void = { _ in }
  var openLink: (MarkdownLink) -> Void = { _ in }

  init(key: ScopedThreadKey, workspaceRoot: String?, assets: AssetStore) {
    self.key = key
    self.workspaceRoot = workspaceRoot
    self.assets = assets
  }

  var markdownOptions: MarkdownOptions { MarkdownOptions(baseDirectory: workspaceRoot) }

  var imageLoader: MarkdownImageLoader {
    { [assets, key] image in await assets.image(for: image, in: key) }
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension EnvironmentValues {
  @Entry var timelineHost: TimelineHost?
}
