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
  /// Protocol 2: output and arguments the timeline withholds, loaded when a work entry opens.
  let details: TurnItemDetailLoader
  let disclosure = EntryDisclosure()
  var toggleTurn: (V1.TurnId) -> Void = { _ in }
  var toggleWorkGroup: (String) -> Void = { _ in }
  var toggleLocal: (String) -> Void = { _ in }
  /// Protocol 2: fold or unfold the provider output of a superseded attempt.
  var toggleAttempt: (String) -> Void = { _ in }
  /// Subagent and created-thread cards: select that thread in this environment.
  var openThread: (ThreadId) -> Void = { _ in }
  var openLink: (MarkdownLink) -> Void = { _ in }
  /// "Changed files": open the diff panel on a turn, at a file when given.
  var openDiff: (V1.TurnId, String?) -> Void = { _, _ in }
  /// A row's content changed size on its own (a work entry opened, its detail arrived): re-measure that row.
  var rowChanged: (String) -> Void = { _ in }
  /// "Cancel" on the worktree setup card.
  var cancelWorktreeSetup: () -> Void = {}

  init(key: ScopedThreadKey, workspaceRoot: String?, assets: AssetStore, details: TurnItemDetailLoader) {
    self.key = key
    self.workspaceRoot = workspaceRoot
    self.assets = assets
    self.details = details
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
  /// The table row a view renders in.
  @Entry var timelineRowID: String?
}
