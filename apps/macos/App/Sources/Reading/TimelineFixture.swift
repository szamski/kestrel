#if DEBUG
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Timeline

/// Debug-only: renders a protocol-2 thread projection from a file (`-T3TimelineFixture <scenario.json>`,
/// a file of the timeline oracle's `scenarios/` or a bare projection) in the real reading window, with a
/// canned diff behind the diff panel. For checking rows and the diff panel when no server thread has tool
/// activity. `-T3TimelineFixtureExpand YES` opens every fold and work group.
enum TimelineFixture {
  static var projection: OrchestrationV2ThreadProjection? {
    guard let path = UserDefaults.standard.string(forKey: "T3TimelineFixture"), let data = FileManager.default.contents(atPath: path),
      let json = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    var wire = json
    if case .object(let object) = json, let inner = object["projection"] { wire = inner }
    guard let encoded = try? JSONEncoder().encode(wire) else { return nil }
    return try? JSONDecoder().decode(OrchestrationV2ThreadProjection.self, from: encoded)
  }

  static var expandAll: Bool { UserDefaults.standard.bool(forKey: "T3TimelineFixtureExpand") }

  static let key = ScopedThreadKey(environmentId: EnvironmentId(rawValue: "fixture"), threadId: ThreadId(rawValue: "thread-syn"))

  /// A patch for the showcase scenario's two files.
  static let patch = """
    diff --git a/Sources/Sync/SyncClient.swift b/Sources/Sync/SyncClient.swift
    index 3b1f2a0..9c4d7e1 100644
    --- a/Sources/Sync/SyncClient.swift
    +++ b/Sources/Sync/SyncClient.swift
    @@ -12,9 +12,30 @@ public actor SyncClient {
       public init(transport: any SyncTransport) { self.transport = transport }

    -  public func send(_ request: SyncRequest) async throws -> SyncResponse {
    -    try await transport.send(request)
    -  }
    +  /// Sends a request, retrying transient failures with exponential backoff.
    +  public func send(_ request: SyncRequest, maxAttempts: Int = 3) async throws -> SyncResponse {
    +    var delay: Duration = .milliseconds(200)
    +    var attempt = 1
    +    while true {
    +      do {
    +        return try await transport.send(request)
    +      } catch let error as SyncError where error.isTransient && attempt < maxAttempts {
    +        try await Task.sleep(for: delay)
    +        delay *= 2
    +        attempt += 1
    +      }
    +    }
    +  }
     }
    diff --git a/Tests/SyncTests/SyncClientTests.swift b/Tests/SyncTests/SyncClientTests.swift
    index 51aa0c2..e7d09b4 100644
    --- a/Tests/SyncTests/SyncClientTests.swift
    +++ b/Tests/SyncTests/SyncClientTests.swift
    @@ -20,3 +20,18 @@ final class SyncClientTests: XCTestCase {
         XCTAssertEqual(response.status, .ok)
       }
    +
    +  func testRetriesTransientFailures() async throws {
    +    let transport = FlakyTransport(failures: 2)
    +    let client = SyncClient(transport: transport)
    +    let response = try await client.send(.ping)
    +    XCTAssertEqual(response.status, .ok)
    +    XCTAssertEqual(transport.attempts, 3)
    +  }
    +
    +  func testGivesUpAfterMaxAttempts() async {
    +    let client = SyncClient(transport: FlakyTransport(failures: 5))
    +    await XCTAssertThrowsErrorAsync(try await client.send(.ping))
    +  }
     }
    """
}

@MainActor @Observable
final class FixtureTimeline {
  let projection: OrchestrationV2ThreadProjection
  private(set) var items: [TimelineItem] = []
  private(set) var checkpoints: [V1.OrchestrationCheckpointSummary] = []
  private var expandedTurnIds: Set<V1.TurnId> = []
  private var expandedWorkGroupIds: Set<String> = []
  private var expandedAttemptIds: Set<String> = []
  private var expandedLocal: Set<String> = []

  init(projection: OrchestrationV2ThreadProjection, expandAll: Bool) {
    self.projection = projection
    if expandAll {
      expandedTurnIds = Set(projection.runs.map { V1.TurnId(rawValue: $0.id.rawValue) })
      expandedAttemptIds = Set(projection.attempts.map(\.id.rawValue))
      let first = derive()
      var groups = Set<String>()
      for row in first.rows {
        switch row {
        case .workToggle(let value): groups.insert(value.groupId)
        case .workLive(let value): groups.insert(value.groupId)
        default: break
        }
      }
      expandedWorkGroupIds = groups
    }
    apply(derive())
  }

  private func derive() -> ThreadTimelineV2 {
    deriveThreadTimeline(
      projection: projection,
      context: TimelineContextV2(
        expandedRunIds: Set(expandedTurnIds.map(\.rawValue)), expandedAttemptIds: expandedAttemptIds, expandedWorkGroupIds: expandedWorkGroupIds))
  }

  private func apply(_ timeline: ThreadTimelineV2) {
    checkpoints = timeline.checkpoints
    items = timeline.rows.map { TimelineItem(row: $0, expanded: expandedLocal.contains($0.id)) }
  }

  func toggleTurn(_ id: V1.TurnId) {
    if !expandedTurnIds.insert(id).inserted { expandedTurnIds.remove(id) }
    apply(derive())
  }

  func toggleAttempt(_ id: String) {
    if !expandedAttemptIds.insert(id).inserted { expandedAttemptIds.remove(id) }
    apply(derive())
  }

  func toggleWorkGroup(_ id: String) {
    if !expandedWorkGroupIds.insert(id).inserted { expandedWorkGroupIds.remove(id) }
    apply(derive())
  }

  func toggleLocal(_ id: String) {
    if !expandedLocal.insert(id).inserted { expandedLocal.remove(id) }
    items = items.map { TimelineItem(row: $0.row, expanded: expandedLocal.contains($0.id)) }
  }
}

struct TimelineFixtureReader: View {
  let app: AppModel
  let panel: RightPanelStore
  @State private var model: FixtureTimeline
  @State private var host: TimelineHost
  @State private var diff = DiffPanelModel(fetch: { _ in DiffFetchResult(patch: TimelineFixture.patch, truncated: false) })

  init(app: AppModel, panel: RightPanelStore, projection: OrchestrationV2ThreadProjection) {
    self.app = app
    self.panel = panel
    let model = FixtureTimeline(projection: projection, expandAll: TimelineFixture.expandAll)
    let host = TimelineHost(key: TimelineFixture.key, workspaceRoot: "/workspace/project", assets: app.assets)
    host.toggleTurn = { [model] in model.toggleTurn($0) }
    host.toggleWorkGroup = { [model] in model.toggleWorkGroup($0) }
    host.toggleLocal = { [model] in model.toggleLocal($0) }
    host.toggleAttempt = { [model] in model.toggleAttempt($0) }
    host.openDiff = { [weak panel] turnId, path in panel?.revealDiff(turnId: turnId.rawValue, filePath: path, in: TimelineFixture.key) }
    _model = State(initialValue: model)
    _host = State(initialValue: host)
  }

  var body: some View {
    RightPanelLayout(key: TimelineFixture.key, store: panel) {
      TimelineTable(items: model.items, host: host, hasOlder: false) {}
    } panel: {
      RightPanelView(app: app, key: TimelineFixture.key, turns: model.checkpoints, store: panel, diff: diff)
    }
    .navigationTitle("Fixture: \(model.projection.thread.title)")
    .task { if let turn = model.checkpoints.first { panel.revealDiff(turnId: turn.turnId.rawValue, filePath: nil, in: TimelineFixture.key) } }
  }
}
#endif
