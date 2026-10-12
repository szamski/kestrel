import Foundation
import T3Contracts

// The pull request inbox: typed query, grouping by involvement, sort, local narrowing and facets.
// Ports of the parts of `pullRequestList.logic.ts` that do not belong to the web's paging cache.

/// A listed change request with the environment that read it. The page unions every connected environment, so acting on
/// a row, refreshing it or opening its detail all need the tag the listing itself does not carry.
public struct EnvironmentPullRequestEntry: Sendable, Hashable, Identifiable {
  public var environmentId: EnvironmentId
  public var entry: PullRequestListEntry

  public init(environmentId: EnvironmentId, entry: PullRequestListEntry) {
    self.environmentId = environmentId
    self.entry = entry
  }

  /// Repository plus number is unique on one host; the environment on top, because two machines can hold the same repository.
  public var id: String { "\(environmentId.rawValue):\(entry.host):\(entry.repository)#\(entry.number)" }

  /// The reference every RPC about this pull request takes.
  public var reference: PullRequestRef { PullRequestRef(projectId: entry.projectId, host: entry.host, repository: entry.repository, number: entry.number) }
}

public enum PullRequestListSort: String, Sendable, CaseIterable, Codable {
  case ready, blocked, updated, newest, oldest, largest, smallest

  public var title: String {
    switch self {
    case .ready: "Ready to merge"
    case .blocked: "Blocked"
    case .updated: "Recently updated"
    case .newest: "Newest"
    case .oldest: "Oldest"
    case .largest: "Largest diff"
    case .smallest: "Smallest diff"
    }
  }
}

public enum PullRequestGroupKey: String, Sendable {
  case reviewRequested, authored, others

  public var title: String {
    switch self {
    case .reviewRequested: "Review requested"
    case .authored: "Authored"
    case .others: "Others"
    }
  }
}

public struct PullRequestGroup: Sendable, Identifiable {
  public var key: PullRequestGroupKey
  public var entries: [EnvironmentPullRequestEntry]

  public init(key: PullRequestGroupKey, entries: [EnvironmentPullRequestEntry]) {
    self.key = key
    self.entries = entries
  }

  public var id: String { key.rawValue }
  public var title: String { key.title }
}

public struct PullRequestAuthorFacet: Sendable, Hashable, Identifiable {
  public var actor: PullRequestActor
  public var count: Int
  public var mergedCount: Int
  public var id: String { actor.login.lowercased() }
}

public struct PullRequestLabelFacet: Sendable, Hashable, Identifiable {
  public var name: String
  public var color: String?
  public var count: Int
  public var id: String { name.lowercased() }
}

public enum PullRequestListLogic {
  // MARK: Typed query

  /// A typed query split into the qualifiers the hosts can act on and the text that is left: `label:foo`,
  /// `-label:"needs design"`, `author:octocat`, `draft:true`, `review:approved`, `status:success`. An unknown key is read as
  /// the namespaced label it almost always is (`size:XXL`); quoting is the way back to plain text.
  public static func parseQuery(_ raw: String) -> (text: String, filters: PullRequestListFilters) {
    var text: [String] = []
    var labels: [[String]] = []
    var excluded: [String] = []
    var author: String?
    var draft: PullRequestListFiltersDraft?
    var review: PullRequestListFiltersReview?
    var checks: PullRequestListFiltersChecks?
    let maxValues = 10, maxLength = 200

    func unquote(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces) }
    func list(_ raw: String) -> [String] {
      // Quoting names one whole label however many commas it holds.
      if raw.captures(#"^\s*"[^"]*"\s*$"#) != nil { let whole = unquote(raw); return whole.isEmpty ? [] : [whole] }
      return raw.split(separator: ",", omittingEmptySubsequences: false).map { unquote(String($0)) }.filter { !$0.isEmpty }
    }
    func bounded(_ names: [String]) -> [String] {
      names.prefix(maxValues).map { String($0.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    for token in tokens(raw) {
      guard let qualifier = token.captures(#"^(-?)([A-Za-z][A-Za-z0-9_-]*):(.*)$"#) else {
        text.append(token)
        continue
      }
      let negated = qualifier[1] == "-"
      let key = qualifier[2].lowercased()
      let rawValue = qualifier[3]
      let value = unquote(rawValue)
      if value.isEmpty { text.append(token); continue }
      switch key {
      case "label":
        let names = bounded(list(rawValue))
        if names.isEmpty { text.append(token); continue }
        if negated { excluded += names } else { labels.append(names) }
      case "author":
        if negated { text.append(token); continue }
        author = String(value.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
      case "draft":
        guard !negated, value.lowercased() == "true" || value.lowercased() == "false" else { text.append(token); continue }
        draft = value.lowercased() == "true" ? .only : .hide
      case "review":
        let decision = negated ? nil : reviewValue(value.lowercased())
        guard let decision else { text.append(token); continue }
        review = decision
      case "status", "checks":
        let state: PullRequestListFiltersChecks? = ["success": .passing, "passing": .passing, "failure": .failing, "failing": .failing][value.lowercased()]
        guard !negated, let state else { text.append(token); continue }
        checks = state
      default:
        // A pasted link is not a namespaced label.
        if value.hasPrefix("/") { text.append(token); continue }
        let names = bounded(list(rawValue).map { $0.contains(":") ? $0 : "\(qualifier[2]):\($0)" })
        if names.isEmpty { text.append(token); continue }
        if negated { excluded += names } else { labels.append(names) }
      }
    }
    var filters = PullRequestListFilters()
    if !labels.isEmpty { filters.labels = Array(labels.prefix(maxValues)) }
    if !excluded.isEmpty { filters.excludedLabels = Array(excluded.prefix(maxValues)) }
    filters.author = author
    filters.draft = draft
    filters.review = review
    filters.checks = checks
    return (text.joined(separator: " "), filters)
  }

  private static func reviewValue(_ value: String) -> PullRequestListFiltersReview? {
    switch value {
    case "approved": .approved
    case "changes_requested", "changes-requested": .changesRequested
    case "required", "review-required": .reviewRequired
    case "none": .noneValue
    default: nil
    }
  }

  /// A run of non-space characters in which a quoted stretch counts as part of the token.
  private static func tokens(_ raw: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"(?:[^\s"]|"[^"]*")+"#) else { return [] }
    return regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { Range($0.range, in: raw).map { String(raw[$0]) } }
  }

  /// Whether any filter is set (the server is only sent `filters` when so).
  public static func hasFilters(_ filters: PullRequestListFilters) -> Bool {
    filters.draft != nil || filters.review != nil || filters.checks != nil || filters.author != nil || !(filters.labels ?? []).isEmpty
      || !(filters.excludedLabels ?? []).isEmpty
  }

  // MARK: Viewer and involvement

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The signed-in login for the host a row came from. `viewers` is keyed `"<environmentId> <host>"`, else by host.
  public static func viewer(of row: EnvironmentPullRequestEntry, in viewers: [String: String]) -> String? {
    normalized(viewers["\(row.environmentId.rawValue) \(row.entry.host)"] ?? viewers[row.entry.host])
  }

  public static func isAuthoredByViewer(_ row: EnvironmentPullRequestEntry, in viewers: [String: String]) -> Bool {
    guard let viewer = viewer(of: row, in: viewers) else { return false }
    return normalized(row.entry.author?.login) == viewer
  }

  /// `author:me` / `@me` name whoever is signed in to the host being read.
  public static func resolveAuthor(_ filter: String, viewer: String?) -> String {
    let trimmed = filter.trimmingCharacters(in: .whitespaces)
    if let viewer, ["me", "@me"].contains(trimmed.lowercased()) { return viewer }
    return trimmed
  }

  public static func filter(_ rows: [EnvironmentPullRequestEntry], involvement: PullRequestInvolvement, viewers: [String: String]) -> [EnvironmentPullRequestEntry] {
    switch involvement {
    case .reviewing: rows.filter { $0.entry.viewerReviewRequested }
    case .authored: rows.filter { isAuthoredByViewer($0, in: viewers) }
    default: rows
    }
  }

  /// Only relationships the list data actually carries.
  public static func group(_ rows: [EnvironmentPullRequestEntry], viewers: [String: String]) -> [PullRequestGroup] {
    var buckets: [PullRequestGroupKey: [EnvironmentPullRequestEntry]] = [:]
    for row in rows {
      if isAuthoredByViewer(row, in: viewers) {
        buckets[.authored, default: []].append(row)
      } else if row.entry.viewerReviewRequested {
        buckets[.reviewRequested, default: []].append(row)
      } else {
        buckets[.others, default: []].append(row)
      }
    }
    return [PullRequestGroupKey.authored, .reviewRequested, .others].compactMap { key in
      buckets[key].map { PullRequestGroup(key: key, entries: $0) }
    }
  }

  // MARK: Local narrowing

  /// The further narrowings over rows that have already arrived, for hosts that could not apply them themselves. `checks`
  /// is absent: no listed row carries its check state beyond `checksState`, which the host filters on.
  public static func matches(_ entry: PullRequestListEntry, filters: PullRequestListFilters, viewer: String?) -> Bool {
    let labels = Set(entry.labels.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
    func holds(_ label: String) -> Bool { labels.contains(label.trimmingCharacters(in: .whitespaces).lowercased()) }
    if let draft = filters.draft, entry.isDraft != (draft == .only) { return false }
    if let review = filters.review {
      if review == .noneValue { if entry.reviewDecision != nil { return false } } else {
        let wanted: PullRequestReviewDecision = review == .approved ? .approved : review == .changesRequested ? .changesRequested : .reviewRequired
        if entry.reviewDecision != wanted { return false }
      }
    }
    if let groups = filters.labels, !groups.allSatisfy({ $0.contains(where: holds) }) { return false }
    if let excluded = filters.excludedLabels, excluded.contains(where: holds) { return false }
    if let author = filters.author, entry.author?.login.lowercased() != resolveAuthor(author, viewer: viewer).lowercased() { return false }
    return true
  }

  /// Free text over the fields a row shows, plus `#123` / `123`.
  public static func matches(_ entry: PullRequestListEntry, text: String) -> Bool {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty { return true }
    return "#\(entry.number) \(entry.title) \(entry.repository) \(entry.headBranch) \(entry.author?.login ?? "")".lowercased().contains(query)
  }

  // MARK: Facets

  public static func facets(_ rows: [EnvironmentPullRequestEntry], state: PullRequestListState) -> (authors: [PullRequestAuthorFacet], labels: [PullRequestLabelFacet]) {
    var authors: [String: PullRequestAuthorFacet] = [:]
    var labels: [String: PullRequestLabelFacet] = [:]
    var seen = Set<String>()
    for row in rows where seen.insert(row.id).inserted {
      let entry = row.entry
      let inState = state == .all || entry.state.rawValue == state.rawValue
      if let author = entry.author, let key = normalized(author.login) {
        let held = authors[key]
        authors[key] = PullRequestAuthorFacet(
          actor: held?.actor ?? author, count: (held?.count ?? 0) + (inState ? 1 : 0), mergedCount: (held?.mergedCount ?? 0) + (entry.state == .merged ? 1 : 0))
      }
      guard inState else { continue }
      for label in entry.labels {
        guard let key = normalized(label.name) else { continue }
        let held = labels[key]
        labels[key] = PullRequestLabelFacet(name: held?.name ?? label.name, color: held?.color ?? label.color, count: (held?.count ?? 0) + 1)
      }
    }
    return (
      authors.values.filter { $0.count > 0 }.sorted {
        $0.mergedCount != $1.mergedCount ? $0.mergedCount > $1.mergedCount : $0.count != $1.count ? $0.count > $1.count : $0.actor.login < $1.actor.login
      },
      labels.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    )
  }

  // MARK: Sort

  private static func time(_ value: IsoDateTime?) -> Double? { value.flatMap { IsoTimestamp.parse($0) } }

  /// The default review queue: green and approved, then green work waiting on a verdict, then everything else still open.
  /// Drafts stay in the third tier. Finished work follows open work; a known conflict is never ready. Within a tier smaller
  /// measured diffs come first, then recency.
  public static func ranked(byReadiness rows: [EnvironmentPullRequestEntry]) -> [EnvironmentPullRequestEntry] {
    func tier(_ entry: PullRequestListEntry) -> Int {
      if entry.mergeability == .conflicting { return 4 }
      if entry.state != .open { return 3 }
      if entry.isDraft { return 2 }
      if entry.checksState == .passing && entry.reviewDecision == .approved { return 0 }
      if entry.checksState == .passing { return 1 }
      return 2
    }
    func measured(_ entry: PullRequestListEntry) -> Bool { entry.additions + entry.deletions > 0 }
    return rows.sorted { left, right in
      let (l, r) = (left.entry, right.entry)
      if tier(l) != tier(r) { return tier(l) < tier(r) }
      if measured(l) != measured(r) { return measured(l) }
      let sizeL = l.additions + l.deletions, sizeR = r.additions + r.deletions
      if sizeL != sizeR { return sizeL < sizeR }
      return (time(l.updatedAt) ?? 0) > (time(r.updatedAt) ?? 0)
    }
  }

  private static func ranked(_ rows: [EnvironmentPullRequestEntry], tier: (PullRequestListEntry) -> Int) -> [EnvironmentPullRequestEntry] {
    rows.sorted { left, right in
      if tier(left.entry) != tier(right.entry) { return tier(left.entry) < tier(right.entry) }
      return (time(left.entry.updatedAt) ?? 0) > (time(right.entry.updatedAt) ?? 0)
    }
  }

  /// Applies the sort inside every involvement group. Authored work stays first (the groups keep their order).
  public static func sort(_ groups: [PullRequestGroup], by sort: PullRequestListSort, searching: Bool, involvement: PullRequestInvolvement = .all) -> [PullRequestGroup] {
    func apply(_ rank: ([EnvironmentPullRequestEntry]) -> [EnvironmentPullRequestEntry]) -> [PullRequestGroup] {
      groups.map { PullRequestGroup(key: $0.key, entries: rank($0.entries)) }
    }
    switch sort {
    case .ready: return searching ? groups : apply(ranked(byReadiness:))
    case .blocked:
      if searching { return groups }
      return groups.map { group in
        let role: PullRequestInvolvement = group.key == .others ? involvement : group.key == .authored ? .authored : .reviewing
        switch role {
        case .authored:
          return PullRequestGroup(
            key: group.key,
            entries: ranked(group.entries) { entry in
              if entry.state != .open { return 6 }
              if entry.mergeability == .conflicting { return 0 }
              if entry.reviewDecision == .changesRequested { return 1 }
              if entry.checksState == .failing { return 2 }
              if entry.isDraft { return 3 }
              if entry.checksState == .passing && entry.reviewDecision == .approved { return 5 }
              return 4
            })
        case .reviewing: return PullRequestGroup(key: group.key, entries: ranked(group.entries) { $0.state == .open ? 0 : 1 })
        default: return group
        }
      }
    case .updated: return groups
    case .newest, .oldest, .largest, .smallest:
      func stamp(_ entry: PullRequestListEntry) -> Double { time(entry.updatedAt) ?? time(entry.createdAt) ?? 0 }
      return apply { rows in
        rows.sorted { left, right in
          let (l, r) = (left.entry, right.entry)
          if sort == .newest || sort == .oldest {
            let created = (time(l.createdAt), time(r.createdAt))
            if (created.0 != nil) != (created.1 != nil) { return created.0 != nil }
            let dated = (created.0 ?? 0) - (created.1 ?? 0)
            if dated != 0 { return sort == .newest ? dated > 0 : dated < 0 }
            return stamp(l) > stamp(r)
          }
          let measuredL = l.additions + l.deletions > 0, measuredR = r.additions + r.deletions > 0
          if measuredL != measuredR { return measuredL }
          let sized = (l.additions + l.deletions) - (r.additions + r.deletions)
          if sized != 0 { return sort == .largest ? sized > 0 : sized < 0 }
          return stamp(l) > stamp(r)
        }
      }
    }
  }

  // MARK: Merging environments

  /// Rows of several environments in the order given, keeping the first of a pull request two environments both listed.
  public static func merge(_ lists: [[EnvironmentPullRequestEntry]]) -> [EnvironmentPullRequestEntry] {
    var seen = Set<String>()
    var result: [EnvironmentPullRequestEntry] = []
    for row in lists.joined() {
      let key = "\(row.entry.host)/\(row.entry.repository.lowercased())#\(row.entry.number)"
      if seen.insert(key).inserted { result.append(row) }
    }
    return result
  }
}
