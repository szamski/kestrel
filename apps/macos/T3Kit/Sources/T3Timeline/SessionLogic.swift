import Foundation
import T3Contracts

// Port of the thread-level half of apps/web/src/session-logic.ts: timeline interleaving,
// active plan, latest proposed plan, session phase and working-time helpers.

/// The slice of a latest turn that timing decisions read (`LatestTurnTiming`).
public struct LatestTurnTiming: Sendable, Hashable {
  public var turnId: TurnId?
  public var state: OrchestrationLatestTurnState?
  public var startedAt: String?
  public var completedAt: String?

  public init(turnId: TurnId?, state: OrchestrationLatestTurnState? = nil, startedAt: String?, completedAt: String?) {
    self.turnId = turnId
    self.state = state
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  public init(_ turn: OrchestrationLatestTurn) {
    self.init(turnId: turn.turnId, state: turn.state, startedAt: turn.startedAt?.rawValue, completedAt: turn.completedAt?.rawValue)
  }
}

public func isLatestTurnSettled(latestTurn: LatestTurnTiming?, session: OrchestrationSession?) -> Bool {
  guard let latestTurn, !(latestTurn.startedAt ?? "").isEmpty else { return false }
  if (latestTurn.completedAt ?? "").isEmpty { return false }
  guard let session else { return true }
  return session.status != .running
}

/// When the working indicator should count from (`deriveActiveWorkStartedAt`).
public func deriveActiveWorkStartedAt(
  latestTurn: LatestTurnTiming?,
  session: OrchestrationSession?,
  sendStartedAt: String?,
  latestUserMessageAt: String? = nil
) -> String? {
  let runningTurnId = session?.status == .running ? session?.activeTurnId : nil
  if let runningTurnId {
    if latestTurn?.turnId == runningTurnId {
      // `startedAt ?? sendStartedAt ?? latestUserMessageAt`: `??` keeps empty strings.
      return latestTurn?.startedAt ?? sendStartedAt ?? latestUserMessageAt
    }
    return sendStartedAt ?? latestUserMessageAt
  }
  if !isLatestTurnSettled(latestTurn: latestTurn, session: session) { return latestTurn?.startedAt ?? sendStartedAt }
  return sendStartedAt
}

public func derivePhase(_ session: OrchestrationSession?) -> SessionPhase {
  guard let session else { return .disconnected }
  switch session.status {
  case .stopped, .interrupted, .error: return .disconnected
  case .starting: return .connecting
  case .running: return .running
  default: return .ready
  }
}

// MARK: - Timeline entries

/// Interleaves messages, plans and work rows by creation time. Ties keep source order
/// (messages, then plans, then work), like the stable sort of the TypeScript.
public func deriveTimelineEntries(
  messages: [OrchestrationMessage],
  proposedPlans: [ProposedPlan],
  workEntries: [WorkLogEntry]
) -> [TimelineEntry] {
  // An asynchronous answer is shown once, folded into its work row, not as a user message too.
  let foldedAnswerMessageIds = Set(workEntries.compactMap { $0.questionAnswer.map { "async-answer:\($0.requestId.rawValue)" } })
  var entries: [TimelineEntry] = []
  entries.reserveCapacity(messages.count + proposedPlans.count + workEntries.count)
  for message in messages where message.role != .user || !foldedAnswerMessageIds.contains(message.id.rawValue) {
    entries.append(.message(message))
  }
  for plan in proposedPlans { entries.append(.proposedPlan(plan)) }
  for entry in workEntries { entries.append(.work(entry)) }
  return entries.stableSorted { jsLocaleCompare($0.createdAt, $1.createdAt) }
}

/// `inferCheckpointTurnCountByTurnId`: the position of each turn among completed checkpoints.
public func inferCheckpointTurnCountByTurnId(_ summaries: [OrchestrationCheckpointSummary]) -> [TurnId: Int] {
  let sorted = summaries.stableSorted { jsLocaleCompare($0.completedAt.rawValue, $1.completedAt.rawValue) }
  var result: [TurnId: Int] = [:]
  for (index, summary) in sorted.enumerated() { result[summary.turnId] = index + 1 }
  return result
}

// MARK: - Plans

private func planStateFromActivity(_ activity: OrchestrationThreadActivity) -> ActivePlanState? {
  let payload = activity.payload.looseRecord
  guard let rawPlan = payload?["plan"]?.arrayOrNil else { return nil }
  var steps: [ActivePlanState.Step] = []
  for entry in rawPlan {
    guard let record = entry.strictRecord, let step = record["step"]?.stringOrNil else { continue }
    let raw = record["status"]?.stringOrNil
    let status: ActivePlanState.StepStatus = raw == "completed" ? .completed : raw == "inProgress" ? .inProgress : .pending
    steps.append(.init(durationMs: nil, step: step, status: status))
  }
  if steps.isEmpty { return nil }
  var explanation: String??
  if let payload, let value = payload["explanation"] { explanation = .some(value.stringOrNil) }
  return ActivePlanState(createdAt: activity.createdAt.rawValue, turnId: activity.turnId, explanation: explanation, steps: steps)
}

private func keyedSteps(_ steps: [ActivePlanState.Step]) -> [(key: String, step: ActivePlanState.Step)] {
  var occurrences: [String: Int] = [:]
  return steps.map { step in
    let occurrence = occurrences[step.step, default: 0]
    occurrences[step.step] = occurrence + 1
    return ("\(step.step):\(occurrence)", step)
  }
}

private func addPlanStepDurations(_ plan: ActivePlanState, _ activities: [OrchestrationThreadActivity]) -> ActivePlanState {
  var timings: [(key: String, startedAt: Double?, completedAt: Double?)] = []
  var timingIndex: [String: Int] = [:]
  var planStartedAt: Double?
  for activity in activities {
    guard let snapshot = planStateFromActivity(activity), let activityAt = jsDateParse(activity.createdAt.rawValue) else { continue }
    if planStartedAt == nil { planStartedAt = activityAt }
    for (key, step) in keyedSteps(snapshot.steps) {
      let index: Int
      if let existing = timingIndex[key] {
        index = existing
      } else {
        index = timings.count
        timingIndex[key] = index
        timings.append((key, nil, nil))
      }
      if step.status == .inProgress && timings[index].startedAt == nil { timings[index].startedAt = activityAt }
      if step.status == .completed && timings[index].completedAt == nil { timings[index].completedAt = activityAt }
    }
  }
  // `(a ?? Infinity) - (b ?? Infinity)`: two missing times compare as NaN, i.e. equal.
  let sorted = timings.stableSorted { left, right in
    switch (left.completedAt, right.completedAt) {
    case (nil, nil): 0
    case (nil, _): 1
    case (_, nil): -1
    case (let a?, let b?): a < b ? -1 : a > b ? 1 : 0
    }
  }
  var durationByKey: [String: Double] = [:]
  var previousCompletedAt = planStartedAt
  for timing in sorted {
    guard let completedAt = timing.completedAt else { continue }
    let startedAt = timing.startedAt ?? previousCompletedAt
    if let startedAt, completedAt > startedAt { durationByKey[timing.key] = completedAt - startedAt }
    previousCompletedAt = completedAt
  }
  var result = plan
  result.steps = keyedSteps(plan.steps).map { key, step in
    guard step.status == .completed, let duration = durationByKey[key] else { return step }
    var withDuration = step
    withDuration.durationMs = duration
    return withDuration
  }
  return result
}

/// The checklist the agent is working through, preferring the latest turn's plan.
public func deriveActivePlanState(activities: [OrchestrationThreadActivity], latestTurnId: TurnId?) -> ActivePlanState? {
  let allPlanActivities = activities.filter { $0.kind == "turn.plan.updated" }.stableSorted(by: compareActivitiesByOrder)
  // Prefer the plan from the current turn; fall back to the most recent plan from any turn so
  // that TodoWrite tasks persist across follow-up messages.
  let latest =
    latestTurnId.flatMap { turnId in turnId.rawValue.isEmpty ? nil : allPlanActivities.last { $0.turnId == turnId } } ?? allPlanActivities.last
  guard let latest, let plan = planStateFromActivity(latest) else { return nil }
  let matching = allPlanActivities.filter { $0.turnId == latest.turnId }
  let latestClearIndex = matching.lastIndex { planStateFromActivity($0) == nil } ?? -1
  return addPlanStepDurations(plan, Array(matching[(latestClearIndex + 1)...]))
}

private func latestProposedPlanState(_ plan: ProposedPlan) -> LatestProposedPlanState {
  LatestProposedPlanState(
    id: plan.id,
    createdAt: plan.createdAt.rawValue,
    updatedAt: plan.updatedAt.rawValue,
    turnId: plan.turnId,
    planMarkdown: plan.planMarkdown,
    implementedAt: plan.implementedAt?.rawValue,
    implementationThreadId: plan.implementationThreadId
  )
}

public func findLatestProposedPlan(_ proposedPlans: [ProposedPlan], latestTurnId: TurnId?) -> LatestProposedPlanState? {
  func order(_ left: ProposedPlan, _ right: ProposedPlan) -> Int {
    let updated = jsLocaleCompare(left.updatedAt.rawValue, right.updatedAt.rawValue)
    return updated != 0 ? updated : jsLocaleCompare(left.id, right.id)
  }
  if let latestTurnId, !latestTurnId.rawValue.isEmpty,
    let match = proposedPlans.filter({ $0.turnId == latestTurnId }).stableSorted(by: order).last
  {
    return latestProposedPlanState(match)
  }
  return proposedPlans.stableSorted(by: order).last.map(latestProposedPlanState)
}

public func hasActionableProposedPlan(_ plan: LatestProposedPlanState?) -> Bool {
  plan != nil && plan!.implementedAt == nil
}

// MARK: - Durations

/// `formatDuration` of packages/shared/src/orchestrationTiming.ts.
public func formatDuration(_ durationMs: Double) -> String {
  if !durationMs.isFinite || durationMs < 0 { return "0ms" }
  if durationMs < 1_000 { return "\(max(1, Int(jsRound(durationMs))))ms" }
  if durationMs < 10_000 {
    let tenths = jsRound(durationMs / 100) / 10
    return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
  }
  if durationMs < 60_000 { return "\(Int(jsRound(durationMs / 1_000)))s" }
  let totalSeconds = Int(jsRound(durationMs / 1_000))
  let hours = totalSeconds / 3_600
  let minutes = (totalSeconds % 3_600) / 60
  let seconds = totalSeconds % 60
  var parts: [String] = []
  if hours > 0 { parts.append("\(hours)h") }
  if minutes > 0 { parts.append("\(minutes)m") }
  if seconds > 0 { parts.append("\(seconds)s") }
  return parts.joined(separator: " ")
}

/// `Math.round`: halves round toward positive infinity.
func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }
