import Foundation
import T3Contracts

/// Port of `packages/shared/src/backgroundActivitySettings.ts` and the settings page helpers: the shared power policy
/// that gates background work (Git fetches, provider health probes) on a server. Intervals are milliseconds on the wire.
public enum BackgroundActivityPolicy {
  public enum Profile: String, CaseIterable, Sendable {
    case balanced, performance
    case batterySaver = "battery-saver"
  }

  public struct Resolved: Equatable, Sendable {
    public var profile: Profile
    public var automaticGitFetchInterval: Double
    public var providerHealthRefreshInterval: Double
    public var hostPowerMonitorActiveInterval: Double
    public var hostPowerMonitorIdleInterval: Double
    public var idleClientTtl: Double
    public var pauseWhenHostLocked: Bool
    public var pauseWhenHostLowPower: Bool
    public var pauseWhenClientLowPower: Bool
    public var pauseWhenOnBattery: Bool
  }

  public static func preset(_ profile: Profile) -> Resolved {
    switch profile {
    case .performance:
      Resolved(
        profile: profile, automaticGitFetchInterval: 15_000, providerHealthRefreshInterval: 60_000, hostPowerMonitorActiveInterval: 30_000,
        hostPowerMonitorIdleInterval: 120_000, idleClientTtl: 45_000, pauseWhenHostLocked: true, pauseWhenHostLowPower: false,
        pauseWhenClientLowPower: false, pauseWhenOnBattery: false)
    case .balanced:
      Resolved(
        profile: profile, automaticGitFetchInterval: 30_000, providerHealthRefreshInterval: 300_000, hostPowerMonitorActiveInterval: 30_000,
        hostPowerMonitorIdleInterval: 300_000, idleClientTtl: 45_000, pauseWhenHostLocked: true, pauseWhenHostLowPower: true,
        pauseWhenClientLowPower: true, pauseWhenOnBattery: false)
    case .batterySaver:
      Resolved(
        profile: profile, automaticGitFetchInterval: 0, providerHealthRefreshInterval: 900_000, hostPowerMonitorActiveInterval: 60_000,
        hostPowerMonitorIdleInterval: 600_000, idleClientTtl: 45_000, pauseWhenHostLocked: true, pauseWhenHostLowPower: true,
        pauseWhenClientLowPower: true, pauseWhenOnBattery: true)
    }
  }

  private static func base(_ value: BackgroundActivitySettings) -> Profile {
    let raw = value.profile == .custom ? value.baseProfile?.rawValue : value.profile.rawValue
    return raw.flatMap(Profile.init(rawValue:)) ?? .balanced
  }

  private static func resolve(_ value: BackgroundActivitySettings) -> Resolved {
    var resolved = preset(base(value))
    guard value.profile == .custom else { return resolved }
    let o = value.overrides
    resolved.automaticGitFetchInterval = o.automaticGitFetchInterval ?? resolved.automaticGitFetchInterval
    resolved.providerHealthRefreshInterval = o.providerHealthRefreshInterval ?? resolved.providerHealthRefreshInterval
    resolved.hostPowerMonitorActiveInterval = o.hostPowerMonitorActiveInterval ?? resolved.hostPowerMonitorActiveInterval
    resolved.hostPowerMonitorIdleInterval = o.hostPowerMonitorIdleInterval ?? resolved.hostPowerMonitorIdleInterval
    resolved.idleClientTtl = o.idleClientTtl ?? resolved.idleClientTtl
    resolved.pauseWhenHostLocked = o.pauseWhenHostLocked ?? resolved.pauseWhenHostLocked
    resolved.pauseWhenHostLowPower = o.pauseWhenHostLowPower ?? resolved.pauseWhenHostLowPower
    resolved.pauseWhenClientLowPower = o.pauseWhenClientLowPower ?? resolved.pauseWhenClientLowPower
    resolved.pauseWhenOnBattery = o.pauseWhenOnBattery ?? resolved.pauseWhenOnBattery
    return resolved
  }

  /// The effective policy. Older servers only knew a profile and two intervals; those apply while the shared policy is untouched.
  public static func resolved(_ settings: ServerSettings) -> Resolved {
    let current = settings.backgroundActivity
    let untouched = current.profile == .balanced && current.baseProfile == nil && current.overrides == BackgroundActivitySettingsOverrides()
    let legacyProfile = Profile(rawValue: settings.backgroundActivityProfile.rawValue) ?? .balanced
    let legacy = legacyProfile != .balanced || settings.automaticGitFetchInterval != 30_000 || settings.providerHealthRefreshInterval != 300_000
    guard untouched, legacy else { return resolve(current) }
    var o = BackgroundActivitySettingsOverrides()
    if settings.automaticGitFetchInterval != 30_000 { o.automaticGitFetchInterval = settings.automaticGitFetchInterval }
    if settings.providerHealthRefreshInterval != 300_000 { o.providerHealthRefreshInterval = settings.providerHealthRefreshInterval }
    let custom = o != BackgroundActivitySettingsOverrides()
    return resolve(
      BackgroundActivitySettings(
        profile: custom ? .custom : BackgroundActivitySettingsProfile(rawValue: legacyProfile.rawValue),
        baseProfile: custom ? BackgroundActivitySettingsBaseProfile(rawValue: legacyProfile.rawValue) : nil, overrides: o))
  }

  /// A preset when the effective policy equals one, otherwise nil ("Advanced").
  public static func matchingProfile(_ settings: ServerSettings) -> Profile? {
    var effective = resolved(settings)
    let profile = effective.profile
    for candidate in [profile] + Profile.allCases.filter({ $0 != profile }) {
      effective.profile = candidate
      if effective == preset(candidate) { return candidate }
    }
    return nil
  }

  /// Choosing a preset resets every override.
  public static func profilePatch(_ profile: Profile) -> ServerSettingsPatch {
    var patch = ServerSettingsPatch()
    patch.backgroundActivity = ServerSettingsPatchBackgroundActivity(
      schemaVersion: 1, profile: BackgroundActivitySettingsProfile(rawValue: profile.rawValue), overrides: ServerSettingsPatchBackgroundActivityOverrides())
    return patch
  }

  /// Changing the shared policy keeps the current overrides.
  public static func sharedPolicyPatch(_ settings: ServerSettings, profile: Profile) -> ServerSettingsPatch {
    let current = settings.backgroundActivity
    var patch = ServerSettingsPatch()
    patch.backgroundActivity = ServerSettingsPatchBackgroundActivity(
      schemaVersion: 1, profile: .custom, baseProfile: BackgroundActivitySettingsBaseProfile(rawValue: profile.rawValue),
      overrides: patchOverrides(current.profile == .custom ? current.overrides : BackgroundActivitySettingsOverrides()))
    return patch
  }

  /// Edits one or more intervals/switches on top of the effective policy; the result is a custom policy over the same base.
  public static func overridePatch(_ settings: ServerSettings, edit: (inout Resolved) -> Void) -> ServerSettingsPatch {
    var next = resolved(settings)
    edit(&next)
    var patch = ServerSettingsPatch()
    patch.backgroundActivity = ServerSettingsPatchBackgroundActivity(
      schemaVersion: 1, profile: .custom, baseProfile: BackgroundActivitySettingsBaseProfile(rawValue: base(settings.backgroundActivity).rawValue),
      overrides: ServerSettingsPatchBackgroundActivityOverrides(
        automaticGitFetchInterval: next.automaticGitFetchInterval, providerHealthRefreshInterval: next.providerHealthRefreshInterval,
        hostPowerMonitorActiveInterval: next.hostPowerMonitorActiveInterval, hostPowerMonitorIdleInterval: next.hostPowerMonitorIdleInterval,
        idleClientTtl: next.idleClientTtl, pauseWhenHostLocked: next.pauseWhenHostLocked, pauseWhenHostLowPower: next.pauseWhenHostLowPower,
        pauseWhenClientLowPower: next.pauseWhenClientLowPower, pauseWhenOnBattery: next.pauseWhenOnBattery))
    return patch
  }

  public static func isDefault(_ settings: ServerSettings) -> Bool { resolved(settings) == preset(.balanced) }

  private static func patchOverrides(_ o: BackgroundActivitySettingsOverrides) -> ServerSettingsPatchBackgroundActivityOverrides {
    ServerSettingsPatchBackgroundActivityOverrides(
      automaticGitFetchInterval: o.automaticGitFetchInterval, providerHealthRefreshInterval: o.providerHealthRefreshInterval,
      hostPowerMonitorActiveInterval: o.hostPowerMonitorActiveInterval, hostPowerMonitorIdleInterval: o.hostPowerMonitorIdleInterval,
      idleClientTtl: o.idleClientTtl, pauseWhenHostLocked: o.pauseWhenHostLocked, pauseWhenHostLowPower: o.pauseWhenHostLowPower,
      pauseWhenClientLowPower: o.pauseWhenClientLowPower, pauseWhenOnBattery: o.pauseWhenOnBattery)
  }
}
