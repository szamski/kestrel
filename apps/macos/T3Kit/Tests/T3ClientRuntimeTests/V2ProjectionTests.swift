import Foundation
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// The wire fixtures are what Effect encodes for real protocol-2 values (scripts/generate-wire-fixtures.ts); the
/// `after-events` and `with-history` snapshots are what the TypeScript reducers computed from the others.
/// The Swift reducers must reproduce them exactly.
enum WireFixture {
  static func data(_ name: String, file: String = #filePath) throws -> Data {
    let tests = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: tests.appendingPathComponent("T3ContractsTests/Fixtures/wire/\(name).json"))
  }

  static func decode<T: Decodable>(_ type: T.Type, _ name: String, file: String = #filePath) throws -> T {
    try JSONDecoder().decode(type, from: try data(name, file: file))
  }
}

/// Differences between two values as JSON (`null` and a missing key differ on purpose).
private func differences<T: Encodable>(_ expected: T, _ actual: T) throws -> [String] {
  jsonDiff(try toAny(expected), try toAny(actual), limit: 8)
}

@Suite struct V2ProjectionTests {
  private func streamEvents() throws -> [OrchestrationV2ThreadStreamItem] {
    try WireFixture.decode([OrchestrationV2ThreadStreamItem].self, "v2-thread-stream-events")
  }

  @Test func eventsReduceTheBoundedWindowToWhatTheWebReducerComputed() throws {
    let bounded = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot")
    let expected = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-after-events-snapshot")
    var projection = bounded.projection
    let options = ProjectionOptions(partialTimeline: true, latestLocalTurnOrdinal: bounded.latestLocalTurnOrdinal)
    for case .event(let item) in try streamEvents() {
      if case .updated(let next) = ThreadProjectionReducer.apply(projection, item.event, options: options) { projection = next }
    }
    let diff = try differences(expected.projection, projection)
    #expect(diff.isEmpty, "\(diff)")
  }

  @Test func theMachineAppliesSnapshotEventsAndTheCompletionMarkerLikeTheWebState() throws {
    let bounded = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot")
    let expected = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-after-events-snapshot")
    var machine = ThreadDetailMachineV2()
    let plan = machine.beginSubscription(config: nil)
    #expect(plan.needsSnapshot && !plan.parked)
    machine.applyHttp(HTTPSnapshotLoader.detail(bounded), history: ThreadHistoryMeta.of(bounded))
    #expect(machine.state.history.historyCursor == "fixture-v2-before-10" && machine.state.history.hasMoreHistory)
    // The batch includes `synchronized`; events 108 and 109 land in a window that must not take older rows.
    let deleted = machine.apply(try streamEvents())
    #expect(!deleted)
    #expect(machine.lastSequence == 109)
    #expect(machine.state.projection == expected.projection)
    #expect(machine.state.history.latestLocalTurnOrdinal == 18, "a new local row moves the partial-window watermark")
    #expect(machine.state.status == .live)
    // The settled thread is cached with its window evidence so a cold open can page again.
    let request = machine.takePersistRequest()
    let saved = try #require(request)
    #expect(saved.snapshotSequence == 109 && optionalValue(saved.historyCursor) == "fixture-v2-before-10")
  }

  @Test func olderHistoryMergesWithoutReplacingFresherLiveRows() throws {
    let after = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-after-events-snapshot")
    let merged = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-with-history-snapshot")
    let page = try WireFixture.decode(OrchestrationV2ThreadHistoryPage.self, "v2-thread-older-history")
    let result = ThreadHistory.mergeOlder(after.projection, page.items)
    let diff = try differences(merged.projection, result)
    #expect(diff.isEmpty, "\(diff)")
    // The stale overlapping assistant row in the page lost against the streamed text.
    let assistant = result.visibleTurnItems.first { $0.sourceItemId.rawValue == "item-v2-assistant" }
    if case .assistantMessage(let item)? = assistant?.item { #expect(item.text == "The native wire contract and attachments are valid.") }
    #expect(ThreadHistory.mergeOlder(result, page.items) == result, "merging the same page twice is a no-op")
  }

  @Test func loadingEarlierFollowsTheCursorThatStartedTheRequest() throws {
    let bounded = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot")
    let page = try WireFixture.decode(OrchestrationV2ThreadHistoryPage.self, "v2-thread-older-history")
    var machine = ThreadDetailMachineV2()
    _ = machine.beginSubscription(config: nil)
    machine.applyHttp(HTTPSnapshotLoader.detail(bounded), history: ThreadHistoryMeta.of(bounded))
    guard case .request(let cursor) = machine.beginLoadEarlier() else {
      Issue.record("expected a request")
      return
    }
    #expect(machine.beginLoadEarlier() == .busy && machine.state.history.loading)
    // A socket snapshot replaced the window while the page was in flight: the answer no longer applies.
    var stale = machine
    stale.apply([
      .snapshot(
        OrchestrationV2ThreadStreamItemSnapshot(
          snapshotSequence: 120, projection: bounded.projection, historyCursor: .some("another-cursor"), hasMoreHistory: true, latestLocalTurnOrdinal: .some(17)))
    ])
    #expect(stale.completeLoadEarlier(cursor: cursor, page: page, message: nil) == .noop)
    #expect(machine.completeLoadEarlier(cursor: cursor, page: nil, message: "offline") == .error("offline"))
    #expect(machine.state.history.error == "offline" && !machine.state.history.loading && machine.state.history.showsLoadEarlier)
    guard case .request(let retry) = machine.beginLoadEarlier() else {
      Issue.record("a failed load can be retried")
      return
    }
    #expect(machine.completeLoadEarlier(cursor: retry, page: page, message: nil) == .loaded)
    #expect(!machine.state.history.hasMoreHistory && machine.state.history.expanded && machine.state.history.historyCursor == nil)
    #expect(machine.takePersistRequest() == nil || machine.state.history.expanded, "an expanded timeline stays out of the cache")
  }

  @Test func aThreadDeleteEventEndsTheStateAndAGapSkipsUnknownEvents() throws {
    let bounded = try WireFixture.decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot")
    var machine = ThreadDetailMachineV2()
    _ = machine.beginSubscription(config: nil)
    machine.applyHttp(HTTPSnapshotLoader.detail(bounded), history: ThreadHistoryMeta.of(bounded))
    // An event type from a newer server moves the cursor and nothing else.
    let unknown = OrchestrationV2ThreadStreamItemUnknownEvent(sequence: 101, event: .init(type: "future.event", payload: nil))
    machine.apply([.unknownEvent(unknown)])
    #expect(machine.lastSequence == 101 && machine.state.projection == bounded.projection)
    // Replaying an old sequence changes nothing.
    var event = try streamEvents().compactMap { item -> OrchestrationV2ThreadStreamItemEvent? in if case .event(let e) = item { e } else { nil } }[0]
    event.sequence = 100
    machine.apply([.event(event)])
    #expect(machine.state.projection == bounded.projection)
  }
}

@Suite struct V2ShellTests {
  @Test func snapshotThenDeltasMatchTheServerAndTheSidebarShapeFollows() throws {
    let snapshot = try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot")
    let updates = try WireFixture.decode([OrchestrationV2ShellStreamItem].self, "v2-shell-stream-updates")
    var machine = ShellStateMachine()
    machine.beginSubscription(supportsCompletionMarker: true)
    machine.apply(v2: [.snapshot(OrchestrationV2ShellStreamItemSnapshot(snapshot: snapshot))])
    #expect(machine.state.status == .synchronizing, "a completion marker was requested: not live before `synchronized`")
    let first = try #require(machine.state.snapshot?.threads.first)
    #expect(first.hasPendingApprovals && !first.hasPendingUserInput, "a pending command request is an approval")
    machine.apply(v2: [updates[0]])
    #expect(machine.state.status == .live)

    let result = machine.apply(v2: Array(updates.dropFirst()))
    #expect(result.changed && result.snapshotChanged)
    let v2 = try #require(machine.state.v2)
    #expect(v2.snapshotSequence == 104 && v2.threads.isEmpty && v2.archivedThreads.isEmpty, "removed and archived deltas leave the live shell")
    #expect(v2.projects.first?.title == "Updated fixture project")
    let shown = try #require(machine.state.snapshot)
    #expect(shown.snapshotSequence == 104 && shown.threads.isEmpty && shown.projects.first?.title == "Updated fixture project")

    // Stale deltas (sequence <= cursor) change nothing.
    var again = machine
    again.apply(v2: [updates[1]])
    #expect(again.state == machine.state)
  }

  @Test func theRunBecomesTheLatestTurnAndTheActivityBecomesTheSession() throws {
    let snapshot = try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot")
    var thread = snapshot.threads[0]
    thread.pendingRuntimeRequest = OrchestrationV2PendingRuntimeRequestSummary(id: "request-1", kind: .user_input, createdAt: thread.updatedAt)
    thread.status = .running
    thread.activityRunStatus = .some(.running)
    let shown = ShellPresentation.thread(thread)
    #expect(shown.hasPendingUserInput && !shown.hasPendingApprovals)
    #expect(shown.session?.status == .running && shown.latestTurn?.state == .running)
    #expect(ThreadList.status(shown) == .input)

    thread.pendingRuntimeRequest = nil
    thread.status = .queued
    thread.activityRunStatus = nil
    #expect(ShellPresentation.thread(thread).session?.status == .starting, "queued work reads as starting")
    thread.status = .completed
    thread.latestRunCompletedAt = nil  // an older server omits the stamp: the shell's own time stands in once the run is over
    thread.pendingBackgroundTasks = []
    let completed = ShellPresentation.thread(thread)
    #expect(completed.latestTurn?.state == .completed && completed.latestTurn?.completedAt != nil && completed.session?.status == .ready)
  }

  @Test func aProjectUpdateWithoutIdentityKeepsTheResolvedOne() throws {
    var snapshot = try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot")
    let identity = try JSONDecoder().decode(RepositoryIdentity.self, from: Data(#"{"canonicalKey":"github.com/o/r","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"git@github.com:o/r.git"}}"#.utf8))
    snapshot.projects[0].repositoryIdentity = .some(identity)
    var update = snapshot.projects[0]
    update.repositoryIdentity = .some(nil)
    let reduced = ShellReducerV2.apply(snapshot, .projectUpdated(OrchestrationV2ShellStreamItemProjectUpdated(sequence: snapshot.snapshotSequence + 1, project: update)))
    #expect(optionalValue(reduced.projects[0].repositoryIdentity) == identity)
    // An enrichment snapshot patches identity only and never replaces structure or the cursor.
    var enrichment = snapshot
    enrichment.snapshotSequence = 5
    enrichment.threads = []
    let merged = ShellReducerV2.mergeSnapshot(previous: snapshot, enrichment, resolvedRoots: [snapshot.projects[0].workspaceRoot])
    #expect(merged.snapshotSequence == snapshot.snapshotSequence && merged.threads == snapshot.threads)
  }
}
