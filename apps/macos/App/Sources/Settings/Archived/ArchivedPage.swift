import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Archived: the archived threads of the selected environments, grouped by project, with Unarchive and Delete.
/// They are not in the live shell, so they are loaded on demand (`ClientRuntime.archivedProjects`) and reloaded after every change.
struct ArchivedPage: View {
  @Environment(SettingsModel.self) private var model
  @State private var groups: [ArchivedProject] = []
  @State private var loading = true
  @State private var failure: String?
  @State private var pendingDelete: ArchivedThread?

  /// The environments this scope reads: connected ones among the scope's own.
  private var environmentIds: [EnvironmentId] {
    model.environments.filter { $0.connected && model.scope.environmentIds.contains($0.environmentId) }.map(\.environmentId)
  }

  /// Archived threads of a project or checkout scope are limited to its members.
  private func visible(_ group: ArchivedProject) -> Bool {
    let scope = model.scope
    return !scope.isProject || scope.members.contains { $0.environmentId == group.environmentId && $0.projectId == group.projectId }
  }

  var body: some View {
    let shown = groups.filter(visible)
    ScrollViewReader { proxy in
      Form {
        if shown.isEmpty {
          Section(SettingsRegistry.items.first { $0.id == "archive" }?.title ?? "Archived threads") {
            HStack(spacing: 10) {
              if loading { ProgressView().controlSize(.small) } else { Image(systemName: "archivebox").foregroundStyle(.secondary) }
              VStack(alignment: .leading, spacing: 2) {
                Text(loading ? "Loading archived threads" : failure != nil ? "Could not load archived threads" : "No archived threads")
                Text(loading ? "Checking connected environments." : failure ?? "Archived threads will appear here.").font(.callout).foregroundStyle(.secondary)
              }
            }
            .id("archive")
          }
        } else {
          ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
            Section {
              ForEach(group.threads) { thread in row(thread) }
            } header: {
              Label(group.title, systemImage: "folder").help(group.workspaceRoot).id(index == 0 ? "archive" : group.id)
            }
          }
        }
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
      }
    }
    .task(id: environmentIds) { await load() }
    .confirmationDialog(
      "Delete thread \u{201C}\(pendingDelete?.title ?? "")\u{201D}?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { if let thread = pendingDelete { delete(thread) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently clears conversation history for this thread.")
    }
  }

  private func row(_ thread: ArchivedThread) -> some View {
    LabeledContent {
      Button("Unarchive", systemImage: "archivebox.circle") { unarchive(thread) }.controlSize(.small)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.title).lineLimit(1)
        Text("Archived \(relative(thread.archivedAt ?? thread.createdAt)) \u{00B7} Created \(relative(thread.createdAt))").font(.callout).foregroundStyle(.secondary)
      }
    }
    .contextMenu {
      Button("Unarchive") { unarchive(thread) }
      Button("Delete", role: .destructive) { requestDelete(thread) }
    }
  }

  private func relative(_ time: IsoDateTime) -> String {
    time.date?.formatted(.relative(presentation: .named, unitsStyle: .wide)) ?? time.rawValue
  }

  // MARK: Loading and actions

  private func load() async {
    let ids = environmentIds
    failure = nil
    if groups.isEmpty { loading = true }
    var loaded: [ArchivedProject] = []
    for id in ids {
      do { loaded += try await model.runtime.archivedProjects(environmentId: id) } catch { failure = AppModel.describe(error) }
    }
    guard !Task.isCancelled else { return }
    groups = loaded
    loading = false
  }

  private func unarchive(_ thread: ArchivedThread) {
    Task {
      do {
        try await model.runtime.unarchiveThread(thread.key)
        await load()
      } catch { model.report("Failed to unarchive thread. \(AppModel.describe(error))") }
    }
  }

  private func requestDelete(_ thread: ArchivedThread) {
    if model.client.confirmThreadDelete { pendingDelete = thread } else { delete(thread) }
  }

  private func delete(_ thread: ArchivedThread) {
    pendingDelete = nil
    Task {
      do {
        try await model.runtime.deleteThread(thread.key)
        await load()
      } catch { model.report("Failed to delete thread. \(AppModel.describe(error))") }
    }
  }
}
