import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The right panel's "Pull requests" tab: the pull requests linked to this thread, stacks indented under their base, with
/// the link dialog and unlinking. What a server can do follows its capabilities: several links, one legacy link, or none.
struct ThreadPullRequestsPanel: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore

  private let inbox = PullRequestsStore.shared

  private var shell: V1.OrchestrationThreadShell? { app.runtime.threadShell(key)?.shell }
  private var mode: ThreadPullRequestLinkMode { app.runtime.threadPullRequestLinkMode(key.environmentId) }

  /// The multi-link array, or the legacy single link as one entry.
  private var links: [ThreadPullRequestItem] {
    guard let shell else { return [] }
    let visible = ThreadPullRequests.visible(shell.pullRequests)
    if !visible.isEmpty { return visible }
    guard let legacy = shell.linkedPullRequest.flatMap({ $0 }) else { return [] }
    let parsed = ChangeRequestURL.parse(legacy.url)
    return [
      ThreadPullRequestItem(
        host: parsed?.host ?? "", repository: legacy.repository, number: legacy.number, url: legacy.url, source: .manual, linkedAt: shell.updatedAt)
    ]
  }

  var body: some View {
    let lines = ThreadPullRequests.lines(ThreadPullRequests.chains(links))
    VStack(spacing: 0) {
      if lines.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
              if let size = line.stackSize { stackCaption(size) }
              row(line)
            }
          }
          .padding(8)
        }
        .frame(maxHeight: .infinity)
        Divider()
        footer(lines)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No linked pull requests", systemImage: "arrow.triangle.pull")
    } description: {
      Text(
        mode == .unsupported
          ? "This environment does not link pull requests to threads."
          : "Pull requests the agent opens from this thread land here. Link one yourself from a URL or a number.")
    } actions: {
      if mode != .unsupported { Button("Link Pull Request\u{2026}") { inbox.linkRequest = key } }
    }
  }

  private func stackCaption(_ size: Int) -> some View {
    Label("Stack of \(size)", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(Palette.muted).padding(.top, 8).padding(.horizontal, 6)
  }

  private func row(_ line: ThreadPullRequestLine) -> some View {
    let link = line.link
    let snapshot = link.snapshot
    let state = snapshot?.state ?? .open
    let draft = snapshot?.isDraft ?? false
    let target = target(for: link)
    return Button {
      if let target { store.openSurface(.pullRequest(target), in: key) } else if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: PullRequestStyle.symbol(state, draft: draft)).foregroundStyle(PullRequestStyle.tint(state, draft: draft)).frame(width: 16)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text("#\(link.number)").font(.callout.monospaced()).foregroundStyle(Palette.muted)
            Text(snapshot?.title ?? link.repository).lineLimit(1).fontWeight(.medium)
            Spacer(minLength: 4)
            if let symbol = PullRequestStyle.reviewSymbol(snapshot?.reviewDecision.flatMap { $0 }) { Image(systemName: symbol.name).foregroundStyle(symbol.tint).help(symbol.help) }
            if let symbol = PullRequestStyle.checksSymbol(snapshot?.checksState.flatMap { $0 }) { Image(systemName: symbol.name).foregroundStyle(symbol.tint).help(symbol.help) }
          }
          HStack(spacing: 6) {
            if let snapshot { Text("\(snapshot.headBranch) \u{2192} \(snapshot.baseBranch)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) } else {
              Text(link.repository).font(.caption)
            }
            Spacer(minLength: 4)
            if snapshot?.mergeability == .conflicting, state == .open { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Merge conflicts") }
            if let updated = snapshot?.updatedAt { Text(PullRequestStyle.relative(updated)) }
          }
          .font(.caption).foregroundStyle(Palette.muted)
        }
      }
      .padding(.leading, CGFloat(min(line.depth, 3)) * 16 + 6)
      .padding(.vertical, 5).padding(.trailing, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      if let target {
        Button("Open in This Panel") { store.openSurface(.pullRequest(target), in: key) }
        Button("Open in Pull Requests") { inbox.show(target) }
      }
      Button("Open on the Host") { if let url = URL(string: link.url) { NSWorkspace.shared.open(url) } }
      Button("Copy Number") { PullRequestStyle.copy("#\(link.number)") }
      Button("Copy Link") { PullRequestStyle.copy(link.url) }
      if mode != .unsupported {
        Divider()
        Button("Unlink", role: .destructive) { unlink(link) }
      }
    }
    .accessibilityLabel("Pull request \(link.number), \(snapshot?.title ?? link.repository)")
  }

  private func footer(_ lines: [ThreadPullRequestLine]) -> some View {
    let open = lines.filter { $0.link.isOpen }.count
    let synced = lines.compactMap { $0.link.snapshot?.syncedAt }.max { (IsoTimestamp.parse($0) ?? 0) < (IsoTimestamp.parse($1) ?? 0) }
    return HStack {
      Text("\(open) open \u{00B7} \(lines.count) linked\(synced.map { " \u{00B7} synced \(PullRequestStyle.relative($0))" } ?? "")").font(.caption).foregroundStyle(Palette.muted)
      Spacer()
      if mode != .unsupported { Button { inbox.linkRequest = key } label: { Label("Link", systemImage: "plus") }.buttonStyle(.borderless).font(.caption) }
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  // MARK: Helpers

  /// The pull request the RPCs address: the project whose repository it is, else the thread's own project. Without a pull
  /// request capability the row only opens on the host.
  private func target(for link: ThreadPullRequestItem) -> PullRequestTarget? {
    guard inbox.supports(key.environmentId), let parsed = ChangeRequestURL.parse(link.url) else { return nil }
    let projects = app.runtime.projects.filter { $0.environmentId == key.environmentId }
    guard let project = PullRequestProjects.project(for: parsed, in: projects)?.projectId ?? shell?.projectId else { return nil }
    return PullRequestTarget(environmentId: key.environmentId, projectId: project, host: link.host, repository: link.repository, number: link.number)
  }

  private func unlink(_ link: ThreadPullRequestItem) {
    app.run { try await ThreadPullRequestLinking.change(key, url: link.url, linked: false, in: app) }
  }
}
