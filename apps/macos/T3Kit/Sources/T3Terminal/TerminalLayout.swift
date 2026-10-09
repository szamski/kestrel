import Foundation

/// The drawer's terminals for one thread, grouped like the web client's `terminalUiStateStore`:
/// each group is a tab; the terminals inside a group are split panes (side by side, or stacked when
/// the group is vertical). Pure value type; the drawer model owns one per thread.
public struct TerminalLayout: Sendable, Hashable {
  public struct Group: Sendable, Hashable, Identifiable {
    public var id: String
    public var terminalIds: [String]
    /// Panes stacked top to bottom instead of side by side.
    public var isVertical = false
  }

  public static let defaultTerminalId = "term-1"
  public static let maxTerminalsPerGroup = 4

  public private(set) var terminalIds: [String]
  public private(set) var activeTerminalId: String
  public private(set) var groups: [Group]
  public private(set) var activeGroupId: String

  public init() {
    terminalIds = [Self.defaultTerminalId]
    activeTerminalId = Self.defaultTerminalId
    groups = [Group(id: Self.groupId(for: Self.defaultTerminalId), terminalIds: [Self.defaultTerminalId])]
    activeGroupId = groups[0].id
  }

  private static func groupId(for terminalId: String) -> String { "group-\(terminalId)" }

  /// `term-N` with the lowest free N (`nextTerminalId` in packages/shared).
  public static func nextTerminalId(existing: [String]) -> String {
    let used = Set(existing.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    var index = 1
    while used.contains("term-\(index)") { index += 1 }
    return "term-\(index)"
  }

  public var activeGroup: Group? { groups.first { $0.id == activeGroupId } }

  /// The active group is full; splitting again would be refused.
  public var hasReachedSplitLimit: Bool { (activeGroup?.terminalIds.count ?? 0) >= Self.maxTerminalsPerGroup }

  // MARK: Edits

  /// A new tab.
  public mutating func newTerminal(_ id: String) { upsert(id, split: false) }

  /// A new pane next to the active terminal, in the active group.
  public mutating func split(_ id: String, vertical: Bool = false) { upsert(id, split: true, vertical: vertical) }

  public mutating func activate(_ id: String) {
    guard terminalIds.contains(id) else { return }
    activeTerminalId = id
    activeGroupId = groups.first { $0.terminalIds.contains(id) }?.id ?? activeGroupId
  }

  /// Removes a terminal; closing the last one resets to the default layout.
  public mutating func close(_ id: String) {
    guard terminalIds.contains(id) else { return }
    let remaining = terminalIds.filter { $0 != id }
    guard !remaining.isEmpty else { self = TerminalLayout(); return }
    let closedIndex = terminalIds.firstIndex(of: id) ?? 0
    let nextActive = activeTerminalId == id ? remaining[min(closedIndex, remaining.count - 1)] : activeTerminalId
    var nextGroups: [Group] = []
    for var group in groups {
      group.terminalIds.removeAll { $0 == id }
      if !group.terminalIds.isEmpty { nextGroups.append(group) }
    }
    terminalIds = remaining
    groups = nextGroups
    activeTerminalId = nextActive
    activeGroupId = groups.first { $0.terminalIds.contains(nextActive) }?.id ?? groups.first?.id ?? Self.groupId(for: nextActive)
  }

  /// Aligns the layout with the terminals the server reports for the thread. A server list that is
  /// a strict subset of ours is ignored: it means a terminal we just opened is not in metadata yet.
  public mutating func reconcile(serverTerminalIds: [String], suppressed: Set<String> = []) {
    let next = serverTerminalIds.filter { !suppressed.contains($0) }
    if next == terminalIds || (Set(next).isStrictSubset(of: terminalIds)) { return }
    let active = next.contains(activeTerminalId) ? activeTerminalId : (next.first ?? "")
    let kept = groups.compactMap { group -> Group? in
      var group = group
      group.terminalIds = group.terminalIds.filter(next.contains)
      return group.terminalIds.isEmpty ? nil : group
    }
    var nextGroups = kept
    var used = Set(kept.map(\.id))
    for id in next where !nextGroups.contains(where: { $0.terminalIds.contains(id) }) {
      nextGroups.append(Group(id: Self.uniqueGroupId(Self.groupId(for: id), used: &used), terminalIds: [id]))
    }
    terminalIds = next
    groups = nextGroups
    activeTerminalId = active
    activeGroupId = nextGroups.first { $0.terminalIds.contains(active) }?.id ?? nextGroups.first?.id ?? ""
  }

  // MARK: Internals

  private static func uniqueGroupId(_ base: String, used: inout Set<String>) -> String {
    var candidate = base
    var index = 2
    while used.contains(candidate) { candidate = "\(base)-\(index)"; index += 1 }
    used.insert(candidate)
    return candidate
  }

  private mutating func upsert(_ rawId: String, split: Bool, vertical: Bool = false) {
    let id = rawId.trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty else { return }
    let isSplit = split && !terminalIds.isEmpty
    let isNew = !terminalIds.contains(id)
    let ids = isNew ? terminalIds + [id] : terminalIds
    var nextGroups = groups
    if let index = nextGroups.firstIndex(where: { $0.terminalIds.contains(id) }) {
      nextGroups[index].terminalIds.removeAll { $0 == id }
      if nextGroups[index].terminalIds.isEmpty { nextGroups.remove(at: index) }
    }
    var used = Set(nextGroups.map(\.id))

    guard isSplit else {
      let groupId = Self.uniqueGroupId(Self.groupId(for: id), used: &used)
      nextGroups.append(Group(id: groupId, terminalIds: [id]))
      commit(ids, nextGroups, active: id, group: groupId)
      return
    }

    var destination = nextGroups.firstIndex { $0.id == activeGroupId } ?? nextGroups.firstIndex { $0.terminalIds.contains(activeTerminalId) }
    if destination == nil {
      nextGroups.append(Group(id: Self.uniqueGroupId(Self.groupId(for: activeTerminalId), used: &used), terminalIds: [activeTerminalId]))
      destination = nextGroups.count - 1
    }
    guard let destination else { return }
    if isNew && !nextGroups[destination].terminalIds.contains(id) && nextGroups[destination].terminalIds.count >= Self.maxTerminalsPerGroup { return }
    if !nextGroups[destination].terminalIds.contains(id) {
      if let anchor = nextGroups[destination].terminalIds.firstIndex(of: activeTerminalId) {
        nextGroups[destination].terminalIds.insert(id, at: anchor + 1)
      } else {
        nextGroups[destination].terminalIds.append(id)
      }
    }
    nextGroups[destination].isVertical = vertical
    commit(ids, nextGroups, active: id, group: nextGroups[destination].id)
  }

  private mutating func commit(_ ids: [String], _ nextGroups: [Group], active: String, group: String) {
    terminalIds = ids
    groups = nextGroups
    activeTerminalId = active
    activeGroupId = group
  }
}
