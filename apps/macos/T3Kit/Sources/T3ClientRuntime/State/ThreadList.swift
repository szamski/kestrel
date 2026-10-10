import Foundation
import T3Contracts

/// Port of `buildThreadListV2Items` (apps/mobile/src/features/threads/threadListV2.ts), which is
/// itself the web sidebar v2 partition: Pinned / Active cards, then the Snoozed shelf, then Settled.
public struct ThreadListLayout: Sendable, Equatable {
  public struct Item: Sendable, Equatable, Identifiable {
    public enum Variant: String, Sendable { case card, slim }
    public var thread: EnvironmentThreadShell
    public var variant: Variant
    /// Snoozed-shelf row: shows the wake countdown and offers Wake.
    public var snoozed: Bool
    /// Pinned-block row.
    public var pinned: Bool
    public var isLast: Bool
    public var id: String { thread.id }
  }

  public var items: [Item] = []
  /// Settled threads beyond the render limit.
  public var hiddenSettledCount = 0
  public var snoozedCount = 0
  public var snoozedShelfHeaderIndex: Int?
  public var settledCount = 0
  public var settledShelfHeaderIndex: Int?
  /// Soonest wake time among snoozed threads; arm a timer here so the list re-partitions on expiry.
  public var nextSnoozeWakeAt: IsoDateTime?

  public enum Section: Sendable { case pinned, active, snoozed, settled }

  public func section(of item: Item) -> Section {
    if item.snoozed { return .snoozed }
    if item.variant == .slim { return .settled }
    return item.pinned ? .pinned : .active
  }
}

public struct ThreadListInput: Sendable {
  public var threads: [EnvironmentThreadShell]
  public var environmentId: EnvironmentId?
  public var projectRefs: [ScopedProjectRef]?
  public var searchQuery: String
  /// `ThreadList.matchKey` of content-search hits from the server.
  public var matchedThreadKeys: Set<String>?
  /// Environments whose server supports thread.settle/unsettle; nil = no gating.
  public var settlementEnvironmentIds: Set<EnvironmentId>?
  public var snoozeEnvironmentIds: Set<EnvironmentId>?
  public var settledLimit: Int?
  public var now: IsoDateTime
  public var snoozedShelfExpanded: Bool
  public var settledShelfExpanded: Bool
  public var selectedThreadKey: String?
  /// Threads with a message waiting in the outbox stay active even when the server settled them.
  public var queuedThreadKeys: Set<String>?

  public init(
    threads: [EnvironmentThreadShell], environmentId: EnvironmentId? = nil, projectRefs: [ScopedProjectRef]? = nil,
    searchQuery: String = "", matchedThreadKeys: Set<String>? = nil, settlementEnvironmentIds: Set<EnvironmentId>? = nil,
    snoozeEnvironmentIds: Set<EnvironmentId>? = nil, settledLimit: Int? = nil, now: IsoDateTime,
    snoozedShelfExpanded: Bool = false, settledShelfExpanded: Bool = true, selectedThreadKey: String? = nil,
    queuedThreadKeys: Set<String>? = nil
  ) {
    self.threads = threads
    self.environmentId = environmentId
    self.projectRefs = projectRefs
    self.searchQuery = searchQuery
    self.matchedThreadKeys = matchedThreadKeys
    self.settlementEnvironmentIds = settlementEnvironmentIds
    self.snoozeEnvironmentIds = snoozeEnvironmentIds
    self.settledLimit = settledLimit
    self.now = now
    self.snoozedShelfExpanded = snoozedShelfExpanded
    self.settledShelfExpanded = settledShelfExpanded
    self.selectedThreadKey = selectedThreadKey
    self.queuedThreadKeys = queuedThreadKeys
  }
}

public enum ThreadList {
  /// `threadSearchMatchKey`: `JSON.stringify([environmentId, threadId])`.
  public static func matchKey(environmentId: EnvironmentId, threadId: ThreadId) -> String {
    let data = try! JSONEncoder().encode([environmentId.rawValue, threadId.rawValue])
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
  }

  /// Search terms of a thread's visible pull request links (`threadPullRequestSearchTerms`).
  static func pullRequestSearchTerms(_ shell: V1.OrchestrationThreadShell) -> [String] {
    if !shell.pullRequests.isEmpty {
      return shell.pullRequests.filter { $0.source != .stackDismissed }.flatMap { link in
        ["#\(link.number)", "\(link.repository)#\(link.number)", link.url, link.snapshot?.title ?? ""]
      }
    }
    if let legacy = optionalValue(shell.linkedPullRequest) {
      return ["#\(legacy.number)", "\(legacy.repository)#\(legacy.number)", legacy.url]
    }
    return []
  }

  public static func build(_ input: ThreadListInput) -> ThreadListLayout {
    let now = input.now
    let query = input.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let projectKeys = input.projectRefs.map { Set($0.map { "\($0.environmentId.rawValue):\($0.projectId.rawValue)" }) }

    var pinned: [EnvironmentThreadShell] = [], active: [EnvironmentThreadShell] = []
    var settled: [EnvironmentThreadShell] = [], snoozed: [EnvironmentThreadShell] = []
    var nextWake: IsoDateTime?
    for thread in input.threads {
      let shell = thread.shell
      if let environmentId = input.environmentId, thread.environmentId != environmentId { continue }
      if let projectKeys, !projectKeys.contains("\(thread.environmentId.rawValue):\(shell.projectId.rawValue)") { continue }
      if !query.isEmpty,
        !shell.title.lowercased().contains(query),
        !pullRequestSearchTerms(shell).contains(where: { $0.lowercased().contains(query) }),
        input.matchedThreadKeys?.contains(matchKey(environmentId: thread.environmentId, threadId: shell.id)) != true
      {
        continue
      }
      let supportsSettlement = input.settlementEnvironmentIds?.contains(thread.environmentId) ?? true
      let supportsSnooze = input.snoozeEnvironmentIds?.contains(thread.environmentId) ?? true
      // Snooze outranks settlement and pinning until the thread wakes.
      if supportsSnooze, ThreadSettled.effectiveSnoozed(shell, now: now) {
        snoozed.append(thread)
        if let until = optionalValue(shell.snoozedUntil),
          nextWake == nil || (IsoTimestamp.parse(until) ?? 0) < (IsoTimestamp.parse(nextWake!) ?? 0)
        {
          nextWake = until
        }
        continue
      }
      let queued = input.queuedThreadKeys?.contains(thread.id) == true
      if supportsSettlement, shell.settledOverride == .settled, !queued {
        settled.append(thread)
      } else if optionalValue(shell.pinnedAt) != nil {
        pinned.append(thread)
      } else {
        active.append(thread)
      }
    }

    let orderedActive = ThreadSort.sortActive(active)
    let orderedSnoozed = stableSorted(snoozed) { l, r in
      let a = optionalValue(l.shell.snoozedUntil).flatMap(IsoTimestamp.parse) ?? 0
      let b = optionalValue(r.shell.snoozedUntil).flatMap(IsoTimestamp.parse) ?? 0
      return a == b ? 0 : (a < b ? -1 : 1)
    }
    let selected = input.selectedThreadKey
    let visibleSnoozed = input.snoozedShelfExpanded ? orderedSnoozed : orderedSnoozed.filter { $0.id == selected }
    let orderedSettled = ThreadSort.sortSettled(settled)
    let limit = input.settledLimit ?? Int.max
    var pagedSettled = orderedSettled.count > limit ? Array(orderedSettled.prefix(limit)) : orderedSettled
    if let selectedSettled = orderedSettled.dropFirst(pagedSettled.count).first(where: { $0.id == selected }) {
      pagedSettled.append(selectedSettled)
    }
    let visibleSettled = input.settledShelfExpanded ? pagedSettled : pagedSettled.filter { $0.id == selected }

    var layout = ThreadListLayout()
    func add(_ thread: EnvironmentThreadShell, _ variant: ThreadListLayout.Item.Variant, snoozed: Bool, pinned: Bool) {
      layout.items.append(.init(thread: thread, variant: variant, snoozed: snoozed, pinned: pinned, isLast: false))
    }
    for thread in ThreadSort.sortPinned(pinned) { add(thread, .card, snoozed: false, pinned: true) }
    for thread in orderedActive { add(thread, .card, snoozed: false, pinned: false) }
    layout.snoozedShelfHeaderIndex = orderedSnoozed.isEmpty ? nil : layout.items.count
    for thread in visibleSnoozed { add(thread, .slim, snoozed: true, pinned: false) }
    layout.settledShelfHeaderIndex = orderedSettled.isEmpty ? nil : layout.items.count
    for thread in visibleSettled { add(thread, .slim, snoozed: false, pinned: false) }
    if !layout.items.isEmpty { layout.items[layout.items.count - 1].isLast = true }
    layout.hiddenSettledCount = orderedSettled.count - pagedSettled.count
    layout.snoozedCount = orderedSnoozed.count
    layout.settledCount = orderedSettled.count
    layout.nextSnoozeWakeAt = nextWake
    return layout
  }
}

// MARK: Row status

public enum ThreadRowStatus: String, Sendable { case approval, input, working, monitoring, failed, ready }

extension ThreadList {
  /// `resolveSidebarThreadStatus` (web Sidebar.logic.ts): approval > input > working > failed > background > ready.
  public static func status(_ shell: V1.OrchestrationThreadShell) -> ThreadRowStatus {
    if shell.hasPendingApprovals { return .approval }
    if shell.hasPendingUserInput { return .input }
    if shell.session?.status == .running || shell.session?.status == .starting { return .working }
    if shell.session?.status == .error { return .failed }
    switch optionalValue(shell.backgroundLiveness) {
    case .working?: return .working
    case .monitoring?: return .monitoring
    default: return .ready
    }
  }

  /// `hasUnseenCompletion`: a never-visited thread counts as read.
  public static func hasUnseenCompletion(_ shell: V1.OrchestrationThreadShell, lastVisitedAt: IsoDateTime?) -> Bool {
    guard let completedAt = shell.latestTurn?.completedAt, let completed = IsoTimestamp.parse(completedAt) else { return false }
    guard let lastVisitedAt else { return false }
    guard let visited = IsoTimestamp.parse(lastVisitedAt) else { return true }
    return completed > visited
  }

  /// The "Woke" pill: the thread woke after the user last visited it and is not settled.
  public static func isWoke(_ shell: V1.OrchestrationThreadShell, wokeAt: IsoDateTime?, lastVisitedAt: IsoDateTime?) -> Bool {
    guard let wokeAt, let woke = IsoTimestamp.parse(wokeAt), shell.settledOverride != .settled else { return false }
    guard let lastVisitedAt, let visited = IsoTimestamp.parse(lastVisitedAt) else { return true }
    return visited < woke
  }
}
