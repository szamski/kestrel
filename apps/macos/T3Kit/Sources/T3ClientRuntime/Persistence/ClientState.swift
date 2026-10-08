import Foundation
import T3Contracts

/// State the client owns locally and the server never sees. Today: when each thread was last
/// visited, which is all that "unread" and "woke" are derived from.
public struct ClientState: Sendable, Equatable, Codable {
  public var version = 1
  /// `environmentId:threadId` -> ISO timestamp.
  public var threadLastVisitedAtById: [String: IsoDateTime] = [:]
  public init() {}

  /// `markThreadVisited` (apps/web/src/uiStateStore.ts): never moves a visit backwards.
  public mutating func markVisited(_ key: String, at visitedAt: IsoDateTime) {
    guard let visited = IsoTimestamp.parse(visitedAt) else { return }
    if let previous = threadLastVisitedAtById[key].flatMap(IsoTimestamp.parse), previous >= visited { return }
    threadLastVisitedAtById[key] = visitedAt
  }

  /// `markThreadUnread`: stamps the visit one millisecond before the latest completion.
  public mutating func markUnread(_ key: String, latestTurnCompletedAt: IsoDateTime?) {
    guard let completed = latestTurnCompletedAt.flatMap(IsoTimestamp.parse) else { return }
    let unreadVisitedAt = IsoTimestamp.format(milliseconds: completed - 1)
    if threadLastVisitedAtById[key] == unreadVisitedAt { return }
    threadLastVisitedAtById[key] = unreadVisitedAt
  }

  /// Explicit environment removal clears the client-owned state of its threads.
  public mutating func removeEnvironment(_ environmentId: EnvironmentId) {
    let prefix = environmentId.rawValue + ":"
    threadLastVisitedAtById = threadLastVisitedAtById.filter { !$0.key.hasPrefix(prefix) }
  }
}

/// Loads and saves `ClientState` as `client-state.json` (debounced writes).
public actor ClientStateStore {
  public nonisolated let state: ValueHub<ClientState>
  private let url: URL
  private let writer: DebouncedWriter<ClientState>

  public init(directory: URL, clock: any RuntimeClock = SystemClock()) {
    let url = directory.appendingPathComponent("client-state.json")
    self.url = url
    let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ClientState.self, from: $0) } ?? ClientState()
    state = ValueHub(loaded)
    writer = DebouncedWriter(clock: clock) { snapshot in
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
  }

  public func update(_ change: @Sendable (inout ClientState) -> Void) async {
    var next = state.value
    change(&next)
    guard next != state.value else { return }
    state.set(next)
    await writer.submit(next)
  }

  public func flush() async { await writer.flush() }
}
