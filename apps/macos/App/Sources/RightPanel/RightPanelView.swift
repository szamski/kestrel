import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The panel body: a tab strip (one tab per open surface) with maximize and close, and the active surface.
struct RightPanelView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let turns: [V1.OrchestrationCheckpointSummary]
  let store: RightPanelStore
  let diff: DiffPanelModel
  /// A file tab with unsaved edits that the user asked to close.
  @State private var closing: RightPanelSurface?

  var body: some View {
    let state = store.state(key)
    VStack(spacing: 0) {
      HStack(spacing: 2) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 2) { ForEach(state.surfaces) { surface in tab(surface, active: surface.id == state.activeSurfaceId) } }
        }
        Spacer(minLength: 8)
        Button { store.toggleMaximized(key) } label: {
          Image(systemName: store.isMaximized(key) ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .help(store.isMaximized(key) ? "Restore panel" : "Maximize panel")
        .accessibilityLabel(store.isMaximized(key) ? "Restore panel" : "Maximize panel")
        Button { store.close(key) } label: { Image(systemName: "xmark") }
          .help("Close panel")
          .accessibilityLabel("Close panel")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 10)
      .frame(height: 36)
      Divider()
      switch state.active?.kind {
      case .diff?:
        DiffPanelView(app: app, key: key, turns: turns, store: store, model: diff)
      case .files?:
        FilesPanelView(app: app, key: key, store: store)
      case .file?:
        if let path = state.active?.filePath {
          FilePreviewView(app: app, key: key, path: path, store: store).id(path)
        }
      case .preview?:
        PreviewPanelView(app: app, key: key).id(key)
      case .pullRequests?:
        ThreadPullRequestsPanel(app: app, key: key, store: store)
      case .pullRequest?:
        if let target = state.active?.pullRequestTarget {
          PullRequestDetailView(app: app, target: target, compact: true, open: { store.openSurface(.pullRequest($0), in: key) }).id(target.id)
        }
      case let kind?:
        ContentUnavailableView(kind.title, systemImage: kind.symbol, description: Text("This tab is not available in the native app yet."))
      case nil:
        ContentUnavailableView("Nothing open", systemImage: "sidebar.right")
      }
    }
    // Fill the panel whatever the surface, keeping the tab bar at the top when the content does not expand.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .confirmationDialog(
      "Save changes to \(closing?.title ?? "this file")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), presenting: closing
    ) { surface in
      Button("Save") { Task { if let path = surface.filePath, await FileSurfaces.shared.existingDocument(path, in: key)?.save() == true { close(surface) } } }
      Button("Discard Changes", role: .destructive) { close(surface) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Your changes will be lost if you close the tab without saving.")
    }
  }

  /// Closes a tab; a file with unsaved edits asks first.
  private func requestClose(_ surface: RightPanelSurface) {
    if let path = surface.filePath, FileSurfaces.shared.existingDocument(path, in: key)?.isDirty == true {
      closing = surface
    } else {
      close(surface)
    }
  }

  private func close(_ surface: RightPanelSurface) {
    if let path = surface.filePath { FileSurfaces.shared.closeDocument(path, in: key) }
    store.closeSurface(surface.id, in: key)
  }

  private func tab(_ surface: RightPanelSurface, active: Bool) -> some View {
    HStack(spacing: 4) {
      Button { store.activate(surface.id, in: key) } label: {
        Label(surface.title, systemImage: surface.filePath.map { FileLogic.symbol(for: $0) } ?? surface.kind.symbol).labelStyle(.titleAndIcon).font(.callout.weight(active ? .semibold : .regular)).lineLimit(1)
      }
      .buttonStyle(.plain)
      Button { requestClose(surface) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.muted)
        .help("Close \(surface.title)")
        .accessibilityLabel("Close \(surface.title) tab")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(active ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .foregroundStyle(active ? Palette.text : Palette.muted)
  }
}
