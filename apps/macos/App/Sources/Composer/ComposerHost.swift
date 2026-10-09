import AppKit
import SwiftUI
import T3ClientRuntime
import T3Composer

/// The composer under a thread's timeline. It appears once the thread's project is known and is
/// rebuilt when the target changes (a worktree starting, say); drafts live in the shared services.
struct ComposerHost: View {
  @Environment(AppModel.self) private var app
  let key: ScopedThreadKey
  var draft: DraftThread?

  var body: some View {
    if let target = app.composerTarget(for: key, draft: draft) {
      VStack(spacing: 0) {
        ComposerBar(app: app, target: target).id(target)
        SourceControlStrip(key: key, draft: draft)
      }
    }
  }
}

private struct ComposerBar: View {
  let app: AppModel
  let target: ComposerTarget
  @State private var model: ComposerModel

  init(app: AppModel, target: ComposerTarget) {
    self.app = app
    self.target = target
    _model = State(initialValue: app.composer.model(for: target))
  }

  var body: some View {
    ComposerView(model: model, style: AppTheme.shared.composerStyle) { atom, _ in
      app.activateChip(atom, in: ScopedThreadKey(environmentId: .init(target.environmentId), threadId: .init(target.threadId)), cwd: target.cwd)
    }
    .frame(maxWidth: timelineColumnWidth + 2 * timelineHorizontalInset)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.bottom, 4)
    .zIndex(1)
    .task {
      // The diff panel inserts review comments through the model that is on screen.
      LiveComposers.shared.register(model, for: target.key)
      await model.start()
      model.requestFocus()
      // The window assigns its own initial focus after the first layout; take it back unless the user is typing elsewhere.
      try? await Task.sleep(for: .milliseconds(500))
      if let window = NSApp.keyWindow ?? NSApp.mainWindow, !(window.firstResponder is NSText) { model.requestFocus() }
    }
    .onDisappear {
      LiveComposers.shared.unregister(model, for: target.key)
      model.stop()
      Task { await app.composer.services.persistDraftsNow() }
    }
  }
}

/// A project's unsent new thread: an empty page with the composer; the thread is created by its first send.
struct DraftReader: View {
  let draft: DraftThread

  var body: some View {
    VStack(spacing: 0) {
      ContentUnavailableView {
        Label("New thread", systemImage: "square.and.pencil")
      } description: {
        Text("Start working in \(draft.projectTitle).")
      }
      .frame(maxHeight: .infinity)
      ComposerHost(key: draft.key, draft: draft)
    }
    .navigationTitle("New thread")
    .navigationSubtitle(draft.projectTitle)
    .toolbar { ToolbarItemGroup(placement: .primaryAction) { SourceControlToolbarItems(key: draft.key, draft: draft) } }
  }
}
