import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

/// A 500-turn thread of tool-heavy turns. The budget in the issue is 5 ms in release; debug
/// builds are far slower, so the assertion only guards against accidental quadratic behavior.
@Suite struct PerformanceTests {
  static func largeThread(turns: Int) -> (messages: [V1.OrchestrationMessage], activities: [V1.OrchestrationThreadActivity], checkpoints: [V1.OrchestrationCheckpointSummary]) {
    var messages: [V1.OrchestrationMessage] = []
    var activities: [V1.OrchestrationThreadActivity] = []
    var checkpoints: [V1.OrchestrationCheckpointSummary] = []
    func time(_ turn: Int, _ offset: Int) -> String {
      let seconds = turn * 40 + offset
      return String(format: "2026-03-%02dT%02d:%02d:%02d.000Z", 1 + seconds / 86_400, seconds / 3_600 % 24, seconds / 60 % 60, seconds % 60)
    }
    for turn in 0..<turns {
      let turnId = "turn-\(turn)"
      messages.append(message("user-\(turn)", "user", text: "Request \(turn)", at: time(turn, 0)))
      messages.append(message("reasoning-\(turn)", "reasoning", text: "thinking", turn: turnId, at: time(turn, 1)))
      for tool in 0..<4 {
        let id = "tool-\(turn)-\(tool)"
        let payload = #"{"itemType":"command_execution","toolCallId":"\#(id)","status":"completed","title":"Ran command","data":{"item":{"command":"git status \#(tool)","aggregatedOutput":"ok"}}}"#
        activities.append(activity("\(id)-s", "tool.started", turn: turnId, at: time(turn, 2 + tool), payload))
        activities.append(activity("\(id)-c", "tool.completed", turn: turnId, at: time(turn, 3 + tool), payload))
      }
      messages.append(message("assistant-\(turn)", "assistant", text: String(repeating: "answer ", count: 20), turn: turnId, at: time(turn, 20), updatedAt: time(turn, 30)))
      checkpoints.append(
        decodeJSON(
          """
          {"turnId":"\(turnId)","checkpointTurnCount":\(turn + 1),"checkpointRef":"ref-\(turn)","status":"ready",
           "files":[{"path":"src/f\(turn).ts","kind":"modified","additions":2,"deletions":1}],"assistantMessageId":"assistant-\(turn)","completedAt":"\(time(turn, 31))"}
          """))
    }
    return (messages, activities, checkpoints)
  }

  @Test func derivesA500TurnThreadWithoutBlowingUp() {
    let thread = Self.largeThread(turns: 500)
    let clock = ContinuousClock()
    var timeline: ThreadTimeline?
    let elapsed = clock.measure {
      timeline = deriveThreadTimeline(
        messages: thread.messages, proposedPlans: [], activities: thread.activities, checkpoints: thread.checkpoints, latestTurn: nil, session: nil)
    }
    #expect(timeline?.rows.isEmpty == false)
    #expect(timeline?.workEntries.count == 500 * 4)
    // Report once for the record; the hard limit is generous because tests run unoptimized.
    print("T3Timeline: derived 500 turns (\(thread.messages.count) messages, \(thread.activities.count) activities) in \(elapsed)")
    #expect(elapsed < .seconds(5))
  }

  @Test func deriverReusesTheWorkLogWhileActivitiesAreUnchanged() {
    let data = Self.largeThread(turns: 50)
    var thread: V1.OrchestrationThread = decodeJSON(
      """
      {"id":"t","projectId":"p","title":"t","modelSelection":{"instanceId":"codex","model":"m"},"runtimeMode":"full-access","interactionMode":"default",
       "branch":null,"worktreePath":null,"pullRequests":[],"latestTurn":null,"createdAt":"2026-03-01T00:00:00.000Z","updatedAt":"2026-03-01T00:00:00.000Z",
       "messages":[],"proposedPlans":[],"activities":[],"checkpoints":[],"session":null}
      """)
    thread.messages = data.messages
    thread.activities = data.activities
    var deriver = ThreadTimelineDeriver()
    let first = deriver.derive(thread)
    thread.messages[thread.messages.count - 1].text += " more"
    let second = deriver.derive(thread)
    #expect(first.workEntries == second.workEntries)
    #expect(second.rows.count == first.rows.count)
    #expect(second.projection == deriveThreadTimeline(thread).projection)
  }
}
