import Foundation
import T3Contracts

/// Server settings per environment. Reading is `serverConfigs[id]?.config.settings` (snapshot plus `settingsUpdated`);
/// writing goes through `SettingsPlanner` for the target and this method for each environment it names.
extension ClientRuntime {
  /// Saves a settings patch on one environment. The edit shows at once; a rejection undoes it and throws.
  public func updateServerSettings(environmentId: EnvironmentId, patch: ServerSettingsPatch) async throws(CommandError) {
    guard let runtime = await registry.runtime(for: environmentId) else { throw .notConnected(environment: environmentId.rawValue) }
    try await runtime.updateSettings(patch)
  }
}
