import Foundation
import T3ClientRuntime
import T3Contracts

/// Linking a pull request to a thread, through whichever command the thread's environment advertises (`usePullRequestLinking`).
@MainActor
enum ThreadPullRequestLinking {
  struct Failure: LocalizedError {
    var errorDescription: String?
  }

  /// Whether the thread has this pull request linked: a multi-link entry, else the legacy single link.
  static func isLinked(_ key: ScopedThreadKey, url: String, in app: AppModel) -> Bool {
    guard let shell = app.runtime.threadShell(key)?.shell, let parsed = ChangeRequestURL.parse(url) else { return false }
    let wanted = ThreadPullRequestKey(host: parsed.authority ?? parsed.host, repository: parsed.repository, number: parsed.number, url: url)
    switch app.runtime.threadPullRequestLinkMode(key.environmentId) {
    case .multiple:
      return ThreadPullRequests.visible(shell.pullRequests).contains { $0.linkKey == wanted }
    case .single:
      guard let linked = shell.linkedPullRequest.flatMap({ $0 }) else { return false }
      return linked.url == url || (linked.number == parsed.number && linked.repository.lowercased() == parsed.repository)
    case .unsupported:
      return false
    }
  }

  /// Whether this environment can link the pull request at all: multi-link stores any link; the single link needs a project
  /// checked out from that repository.
  static func canLink(_ link: ChangeRequestLink, environmentId: EnvironmentId, in app: AppModel) -> Bool {
    switch app.runtime.threadPullRequestLinkMode(environmentId) {
    case .multiple: true
    case .single: PullRequestProjects.project(for: link, in: app.runtime.projects.filter { $0.environmentId == environmentId }) != nil
    case .unsupported: false
    }
  }

  static func change(_ key: ScopedThreadKey, url: String, linked: Bool, in app: AppModel) async throws {
    guard let parsed = ChangeRequestURL.parse(url) else { throw Failure(errorDescription: "That is not a pull request this client can read.") }
    let projects = app.runtime.projects.filter { $0.environmentId == key.environmentId }
    let project = PullRequestProjects.project(for: parsed, in: projects)
    let identity = project.flatMap(PullRequestProjects.identity(of:))
    guard
      let mutation = ThreadPullRequestMutation.plan(
        mode: app.runtime.threadPullRequestLinkMode(key.environmentId), link: parsed, url: url, legacyProjectId: project?.projectId,
        legacyRepository: identity.flatMap(PullRequestProjects.repository(of:)), linked: linked)
    else { throw Failure(errorDescription: "This environment does not support linking this pull request.") }
    try await app.runtime.changeThreadPullRequestLink(key, mutation)
  }
}
