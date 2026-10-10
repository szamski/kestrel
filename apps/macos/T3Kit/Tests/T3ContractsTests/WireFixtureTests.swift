import CryptoKit
import Foundation
import Testing

@testable import T3Contracts

private enum WireFixtureError: Error { case notADispatch(String) }

/// Fixtures/wire/*.json are what Effect's JSON codec encodes for real V2 contract values
/// (scripts/generate-wire-fixtures.ts). Each must decode, and re-encode to the same JSON.
@Suite struct WireFixtureTests {
  private func wire(_ name: String) throws -> Data { try Fixtures.data("wire/\(name).json") }

  private func decode<T: Codable>(_ type: T.Type, _ name: String) throws -> T {
    let data = try wire(name)
    let diffs = try JSONCheck.roundTrip(type, data)
    #expect(diffs.isEmpty, "\(name): \(diffs.joined(separator: "; "))")
    return try JSONDecoder().decode(type, from: data)
  }

  @Test func shellSnapshotAndStreams() throws {
    let snapshot = try decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot")
    #expect(snapshot.snapshotSequence == 100 && snapshot.threads.count == 1 && snapshot.projects.count == 1)
    guard case .snapshot(let streamed) = try decode(OrchestrationV2ShellStreamItem.self, "v2-shell-stream-snapshot") else {
      Issue.record("expected a snapshot item")
      return
    }
    #expect(streamed.snapshot.snapshotSequence == 100)
    let updates = try decode([OrchestrationV2ShellStreamItem].self, "v2-shell-stream-updates")
    #expect(updates.count == 5)
    if case .unknown = updates[0] { Issue.record("`synchronized` must be a known shell item") }
  }

  @Test func threadSnapshotsHistoryAndEvents() throws {
    let bounded = try decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-bounded-snapshot")
    #expect(bounded.hasMoreHistory && bounded.historyCursor == "fixture-v2-before-10")
    #expect(bounded.projection.runs.count == 3 && !bounded.projection.turnItems.isEmpty)
    _ = try decode(OrchestrationV2ThreadStreamItem.self, "v2-thread-stream-snapshot")
    let events = try decode([OrchestrationV2ThreadStreamItem].self, "v2-thread-stream-events")
    #expect(events.count == 10)
    let history = try decode(OrchestrationV2ThreadHistoryPage.self, "v2-thread-older-history")
    #expect(!history.hasMoreHistory && history.nextCursor == nil)
    // Snapshots the client's own reducers derived after the events and the older page.
    let after = try decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-after-events-snapshot")
    let merged = try decode(OrchestrationV2ThreadBoundedSnapshot.self, "v2-thread-with-history-snapshot")
    #expect(after.snapshotSequence == 109 && merged.projection.turnItems.count > after.projection.turnItems.count)
  }

  @Test func sendSteerAndQueueCommands() throws {
    func dispatch(_ name: String) throws -> OrchestrationV2CommandMessageDispatch {
      guard case .messageDispatch(let value) = try decode(OrchestrationV2Command.self, name) else {
        throw WireFixtureError.notADispatch(name)
      }
      return value
    }
    let send = try dispatch("v2-send-command")
    #expect(send.attachments.count == 2)
    guard case .startImmediately = send.dispatchMode else { throw WireFixtureError.notADispatch("send must start immediately") }
    guard case .steerActive(let steer) = try dispatch("v2-steer-command").dispatchMode else {
      throw WireFixtureError.notADispatch("steer must target the active run")
    }
    #expect(steer.targetRunId.rawValue == "run-v2-active")
    guard case .queueAfterActive = try dispatch("v2-queue-send-command").dispatchMode else {
      throw WireFixtureError.notADispatch("queued send must wait for the active run")
    }
  }

  @Test func controlCommandsAndLaunchInput() throws {
    for name in [
      "approval", "question-attachment", "question-dismiss", "interrupt", "queue-resume", "queue-reorder",
      "queue-cancel", "queue-edit", "queue-promote", "rollback",
    ] {
      let command = try decode(OrchestrationV2Command.self, "v2-\(name)-command")
      if case .unknown = command { Issue.record("\(name): decoded as an unknown command") }
    }
    let launch = try decode(OrchestrationV2ThreadLaunchInput.self, "v2-launch-input")
    #expect(launch.threadId?.rawValue == "thread-v2-new" && launch.initialMessage?.attachments.count == 2)
  }

  /// The protocol-1 recordings are the baseline for the `V1` types; they must stay exactly as recorded.
  @Test func frozenV1RecordingsMatchTheirManifest() throws {
    struct Manifest: Decodable {
      let baseline: String
      let sha256: [String: String]
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: try wire("frozen-v1-manifest"))
    #expect(manifest.sha256.count > 20)
    for (name, digest) in manifest.sha256 {
      let bytes = try Fixtures.data(name)
      #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest, "\(name) changed")
    }
    let shell = try Fixtures.data("shell.json")
    #expect(try JSONCheck.roundTrip(V1.OrchestrationShellSnapshot.self, shell).isEmpty)
  }
}
