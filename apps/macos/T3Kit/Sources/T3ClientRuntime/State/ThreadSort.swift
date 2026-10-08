import Foundation
import T3Contracts

/// Port of `state/threadSort.ts`: settled / pinned / active ordering and the fractional
/// order keys that let one write move one thread.
public enum ThreadSort {
  static func sortable(_ iso: IsoDateTime?) -> Double? { iso.flatMap(IsoTimestamp.parse) }

  /// The timestamp a settled row sorts and labels by: settledAt when stamped, otherwise the
  /// latest message or turn stamp, then updatedAt.
  public static func resolveSettledThreadTimestamp(_ thread: OrchestrationThreadShell) -> IsoDateTime? {
    if let settledAt = thread.settledAt, sortable(settledAt) != nil { return settledAt }
    var latest: IsoDateTime?
    var latestMs = -Double.infinity
    for candidate in [thread.latestUserMessageAt, thread.latestTurn?.requestedAt, thread.latestTurn?.startedAt, thread.latestTurn?.completedAt] {
      if let candidate, let parsed = sortable(candidate), parsed > latestMs {
        latest = candidate
        latestMs = parsed
      }
    }
    if let latest { return latest }
    return sortable(thread.updatedAt) == nil ? nil : thread.updatedAt
  }

  /// Settled rows are history: newest end first, id tiebreak.
  public static func sortSettled(_ threads: [EnvironmentThreadShell]) -> [EnvironmentThreadShell] {
    let keyed = threads.map { thread -> (EnvironmentThreadShell, Double) in
      let timestamp = resolveSettledThreadTimestamp(thread.shell)
      return (thread, timestamp.flatMap(IsoTimestamp.parse) ?? 0)
    }
    return stableSorted(keyed) { l, r in
      if l.1 != r.1 { return r.1 < l.1 ? -1 : 1 }
      return JS.localeCompare(l.0.shell.id.rawValue, r.0.shell.id.rawValue)
    }.map(\.0)
  }

  /// Sort anchor for the active list: creation time, re-anchored to unsettledAt on re-entry.
  private static func activeAnchor(_ shell: OrchestrationThreadShell) -> Double {
    max(sortable(shell.createdAt) ?? 0, sortable(optionalValue(shell.unsettledAt)) ?? 0)
  }

  private static func identityTiebreak(_ l: EnvironmentThreadShell, _ r: EnvironmentThreadShell) -> Int {
    let c = JS.localeCompare(l.shell.id.rawValue, r.shell.id.rawValue)
    return c != 0 ? c : JS.localeCompare(l.environmentId.rawValue, r.environmentId.rawValue)
  }

  /// Pinned block: user-arranged keys first (string order, id tiebreak), then keyless threads newest-created first.
  public static func sortPinned(_ threads: [EnvironmentThreadShell]) -> [EnvironmentThreadShell] {
    if threads.count < 2 { return threads }
    var keyed: [(EnvironmentThreadShell, String)] = []
    var keyless: [EnvironmentThreadShell] = []
    for thread in threads {
      if let key = optionalValue(thread.shell.pinOrderKey) { keyed.append((thread, key)) } else { keyless.append(thread) }
    }
    let sortedKeyed = stableSorted(keyed) { l, r in
      l.1 == r.1 ? identityTiebreak(l.0, r.0) : (JS.less(l.1, r.1) ? -1 : 1)
    }.map(\.0)
    let timestamps = keyless.map { sortable($0.shell.createdAt) ?? 0 }
    let order = stableSorted(Array(keyless.indices)) { a, b in
      timestamps[a] != timestamps[b] ? (timestamps[b] < timestamps[a] ? -1 : 1) : identityTiebreak(keyless[a], keyless[b])
    }
    return sortedKeyed + order.map { keyless[$0] }
  }

  /// New and reopened threads lead the active list; arranged threads follow their saved keys.
  public static func sortActive(_ threads: [EnvironmentThreadShell]) -> [EnvironmentThreadShell] {
    if threads.count < 2 { return threads }
    let anchors = threads.map { optionalValue($0.shell.activeOrderKey) == nil ? activeAnchor($0.shell) : 0 }
    let indices = stableSorted(Array(threads.indices)) { a, b in
      let lk = optionalValue(threads[a].shell.activeOrderKey), rk = optionalValue(threads[b].shell.activeOrderKey)
      if lk == nil, rk != nil { return -1 }
      if lk != nil, rk == nil { return 1 }
      var order = 0
      if let lk, let rk {
        order = lk == rk ? 0 : (JS.less(lk, rk) ? -1 : 1)
      } else {
        let diff = anchors[b] - anchors[a]
        order = diff == 0 ? 0 : (diff < 0 ? -1 : 1)
      }
      return order != 0 ? order : identityTiebreak(threads[a], threads[b])
    }
    return indices.map { threads[$0] }
  }

  /// Timestamp for `updated_at` / `created_at` list orders.
  public enum SortOrder: String, Sendable { case updatedAt = "updated_at", createdAt = "created_at" }

  public static func sortTimestamp(_ shell: OrchestrationThreadShell, order: SortOrder) -> Double {
    if order == .createdAt { return sortable(shell.createdAt) ?? sortable(shell.updatedAt) ?? -.infinity }
    if let latest = sortable(shell.latestUserMessageAt) { return latest }
    return sortable(shell.updatedAt) ?? sortable(shell.createdAt) ?? -.infinity
  }

  public static func sortThreads(_ threads: [EnvironmentThreadShell], order: SortOrder) -> [EnvironmentThreadShell] {
    if threads.count < 2 { return threads }
    let keyed = threads.map { ($0, sortTimestamp($0.shell, order: order)) }
    return stableSorted(keyed) { l, r in
      if l.1 != r.1 { return r.1 < l.1 ? -1 : 1 }
      let (a, b) = (l.0.shell.id.rawValue, r.0.shell.id.rawValue)
      return JS.less(a, b) ? 1 : (JS.less(b, a) ? -1 : 0)
    }.map(\.0)
  }

  // MARK: Fractional order keys

  private static let digits = Array("abcdefghijklmnopqrstuvwxyz")

  private static func isValidKey(_ key: String) -> Bool {
    if key.isEmpty { return false }
    for c in key where !digits.contains(c) { return false }
    // A trailing minimum digit would leave no room before this key; generators never produce it.
    return key.last != digits[0]
  }

  private static func charAt(_ s: [Character], _ i: Int) -> Character? { i < s.count ? s[i] : nil }

  /// Midpoint of two digit strings read as fractions in (0, 1); "" is the open bound. Requires a < b.
  private static func midpoint(_ a: [Character], _ b: [Character]) -> [Character] {
    if !b.isEmpty {
      // Recurse past the longest common prefix ("a" pads the shorter side).
      var n = 0
      while (charAt(a, n) ?? digits[0]) == charAt(b, n) { n += 1 }
      if n > 0 { return Array(b[0..<n]) + midpoint(Array(a.dropFirst(min(n, a.count))), Array(b.dropFirst(n))) }
    }
    let digitA = a.isEmpty ? 0 : digits.firstIndex(of: a[0])!
    let digitB = b.isEmpty ? digits.count : digits.firstIndex(of: b[0])!
    if digitB - digitA > 1 { return [digits[Int((Double(digitA + digitB) / 2 + 0.5).rounded(.down))]] }
    // Consecutive leading digits: shorten into b's spare digits, or extend a.
    if b.count > 1 { return [b[0]] }
    return [digits[digitA]] + midpoint(Array(a.dropFirst()), [])
  }

  /// Key that sorts strictly between two neighbours; nil bounds are the open ends. Nil when keys are corrupt or out of order.
  public static func pinOrderKeyBetween(_ before: String?, _ after: String?) -> String? {
    let a = before ?? "", b = after ?? ""
    if !a.isEmpty, !isValidKey(a) { return nil }
    if !b.isEmpty, !isValidKey(b) { return nil }
    if !b.isEmpty, !JS.less(a, b) { return nil }
    return String(midpoint(Array(a), Array(b)))
  }

  /// Evenly spaced keys for materialising an order.
  public static func generateSpreadPinOrderKeys(_ count: Int) -> [String] {
    var width = 2
    var space = pow(Double(digits.count), Double(width))
    while space <= Double(count + 1) * 2 {
      width += 1
      space *= Double(digits.count)
    }
    let step = space / Double(count + 1)
    var keys: [String] = []
    for i in 0..<count {
      var value = Int((step * Double(i + 1) + 0.5).rounded(.down))
      if value % digits.count == 0 { value += 1 }  // skip a trailing minimum digit
      var key = ""
      for _ in 0..<width {
        key = String(digits[value % digits.count]) + key
        value /= digits.count
      }
      keys.append(key)
    }
    return keys
  }

  public struct KeyAssignment: Sendable, Equatable { public let id: String; public let orderKey: String }

  /// Assignments needed to realise a new order: one write when the moved thread sits between two
  /// keyed (or absent) neighbours, otherwise the whole section gets fresh spread keys.
  public static func planPinnedReorder(orderedIds: [String], keysById: [String: String?], movedId: String) -> [KeyAssignment] {
    let visible = Set(orderedIds)
    let reserved = Set(keysById.compactMap { id, key in !visible.contains(id) ? key.flatMap { $0 } : nil })
    guard let movedIndex = orderedIds.firstIndex(of: movedId) else { return [] }
    let beforeId = movedIndex > 0 ? orderedIds[movedIndex - 1] : nil
    let afterId = movedIndex < orderedIds.count - 1 ? orderedIds[movedIndex + 1] : nil
    let beforeKey = beforeId.flatMap { keysById[$0] ?? nil }
    let afterKey = afterId.flatMap { keysById[$0] ?? nil }
    let beforeUsable = beforeId == nil || beforeKey != nil
    let afterUsable = afterId == nil || afterKey != nil
    if beforeUsable, afterUsable {
      var key = pinOrderKeyBetween(beforeKey, afterKey)
      while let k = key, reserved.contains(k) { key = pinOrderKeyBetween(k, afterKey) }
      if let key { return [KeyAssignment(id: movedId, orderKey: key)] }
    }
    // Keyless neighbour (or corrupt keys): rewrite the section in the new order.
    let keys = Array(generateSpreadPinOrderKeys(orderedIds.count + reserved.count).filter { !reserved.contains($0) }.prefix(orderedIds.count))
    return orderedIds.enumerated().compactMap { index, id in
      (keysById[id] ?? nil) == keys[index] ? nil : KeyAssignment(id: id, orderKey: keys[index])
    }
  }

  /// `planPinnedReorder` for Move up / Move down: swap with the displayed neighbour; nil off either end.
  public static func planPinnedMove(orderedIds: [String], keysById: [String: String?], movedId: String, up: Bool) -> [KeyAssignment]? {
    guard let from = orderedIds.firstIndex(of: movedId) else { return nil }
    let to = up ? from - 1 : from + 1
    guard to >= 0, to < orderedIds.count else { return nil }
    var order = orderedIds
    order.remove(at: from)
    order.insert(movedId, at: to)
    return planPinnedReorder(orderedIds: order, keysById: keysById, movedId: movedId)
  }
}
