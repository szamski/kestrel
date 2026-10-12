import Foundation
import Observation
import T3ClientRuntime
import T3Contracts

/// The pull request inbox: the list the user filtered, read from every connected environment that serves pull requests, and
/// the live refresh signal that keeps it and the open detail current.
///
/// A singleton like `FileSurfaces`: the sidebar entry, the commands, the right panel tabs and the inbox all reach it.
/// Environments that own the projects answer; GitHub accounts are not routed across environments.
@MainActor @Observable
final class PullRequestsStore {
  static let shared = PullRequestsStore()

  struct Prefs: Codable, Equatable {
    var involvement: PullRequestInvolvement = .all
    var state: PullRequestListState = .open
    /// `ProjectGroup.key`: one logical project across the environments that hold it.
    var projectKey: String?
    var draft: PullRequestListFiltersDraft?
    var review: PullRequestListFiltersReview?
    var checks: PullRequestListFiltersChecks?
    var author: String?
    var labels: [String] = []
    var sort: PullRequestListSort = .ready
  }

  enum Phase: Equatable { case idle, loading, loaded, failed(String) }

  struct ListIssue: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var unavailable = false
  }

  // MARK: State

  /// The inbox replaces the reading window while shown (`MainView`).
  var isShowing = false
  var selected: PullRequestTarget?
  var prefs: Prefs {
    didSet {
      guard prefs != oldValue else { return }
      if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
      reloadSoon(after: 0)
    }
  }
  /// Typed search with qualifiers (`label:bug author:me`).
  var query = "" {
    didSet { if query != oldValue { reloadSoon(after: 0.4) } }
  }

  private(set) var rows: [EnvironmentPullRequestEntry] = []
  private(set) var viewers: [String: String] = [:]
  private(set) var issues: [ListIssue] = []
  private(set) var phase: Phase = .idle
  private(set) var refreshing = false
  private(set) var loadingMore = false
  private(set) var loadedAt: Date?
  /// Per environment, where the next page of each repository carries on from.
  private(set) var nextCursors: [EnvironmentId: [String: String]] = [:]
  private(set) var stats: [String: (additions: Int, deletions: Int)] = [:]
  /// Bumps when the server says pull request data may have changed; open details reload on it.
  private(set) var revision = 0
  /// What a thread link dialog is open for (`LinkPullRequestSheet`).
  var linkRequest: ScopedThreadKey?
  /// Asks the open detail to switch tabs (commands, the debug driver).
  var requestedTab: PullRequestTab?
  /// Inline review comments written in the Code tab and not yet submitted, by pull request.
  private(set) var reviewDrafts: [String: [PullRequestReviewCommentDraft]] = [:]

  @ObservationIgnored private(set) weak var app: AppModel?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var reload: Task<Void, Never>?
  @ObservationIgnored private var signal: Task<Void, Never>?
  @ObservationIgnored private var live: [EnvironmentId: Task<Void, Never>] = [:]
  @ObservationIgnored private var holders = 0

  private static let prefsKey = "pullRequests.prefs.v1"
  static let pageSize = 50

  init() {
    prefs = UserDefaults.standard.data(forKey: Self.prefsKey).flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
  }

  func attach(_ app: AppModel) { self.app = app }

  /// Environments whose refresh subscription is open.
  var liveCount: Int { live.count }

  private var client: PullRequestsClient? { app.map { PullRequestsClient(runtime: $0.runtime) } }

  // MARK: Navigation

  /// Shows the inbox in place of the open thread, on `target` when given.
  func show(_ target: PullRequestTarget? = nil) {
    if let target { selected = target }
    app?.selection = nil
    isShowing = true
  }

  func hide() { isShowing = false }

  // MARK: Review drafts

  func drafts(for target: PullRequestTarget) -> [PullRequestReviewCommentDraft] { reviewDrafts[target.id] ?? [] }
  func addDraft(_ draft: PullRequestReviewCommentDraft, for target: PullRequestTarget) { reviewDrafts[target.id, default: []].append(draft) }
  func removeDraft(at index: Int, for target: PullRequestTarget) {
    guard reviewDrafts[target.id]?.indices.contains(index) == true else { return }
    reviewDrafts[target.id]?.remove(at: index)
  }
  func clearDrafts(for target: PullRequestTarget) { reviewDrafts[target.id] = nil }

  // MARK: Environments

  /// Connected environments whose server reads pull requests.
  var environments: [EnvironmentStatus] {
    guard let runtime = app?.runtime else { return [] }
    return runtime.environments.filter { $0.enabled && $0.connection.phase == .connected && supports($0.environmentId) }
  }

  func supports(_ environmentId: EnvironmentId) -> Bool {
    app?.runtime.serverConfigs[environmentId]?.config.environment.capabilities.pullRequests == true
  }

  func environmentLabel(_ id: EnvironmentId) -> String { app?.environmentLabel(id) ?? id.rawValue }

  var projectOptions: [(key: String, label: String)] { (app?.runtime.projectGroups ?? []).map { ($0.key, $0.label) } }

  // MARK: Query

  /// The menu's filters with what was typed on top of them (a typed qualifier wins).
  var effective: (text: String, filters: PullRequestListFilters) {
    let typed = PullRequestListLogic.parseQuery(query)
    var filters = PullRequestListFilters(
      draft: prefs.draft, review: prefs.review, checks: prefs.checks, labels: prefs.labels.isEmpty ? nil : prefs.labels.map { [$0] }, author: prefs.author)
    if let labels = typed.filters.labels { filters.labels = (filters.labels ?? []) + labels }
    if let excluded = typed.filters.excludedLabels { filters.excludedLabels = excluded }
    if let value = typed.filters.author { filters.author = value }
    if let value = typed.filters.draft { filters.draft = value }
    if let value = typed.filters.review { filters.review = value }
    if let value = typed.filters.checks { filters.checks = value }
    return (typed.text, filters)
  }

  private func input(for environmentId: EnvironmentId, cursors: [String: String]?) -> PullRequestListInput? {
    var projectIds: [ProjectId]?
    if let key = prefs.projectKey, let group = app?.runtime.projectGroups.first(where: { $0.key == key }) {
      let ids = group.memberProjectRefs.filter { $0.environmentId == environmentId }.map(\.projectId)
      if ids.isEmpty { return nil }
      projectIds = ids
    }
    let (text, filters) = effective
    return PullRequestListInput(
      state: prefs.state, involvement: prefs.involvement, filters: PullRequestListLogic.hasFilters(filters) ? filters : nil, projectIds: projectIds, limit: Self.pageSize,
      cursors: cursors, query: text.isEmpty ? nil : text)
  }

  // MARK: Loading

  func reloadSoon(after delay: Double = 0) {
    reload?.cancel()
    reload = Task { [weak self] in
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard !Task.isCancelled else { return }
      await self?.load()
    }
  }

  /// Loads the first time the inbox is shown, and again when the data is a minute old.
  func loadIfNeeded() async {
    if phase == .idle || loadedAt.map({ Date.now.timeIntervalSince($0) > 60 }) != false { await load() }
  }

  func load() async {
    guard let client else { return }
    generation += 1
    let current = generation
    let targets = environments.compactMap { environment in input(for: environment.environmentId, cursors: nil).map { (environment.environmentId, $0) } }
    refreshing = true
    if rows.isEmpty { phase = .loading }
    defer { if current == generation { refreshing = false } }
    if targets.isEmpty {
      guard current == generation else { return }
      rows = []
      issues = []
      nextCursors = [:]
      phase = app?.runtime.environments.isEmpty == false && environments.isEmpty ? .failed("No connected environment reads pull requests.") : .loaded
      return
    }
    var answers: [(EnvironmentId, Result<PullRequestListResult, PullRequestsFailure>)] = []
    await withTaskGroup(of: (EnvironmentId, Result<PullRequestListResult, PullRequestsFailure>).self) { group in
      for (environmentId, input) in targets {
        group.addTask {
          do { return (environmentId, .success(try await client.call(Rpc.pullRequestsList, input, in: environmentId))) } catch {
            return (environmentId, .failure(PullRequestsClient.failure(error)))
          }
        }
      }
      for await answer in group { answers.append(answer) }
    }
    guard current == generation, !Task.isCancelled else { return }
    apply(answers: answers, order: targets.map(\.0), append: false)
    loadedAt = .now
  }

  func loadMore() async {
    guard let client, !loadingMore, !nextCursors.isEmpty else { return }
    let current = generation
    loadingMore = true
    defer { loadingMore = false }
    let targets = nextCursors.compactMap { environmentId, cursors in input(for: environmentId, cursors: cursors).map { (environmentId, $0) } }
    var answers: [(EnvironmentId, Result<PullRequestListResult, PullRequestsFailure>)] = []
    await withTaskGroup(of: (EnvironmentId, Result<PullRequestListResult, PullRequestsFailure>).self) { group in
      for (environmentId, input) in targets {
        group.addTask {
          do { return (environmentId, .success(try await client.call(Rpc.pullRequestsList, input, in: environmentId))) } catch {
            return (environmentId, .failure(PullRequestsClient.failure(error)))
          }
        }
      }
      for await answer in group { answers.append(answer) }
    }
    guard current == generation else { return }
    for (environmentId, _) in targets { nextCursors[environmentId] = nil }
    apply(answers: answers, order: targets.map(\.0), append: true)
  }

  private func apply(answers: [(EnvironmentId, Result<PullRequestListResult, PullRequestsFailure>)], order: [EnvironmentId], append: Bool) {
    if !append { nextCursors = [:] }
    var lists: [[EnvironmentPullRequestEntry]] = append ? [rows] : []
    var issues: [ListIssue] = append ? self.issues : []
    var viewers = append ? self.viewers : [:]
    for environmentId in order {
      guard let result = answers.first(where: { $0.0 == environmentId })?.1 else { continue }
      switch result {
      case .success(let list):
        lists.append(list.entries.map { EnvironmentPullRequestEntry(environmentId: environmentId, entry: $0) })
        for (host, login) in list.viewers { viewers["\(environmentId.rawValue) \(host)"] = login }
        for error in list.errors { issues.append(ListIssue(title: error.projectTitle, message: error.message)) }
        for provider in list.providers where !provider.configured {
          issues.append(ListIssue(title: provider.host, message: provider.detail ?? "Not signed in on \(environmentLabel(environmentId)).", unavailable: true))
        }
        // An environment with more to give but no cursor is read again at a larger page by the next full load; here it stays as read.
        if !list.nextCursors.isEmpty { nextCursors[environmentId] = list.nextCursors }
      case .failure(let failure):
        issues.append(ListIssue(title: environmentLabel(environmentId), message: failure.message, unavailable: failure.kind != .other))
      }
    }
    rows = PullRequestListLogic.merge(lists)
    self.viewers = viewers
    self.issues = issues
    phase = rows.isEmpty && !issues.isEmpty && issues.count >= order.count && answers.allSatisfy({ if case .failure = $0.1 { true } else { false } }) ? .failed(issues.first?.message ?? "") : .loaded
    Task { await loadStats() }
  }

  /// Hosts that list without line counts get them in a second round trip, for the rows that show them.
  private func loadStats() async {
    guard let client else { return }
    var wanted: [EnvironmentId: [PullRequestRef]] = [:]
    for row in rows where row.entry.additions == 0 && row.entry.deletions == 0 && stats[row.id] == nil {
      wanted[row.environmentId, default: []].append(row.reference)
    }
    for (environmentId, refs) in wanted {
      for chunk in stride(from: 0, to: refs.count, by: 100).map({ Array(refs[$0..<min($0 + 100, refs.count)]) }) {
        guard let result = try? await client.call(Rpc.pullRequestsListStats, PullRequestListStatsInput(refs: chunk), in: environmentId) else { continue }
        for stat in result.stats {
          if let row = rows.first(where: { $0.environmentId == environmentId && $0.entry.projectId == stat.projectId && $0.entry.repository == stat.repository && $0.entry.number == stat.number }) {
            stats[row.id] = (stat.additions, stat.deletions)
          }
        }
      }
    }
  }

  // MARK: Derived

  /// What the list shows: the rows narrowed to the filters, grouped by involvement and sorted.
  func groups() -> [PullRequestGroup] {
    let (text, filters) = effective
    var visible = rows.filter { row in
      let entry = row.entry
      guard prefs.state == .all || entry.state.rawValue == prefs.state.rawValue else { return false }
      return PullRequestListLogic.matches(entry, filters: filters, viewer: PullRequestListLogic.viewer(of: row, in: viewers))
    }
    if !text.isEmpty { visible = visible.filter { PullRequestListLogic.matches($0.entry, text: text) } }
    visible = PullRequestListLogic.filter(visible, involvement: prefs.involvement, viewers: viewers)
    let groups = prefs.involvement == .all ? PullRequestListLogic.group(visible, viewers: viewers) : [PullRequestGroup(key: .others, entries: visible)].filter { !$0.entries.isEmpty }
    return PullRequestListLogic.sort(groups, by: prefs.sort, searching: !query.trimmingCharacters(in: .whitespaces).isEmpty, involvement: prefs.involvement)
  }

  func stat(for row: EnvironmentPullRequestEntry) -> (additions: Int, deletions: Int) {
    if row.entry.additions != 0 || row.entry.deletions != 0 { return (row.entry.additions, row.entry.deletions) }
    return stats[row.id] ?? (0, 0)
  }

  var facets: (authors: [PullRequestAuthorFacet], labels: [PullRequestLabelFacet]) { PullRequestListLogic.facets(rows, state: prefs.state) }

  /// Open pull requests waiting for the viewer's review, for the sidebar badge.
  var reviewRequestedCount: Int { rows.filter { $0.entry.viewerReviewRequested && $0.entry.state == .open }.count }

  var hasFilters: Bool {
    prefs.projectKey != nil || prefs.draft != nil || prefs.review != nil || prefs.checks != nil || prefs.author != nil || !prefs.labels.isEmpty
      || !query.trimmingCharacters(in: .whitespaces).isEmpty
  }

  func clearFilters() {
    prefs.projectKey = nil
    prefs.draft = nil
    prefs.review = nil
    prefs.checks = nil
    prefs.author = nil
    prefs.labels = []
    query = ""
  }

  // MARK: Live refresh

  /// Views that show pull request data hold the live subscription while they are on screen.
  func retainLive() {
    holders += 1
    syncLive()
  }

  func releaseLive() {
    holders = max(0, holders - 1)
    if holders == 0 {
      live.values.forEach { $0.cancel() }
      live = [:]
    }
  }

  /// Follows the environments that come and go while a view holds the subscription.
  func syncLive() {
    guard holders > 0, let client else { return }
    let wanted = Set(environments.map(\.environmentId))
    for (id, task) in live where !wanted.contains(id) {
      task.cancel()
      live[id] = nil
    }
    for id in wanted where live[id] == nil {
      live[id] = Task { [weak self] in
        while !Task.isCancelled {
          if let stream = try? await client.refreshes(in: id) {
            do { for try await _ in stream { self?.refreshSignal() } } catch {}
          }
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  /// The server said pull request data may have changed: the list and the open detail read again.
  func refreshSignal() {
    signal?.cancel()
    signal = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled, let self else { return }
      revision += 1
      if isShowing { reloadSoon(after: 0) }
    }
  }

  /// A write finished here: other readers (list rows, other tabs of the same pull request) read again.
  func noteChanged() {
    revision += 1
    if isShowing { reloadSoon(after: 0.3) }
  }

  func refreshNow() {
    revision += 1
    reloadSoon(after: 0)
  }
}
