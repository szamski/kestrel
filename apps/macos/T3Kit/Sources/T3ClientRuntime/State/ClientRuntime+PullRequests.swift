import Foundation
import T3Contracts

extension ClientRuntime {
  /// How the thread's environment takes link edits (`threadPullRequests` / `threadPullRequestLinking`). An environment
  /// without a config yet is unsupported until its capabilities arrive.
  public func threadPullRequestLinkMode(_ environmentId: EnvironmentId) -> ThreadPullRequestLinkMode {
    ThreadPullRequestLinkMode(serverConfigs[environmentId]?.config.environment.capabilities)
  }

  /// Links or unlinks a pull request through the command this environment advertises: the multi-link commands, or the
  /// single legacy link through `thread.meta.update`. Never calls the multi-link commands on a legacy-only server.
  public func changeThreadPullRequestLink(_ key: ScopedThreadKey, _ mutation: ThreadPullRequestMutation) async throws(CommandError) {
    guard let runtime = await runtime(for: key.environmentId) else { throw .notConnected(environment: key.environmentId.rawValue) }
    let meta = CommandMeta.fresh(clock: clock)
    let command: V1.ClientOrchestrationCommand
    switch mutation {
    case .link(let target, let url):
      command = ThreadCommand.linkPullRequest(key.threadId, host: target.host, repository: target.repository, number: target.number, url: url, meta: meta)
    case .unlink(let target):
      command = ThreadCommand.unlinkPullRequest(key.threadId, host: target.host, repository: target.repository, number: target.number, meta: meta)
    case .legacy(let linked):
      command = ThreadCommand.updateMetadata(key.threadId, linkedPullRequest: .some(linked), meta: meta)
    }
    try await runtime.dispatch(command, thread: key.threadId)
  }
}
