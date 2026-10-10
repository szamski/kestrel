import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

// Builders for the hand-written tests: wire JSON in, generated types out, so the tests exercise
// the same decoding the app does.

func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) -> T {
  do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) } catch { fatalError("bad test JSON: \(error)\n\(json)") }
}

func decodeJSON<T: Decodable>(_ json: String) -> T { decodeJSON(T.self, json) }

private func jsonString(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

/// `makeActivity` of session-logic.test.ts. `payload` is JSON text.
func activity(
  _ id: String,
  _ kind: String = "tool.started",
  summary: String = "Tool call",
  tone: String = "tool",
  turn: String? = nil,
  sequence: Int? = nil,
  at: String = "2026-02-23T00:00:00.000Z",
  _ payload: String = "{}"
) -> V1.OrchestrationThreadActivity {
  decodeJSON(
    """
    {"id":"\(id)","tone":"\(tone)","kind":"\(kind)","summary":\(summaryLiteral(summary)),"payload":\(payload),
     "turnId":\(jsonString(turn)),\(sequence.map { "\"sequence\":\($0)," } ?? "")"createdAt":"\(at)"}
    """)
}

private func summaryLiteral(_ summary: String) -> String {
  let data = try! JSONEncoder().encode(summary)
  return String(decoding: data, as: UTF8.self)
}

/// A wire message. Defaults: a settled assistant message of turn-1.
func message(
  _ id: String,
  _ role: String = "assistant",
  text: String = "text",
  turn: String? = "turn-1",
  streaming: Bool = false,
  at: String = "2026-01-01T00:00:00.000Z",
  updatedAt: String? = nil
) -> V1.OrchestrationMessage {
  decodeJSON(
    """
    {"id":"\(id)","role":"\(role)","text":\(summaryLiteral(text)),"turnId":\(jsonString(role == "user" ? nil : turn)),
     "streaming":\(streaming),"createdAt":"\(at)","updatedAt":"\(updatedAt ?? at)"}
    """)
}

func workEntry(
  _ id: String,
  label: String = "Tool call",
  tone: WorkLogTone = .tool,
  turn: String? = nil,
  at: String = "2026-01-01T00:00:00.000Z",
  kind: String? = nil
) -> WorkLogEntry {
  WorkLogEntry(id: id, createdAt: at, turnId: turn.map { V1.TurnId($0) }, label: label, tone: tone, sourceActivityKind: kind)
}

func timelineEntries(_ values: [TimelineEntry]) -> [TimelineEntry] { values }

func latestTurn(_ id: String = "turn-1", state: V1.OrchestrationLatestTurnState = .completed, started: String? = "2026-01-01T00:00:00.000Z", completed: String? = nil)
  -> LatestTurnTiming
{
  LatestTurnTiming(turnId: V1.TurnId(id), state: state, startedAt: started, completedAt: completed)
}

func rows(
  _ entries: [TimelineEntry],
  latestTurn: LatestTurnTiming? = nil,
  runningTurnId: String? = nil,
  expandedTurnIds: Set<String> = [],
  expandedWorkGroupIds: Set<String> = [],
  isWorking: Bool = false,
  activeTurnStartedAt: String? = nil,
  summaries: [V1.OrchestrationCheckpointSummary] = [],
  rollback: Bool = false,
  liveAgentTaskIds: Set<String>? = nil,
  worktreeSetup: WorktreeSetupSnapshot? = nil,
  queued: [QueuedMessagePlaceholder] = []
) -> [TimelineRow] {
  deriveMessagesTimelineRows(
    TimelineRowsInput(
      timelineEntries: entries,
      latestTurn: latestTurn,
      runningTurnId: runningTurnId.map { V1.TurnId($0) },
      expandedTurnIds: Set(expandedTurnIds.map { V1.TurnId($0) }),
      expandedWorkGroupIds: expandedWorkGroupIds,
      isWorking: isWorking,
      activeTurnStartedAt: activeTurnStartedAt,
      turnDiffSummaries: summaries,
      supportsConversationRollback: rollback,
      liveAgentTaskIds: liveAgentTaskIds,
      worktreeSetup: worktreeSetup,
      queuedMessages: queued
    ))
}

extension TimelineRow {
  var kind: String {
    switch self {
    case .activityGroup: "activity-group"
    case .work: "work"
    case .workLive: "work-live"
    case .workToggle: "work-toggle"
    case .turnFold: "turn-fold"
    case .contextCompaction: "context-compaction"
    case .message: "message"
    case .assistantMeta: "assistant-meta"
    case .proposedPlan: "proposed-plan"
    case .working: "working"
    case .thinking: "thinking"
    case .worktreeSetup: "worktree-setup"
    case .queuedMessage: "queued-message"
    case .attemptFold: "attempt-fold"
    case .event: "event"
    case .htmlRender: "html-render"
    case .mcpApp: "mcp-app"
    }
  }
}

func kinds(_ rows: [TimelineRow]) -> [String] { rows.map(\.kind) }
