import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// One query's refs, fetched a page (100) at a time as the list scrolls.
@MainActor @Observable
final class RefList {
  private(set) var refs: [VcsRef] = []
  private(set) var nextCursor: Int?
  private(set) var isLoading = false
  private(set) var error: String?
  private(set) var loaded = false
  @ObservationIgnored private var generation = 0

  var hasMore: Bool { nextCursor != nil }

  func reload(_ store: SourceControlStore, environmentId: EnvironmentId, cwd: String, query: String) async {
    generation += 1
    let mine = generation
    isLoading = true
    defer { if mine == generation { isLoading = false } }
    do {
      let page = try await store.listRefs(environmentId, cwd: cwd, query: query, cursor: nil)
      guard mine == generation else { return }
      refs = page.refs
      nextCursor = page.nextCursor
      error = nil
      loaded = true
    } catch {
      guard mine == generation, !SourceControlStore.isCancellation(error) else { return }
      self.error = SourceControlStore.describe(error)
    }
  }

  func loadMore(_ store: SourceControlStore, environmentId: EnvironmentId, cwd: String, query: String) async {
    guard let cursor = nextCursor, !isLoading else { return }
    let mine = generation
    isLoading = true
    defer { if mine == generation { isLoading = false } }
    do {
      let page = try await store.listRefs(environmentId, cwd: cwd, query: query, cursor: cursor)
      guard mine == generation else { return }
      let known = Set(refs.map(\.name))
      refs += page.refs.filter { !known.contains($0.name) }
      nextCursor = page.nextCursor
    } catch {
      guard mine == generation, !SourceControlStore.isCancellation(error) else { return }
      self.error = SourceControlStore.describe(error)
    }
  }
}

/// The branch popover: search, the refs of the checkout, "create ref" and (for a new worktree) "start from origin".
struct BranchPicker: View {
  let store: SourceControlStore
  let info: WorkspaceInfo
  var activeBranch: String?
  var done: () -> Void
  @State private var query = ""
  @State private var list = RefList()
  @FocusState private var searching: Bool

  private var selectingWorktreeBase: Bool { info.isDraft && info.envMode == .worktree && info.worktreePath == nil }
  /// The server filters by the sanitized name: a typed "new branch" must still find "new-branch".
  private var searchQuery: String { BranchToolbarLogic.sanitizeNewRefName(query) }
  private var createName: String? {
    let name = BranchToolbarLogic.sanitizeNewRefName(query)
    guard !selectingWorktreeBase, !name.isEmpty, !list.refs.contains(where: { $0.name == name }) else { return nil }
    return name
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search refs...", text: $query)
          .textFieldStyle(.plain)
          .focused($searching)
          .onSubmit(chooseFirst)
      }
      .padding(.horizontal, 12)
      .frame(height: 36)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(list.refs, id: \.name) { ref in
            RefRow(ref: ref, current: ref.name == activeBranch, badge: badge(ref)) { choose(ref) }
          }
          if let name = createName {
            PopoverRow(title: "Create new ref \u{201C}\(name)\u{201D}", icon: "plus", selected: false) {
              done()
              Task { await store.createRef(name, in: info) }
            }
          }
          if list.hasMore {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
              .task(id: list.refs.count) { await list.loadMore(store, environmentId: info.key.environmentId, cwd: info.cwd, query: searchQuery) }
          }
          if list.loaded, list.refs.isEmpty, createName == nil {
            Text("No refs found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(16)
          }
          if let error = list.error {
            Text(error).font(.caption).foregroundStyle(.red).padding(10)
          }
        }
        .padding(4)
      }
      .frame(height: min(232, max(56, CGFloat(list.refs.count + (createName == nil ? 0 : 1)) * 26 + 16)))
      if selectingWorktreeBase {
        Divider()
        Toggle(
          isOn: Binding(
            get: { info.workspace.startFromOrigin }, set: { value in store.updateWorkspace(info) { $0.startFromOrigin = value } })
        ) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Start from origin")
            Text("Base the worktree on the remote branch, not your local copy.").font(.caption).foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(10)
      }
    }
    .frame(width: 330)
    .task(id: searchQuery) {
      // A pause in typing, then the first page of the new query.
      if list.loaded { try? await Task.sleep(for: .milliseconds(200)) }
      guard !Task.isCancelled else { return }
      await list.reload(store, environmentId: info.key.environmentId, cwd: info.cwd, query: searchQuery)
    }
    .onAppear { searching = true }
  }

  private func badge(_ ref: VcsRef) -> String? {
    if ref.current { return "current" }
    if let path = ref.worktreePath, path != info.project.project.workspaceRoot { return "worktree" }
    if ref.isRemote == true { return "remote" }
    if ref.isDefault { return "default" }
    return nil
  }

  private func choose(_ ref: VcsRef) {
    done()
    Task { await store.select(ref, in: info) }
  }

  private func chooseFirst() {
    if let ref = list.refs.first { choose(ref) } else if let name = createName {
      done()
      Task { await store.createRef(name, in: info) }
    }
  }
}

private struct RefRow: View {
  let ref: VcsRef
  let current: Bool
  let badge: String?
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(ref.name).lineLimit(1).truncationMode(.middle)
        if let badge { Text(badge).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
        Spacer(minLength: 8)
        if current { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
