import Foundation
import Observation
import T3ClientRuntime
import T3Contracts

/// State of one settings window: the page, the scope target, search, and the two write paths. Device preferences go to
/// `ClientSettingsStore`; server settings are planned against the target by `SettingsPlanner` and saved per environment.
@MainActor @Observable
final class SettingsModel {
  let runtime: ClientRuntime
  let store: ClientSettingsStore

  var page: SettingsPage = .general
  var scopeSearch = SettingsScopeSearch()
  var query = ""
  /// A row to scroll to; `token` makes jumping to the same row twice work.
  private(set) var jump: (id: String, token: Int)?
  private(set) var highlightedRow: String?
  /// The last thing worth telling the user: a refused or unavailable save.
  private(set) var notice: String?
  @ObservationIgnored private var jumpCount = 0
  @ObservationIgnored private var highlightTask: Task<Void, Never>?

  init(runtime: ClientRuntime, store: ClientSettingsStore = .shared) {
    self.runtime = runtime
    self.store = store
    #if DEBUG
    if let name = UserDefaults.standard.string(forKey: "T3SettingsPage"), let start = SettingsPage(rawValue: name) { page = start }
    #endif
  }

  // MARK: Target

  var scope: SettingsScope { SettingsScope.resolve(scopeSearch, groups: runtime.projectGroups, environments: runtime.environments) }
  var environments: [SettingsTargetEnvironment] { runtime.settingsEnvironments }
  var targets: [SettingsTarget] { SettingsPlanner.targets(scope: scope, environments: environments) }
  /// Effective server settings of the representative target (defaults while nothing is connected).
  var server: ServerSettings { targets.first?.settings ?? ServerSettings() }
  var client: ClientSettingsSchema { store.client }

  /// Whether every selected, connected environment supports the server-side thread auto-settle.
  var supportsAutoSettlement: Bool { supports(\.threadAutoSettlement) }
  var supportsRestartContinuation: Bool { supports(\.threadRestartContinuation) }

  private func supports(_ keyPath: KeyPath<ExecutionEnvironmentCapabilities, Bool?>) -> Bool {
    let ids = Set(targets.map(\.environmentId))
    let selected = environments.filter { ids.contains($0.environmentId) }
    return !selected.isEmpty && selected.allSatisfy { $0.capabilities?[keyPath: keyPath] == true }
  }

  /// The provider list pickers draw from: the representative environment's.
  var providers: [ServerConfigProvidersItem] {
    guard let id = targets.first?.environmentId else { return [] }
    return runtime.serverConfigs[id]?.config.providers ?? []
  }

  enum RowState: Equatable { case editable, noTarget, environmentWide }

  /// Server rows need a connected target, and a project can only override project-scoped keys.
  func rowState(_ keys: [String]) -> RowState {
    guard !keys.isEmpty else { return .editable }
    if targets.isEmpty { return .noTarget }
    if scope.isProject, !keys.allSatisfy(SettingsPlanner.projectScopedKeys.contains) { return .environmentWide }
    return .editable
  }

  func isMixed(_ keys: [String]) -> Bool { SettingsPlanner.isMixed(targets, keys: keys) }
  func isOverridden(_ keys: [String]) -> Bool { targets.contains { !$0.overridden.isDisjoint(with: keys) } }

  // MARK: Writes

  func updateClient(_ edit: (inout ClientSettingsSchema) -> Void) { store.update(edit) }

  /// Saves server settings on the current target (each environment optimistically, rolled back if refused).
  func edit(_ patch: ServerSettingsPatch) { run(SettingsPlanner.plan(patch, scope: scope, environments: environments)) }

  /// Drops the project overrides for `keys` so the selected checkouts inherit their environment again.
  func clearOverrides(_ keys: [String]) { run(SettingsPlanner.clearOverrides(keys: Set(keys), scope: scope, environments: environments)) }

  func dismissNotice() { notice = nil }
  func report(_ message: String) { notice = message }

  private func run(_ plan: SettingsPlan) {
    if let reason = plan.unavailableReason {
      notice = "Setting not saved. \(reason)"
      return
    }
    notice = nil
    let runtime = runtime
    // One save per environment, all started together; a failed one is reported by name.
    let saves = plan.writes.map { write in
      Task { @MainActor () -> String? in
        do {
          try await runtime.updateServerSettings(environmentId: write.environmentId, patch: write.patch)
          return nil
        } catch {
          return write.label
        }
      }
    }
    Task { [weak self] in
      var failed: [String] = []
      for save in saves { if let label = await save.value { failed.append(label) } }
      guard !failed.isEmpty else { return }
      let saved = plan.writes.count - failed.count
      self?.notice =
        saved > 0
        ? "Setting saved on some environments. Could not update \(failed.sorted().joined(separator: ", "))."
        : "Setting not saved. Could not update \(failed.sorted().joined(separator: ", "))."
    }
  }

  // MARK: Navigation and search

  /// Jumps to a search result. A row whose owning scope is not the current target still opens, with the reason it cannot be edited here.
  func open(_ item: SettingsSearchItem) {
    query = ""
    page = item.page
    if let required = item.scope ?? item.page.owningScope, !required.isAvailable(in: scope.kind) {
      notice = "\(item.title) is not available for the selected target. Choose its owning scope to continue."
    } else if item.requiresAutoSettlement, !supportsAutoSettlement {
      notice = "\(item.title) requires an environment that supports it. Choose one to continue."
    }
    scrollTo(item.target)
  }

  func scrollTo(_ id: String) {
    jumpCount += 1
    jump = (id, jumpCount)
    highlightedRow = id
    highlightTask?.cancel()
    highlightTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1600))
      if !Task.isCancelled { self?.highlightedRow = nil }
    }
  }

  /// Results narrowed to what the connected environments can show.
  var results: [SettingsSearchItem] {
    let capable = environments.contains { $0.capabilities?.threadAutoSettlement == true }
    return SettingsRegistry.search(query).filter { !$0.requiresAutoSettlement || capable }
  }

  // MARK: Scope selection

  func selectEnvironment(_ id: String?) {
    scopeSearch = SettingsScopeSearch(project: scopeSearch.project, machine: id)
  }

  func selectProject(_ key: String?) {
    scopeSearch = SettingsScopeSearch(project: key, machine: scopeSearch.machine)
  }

  func selectCheckout(_ key: String?) {
    scopeSearch.checkout = key
  }
}
