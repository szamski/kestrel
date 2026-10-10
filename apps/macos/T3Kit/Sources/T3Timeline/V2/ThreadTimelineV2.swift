import Foundation
import T3Contracts

// Everything the reading window renders for one protocol-2 thread, derived from the server's
// thread projection the way ChatView.tsx does: run and runtime summaries
// (client-runtime `state/threadExecution.ts`), checkpoint summaries, plans, then the entries and
// rows of the previous files. Pure; derive off the main actor.

/// Client-side state the rows depend on besides the projection.
public struct TimelineContextV2: Sendable {
  /// `nil` derives "working" from the runtime phase. A host adds its own busy states (a send in
  /// flight, a compaction) by passing `true`, and the background-work parking the shell knows by
  /// passing `false`.
  public var isWorking: Bool?
  public var sendStartedAt: String?
  public var expandedRunIds: Set<String>
  public var expandedAttemptIds: Set<String>
  public var expandedWorkGroupIds: Set<String>
  public var supportsConversationRollback: Bool
  public var worktreeSetup: WorktreeSetupSnapshot?

  public init(
    isWorking: Bool? = nil, sendStartedAt: String? = nil, expandedRunIds: Set<String> = [], expandedAttemptIds: Set<String> = [],
    expandedWorkGroupIds: Set<String> = [], supportsConversationRollback: Bool = false, worktreeSetup: WorktreeSetupSnapshot? = nil
  ) {
    self.isWorking = isWorking
    self.sendStartedAt = sendStartedAt
    self.expandedRunIds = expandedRunIds
    self.expandedAttemptIds = expandedAttemptIds
    self.expandedWorkGroupIds = expandedWorkGroupIds
    self.supportsConversationRollback = supportsConversationRollback
    self.worktreeSetup = worktreeSetup
  }
}

public struct ThreadTimelineV2: Sendable {
  public var entries: [V2TimelineEntry]
  public var rows: [TimelineRow]
  public var phase: SessionPhase
  public var isWorking: Bool
  public var activeTurnStartedAt: String?
  public var runningRunId: String?
  public var activePlan: ActivePlanState?
  public var activeProposedPlan: LatestProposedPlanState?
  public var minimap: [TimelineMinimapItem]
  /// One per run that captured a checkpoint, in the shape the diff panel lists turns.
  public var checkpoints: [V1.OrchestrationCheckpointSummary]
}

// MARK: - Runs and runtime (threadExecution.ts, orchestrationV2ThreadError.ts)

struct RunSummary {
  var runId: String
  var status: String
  var requestedAt: String
  var startedAt: String?
  var completedAt: String?
}

private func epochMillis(_ date: IsoDateTime) -> Double { jsDateParse(date.rawValue) ?? 0 }

/// `runRanAfter`: an unfinished run is the latest.
private func runRanAfter(_ run: OrchestrationV2Run, _ other: OrchestrationV2Run) -> Bool {
  func end(_ candidate: OrchestrationV2Run) -> Double { candidate.completedAt.map(epochMillis) ?? .infinity }
  return end(run) == end(other) ? run.ordinal > other.ordinal : end(run) > end(other)
}

private func latestExecutedRun(_ runs: [OrchestrationV2Run]) -> OrchestrationV2Run? {
  var latest: OrchestrationV2Run?
  for run in runs {
    if run.status.rawValue == "queued" { continue }
    if run.status.rawValue == "cancelled" && run.startedAt == nil { continue }
    if latest == nil || runRanAfter(run, latest!) { latest = run }
  }
  return latest
}

/// The newest run that is not waiting in a held queue.
private func latestUnheldRun(_ runs: [OrchestrationV2Run]) -> OrchestrationV2Run? {
  var latest: OrchestrationV2Run?
  for run in runs {
    if run.status.rawValue == "queued" && run.queueHeld == true { continue }
    if latest == nil || run.ordinal > latest!.ordinal { latest = run }
  }
  return latest
}

private func latestRootProviderFailure(_ run: OrchestrationV2Run, _ items: [TurnItem]) -> OrchestrationV2ThreadProjectionTurnItemsItemError? {
  guard run.status.rawValue == "failed" else { return nil }
  var latest: OrchestrationV2ThreadProjectionTurnItemsItemError?
  for item in items {
    guard case .error(let error) = item, error.status.rawValue == "failed", error.runId == run.id, error.nodeId == run.rootNodeId else { continue }
    if let current = latest {
      let a = epochMillis(error.updatedAt), b = epochMillis(current.updatedAt)
      if a > b || (a == b && (error.ordinal > current.ordinal || (error.ordinal == current.ordinal && jsLocaleCompare(error.id.rawValue, current.id.rawValue) > 0))) {
        latest = error
      }
    } else {
      latest = error
    }
  }
  return latest
}

/// The failed run presented as the thread's outcome while newer queued runs sit behind it.
private func usageLimitRunPresentedAsLatest(_ projection: OrchestrationV2ThreadProjection) -> OrchestrationV2Run? {
  let sessionError = projection.providerSessions.last { $0.providerInstanceId == projection.thread.providerInstanceId }?.lastError
  guard let executed = latestExecutedRun(projection.runs), executed.status.rawValue == "failed" else { return nil }
  let failure = latestRootProviderFailure(executed, projection.turnItems)?.failure
  // A distinct session failure supersedes the turn's classification.
  let sessionDiffers = sessionError != nil && sessionError != failure?.message
  let errorClass = sessionDiffers ? nil : failure?.class.rawValue
  guard errorClass == "usage_limit", projection.runs.contains(where: { $0.ordinal > executed.ordinal }) else { return nil }
  return executed
}

private func presentedLatestRun(_ projection: OrchestrationV2ThreadProjection) -> OrchestrationV2Run? {
  usageLimitRunPresentedAsLatest(projection) ?? latestUnheldRun(projection.runs)
}

private func latestMatchingRun(_ runs: [OrchestrationV2Run], _ predicate: (OrchestrationV2Run) -> Bool) -> OrchestrationV2Run? {
  runs.reduce(nil as OrchestrationV2Run?) { latest, candidate in
    predicate(candidate) && (latest == nil || candidate.ordinal > latest!.ordinal) ? candidate : latest
  }
}

private func summarize(_ run: OrchestrationV2Run) -> RunSummary {
  RunSummary(
    runId: run.id.rawValue, status: run.status.rawValue, requestedAt: run.requestedAt.rawValue, startedAt: run.startedAt?.rawValue,
    completedAt: run.completedAt?.rawValue)
}

private let activityRunStatuses: Set<String> = ["preparing", "starting", "running", "waiting"]
private let interruptibleRunStatuses: Set<String> = ["preparing", "starting", "running"]

struct RuntimeSummary {
  var status: String
  var activeRunId: String?
  var activityStartedAt: String?
}

struct ThreadExecution {
  var latestRun: RunSummary?
  var activityRun: RunSummary?
  var runtime: RuntimeSummary?
  var runlessWorkStartedAt: String?
}

/// `deriveLatestThreadRun`, `deriveThreadActivityRun`, `deriveThreadRuntime` and
/// `deriveRunlessWorkStartedAt`.
// ponytail: background work that parks a waiting run at idle (`derivePendingBackgroundWork`) is
// not ported; the host passes `isWorking: false` for it, as the shell already knows it.
func deriveThreadExecution(_ projection: OrchestrationV2ThreadProjection) -> ThreadExecution {
  let presented = presentedLatestRun(projection)
  let latestRun = presented.map(summarize)
  let live = latestMatchingRun(projection.runs) { activityRunStatuses.contains($0.status.rawValue) }
  let activity = live ?? presented
  var runtime: RuntimeSummary?
  if !(latestRun == nil && projection.thread.activeProviderThreadId == nil) {
    let activeRunId = latestMatchingRun(projection.runs) { interruptibleRunStatuses.contains($0.status.rawValue) }?.id.rawValue
    runtime = RuntimeSummary(
      status: usageLimitRunPresentedAsLatest(projection) != nil ? "failed" : (activity?.status.rawValue ?? "idle"),
      activeRunId: activeRunId,
      activityStartedAt: live.map { ($0.workStartedAt ?? $0.startedAt ?? $0.requestedAt).rawValue })
  }
  var runless: String?
  let thread = projection.thread
  if thread.lineage.relationshipToParent?.rawValue == "subagent" && thread.creationSource.rawValue == "provider",
    let node = projection.nodes.last(where: { $0.kind.rawValue == "root_turn" && $0.runId == nil }), ["pending", "running", "waiting"].contains(node.status.rawValue)
  {
    runless = node.startedAt?.rawValue
  }
  return ThreadExecution(latestRun: latestRun, activityRun: activity.map(summarize), runtime: runtime, runlessWorkStartedAt: runless)
}

func deriveRuntimePhase(_ runtime: RuntimeSummary?) -> SessionPhase {
  guard let runtime else { return .disconnected }
  switch runtime.status {
  case "preparing", "starting", "queued": return .connecting
  case "running", "waiting": return .running
  default: return .ready
  }
}

/// `isLatestRunSettled`.
private func isLatestRunSettled(_ latestRun: RunSummary?, _ runtime: RuntimeSummary?) -> Bool {
  guard let latestRun else { return false }
  if ["preparing", "queued", "starting", "running", "waiting"].contains(latestRun.status) { return false }
  return runtime?.activeRunId != latestRun.runId
}

// MARK: - Checkpoints and plans (threadCheckpoints.ts, session-logic.ts)

/// `deriveThreadCheckpointSummaries`, in the diff panel's turn-summary shape (`turnId` is the run).
public func deriveCheckpointSummaries(_ projection: OrchestrationV2ThreadProjection) -> [V1.OrchestrationCheckpointSummary] {
  projection.checkpoints.compactMap { checkpoint in
    guard let ordinal = checkpoint.appRunOrdinal, let runId = checkpoint.runId else { return nil }
    let assistant = projection.messages.last { $0.runId == runId && $0.role.rawValue == "assistant" }?.id
    return V1.OrchestrationCheckpointSummary(
      turnId: V1.TurnId(rawValue: runId.rawValue), checkpointTurnCount: ordinal, checkpointRef: checkpoint.ref,
      status: V1.OrchestrationCheckpointStatus(rawValue: checkpoint.status.rawValue),
      files: checkpoint.files.map { V1.OrchestrationCheckpointFile(path: $0.path, kind: $0.kind, additions: $0.additions, deletions: $0.deletions) },
      assistantMessageId: assistant, completedAt: checkpoint.capturedAt)
  }
}

private func planItemTime(_ projection: OrchestrationV2ThreadProjection, _ planId: PlanId) -> String {
  for item in projection.turnItems.reversed() {
    switch item {
    case .proposedPlan(let value) where value.planId == planId: return value.updatedAt.rawValue
    case .todoList(let value) where value.planId == planId: return value.updatedAt.rawValue
    default: continue
    }
  }
  return projection.updatedAt.rawValue
}

func deriveActivePlanStateV2(_ projection: OrchestrationV2ThreadProjection, latestRunId: String?) -> ActivePlanState? {
  let plans = projection.plans.compactMap { plan -> OrchestrationV2PlanArtifactTodoList? in
    if case .todoList(let value) = plan { return value }
    return nil
  }
  let plan = plans.last { latestRunId != nil && $0.runId?.rawValue == latestRunId } ?? plans.last
  guard let plan, !plan.steps.isEmpty else { return nil }
  return ActivePlanState(
    createdAt: planItemTime(projection, plan.id), turnId: plan.runId.map { V1.TurnId(rawValue: $0.rawValue) }, explanation: .some(plan.explanation),
    steps: plan.steps.map { step in
      ActivePlanState.Step(
        durationMs: step.durationMs.map(Double.init), step: step.text,
        status: step.status.rawValue == "running" ? .inProgress : (ActivePlanState.StepStatus(rawValue: step.status.rawValue) ?? .pending))
    })
}

func findLatestProposedPlanV2(_ projection: OrchestrationV2ThreadProjection, latestRunId: String?) -> LatestProposedPlanState? {
  let plans = projection.plans.compactMap { plan -> OrchestrationV2PlanArtifactProposedPlan? in
    if case .proposedPlan(let value) = plan { return value }
    return nil
  }
  let candidates = latestRunId.map { id in plans.filter { $0.runId?.rawValue == id } } ?? plans
  let pool = candidates.isEmpty ? plans : candidates
  let sorted = pool.stableSorted { left, right in
    let time = jsLocaleCompare(planItemTime(projection, left.id), planItemTime(projection, right.id))
    return time != 0 ? time : jsLocaleCompare(left.id.rawValue, right.id.rawValue)
  }
  guard let plan = sorted.last else { return nil }
  let updatedAt = planItemTime(projection, plan.id)
  return LatestProposedPlanState(
    id: plan.id.rawValue, createdAt: updatedAt, updatedAt: updatedAt, turnId: plan.runId.map { V1.TurnId(rawValue: $0.rawValue) },
    planMarkdown: plan.markdown, implementedAt: nil, implementationThreadId: nil, status: plan.status.rawValue)
}

// MARK: - Entry point

/// Derives the web chat view's rows from a protocol-2 projection (ChatView.tsx +
/// MessagesTimeline.logic.ts). Pure; a 4000-item projection derives in tens of milliseconds.
public func deriveThreadTimeline(projection: OrchestrationV2ThreadProjection, context: TimelineContextV2 = TimelineContextV2()) -> ThreadTimelineV2 {
  let execution = deriveThreadExecution(projection)
  let phase = deriveRuntimePhase(execution.runtime)
  let isWorking = context.isWorking ?? (phase == .running || execution.runlessWorkStartedAt != nil)
  // `deriveActiveWorkStartedAt`: the runtime's own clock, else the local send.
  let started: String? = execution.runtime?.activityStartedAt.flatMap { jsDateParse($0) != nil ? $0 : nil }
  let activeStart = started ?? (execution.runtime?.activeRunId == nil ? context.sendStartedAt : nil)
  let activeTurnStartedAt = activeStart ?? execution.runlessWorkStartedAt
  let checkpoints = deriveCheckpointSummaries(projection)
  let entries = deriveTimelineEntriesV2(
    visibleTurnItems: projection.visibleTurnItems, attempts: projection.attempts, nodes: projection.nodes, plans: projection.plans)
  let latestRun = execution.activityRun.map { TimelineLatestRun(runId: $0.runId, status: $0.status, startedAt: $0.startedAt, completedAt: $0.completedAt) }
  let rows = deriveMessagesTimelineRowsV2(
    RowsInputV2(
      entries: entries, latestRun: latestRun, runningRunId: execution.runtime?.activeRunId, expandedRunIds: context.expandedRunIds,
      expandedAttemptIds: context.expandedAttemptIds, expandedWorkGroupIds: context.expandedWorkGroupIds, isWorking: isWorking,
      runlessWorkActive: execution.runlessWorkStartedAt != nil, activeTurnStartedAt: activeTurnStartedAt, turnDiffSummaries: checkpoints,
      supportsConversationRollback: context.supportsConversationRollback, worktreeSetup: context.worktreeSetup))
  let settled = isLatestRunSettled(execution.latestRun, execution.runtime)
  return ThreadTimelineV2(
    entries: entries, rows: rows, phase: phase, isWorking: isWorking, activeTurnStartedAt: activeTurnStartedAt,
    runningRunId: execution.runtime?.activeRunId, activePlan: deriveActivePlanStateV2(projection, latestRunId: execution.activityRun?.runId),
    activeProposedPlan: settled ? findLatestProposedPlanV2(projection, latestRunId: execution.latestRun?.runId) : nil,
    minimap: deriveTimelineMinimapItems(rows), checkpoints: checkpoints)
}
