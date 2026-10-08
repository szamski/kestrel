import Foundation
import Testing

@testable import T3Composer

@Suite("Prompt stash oracle") struct StashOracleTests {
  private func image(_ id: String, _ length: Int) -> PersistedImageAttachment {
    PersistedImageAttachment(id: id, name: "\(id).png", mimeType: "image/png", sizeBytes: 10, dataUrl: String(repeating: "x", count: length))
  }

  private func entry(_ any: [String: Any]) -> PromptStashEntry {
    PromptStashEntry(
      id: any.string("id"), createdAt: any.string("createdAt"), prompt: any.string("prompt"),
      attachments: (any["attachments"] as! [[String: Any]]).map { image($0.string("id"), $0.int("length")) },
      droppedImageNames: any["droppedImageNames"] as? [String] ?? [], unreadableImageNames: any["unreadableImageNames"] as? [String],
      pendingImageCount: (any["pendingImageCount"] as? NSNumber)?.intValue)
  }

  private func brief(_ entry: PromptStashEntry) -> [String: Any] {
    ["id": entry.id, "prompt": entry.prompt, "attachments": entry.attachments.map { ["id": $0.id, "length": $0.dataUrl.jsLength] as [String: Any] },
      "dropped": entry.droppedImageNames, "unreadable": entry.unreadableImageNames as Any? ?? NSNull(), "pending": entry.pendingImageCount as Any? ?? NSNull()]
  }

  @Test func scripts() throws {
    try Oracle.check("stashScript") { input in
      var stash = PromptStash(entries: (input["initial"] as! [[String: Any]]).map(entry))
      var trace: [Any] = [["start": stash.entries.map(brief)]]
      for op in input["ops"] as! [[String: Any]] {
        var result: Any = NSNull()
        switch op.string("op") {
        case "stash": result = stash.stash(entry(op["entry"] as! [String: Any]))?.id as Any? ?? NSNull()
        case "take": result = stash.take(op.string("id"))?.id as Any? ?? NSNull()
        case "finalize":
          result = stash.finalizeImages(
            op.string("id"), attachments: (op["images"] as! [[String: Any]]).map { image($0.string("id"), $0.int("length")) },
            droppedImageNames: op["dropped"] as! [String], unreadableImageNames: op["unreadable"] as! [String])
        default: Issue.record("unknown op")
        }
        trace.append(["result": result, "entries": stash.entries.map(brief)])
      }
      return trace
    }
    try Oracle.check("stashPartition") { input in
      let lengths = (input["lengths"] as! [NSNumber]).map(\.intValue)
      let result = PromptStash.partition(lengths.enumerated().map { image("i\($0.offset)", $0.element) })
      return ["kept": result.kept.map(\.id), "dropped": result.droppedNames]
    }
  }

  @Test func dispatchAcknowledgement() {
    typealias Input = QueuedMessages.DispatchInput
    let base = ThreadDispatchSnapshot(startedAt: "t", latestUserMessageId: "u1", latestTurnTurnId: "turn-1", latestTurnStartedAt: "s", sessionStatus: "ready", sessionUpdatedAt: "x")
    // No local dispatch: nothing to acknowledge.
    #expect(!QueuedMessages.hasServerAcknowledged(nil, Input(phase: .ready)))
    // Approvals, questions and errors end the wait.
    #expect(QueuedMessages.hasServerAcknowledged(base, Input(phase: .connecting, hasPendingApproval: true)))
    #expect(QueuedMessages.hasServerAcknowledged(base, Input(phase: .connecting, threadError: "boom")))
    // Connecting never acknowledges.
    #expect(!QueuedMessages.hasServerAcknowledged(base, Input(phase: .connecting, latestUserMessageId: "u2")))
    // A running turn is acknowledged by a new user message (steering) ...
    #expect(QueuedMessages.hasServerAcknowledged(base, Input(phase: .running, latestTurn: .init(turnId: "turn-1", startedAt: "s"), latestUserMessageId: "u2")))
    // ... but unchanged state is not.
    #expect(!QueuedMessages.hasServerAcknowledged(base, Input(phase: .running, latestTurn: .init(turnId: "turn-1", startedAt: "s"), latestUserMessageId: "u1")))
    // A changed turn must have started and be the active one.
    #expect(!QueuedMessages.hasServerAcknowledged(base, Input(phase: .running, latestTurn: .init(turnId: "turn-2"), latestUserMessageId: "u1")))
    #expect(!QueuedMessages.hasServerAcknowledged(
      base, Input(phase: .running, latestTurn: .init(turnId: "turn-2", startedAt: "s2"), latestUserMessageId: "u1", session: .init(status: "running", updatedAt: "y", activeTurnId: "turn-3"))))
    #expect(QueuedMessages.hasServerAcknowledged(
      base, Input(phase: .running, latestTurn: .init(turnId: "turn-2", startedAt: "s2"), latestUserMessageId: "u1", session: .init(status: "running", updatedAt: "y", activeTurnId: "turn-2"))))
    // Idle: any change in turn or session counts.
    #expect(!QueuedMessages.hasServerAcknowledged(base, Input(phase: .ready, latestTurn: .init(turnId: "turn-1", startedAt: "s"), latestUserMessageId: "u1", session: .init(status: "ready", updatedAt: "x"))))
    #expect(QueuedMessages.hasServerAcknowledged(base, Input(phase: .ready, latestTurn: .init(turnId: "turn-1", startedAt: "s"), latestUserMessageId: "u1", session: .init(status: "running", updatedAt: "x"))))
    // A new start-failure activity ends the wait.
    #expect(QueuedMessages.hasServerAcknowledged(base, Input(phase: .ready, latestTurnStartFailureId: "fail-1")))
  }
}
