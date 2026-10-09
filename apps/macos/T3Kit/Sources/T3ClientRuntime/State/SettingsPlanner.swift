import Foundation
import T3Contracts

/// Turns a settings edit into per-environment `server.updateSettings` patches with the web's rules
/// (`planScopedSettingsPatch`): environment and "all" scopes write the patch to every connected target; project
/// and checkout scopes write only project-scopable keys, into each member's override entry. Settings are handled as
/// JSON objects so one rule covers every key and the generated patch types stay the wire format.
public enum SettingsPlanner {
  /// Keys a project may override (`PROJECT_SCOPED_SERVER_SETTING_KEYS`).
  public static let projectScopedKeys: Set<String> = [
    "worktreeCleanup", "defaultModelSelection", "defaultRuntimeMode", "defaultThreadEnvMode", "newWorktreesStartFromOrigin", "worktreeSubmodules",
    "defaultAutoPull", "defaultProjectScripts", "enableAgentBrowserAccess", "enableAgentDeviceAccess", "textGenerationModelSelection",
    "sourceControlWriterModelSelection", "sourceControlWritingStyle", "pullRequestMergeMethod", "sidebarAutoSettleOnMerge",
    "sidebarAutoSettleAfterDays", "continueThreadsAfterServerUpdate", "responseStreamingMode",
  ]
  /// Overrides whose `null` is a stored value (no model, never settle) rather than "inherit".
  static let nullableOverrideKeys: Set<String> = [
    "defaultModelSelection", "sourceControlWriterModelSelection", "pullRequestMergeMethod", "sidebarAutoSettleAfterDays",
  ]
  /// User preferences that live on the server only because it acts on them with no client attached (`sharedSettings.ts`).
  public static let sharedKeys: Set<String> = [
    "continueThreadsAfterServerUpdate", "sidebarAutoSettleAfterDays", "sidebarAutoSettleOnMerge", "newWorktreesStartFromOrigin",
    "sourceControlWritingStyle", "textGenerationModelSelection",
  ]

  // MARK: JSON bridge

  static func object<T: Encodable>(_ value: T) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
  }

  static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// The keys a patch sets, explicit `null` clears included.
  public static func keys(of patch: ServerSettingsPatch) -> Set<String> { Set(object(patch).keys) }

  // MARK: Effective values

  /// The project's effective settings: its overrides laid over the environment value.
  public static func effective(_ settings: ServerSettings, projectId: ProjectId) -> (settings: ServerSettings, overridden: Set<String>) {
    let entry = (object(settings)["projectSettingsOverrides"] as? [String: Any])?[projectId.rawValue] as? [String: Any] ?? [:]
    guard !entry.isEmpty else { return (settings, []) }
    var merged = object(settings)
    for (key, value) in entry { merged[key] = value }
    return (decode(ServerSettings.self, merged) ?? settings, Set(entry.keys))
  }

  /// Effective settings per connected target: members at project scope, environments otherwise.
  public static func targets(scope: SettingsScope, environments: [SettingsTargetEnvironment]) -> [SettingsTarget] {
    let byId = Dictionary(environments.map { ($0.environmentId, $0) }, uniquingKeysWith: { first, _ in first })
    if scope.isProject {
      return scope.members.compactMap { member in
        guard let environment = byId[member.environmentId], environment.connected, let settings = environment.settings else { return nil }
        let resolved = effective(settings, projectId: member.projectId)
        return SettingsTarget(
          environmentId: member.environmentId, label: environment.label, projectId: member.projectId, settings: resolved.settings,
          overridden: resolved.overridden)
      }
    }
    return scope.environmentIds.compactMap { id in
      guard let environment = byId[id], environment.connected, let settings = environment.settings else { return nil }
      return SettingsTarget(environmentId: id, label: environment.label, projectId: nil, settings: settings, overridden: [])
    }
  }

  /// Whether the targets disagree about any of `keys`.
  public static func isMixed(_ targets: [SettingsTarget], keys: [String]) -> Bool {
    guard let first = targets.first else { return false }
    let reference = object(first.settings)
    return targets.dropFirst().contains { target in
      let other = object(target.settings)
      return keys.contains { (reference[$0] as? NSObject) != (other[$0] as? NSObject) }
    }
  }

  // MARK: Planning

  /// Plans one edit. Writing for an unavailable or unconnected target saves nothing and says why.
  public static func plan(_ patch: ServerSettingsPatch, scope: SettingsScope, environments: [SettingsTargetEnvironment]) -> SettingsPlan {
    let patchObject = object(patch)
    if patchObject.isEmpty { return SettingsPlan(writes: [], unavailableReason: nil) }
    if scope.kind == .unavailable { return SettingsPlan(writes: [], unavailableReason: scope.message) }
    if scope.isProject {
      guard patchObject.keys.allSatisfy(projectScopedKeys.contains) else {
        return SettingsPlan(writes: [], unavailableReason: "This setting is environment-wide and cannot be overridden by a project.")
      }
      return projectWrites(scope: scope, environments: environments) { current, effective in
        var next = current
        for (key, value) in patchObject {
          // An "inherit" pick sends null; keys whose override cannot store null mean "remove the override".
          if value is NSNull, !nullableOverrideKeys.contains(key) {
            next[key] = nil
            continue
          }
          if let base = effective[key] as? [String: Any], let patchValue = value as? [String: Any] {
            next[key] = base.merging(patchValue) { _, new in new }
          } else {
            next[key] = value
          }
        }
        return next
      }
    }
    let ready = environments.filter { scope.environmentIds.contains($0.environmentId) && $0.isReady }
    guard !ready.isEmpty else {
      return SettingsPlan(writes: [], unavailableReason: "Connect \(scope.kind == .environment ? scope.label : "an environment") to save this setting.")
    }
    return SettingsPlan(writes: ready.map { SettingsWrite(environmentId: $0.environmentId, label: $0.label, patch: patch) }, unavailableReason: nil)
  }

  /// Removes the keys' project overrides so each selected checkout inherits its environment again.
  public static func clearOverrides(keys: Set<String>, scope: SettingsScope, environments: [SettingsTargetEnvironment]) -> SettingsPlan {
    guard scope.isProject else { return SettingsPlan(writes: [], unavailableReason: "Select a project to reset its overrides.") }
    let plan = projectWrites(scope: scope, environments: environments) { current, _ in current.filter { !keys.contains($0.key) } }
    return plan.writes.isEmpty
      ? SettingsPlan(writes: [], unavailableReason: "Connect the selected checkouts, or update their environments, to reset this override.") : plan
  }

  private static func projectWrites(
    scope: SettingsScope, environments: [SettingsTargetEnvironment], update: ([String: Any], [String: Any]) -> [String: Any]
  ) -> SettingsPlan {
    var order: [EnvironmentId] = []
    var entries: [EnvironmentId: [String: ProjectSettingsOverrides?]] = [:]
    for member in scope.members {
      guard let environment = environments.first(where: { $0.environmentId == member.environmentId }), environment.isReady,
        environment.capabilities?.projectSettingsOverrides == true, let settings = environment.settings
      else { continue }
      let current = (object(settings)["projectSettingsOverrides"] as? [String: Any])?[member.projectId.rawValue] as? [String: Any] ?? [:]
      let effective = object(effective(settings, projectId: member.projectId).settings)
      guard let entry = decode(ProjectSettingsOverrides.self, update(current, effective)) else { continue }
      if entries[member.environmentId] == nil { order.append(member.environmentId) }
      entries[member.environmentId, default: [:]][member.projectId.rawValue] = .some(entry)
    }
    let writes = order.compactMap { id -> SettingsWrite? in
      guard let environment = environments.first(where: { $0.environmentId == id }), let overrides = entries[id] else { return nil }
      var patch = ServerSettingsPatch()
      patch.projectSettingsOverrides = overrides
      return SettingsWrite(environmentId: id, label: environment.label, patch: patch)
    }
    return SettingsPlan(
      writes: writes, unavailableReason: writes.isEmpty ? "Connect the selected checkouts, or update their environments, to save a project override." : nil)
  }

  // MARK: Shared keys

  /// Splits a patch into the preference keys every environment should receive and the rest.
  public static func splitShared(_ patch: ServerSettingsPatch) -> (shared: ServerSettingsPatch, local: ServerSettingsPatch) {
    let all = object(patch)
    return (
      decode(ServerSettingsPatch.self, all.filter { sharedKeys.contains($0.key) }) ?? ServerSettingsPatch(),
      decode(ServerSettingsPatch.self, all.filter { !sharedKeys.contains($0.key) }) ?? ServerSettingsPatch()
    )
  }

  /// A write aimed at one environment: its own keys go there, the shared preferences also go to every other
  /// environment that supports shared-settings sync, so a preference does not drift between machines.
  // ponytail: no per-provider availability check for the text generation model on the other environments.
  public static func fanOut(_ patch: ServerSettingsPatch, from sourceId: EnvironmentId, environments: [SettingsTargetEnvironment]) -> SettingsPlan {
    let (shared, local) = splitShared(patch)
    var writes: [SettingsWrite] = []
    for environment in environments where environment.isReady {
      let isSource = environment.environmentId == sourceId
      guard isSource || environment.capabilities?.threadAutoSettlement == true else { continue }
      var sharedObject = object(shared)
      if environment.capabilities?.threadRestartContinuation != true { sharedObject["continueThreadsAfterServerUpdate"] = nil }
      if !isSource { sharedObject["textGenerationModelSelection"] = nil }
      var combined = sharedObject
      if isSource { combined.merge(object(local)) { _, new in new } }
      guard !combined.isEmpty, let merged = decode(ServerSettingsPatch.self, combined) else { continue }
      writes.append(SettingsWrite(environmentId: environment.environmentId, label: environment.label, patch: merged))
    }
    return SettingsPlan(writes: writes, unavailableReason: writes.isEmpty ? "Connect an environment to save this setting." : nil)
  }

  // MARK: Optimistic apply

  /// The settings after the server applies `patch`, for showing an edit before it is acknowledged. Covers the merge rules of
  /// `applyServerSettingsPatch`: objects merge, `projectSettingsOverrides` entries and `backgroundActivity` are replaced.
  /// Nil when the result does not decode (the edit then waits for the server's answer).
  public static func applying(_ patch: ServerSettingsPatch, to settings: ServerSettings) -> ServerSettings? {
    var next = object(settings)
    for (key, value) in object(patch) {
      switch key {
      case "projectSettingsOverrides":
        var map = next[key] as? [String: Any] ?? [:]
        for (projectId, entry) in value as? [String: Any] ?? [:] { map[projectId] = entry is NSNull ? nil : entry }
        next[key] = map
      case "backgroundActivity", "worktreeCleanup":
        next[key] = value
      case "backgroundActivityProfile", "automaticGitFetchInterval", "providerHealthRefreshInterval":
        continue  // the server folds these into `backgroundActivity`; the answer carries the result
      default:
        next[key] = merge(next[key], value)
      }
    }
    return decode(ServerSettings.self, next)
  }

  private static func merge(_ base: Any?, _ patch: Any) -> Any {
    guard let base = base as? [String: Any], let patch = patch as? [String: Any] else { return patch }
    return base.merging(patch) { old, new in merge(old, new) }
  }
}
