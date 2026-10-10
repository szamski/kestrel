import Foundation
import T3Contracts

/// One sidebar row: the partitioned thread plus the client-derived flags a row renders.
public struct SidebarRow: Sendable, Equatable, Identifiable {
  public var item: ThreadListLayout.Item
  public var thread: EnvironmentThreadShell { item.thread }
  public var id: String { item.id }
  public var section: ThreadListLayout.Section
  public var status: ThreadRowStatus
  /// A completed turn the user has not visited since (a never-visited thread counts as read).
  public var isUnread: Bool
  /// The thread woke from a snooze after the user last visited it.
  public var isWoke: Bool
  public var wokeAt: IsoDateTime?
  /// "2h", "3d" for snoozed rows.
  public var snoozeWakeLabel: String?
  /// Whether the thread may be snoozed right now (not blocked on the user, no queued turn start).
  public var canSnooze: Bool
}

/// The sidebar as sections, in display order: Pinned, Active, Snoozed shelf, Settled shelf.
public struct SidebarModel: Sendable, Equatable {
  public var layout = ThreadListLayout()
  public var rows: [SidebarRow] = []
  public var pinned: [SidebarRow] { rows.filter { $0.section == .pinned } }
  public var active: [SidebarRow] { rows.filter { $0.section == .active } }
  public var snoozed: [SidebarRow] { rows.filter { $0.section == .snoozed } }
  public var settled: [SidebarRow] { rows.filter { $0.section == .settled } }
  public var isEmpty: Bool { rows.isEmpty }
  public init() {}

  static func build(
    input: ThreadListInput, lastVisitedAtById: [String: IsoDateTime]
  ) -> SidebarModel {
    var model = SidebarModel()
    model.layout = ThreadList.build(input)
    model.rows = model.layout.items.map { item in
      let shell = item.thread.shell
      let lastVisited = lastVisitedAtById[item.thread.id]
      let wokeAt = ThreadSettled.threadWokeAt(shell, now: input.now)
      return SidebarRow(
        item: item, section: model.layout.section(of: item), status: ThreadList.status(shell),
        isUnread: ThreadList.hasUnseenCompletion(shell, lastVisitedAt: lastVisited),
        isWoke: ThreadList.isWoke(shell, wokeAt: wokeAt, lastVisitedAt: lastVisited), wokeAt: wokeAt,
        snoozeWakeLabel: item.snoozed ? optionalValue(shell.snoozedUntil).map { ThreadSettled.snoozeWakeLabel($0, now: input.now) } : nil,
        canSnooze: !item.thread.startPending && ThreadSettled.canSnooze(shell, now: input.now))
    }
    return model
  }
}

/// Client-side sidebar filters.
public struct SidebarFilter: Sendable, Equatable {
  public var searchQuery = ""
  public var environmentId: EnvironmentId?
  public var projectRefs: [ScopedProjectRef]?
  public var snoozedShelfExpanded = false
  public var settledShelfExpanded = true
  /// Keeps the open thread's row visible on a collapsed shelf.
  public var selectedThread: ScopedThreadKey?
  /// Settled threads to show before "Show more".
  public var settledLimit: Int?
  public init() {}
}

extension V1.OrchestrationThread {
  /// `mergeEnvironmentThread`: shell and detail subscriptions are independent, so a cached detail can
  /// briefly outlive a newer shell. The shell is authoritative for metadata (branch, worktree, lifecycle
  /// stamps, session); the detail contributes messages, activities, plans and checkpoints.
  public func merged(with shell: V1.OrchestrationThreadShell) -> V1.OrchestrationThread {
    var t = self
    t.projectId = shell.projectId
    t.title = shell.title
    t.modelSelection = shell.modelSelection
    t.runtimeMode = shell.runtimeMode
    t.interactionMode = shell.interactionMode
    t.branch = shell.branch
    t.worktreePath = shell.worktreePath
    t.latestTurn = shell.latestTurn
    t.createdAt = shell.createdAt
    t.updatedAt = shell.updatedAt
    t.archivedAt = shell.archivedAt
    t.settledOverride = shell.settledOverride
    t.settledAt = shell.settledAt
    t.unsettledAt = shell.unsettledAt
    t.activeOrderKey = shell.activeOrderKey
    t.autoSettleDisabledAt = shell.autoSettleDisabledAt
    t.snoozedUntil = shell.snoozedUntil
    t.snoozedAt = shell.snoozedAt
    t.pinnedAt = shell.pinnedAt
    t.pinOrderKey = shell.pinOrderKey
    t.session = shell.session
    return t
  }
}
