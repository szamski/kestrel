import Foundation
import T3Contracts

// The pull request detail: which actions are offered, the checks as one word, review verdicts and the timeline.
// Ports of the parts of `pullRequestDetail.logic.ts` the native detail needs.

public enum PullRequestChecksSummary: Sendable, Equatable {
  case none, pending, failing, passing
}

/// The one merge-area state shown in the header, including terminal and deferred states.
public enum PullRequestPrimaryControl: Sendable, Equatable {
  case resolve, ready, merge, enableAutoMerge, autoMergeArmed, merged, closed
}

public enum PullRequestDetailLogic {
  // MARK: Actions

  public static func mergeLabel(_ method: PullRequestMergeMethod) -> String {
    switch method {
    case .merge: "Merge"
    case .squash: "Squash and merge"
    case .rebase: "Rebase and merge"
    case .unknown(let raw): raw
    }
  }

  /// The host says which strategies it offers at all; the repository narrows that to the ones it allows.
  public static func allowedMergeMethods(_ detail: PullRequestDetail) -> [PullRequestMergeMethod] {
    detail.capabilities.mergeMethods.filter { method in
      switch method {
      case .merge: detail.mergeCapabilities.merge
      case .squash: detail.mergeCapabilities.squash
      case .rebase: detail.mergeCapabilities.rebase
      case .unknown: false
      }
    }
  }

  /// The reader's preference where the repository allows it, and the first allowed method else.
  public static func selectedMergeMethod(allowed: [PullRequestMergeMethod], preferred: PullRequestMergeMethod?) -> PullRequestMergeMethod {
    if let preferred, allowed.contains(preferred) { return preferred }
    return allowed.first ?? .merge
  }

  /// Two questions, both of which have to say yes: whether this host can do it at all, and whether this account may.
  public static func canPerform(_ action: PullRequestAction, in detail: PullRequestDetail) -> Bool {
    detail.capabilities.actions.contains(action) && detail.viewerPermissions.actions.contains(action)
  }

  public static func isConflicting(_ detail: PullRequestDetail) -> Bool { detail.state == .open && detail.mergeability == .conflicting }

  public static func primaryControl(_ detail: PullRequestDetail, checks: PullRequestChecksSummary) -> PullRequestPrimaryControl? {
    if detail.state == .merged { return .merged }
    if detail.state == .closed { return .closed }
    if detail.mergeability == .conflicting { return .resolve }
    if detail.isDraft { return canPerform(.ready, in: detail) ? .ready : nil }
    if detail.autoMergeEnabled == true { return .autoMergeArmed }
    if allowedMergeMethods(detail).isEmpty { return nil }
    if detail.autoMergeEnabled == false, checks != .none, checks != .passing, canPerform(.enableAutoMerge, in: detail) { return .enableAutoMerge }
    return canPerform(.merge, in: detail) ? .merge : nil
  }

  public static func actionTitle(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Merge"
    case .ready: "Ready for review"
    case .draft: "Convert to draft"
    case .close: "Close pull request"
    case .reopen: "Reopen pull request"
    case .updateBranch: "Update branch"
    case .enableAutoMerge: "Enable auto-merge"
    case .disableAutoMerge: "Disable auto-merge"
    case .revert: "Revert"
    case .approveWorkflows: "Approve workflows"
    case .unknown(let raw): raw
    }
  }

  public static func successMessage(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Merge requested"
    case .ready: "Marked ready for review"
    case .draft: "Converted to draft"
    case .close: "Pull request closed"
    case .reopen: "Pull request reopened"
    case .updateBranch: "Branch updated with the base branch"
    case .enableAutoMerge: "Auto-merge enabled"
    case .disableAutoMerge: "Auto-merge disabled"
    case .revert: "Revert pull request opened"
    case .approveWorkflows: "Workflows approved"
    case .unknown: "Done"
    }
  }

  /// Said as the thing that did not happen.
  public static func failureTitle(_ action: PullRequestAction) -> String {
    switch action {
    case .merge: "Could not merge this pull request"
    case .ready: "Could not mark this ready for review"
    case .draft: "Could not convert this to a draft"
    case .close: "Could not close this pull request"
    case .reopen: "Could not reopen this pull request"
    case .updateBranch: "Could not update this branch"
    case .enableAutoMerge: "Could not enable auto-merge"
    case .disableAutoMerge: "Could not disable auto-merge"
    case .revert: "Could not open a revert pull request"
    case .approveWorkflows: "Could not approve workflows"
    case .unknown: "The action failed"
    }
  }

  // MARK: Checks

  /// The checks as one word. Failing outranks running: a red run is already worth acting on.
  public static func classify(_ checks: [PullRequestCheck]) -> PullRequestChecksSummary {
    if checks.isEmpty { return .none }
    if checks.contains(where: { $0.status == .failure || $0.status == .cancelled }) { return .failing }
    if checks.contains(where: { $0.status == .pending || $0.status == .actionRequired }) { return .pending }
    return .passing
  }

  /// Every live facet: "7 of 16 running · 1 failed".
  public static func describe(_ checks: [PullRequestCheck]) -> String {
    if checks.isEmpty { return "No checks reported" }
    let failed = checks.filter { $0.status == .failure || $0.status == .cancelled }.count
    let pending = checks.filter { $0.status == .pending }.count
    let action = checks.filter { $0.status == .actionRequired }.count
    let passed = checks.filter { $0.status == .success }.count
    var parts: [String] = []
    if pending > 0 { parts.append("\(pending) of \(checks.count) running") }
    if action > 0 { parts.append("\(action) of \(checks.count) awaiting action") }
    if failed > 0 { parts.append(parts.isEmpty ? "\(failed) of \(checks.count) failing" : "\(failed) failed") }
    if parts.isEmpty { return passed == checks.count ? "All checks passed" : "\(passed) of \(checks.count) passing" }
    return parts.joined(separator: " \u{00B7} ")
  }

  /// Checks that need attention first (failed, cancelled, awaiting action), then the rest.
  public static func grouped(_ checks: [PullRequestCheck]) -> (attention: [PullRequestCheck], running: [PullRequestCheck], other: [PullRequestCheck]) {
    (
      checks.filter { [.failure, .cancelled, .actionRequired].contains($0.status) },
      checks.filter { $0.status == .pending },
      checks.filter { [.success, .skipped, .neutral].contains($0.status) }
    )
  }

  // MARK: Reviews

  public enum ReviewOutcome: Sendable, Equatable { case approved, changesRequested, dismissed }

  /// Which review states are a verdict. Hosts spell the same three differently (`CHANGES_REQUESTED`, `changes_requested`);
  /// anything else (GitHub's `COMMENTED`) is not a verdict.
  public static func reviewOutcome(_ state: String?) -> ReviewOutcome? {
    switch state?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-") {
    case "approved": .approved
    case "changes-requested": .changesRequested
    case "dismissed": .dismissed
    default: nil
    }
  }

  public struct ReviewOutcomeEntry: Sendable, Identifiable {
    public var key: String
    public var actor: PullRequestActor? = nil
    public var outcome: ReviewOutcome
    public var at: IsoDateTime
    /// Commits landed after this verdict, so it speaks for code that is no longer on the branch.
    public var stale: Bool
    public var id: String { key }
  }

  /// Where each reviewer landed: one entry per person and only their last word. A dismissal is a verdict taken back.
  public static func latestReviewOutcomes(_ comments: [PullRequestComment], commits: [PullRequestCommit] = []) -> [ReviewOutcomeEntry] {
    let newestCommit = commits.compactMap { IsoTimestamp.parse($0.committedDate) }.max()
    var latest: [String: ReviewOutcomeEntry] = [:]
    var order: [String] = []
    for comment in comments {
      guard let outcome = reviewOutcome(comment.reviewState) else { continue }
      // Two deleted accounts are two reviewers.
      let login = comment.author?.login ?? "ghost:\(comment.id)"
      let at = IsoTimestamp.parse(comment.createdAt)
      if let current = latest[login], let held = IsoTimestamp.parse(current.at), let at, held > at { continue }
      if latest[login] == nil { order.append(login) }
      let stale = newestCommit.map { commit in at.map { $0 < commit } ?? false } ?? false
      latest[login] = ReviewOutcomeEntry(key: login, actor: comment.author, outcome: outcome, at: comment.createdAt, stale: stale)
    }
    return order.compactMap { latest[$0] }.filter { $0.outcome != .dismissed }
  }

  // MARK: Timeline

  public struct TimelineEvent: Sendable, Identifiable {
    public enum Kind: Sendable { case opened, commit, comment, review, merged, closed }
    public var id: String
    public var at: IsoDateTime
    public var kind: Kind
    public var title: String
    public var body: String? = nil
    /// A commit headline is plain text and must not be parsed as markdown.
    public var markdown: Bool
    public var url: String? = nil
    public var actor: PullRequestActor?
    public var additions: Int? = nil
    public var deletions: Int? = nil
    public var path: String? = nil
    public var reviewState: String? = nil
    public var reactions: [PullRequestReaction]
    public var comment: PullRequestComment? = nil
  }

  /// Review bots keep bookkeeping in HTML comments, which the markdown renderer drops: a body that is nothing but one
  /// renders as an empty block, so it counts as no body.
  public static func visibleBody(_ body: String) -> String? {
    let stripped = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Creation, commits, comments and reviews, and the terminal event as one list, newest first. Merged wins over closed.
  public static func timeline(_ detail: PullRequestDetail, activity: PullRequestActivity) -> [TimelineEvent] {
    var events: [TimelineEvent] = [
      TimelineEvent(
        id: "created", at: detail.createdAt, kind: .opened, title: "opened this pull request", body: nil, markdown: false, url: nil, actor: detail.author, reactions: [])
    ]
    for commit in activity.commits {
      events.append(
        TimelineEvent(
          id: commit.oid, at: commit.committedDate, kind: .commit, title: "Commit \(commit.oid.prefix(7))", body: commit.messageHeadline.isEmpty ? nil : commit.messageHeadline,
          markdown: false, url: nil, actor: commit.authors?.first, additions: commit.additions, deletions: commit.deletions, reactions: []))
    }
    for comment in activity.comments {
      events.append(
        TimelineEvent(
          id: comment.id, at: comment.createdAt, kind: comment.kind == .review ? .review : .comment, title: comment.kind == .review ? "reviewed" : "commented",
          body: visibleBody(comment.body), markdown: true, url: comment.url, actor: comment.author, path: comment.path, reviewState: comment.reviewState,
          reactions: comment.reactions ?? [], comment: comment))
    }
    if let merged = detail.mergedAt {
      events.append(TimelineEvent(id: "merged", at: merged, kind: .merged, title: "Pull request merged", markdown: false, reactions: []))
    } else if let closed = detail.closedAt {
      events.append(TimelineEvent(id: "closed", at: closed, kind: .closed, title: "Pull request closed", markdown: false, reactions: []))
    }
    return events.sorted { (IsoTimestamp.parse($0.at) ?? 0) > (IsoTimestamp.parse($1.at) ?? 0) }
  }

  public enum TimelineRow: Identifiable {
    case event(TimelineEvent)
    case comments([TimelineEvent])

    public var id: String {
      switch self {
      case .event(let event): event.id
      case .comments(let events): "comments:" + (events.first?.id ?? "")
      }
    }
  }

  /// Consecutive comments are one conversation section. Commits, lifecycle updates and verdicts stay first-class rows: whether
  /// the change was approved is the question a reader opens the timeline with.
  public static func group(_ events: [TimelineEvent]) -> [TimelineRow] {
    var rows: [TimelineRow] = []
    for event in events {
      if (event.kind == .comment || event.kind == .review) && reviewOutcome(event.reviewState) == nil {
        if case .comments(let held)? = rows.last { rows[rows.count - 1] = .comments(held + [event]) } else { rows.append(.comments([event])) }
      } else {
        rows.append(.event(event))
      }
    }
    return rows
  }

  // MARK: Stacks

  /// Saved native membership is enough for navigation (`savedPullRequestStack`): the stack the newest link that names this
  /// pull request carries, with titles from the links' snapshots.
  public static func savedStack(from links: [ThreadPullRequestItem], host: String, repository: String, number: Int) -> PullRequestStack? {
    let matching = links.filter { $0.host.lowercased() == host.lowercased() && $0.repository.lowercased() == repository.lowercased() }
    func synced(_ link: ThreadPullRequestItem) -> Double { IsoTimestamp.parse(link.snapshot?.syncedAt ?? link.linkedAt) ?? 0 }
    let exact = matching.filter { $0.number == number }
    let candidates = exact.isEmpty ? matching.filter { $0.stack?.layers.contains { $0.number == number } == true } : exact
    guard let newest = candidates.max(by: { synced($0) < synced($1) }), let stack = newest.stack, stack.layers.contains(where: { $0.number == number }) else { return nil }
    return PullRequestStack(
      id: stack.id, number: stack.number, url: stack.url, base: stack.base,
      layers: stack.layers.map { layer in
        let snapshot = matching.filter { $0.number == layer.number }.max(by: { synced($0) < synced($1) })?.snapshot
        return PullRequestStackLayersItem(number: layer.number, title: snapshot?.title, isDraft: snapshot?.isDraft, headBranch: layer.headBranch, state: layer.state)
      })
  }
}
