import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

extension CommandCenter {
  /// `pullRequest.copyNumber` (the web copies the link of the pull request in view): the open pull request of the inbox, the
  /// open panel tab, else the thread's current pull request.
  func registerPullRequestCommands() {
    register(.pullRequestCopyNumber, isAvailable: { [self] in pullRequestLink != nil }) { [self] in
      if let link = pullRequestLink { PullRequestStyle.copy(link) }
    }
  }

  /// The URL of the pull request the user is looking at.
  var pullRequestLink: String? {
    let inbox = PullRequestsStore.shared
    if inbox.isShowing, let target = inbox.selected {
      return inbox.rows.first { PullRequestTarget($0) == target }?.entry.url
        ?? ChangeRequestURL.webURL(kind: "github", host: target.host, repository: target.repository, number: target.number)
    }
    guard let key = app.selection else { return nil }
    if let panel = RightPanelStore.live, panel.state(key).isOpen, let target = panel.state(key).active?.pullRequestTarget {
      return ChangeRequestURL.webURL(kind: "github", host: target.host, repository: target.repository, number: target.number)
    }
    guard let shell = app.runtime.threadShell(key)?.shell else { return nil }
    return ThreadPullRequests.current(shell.pullRequests)?.url ?? shell.linkedPullRequest.flatMap { $0 }?.url
  }
}

/// The sidebar's way into the pull request inbox: a row above the footer, with the number of reviews waiting for you (known once the inbox has loaded).
struct PullRequestsSidebarEntry: View {
  @Environment(AppModel.self) private var app
  private let store = PullRequestsStore.shared

  var body: some View {
    let runtime = app.runtime
    let supported = runtime.environments.contains { runtime.serverConfigs[$0.environmentId]?.config.environment.capabilities.pullRequests == true }
    if supported {
      Button { store.isShowing ? store.hide() : store.show() } label: {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.pull").frame(width: 18)
          Text("Pull requests")
          Spacer(minLength: 0)
          if store.reviewRequestedCount > 0 {
            Text("\(store.reviewRequestedCount)").font(.caption.weight(.semibold)).monospacedDigit()
              .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor.opacity(0.25), in: Capsule())
              .help("\(store.reviewRequestedCount) waiting for your review")
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(store.isShowing ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .font(.callout)
      .padding(.horizontal, 8).padding(.top, 6)
      .help("Pull requests of every connected environment")
      .padding(.bottom, 4)
      .themedBarBackground()
      .accessibilityLabel(store.reviewRequestedCount > 0 ? "Pull requests, \(store.reviewRequestedCount) waiting for your review" : "Pull requests")
      .onAppear { store.attach(app) }
    }
  }
}

/// What the main window needs from the pull request feature: the link dialog.
struct PullRequestsHost: ViewModifier {
  @Environment(AppModel.self) private var app
  private let store = PullRequestsStore.shared

  func body(content: Content) -> some View {
    content
      .onAppear { store.attach(app) }
      .onChange(of: app.selection) { _, selection in if selection != nil { store.hide() } }
      .sheet(isPresented: Binding(get: { store.linkRequest != nil }, set: { if !$0 { store.linkRequest = nil } })) {
        if let key = store.linkRequest { LinkPullRequestSheet(key: key).environment(app).themed() }
      }
  }
}

extension View {
  func pullRequestsHost() -> some View { modifier(PullRequestsHost()) }
}
