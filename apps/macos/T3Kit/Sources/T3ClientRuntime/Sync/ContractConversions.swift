import T3Contracts

// The generator emits structurally identical but distinct Swift types where the TypeScript
// schemas were declared separately (thread links vs shell pull requests, plans, ...).

extension OrchestrationThreadShellPullRequestsItemSnapshot {
  init(_ s: ThreadPullRequestSnapshot) {
    self.init(
      state: s.state, title: s.title, headBranch: s.headBranch, baseBranch: s.baseBranch, isDraft: s.isDraft,
      updatedAt: s.updatedAt, syncedAt: s.syncedAt, closedAt: s.closedAt, mergedAt: s.mergedAt,
      author: s.author.map { actor in
        actor.map { OrchestrationThreadShellPullRequestsItemSnapshotAuthor(isBot: $0.isBot, login: $0.login, name: $0.name, avatarUrl: $0.avatarUrl) }
      },
      additions: s.additions, deletions: s.deletions, changedFiles: s.changedFiles,
      reviewDecision: s.reviewDecision, checksState: s.checksState, mergeability: s.mergeability)
  }
}

extension OrchestrationThreadShellPullRequestsItem {
  init(_ link: ThreadPullRequestLink) {
    self.init(
      host: link.host, repository: link.repository, number: link.number, url: link.url, source: link.source,
      linkedAt: link.linkedAt, snapshot: link.snapshot.map(OrchestrationThreadShellPullRequestsItemSnapshot.init),
      stack: link.stack)
  }
}

extension OrchestrationThreadProposedPlansItem {
  init(_ plan: OrchestrationProposedPlan) {
    self.init(
      id: plan.id, turnId: plan.turnId, planMarkdown: plan.planMarkdown, implementedAt: plan.implementedAt,
      implementationThreadId: plan.implementationThreadId, createdAt: plan.createdAt, updatedAt: plan.updatedAt)
  }
}
