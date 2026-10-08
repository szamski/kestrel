import Foundation
import T3Contracts
import Testing

@testable import T3Composer

@Suite("Queued message state machine oracle") struct QueueOracleTests {
  private func messageJSON(_ message: QueuedComposerMessage?) throws -> Any {
    guard let message else { return NSNull() }
    return [
      "id": message.id, "prompt": message.prompt, "queuedAfterToolActivityId": message.queuedAfterToolActivityId as Any? ?? NSNull(),
      "createdAt": message.createdAt, "holdUntilUserAction": message.holdUntilUserAction, "sending": message.sending?.rawValue as Any? ?? NSNull(),
      "sendSettings": try json(message.sendSettings),
    ] as [String: Any]
  }

  private func snapshot(_ n: Int) -> ThreadDispatchSnapshot {
    ThreadDispatchSnapshot(
      startedAt: "2026-01-01T00:00:0\(n % 10).000Z", latestUserMessageId: n % 3 == 0 ? nil : "user-\(n)", latestTurnTurnId: "turn-\(n)", sessionStatus: "ready")
  }

  private func stateJSON(_ store: QueuedMessageStore) throws -> Any {
    var queues: [String: Any] = [:]
    for (key, queue) in store.queuesByThreadKey { queues[key] = try queue.map(messageJSON) }
    var dispatches: [String: Any] = [:]
    for (key, dispatch) in store.lastDispatchByThreadKey {
      dispatches[key] = [
        "messageId": dispatch.messageId as Any? ?? NSNull(), "thread": try json(dispatch.thread),
        "previous": try dispatch.previous.map(json) as Any? ?? NSNull(),
      ] as [String: Any]
    }
    return ["queues": queues, "lastDispatch": dispatches]
  }

  @Test func scriptsMatchTheStore() throws {
    try Oracle.check("queueScript", nullEqualsMissing: true) { input in
      var store = QueuedMessageStore()
      var trace: [Any] = []
      for op in input["ops"] as! [[String: Any]] {
        let key = op["key"] as? String ?? ""
        let alias = op["alias"] as? String ?? ""
        let n = (op["n"] as? NSNumber)?.intValue ?? 0
        var result: Any = NSNull()
        switch op.string("op") {
        case "enqueue":
          let settings = QueuedMessageSendSettings(
            modelSelection: ModelSelection(instanceId: "codex", model: "m\(n)", options: nil), runtimeMode: .fullAccess, interactionMode: .default,
            promptEffort: n % 2 == 0 ? nil : "high")
          let message = QueuedComposerMessage(
            id: alias, prompt: op.string("prompt"), sendSettings: settings, queuedAfterToolActivityId: op["tool"] as? String,
            createdAt: "2026-01-01T00:00:0\(n % 10).000Z")
          store.enqueue(key, message)
          result = try messageJSON(message)
        case "beginSend": result = try messageJSON(store.beginSend(key, id: alias, toolActivityId: op["tool"] as? String))
        case "markDispatching": result = store.markDispatching(key, id: alias, thread: snapshot(n))
        case "finishSend": store.finishSend(key, id: alias)
        case "failSend": result = store.failSend(key, id: alias)
        case "remove": result = try messageJSON(store.remove(key, id: alias))
        case "drain": result = try store.drain(key).map(messageJSON)
        default: Issue.record("unknown op")
        }
        trace.append(["op": op, "result": result, "state": try stateJSON(store)])
      }
      return trace
    }
  }

  @Test func dueAndBoundary() throws {
    try Oracle.check("latestToolActivity") { input in
      let activities = (input["activities"] as! [[String: Any]]).map {
        QueuedMessages.ToolActivity(id: $0.string("id"), kind: $0.string("kind"), sequence: ($0["sequence"] as? NSNumber)?.intValue, createdAt: $0.string("createdAt"))
      }
      return QueuedMessages.latestCompletedToolActivityId(activities) as Any? ?? NSNull()
    }
    try Oracle.check("queuedDue") { input in
      QueuedMessages.isDue(
        holdUntilUserAction: input.bool("holdUntilUserAction"), queuedAfterToolActivityId: input["queuedAfterToolActivityId"] as? String,
        phase: QueuedMessages.Phase(rawValue: input.string("phase"))!, latestToolActivityId: input["latestToolActivityId"] as? String)
    }
  }
}
