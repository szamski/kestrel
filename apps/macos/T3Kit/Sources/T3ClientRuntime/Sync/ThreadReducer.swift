import Foundation
import T3Contracts

/// Port of `packages/client-runtime/src/state/threadReducer.ts`: applies one orchestration
/// event to a thread detail value. Pure; the caller owns cursors, status and persistence.
public enum ThreadReduceResult: Sendable, Equatable {
  case updated(OrchestrationThread)
  case deleted
  case unchanged
}

public enum ThreadReducer {
  public static func apply(_ thread: OrchestrationThread, _ event: OrchestrationEvent) -> ThreadReduceResult {
    var t = thread
    switch event {
    case .projectCreated, .projectMetaUpdated, .projectDeleted:
      return .unchanged

    case .threadCreated(let e):
      let p = e.payload
      return .updated(
        OrchestrationThread(
          id: p.threadId, projectId: p.projectId, title: p.title, modelSelection: p.modelSelection,
          runtimeMode: RuntimeMode(rawValue: p.runtimeMode.rawValue), interactionMode: p.interactionMode,
          branch: p.branch, worktreePath: p.worktreePath, linkedPullRequest: nil, pullRequests: [],
          branchPullRequest: .some(nil), latestTurn: nil, createdAt: p.createdAt, updatedAt: p.updatedAt,
          archivedAt: nil, settledOverride: nil, settledAt: nil, unsettledAt: .some(nil),
          snoozedUntil: .some(nil), snoozedAt: .some(nil), pinnedAt: nil, pinOrderKey: nil,
          activeOrderKey: .some(nil), autoSettleDisabledAt: .some(nil), titleRegeneration: nil,
          titleState: nil, deletedAt: nil, messages: [], proposedPlans: [], activities: [],
          checkpoints: [], session: nil))

    case .threadDeleted:
      return .deleted

    case .threadArchived(let e):
      t.archivedAt = e.payload.archivedAt
      t.titleRegeneration = .some(nil)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadUnarchived(let e):
      t.archivedAt = nil
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadSettled(let e):
      t.settledOverride = .settled
      t.settledAt = e.payload.settledAt
      t.unsettledAt = .some(nil)
      t.activeOrderKey = .some(nil)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadUnsettled(let e):
      let reentry = thread.settledOverride == .active ? (thread.unsettledAt ?? .some(nil)) : .some(e.payload.updatedAt)
      t.settledOverride = e.payload.reason == .user ? .active : nil
      t.settledAt = nil
      // A thread already pinned active keeps its re-entry stamp: the activity reset that
      // clears the pin must not reorder the list.
      t.unsettledAt = reentry
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadSnoozed(let e):
      t.snoozedUntil = .some(e.payload.snoozedUntil)
      t.snoozedAt = .some(e.payload.snoozedAt)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadUnsnoozed(let e):
      t.snoozedUntil = .some(nil)
      t.snoozedAt = .some(nil)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadPinned(let e):
      t.pinnedAt = .some(e.payload.pinnedAt)
      if let key = e.payload.pinOrderKey { t.pinOrderKey = .some(key) }
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadUnpinned(let e):
      t.pinnedAt = .some(nil)
      t.pinOrderKey = .some(nil)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadPinReordered(let e):
      t.pinOrderKey = .some(e.payload.orderKey)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadAutoSettleSet(let e):
      t.autoSettleDisabledAt = .some(e.payload.autoSettleDisabledAt)
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadMetaUpdated(let e):
      let p = e.payload
      if let title = p.title { t.title = title }
      if let v = p.titleState { t.titleState = .some(v) }
      if let v = p.titleRegeneration { t.titleRegeneration = .some(v) }
      if let v = p.modelSelection { t.modelSelection = v }
      if let v = p.branch { t.branch = v }
      if let v = p.worktreePath { t.worktreePath = v }
      if let v = p.linkedPullRequest { t.linkedPullRequest = .some(v) }
      if let v = p.branchPullRequest { t.branchPullRequest = .some(v) }
      if let v = p.activeOrderKey { t.activeOrderKey = .some(v) }
      t.updatedAt = p.updatedAt
      return .updated(t)

    case .threadPullRequestLinked(let e):
      let link = e.payload.link
      let others = thread.pullRequests.filter { !PullRequestKey.equal($0.key, PullRequestKey(link.host, link.repository, link.number)) }
      return withPullRequests(thread, others + [OrchestrationThreadShellPullRequestsItem(link)], e.payload.updatedAt)

    case .threadPullRequestUnlinked(let e):
      let key = PullRequestKey(e.payload.host, e.payload.repository, e.payload.number)
      return withPullRequests(thread, thread.pullRequests.filter { !PullRequestKey.equal($0.key, key) }, e.payload.updatedAt)

    case .threadPullRequestSynced(let e):
      let key = PullRequestKey(e.payload.host, e.payload.repository, e.payload.number)
      guard thread.pullRequests.contains(where: { PullRequestKey.equal($0.key, key) }) else { return .unchanged }
      let mapped = thread.pullRequests.map { existing -> OrchestrationThreadShellPullRequestsItem in
        guard PullRequestKey.equal(existing.key, key) else { return existing }
        var next = existing
        next.snapshot = OrchestrationThreadShellPullRequestsItemSnapshot(e.payload.snapshot)
        next.stack = e.payload.stack
        return next
      }
      return withPullRequests(thread, mapped, e.payload.updatedAt)

    case .threadRuntimeModeSet(let e):
      t.runtimeMode = e.payload.runtimeMode
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadInteractionModeSet(let e):
      t.interactionMode = e.payload.interactionMode
      t.updatedAt = e.payload.updatedAt
      return .updated(t)

    case .threadTurnStartRequested(let e):
      if let selection = e.payload.modelSelection { t.modelSelection = selection }
      t.runtimeMode = RuntimeMode(rawValue: e.payload.runtimeMode.rawValue)
      t.interactionMode = e.payload.interactionMode
      t.updatedAt = e.occurredAt
      return .updated(t)

    case .threadTurnInterruptRequested(let e):
      guard let turnId = e.payload.turnId, var latest = thread.latestTurn, latest.turnId == turnId else {
        return .unchanged
      }
      latest.state = .interrupted
      latest.startedAt = latest.startedAt ?? e.payload.createdAt
      latest.completedAt = latest.completedAt ?? e.payload.createdAt
      t.latestTurn = latest
      t.updatedAt = e.occurredAt
      return .updated(t)

    case .threadMessageSent(let e):
      return .updated(applyMessageSent(thread, e))

    case .threadSessionSet(let e):
      return .updated(applySessionSet(thread, e))

    case .threadSessionStopRequested(let e):
      guard var session = thread.session else { return .unchanged }
      session.status = .stopped
      session.activeTurnId = nil
      session.updatedAt = e.payload.createdAt
      t.session = session
      t.updatedAt = e.occurredAt
      return .updated(t)

    case .threadProposedPlanUpserted(let e):
      let plan = OrchestrationThreadProposedPlansItem(e.payload.proposedPlan)
      var plans = thread.proposedPlans.filter { $0.id != plan.id }
      plans.append(plan)
      t.proposedPlans = stableSorted(plans) { l, r in
        if l.createdAt != r.createdAt { return JS.less(l.createdAt.rawValue, r.createdAt.rawValue) ? -1 : 1 }
        if l.id != r.id { return JS.less(l.id, r.id) ? -1 : 1 }
        return 0
      }
      t.updatedAt = e.occurredAt
      return .updated(t)

    case .threadTurnDiffCompleted(let e):
      return applyTurnDiff(thread, e)

    case .threadReverted(let e):
      return .updated(applyRevert(thread, turnCount: e.payload.turnCount, occurredAt: e.occurredAt))

    case .threadActivityAppended(let e):
      t.activities = appendActivity(thread.activities, e.payload.activity)
      t.updatedAt = e.occurredAt
      return .updated(t)

    case .threadApprovalResponseRequested, .threadUserInputResponseRequested, .threadCheckpointRevertRequested:
      return .unchanged

    case .unknown:
      return .unchanged
    }
  }

  // MARK: Pull requests

  private static func withPullRequests(
    _ thread: OrchestrationThread, _ pullRequests: [OrchestrationThreadShellPullRequestsItem], _ updatedAt: IsoDateTime
  ) -> ThreadReduceResult {
    var t = thread
    t.pullRequests = pullRequests
    if case .some(.some(let linked))? = Optional(thread.linkedPullRequest),
      pullRequests.contains(where: { $0.source != .stackDismissed && $0.url == linked.url })
    {
      // keep the legacy route the server supplied
    } else {
      t.linkedPullRequest = .some(nil)
    }
    t.updatedAt = updatedAt
    return .updated(t)
  }

  // MARK: Messages

  private static func applyMessageSent(_ thread: OrchestrationThread, _ e: OrchestrationEventThreadMessageSent) -> OrchestrationThread {
    let p = e.payload
    var t = thread
    var messages = thread.messages
    if let index = messages.firstIndex(where: { $0.id == p.messageId }) {
      var entry = messages[index]
      // Streaming deltas append; a final non-empty text replaces; an empty final keeps the text.
      entry.text = p.streaming ? entry.text + p.text : (p.text.isEmpty ? entry.text : p.text)
      entry.streaming = p.streaming
      if let turnId = p.turnId { entry.turnId = turnId }
      if !p.streaming { entry.updatedAt = p.updatedAt }
      if let attachments = p.attachments { entry.attachments = attachments }
      if let context = p.context { entry.context = context }
      messages[index] = entry
    } else {
      messages.append(
        OrchestrationMessage(
          id: p.messageId, role: p.role, text: p.text, attachments: p.attachments, context: p.context,
          turnId: p.turnId, streaming: p.streaming, createdAt: p.createdAt, updatedAt: p.updatedAt))
    }

    // A completed assistant message only settles its turn once the session no longer runs it.
    let turnStillRunning =
      p.turnId != nil && thread.session?.status == .running && thread.session?.activeTurnId == p.turnId
    let settlesTurn = !p.streaming && !turnStillRunning
    if p.role == .assistant, let turnId = p.turnId, thread.latestTurn == nil || thread.latestTurn?.turnId == turnId {
      let previous = thread.latestTurn?.turnId == turnId ? thread.latestTurn : nil
      let state: OrchestrationLatestTurnState =
        settlesTurn
        ? (thread.latestTurn?.state == .interrupted ? .interrupted : thread.latestTurn?.state == .error ? .error : .completed)
        : .running
      t.latestTurn = OrchestrationLatestTurn(
        turnId: turnId, state: state, requestedAt: previous?.requestedAt ?? p.createdAt,
        startedAt: previous?.startedAt ?? p.createdAt,
        completedAt: settlesTurn ? p.updatedAt : previous?.completedAt, assistantMessageId: p.messageId,
        sourceProposedPlan: nil)
    }
    if p.role == .assistant, let turnId = p.turnId,
      thread.checkpoints.contains(where: { $0.turnId == turnId && $0.assistantMessageId != p.messageId })
    {
      t.checkpoints = thread.checkpoints.map { entry in
        guard entry.turnId == turnId else { return entry }
        var next = entry
        next.assistantMessageId = p.messageId
        return next
      }
    }
    t.messages = messages
    t.updatedAt = e.occurredAt
    return t
  }

  // MARK: Session

  private static func applySessionSet(_ thread: OrchestrationThread, _ e: OrchestrationEventThreadSessionSet) -> OrchestrationThread {
    var t = thread
    let session = e.payload.session
    if session.status == .running, let active = session.activeTurnId {
      let previous = thread.latestTurn?.turnId == active ? thread.latestTurn : nil
      t.latestTurn = OrchestrationLatestTurn(
        turnId: active, state: .running, requestedAt: previous?.requestedAt ?? session.updatedAt,
        startedAt: previous?.startedAt ?? session.updatedAt, completedAt: nil,
        assistantMessageId: previous?.assistantMessageId, sourceProposedPlan: nil)
    } else if var latest = thread.latestTurn, latest.state == .running, let settled = settledTurnState(session.status) {
      latest.state = settled
      // The session leaving "running" is the authoritative turn end.
      latest.completedAt = session.updatedAt
      t.latestTurn = latest
    }
    t.session = session
    t.updatedAt = e.occurredAt
    return t
  }

  private static func settledTurnState(_ status: OrchestrationSessionStatus) -> OrchestrationLatestTurnState? {
    switch status {
    case .idle, .ready: .completed
    case .error: .error
    case .interrupted, .stopped: .interrupted
    case .starting, .running: nil
    case .unknown: nil
    }
  }

  // MARK: Checkpoints

  private static func turnState(for status: OrchestrationCheckpointStatus) -> OrchestrationLatestTurnState {
    status == .error ? .error : .completed
  }

  private static func applyTurnDiff(_ thread: OrchestrationThread, _ e: OrchestrationEventThreadTurnDiffCompleted) -> ThreadReduceResult {
    let p = e.payload
    let checkpoint = OrchestrationCheckpointSummary(
      turnId: p.turnId, checkpointTurnCount: p.checkpointTurnCount, checkpointRef: p.checkpointRef,
      status: p.status, files: p.files, assistantMessageId: p.assistantMessageId, completedAt: p.completedAt)
    if let existing = thread.checkpoints.first(where: { $0.turnId == p.turnId }),
      existing.status != .missing, p.status == .missing
    {
      return .unchanged
    }
    var t = thread
    var checkpoints = thread.checkpoints.filter { $0.turnId != p.turnId }
    checkpoints.append(checkpoint)
    t.checkpoints = stableSorted(checkpoints) { l, r in l.checkpointTurnCount == r.checkpointTurnCount ? 0 : (l.checkpointTurnCount < r.checkpointTurnCount ? -1 : 1) }
    // Mid-turn diff updates produce placeholder checkpoints: don't settle a turn its session still runs.
    let stillRunning = thread.session?.status == .running && thread.session?.activeTurnId == p.turnId
    if !stillRunning, thread.latestTurn == nil || thread.latestTurn?.turnId == p.turnId {
      t.latestTurn = OrchestrationLatestTurn(
        turnId: p.turnId, state: thread.latestTurn?.state == .interrupted ? .interrupted : turnState(for: p.status),
        requestedAt: thread.latestTurn?.requestedAt ?? p.completedAt,
        startedAt: thread.latestTurn?.startedAt ?? p.completedAt, completedAt: p.completedAt,
        assistantMessageId: p.assistantMessageId, sourceProposedPlan: nil)
    }
    t.updatedAt = e.occurredAt
    return .updated(t)
  }

  private static func applyRevert(_ thread: OrchestrationThread, turnCount: Int, occurredAt: IsoDateTime) -> OrchestrationThread {
    var t = thread
    let checkpoints = stableSorted(thread.checkpoints.filter { $0.checkpointTurnCount <= turnCount }) { l, r in
      l.checkpointTurnCount == r.checkpointTurnCount ? 0 : (l.checkpointTurnCount < r.checkpointTurnCount ? -1 : 1)
    }
    let retainedTurnIds = Set(checkpoints.map(\.turnId))
    t.checkpoints = checkpoints
    t.messages = retainMessagesAfterRevert(thread.messages, retainedTurnIds: retainedTurnIds, turnCount: turnCount)
    t.proposedPlans = thread.proposedPlans.filter { $0.turnId == nil || retainedTurnIds.contains($0.turnId!) }
    t.activities = thread.activities.filter { $0.turnId == nil || retainedTurnIds.contains($0.turnId!) }
    if let latest = checkpoints.last {
      t.latestTurn = OrchestrationLatestTurn(
        turnId: latest.turnId, state: turnState(for: latest.status), requestedAt: latest.completedAt,
        startedAt: latest.completedAt, completedAt: latest.completedAt, assistantMessageId: latest.assistantMessageId,
        sourceProposedPlan: nil)
    } else {
      t.latestTurn = nil
    }
    t.updatedAt = occurredAt
    return t
  }

  private static func isImported(_ id: MessageId) -> Bool { id.rawValue.hasPrefix("import:") }

  private static func retainMessagesAfterRevert(
    _ messages: [OrchestrationMessage], retainedTurnIds: Set<TurnId>, turnCount: Int
  ) -> [OrchestrationMessage] {
    var retained = Set<MessageId>()
    for message in messages {
      if message.role == .system || isImported(message.id) {
        retained.insert(message.id)
      } else if let turnId = message.turnId, retainedTurnIds.contains(turnId) {
        retained.insert(message.id)
      }
    }
    for role in [OrchestrationMessageRole.user, .assistant] {
      let retainedCount = messages.filter { $0.role == role && !isImported($0.id) && retained.contains($0.id) }.count
      let missing = max(0, turnCount - retainedCount)
      let fallback = messages
        .filter { $0.role == role && !retained.contains($0.id) && ($0.turnId == nil || retainedTurnIds.contains($0.turnId!)) }
      let sorted = stableSorted(fallback) { l, r in
        let c = compareDateTimeStrings(l.createdAt.rawValue, r.createdAt.rawValue)
        return c != 0 ? c : JS.localeCompare(l.id.rawValue, r.id.rawValue)
      }
      for message in sorted.prefix(missing) { retained.insert(message.id) }
    }
    return messages.filter { retained.contains($0.id) }
  }

  // MARK: Activities

  /// (sequence ?? MAX, createdAt, id)
  static func activityOrder(_ l: OrchestrationThreadActivity, _ r: OrchestrationThreadActivity) -> Int {
    let ls = l.sequence ?? Int(Int32.max) << 32, rs = r.sequence ?? Int(Int32.max) << 32
    if ls != rs { return ls < rs ? -1 : 1 }
    if l.createdAt != r.createdAt { return JS.less(l.createdAt.rawValue, r.createdAt.rawValue) ? -1 : 1 }
    if l.id != r.id { return JS.less(l.id.rawValue, r.id.rawValue) ? -1 : 1 }
    return 0
  }

  /// A resolvable context-window update has a finite, non-negative `usedTokens`.
  static func isResolvableContextWindowActivity(_ activity: OrchestrationThreadActivity) -> Bool {
    guard activity.kind == "context-window.updated", case .object(let payload) = activity.payload else { return false }
    switch payload["usedTokens"] {
    case .int(let v)?: return v >= 0
    case .double(let v)?: return v.isFinite && v >= 0
    default: return false
    }
  }

  static func appendActivity(_ activities: [OrchestrationThreadActivity], _ activity: OrchestrationThreadActivity) -> [OrchestrationThreadActivity] {
    // A resolvable context-window update supersedes earlier resolvable ones of the same turn.
    let supersedes = isResolvableContextWindowActivity(activity)
    // Live streams append in order: an unseen id at/after the tail of a sorted array is a plain append.
    if !supersedes, let last = activities.last, activityOrder(last, activity) <= 0,
      !activities.contains(where: { $0.id == activity.id }), isSorted(activities)
    {
      return activities + [activity]
    }
    if !supersedes, activities.isEmpty { return [activity] }
    var next = activities.filter { entry in
      entry.id != activity.id && !(supersedes && entry.turnId == activity.turnId && isResolvableContextWindowActivity(entry))
    }
    next.append(activity)
    return stableSorted(next, by: activityOrder)
  }

  private static func isSorted(_ activities: [OrchestrationThreadActivity]) -> Bool {
    var previous: OrchestrationThreadActivity?
    for activity in activities {
      if let previous, activityOrder(previous, activity) > 0 { return false }
      previous = activity
    }
    return true
  }
}

/// `Array.prototype.sort` is stable; Swift's `sorted` does not promise it, so ties keep input order explicitly.
func stableSorted<T>(_ values: [T], by compare: (T, T) -> Int) -> [T] {
  values.enumerated().sorted { l, r in
    let c = compare(l.element, r.element)
    return c != 0 ? c < 0 : l.offset < r.offset
  }.map(\.element)
}

/// `compareDateTimeStrings` from packages/shared: by absolute time, malformed values first, then lexically.
func compareDateTimeStrings(_ left: String, _ right: String) -> Int {
  let l = IsoTimestamp.parse(left), r = IsoTimestamp.parse(right)
  switch (l, r) {
  case (let l?, let r?): return l == r ? 0 : (l < r ? -1 : 1)
  case (nil, nil): return JS.less(left, right) ? -1 : (JS.less(right, left) ? 1 : 0)
  case (_?, nil): return 1
  case (nil, _?): return -1
  }
}

/// Identity of a pull request link (`threadPullRequestKeysEqual`): host and repository compare
/// trimmed and lowercased, with the Azure DevOps SSH/VS host forms canonicalised.
struct PullRequestKey: Equatable {
  var host: String, repository: String, number: Int
  init(_ host: String, _ repository: String, _ number: Int) {
    let canonical = Self.canonical("\(host.trimmingCharacters(in: .whitespaces).lowercased())/\(repository.trimmingCharacters(in: .whitespaces).lowercased())")
    let slash = canonical.firstIndex(of: "/")!
    self.host = String(canonical[..<slash])
    self.repository = String(canonical[canonical.index(after: slash)...])
    self.number = number
  }
  static func equal(_ a: PullRequestKey, _ b: PullRequestKey) -> Bool { a == b }

  private static func canonical(_ key: String) -> String {
    var key = key
    if let m = key.firstMatch(#"^(?:ssh\.dev\.azure\.com|vs-ssh\.visualstudio\.com)/v3/([^/]+)/([^/]+)/([^/]+)$"#) {
      key = "dev.azure.com/\(m[1])/\(m[2])/_git/\(m[3])"
    }
    if let m = key.firstMatch(#"^([^.]+)\.visualstudio\.com/(?:defaultcollection/)?([^/]+)/_git/([^/]+)$"#) {
      key = "dev.azure.com/\(m[1])/\(m[2])/_git/\(m[3])"
    }
    return key
  }
}

extension String {
  fileprivate func firstMatch(_ pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
    else { return nil }
    return (0..<match.numberOfRanges).map { String(self[Range(match.range(at: $0), in: self)!]) }
  }
}

extension OrchestrationThreadShellPullRequestsItem {
  fileprivate var key: PullRequestKey { PullRequestKey(host, repository, number) }
}
