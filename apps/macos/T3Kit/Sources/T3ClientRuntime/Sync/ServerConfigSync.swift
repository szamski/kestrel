import Foundation
import T3Contracts

/// Server configuration of one environment: the cached copy until the live snapshot arrives,
/// then the snapshot plus `keybindingsUpdated` / `providerStatuses` / `settingsUpdated` events.
/// Events come from the session's own config subscription (it doubles as the readiness check),
/// so this store consumes an ordered event pipe instead of opening a second subscription.
public actor ServerConfigSync {
  public nonisolated let projection = ValueHub<ServerConfigProjection?>(nil)
  private let environmentId: EnvironmentId
  private let cache: any SnapshotCache
  private let clock: any RuntimeClock
  private var current: ServerConfigProjection?
  private var writer: DebouncedWriter<ServerConfig>?
  private var task: Task<Void, Never>?

  public init(environmentId: EnvironmentId, cache: any SnapshotCache, clock: any RuntimeClock) {
    self.environmentId = environmentId
    self.cache = cache
    self.clock = clock
  }

  public func start(events: AsyncStream<ServerConfigStreamEvent>) async {
    guard task == nil else { return }
    let environmentId = environmentId, cache = cache
    writer = DebouncedWriter(clock: clock) { config in await cache.saveServerConfig(environmentId, config) }
    if let cached = await cache.loadServerConfig(environmentId) {
      // Stripped on load as well as on save: an older build may have cached published themes.
      current = ServerConfigProjection(config: ServerConfigProjection.withoutEnvironmentThemes(cached), source: .cache)
      projection.set(current)
    }
    task = Task {
      for await event in events { await self.apply(event) }
    }
  }

  public func stop() async {
    task?.cancel()
    await task?.value
    task = nil
    await writer?.flush()
  }

  /// Shows `settings` in place of the current ones (an optimistic edit, or the server's answer to one) and keeps them cached.
  func replaceSettings(_ settings: ServerSettings) async {
    guard var next = current else { return }
    next.config.settings = settings
    current = next
    projection.set(next)
    await writer?.submit(next.config)
  }

  func apply(_ event: ServerConfigStreamEvent) async {
    guard let next = ServerConfigProjection.apply(current, event) else { return }
    current = next
    projection.set(next)
    await writer?.submit(next.config)
  }
}
