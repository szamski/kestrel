import Foundation
import T3Contracts

/// Port of `state/serverConfigProjection.ts`.
public struct ServerConfigProjection: Sendable, Equatable {
  public enum Source: String, Sendable { case cache, live }
  public var config: ServerConfig
  public var source: Source

  /// Cached config keeps the provider and model catalog across reconnects; published themes and
  /// usage-limit sources are current machine state, so they are never restored from a cache.
  public static func withoutEnvironmentThemes(_ config: ServerConfig) -> ServerConfig {
    var stripped = config
    stripped.environmentThemes = nil
    stripped.usageLimitSources = nil
    return stripped
  }

  /// Folds one `subscribeServerConfig` event into the projection. Updates before a snapshot are ignored.
  public static func apply(_ current: ServerConfigProjection?, _ event: ServerConfigStreamEvent) -> ServerConfigProjection? {
    switch event {
    case .snapshot(let e):
      // Wire snapshots never contain published themes: keep the previous set until a capable
      // server sends its authoritative event; a downgrade clears it.
      var config = e.config
      let capabilities = config.environment.capabilities
      if capabilities.environmentThemes == true, let carried = current?.config.environmentThemes { config.environmentThemes = carried }
      if capabilities.usageLimitSources == true, let carried = current?.config.usageLimitSources { config.usageLimitSources = carried }
      return ServerConfigProjection(config: config, source: .live)
    case .keybindingsUpdated(let e):
      guard var next = current else { return nil }
      next.config.keybindings = e.payload.keybindings
      next.config.issues = e.payload.issues
      next.source = .live
      return next
    case .providerStatuses(let e):
      guard var next = current else { return nil }
      next.config.providers = e.payload.providers
      next.source = .live
      return next
    case .settingsUpdated(let e):
      guard var next = current else { return nil }
      next.config.settings = e.payload.settings
      next.source = .live
      return next
    case .environmentThemesUpdated(let e):
      guard var next = current else { return nil }
      next.config.environmentThemes = e.payload.themes.isEmpty ? nil : e.payload.themes
      next.source = .live
      return next
    case .usageLimitSourcesUpdated(let e):
      guard var next = current else { return nil }
      next.config.usageLimitSources = e.payload.sources.isEmpty ? nil : e.payload.sources
      next.source = .live
      return next
    case .unknown:
      return current
    }
  }
}
