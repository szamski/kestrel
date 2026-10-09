import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// State and writes of Settings › Providers for one environment. Provider instances hold per-machine credentials and
/// binaries, so the page edits exactly the environment it shows (the scope bar's representative) and every write goes to
/// that environment alone. Model favorites, order and visibility are device preferences and live in the client settings.
@MainActor @Observable
final class ProvidersController {
  let model: SettingsModel
  let environmentId: EnvironmentId

  var selectedId: String?
  var showAddInstance = false
  var showAddHub = false
  private(set) var refreshing = false
  private(set) var updating: Set<String> = []
  private(set) var updateError: String?
  private(set) var cursorUsageBusy = false

  init(model: SettingsModel, environmentId: EnvironmentId) {
    self.model = model
    self.environmentId = environmentId
  }

  // MARK: Reading

  var runtime: ClientRuntime { model.runtime }
  var config: ServerConfig? { runtime.serverConfigs[environmentId]?.config }
  var settings: ServerSettings { config?.settings ?? ServerSettings() }
  var providers: [ServerConfigProvidersItem] { config?.providers ?? [] }
  var environmentLabel: String { runtime.environments.first { $0.environmentId == environmentId }?.label ?? "this environment" }
  var isMac: Bool { config?.environment.platform.os == .darwin }

  var rows: [ProviderInstanceRow] {
    ProviderInstances.rows(settings: settings, liveInstanceIds: Set(providers.map(\.instanceId.rawValue)))
  }

  var selected: ProviderInstanceRow? { rows.first { $0.instanceId == selectedId } ?? rows.first }

  func live(_ instanceId: String) -> ServerConfigProvidersItem? { providers.first { $0.instanceId.rawValue == instanceId } }

  var lastChecked: Date? { providers.compactMap { $0.checkedAt.date }.max() }

  // MARK: Writing

  /// Saves a settings patch on this environment alone; a refusal is reported on the page.
  func save(_ patch: ServerSettingsPatch, failure: String = "Setting not saved.") {
    let (runtime, id, model) = (runtime, environmentId, model)
    Task { @MainActor in
      do {
        try await runtime.updateServerSettings(environmentId: id, patch: patch)
      } catch {
        model.report("\(failure) \(Self.message(error))")
      }
    }
  }

  /// Edits one instance on top of its current state (an edit never overwrites a newer one), and does nothing if it is gone.
  /// Switching off the provider that writes generated text also resets that selection.
  func edit(_ instanceId: String, _ change: (inout ProviderInstanceConfig) -> Void) {
    guard let row = rows.first(where: { $0.instanceId == instanceId }) else { return }
    let next = row.instance.with(change)
    let disabling = next.enabled == false && ProviderInstances.isEnabled(row.instance)
    let usedForText = settings.textGenerationModelSelection.instanceId.rawValue == instanceId
    save(ProviderInstances.updatePatch(settings: settings, row: row, next: next, resetTextGeneration: disabling && usedForText))
  }

  func delete(_ row: ProviderInstanceRow) {
    if selectedId == row.instanceId { selectedId = nil }
    save(ProviderInstances.deletePatch(settings: settings, instanceId: row.instanceId), failure: "Provider not removed.")
  }

  func resetDefault(_ row: ProviderInstanceRow) {
    guard let patch = ProviderInstances.resetDefaultPatch(settings: settings, driver: row.driver) else { return }
    save(patch, failure: "Provider not reset.")
  }

  // MARK: Requests

  func currentSession() async -> (any EnvironmentSession)? { await runtime.runtime(for: environmentId)?.supervisor.session.value }

  /// `server.refreshProviders`: re-probes every instance, models included. Results arrive through the config stream.
  func refresh(instanceId: String? = nil) {
    guard !refreshing else { return }
    refreshing = true
    Task { @MainActor in
      defer { refreshing = false }
      guard let session = await currentSession() else { return }
      let payload = ServerRefreshProvidersPayload(instanceId: instanceId.map { ProviderInstanceId($0) }, refreshModels: true)
      _ = try? await session.call(Rpc.serverRefreshProviders, payload)
    }
  }

  func runUpdate(_ provider: ServerConfigProvidersItem, targetVersion: String? = nil) {
    let id = provider.instanceId.rawValue
    guard !updating.contains(id) else { return }
    updating.insert(id)
    updateError = nil
    Task { @MainActor in
      defer { updating.remove(id) }
      guard let session = await currentSession() else { return }
      do {
        _ = try await session.call(
          Rpc.serverUpdateProvider, ServerProviderUpdateInput(provider: provider.driver, targetVersion: targetVersion, instanceId: provider.instanceId))
      } catch {
        updateError = "Could not update \(ProviderCatalog.label(provider.driver.rawValue)). \(Self.message(error))"
      }
    }
  }

  func isUpdating(_ provider: ServerConfigProvidersItem?) -> Bool {
    guard let provider else { return false }
    return updating.contains(provider.instanceId.rawValue) || ProviderStatus.isUpdateActive(provider)
  }

  /// Cursor usage reads the macOS keychain on the host, so the provider list is refreshed once the setting is saved.
  func setCursorUsage(_ enabled: Bool) {
    cursorUsageBusy = true
    let (runtime, id, model) = (runtime, environmentId, model)
    Task { @MainActor in
      defer { cursorUsageBusy = false }
      do {
        try await runtime.updateServerSettings(environmentId: id, patch: ServerSettingsPatch(cursorKeychainUsageEnabled: enabled))
        if let session = await runtime.runtime(for: id)?.supervisor.session.value {
          _ = try? await session.call(Rpc.serverRefreshProviders, ServerRefreshProvidersPayload())
        }
      } catch {
        model.report("Cursor account usage not saved. \(Self.message(error))")
      }
    }
  }

  // MARK: Device preferences

  func modelPreferences(_ instanceId: String) -> ClientSettingsSchemaProviderModelPreferencesValue {
    model.client.providerModelPreferences[instanceId] ?? ClientSettingsSchemaProviderModelPreferencesValue()
  }

  func favorites(_ instanceId: String) -> [String] { model.client.favorites.filter { $0.provider.rawValue == instanceId }.map(\.model) }

  func setModelPreferences(_ instanceId: String, hidden: [String], order: [String]) {
    let next = ProviderModels.normalizedPreferences(hidden: hidden, order: order)
    model.updateClient { $0.providerModelPreferences[instanceId] = next }
  }

  func setFavorites(_ instanceId: String, _ slugs: [String]) {
    model.updateClient { $0.favorites = ProviderModels.favorites($0.favorites, instanceId: instanceId, replacingWith: slugs) }
  }

  // MARK: Messages

  /// What a failed request says, in words for the user.
  static func message(_ error: any Error) -> String {
    (error as? FailureMessage)?.failureMessage ?? (error as? CommandError)?.message ?? "The request failed."
  }

  /// Only web links are opened from server-provided URLs.
  static func open(_ link: String) -> Bool {
    guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
    return NSWorkspace.shared.open(url)
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension ProviderInstanceConfig {
  func with(_ edit: (inout ProviderInstanceConfig) -> Void) -> ProviderInstanceConfig {
    var copy = self
    edit(&copy)
    return copy
  }
}
