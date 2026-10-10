import Foundation
import T3Contracts

/// Presents a protocol-2 shell record in the shape every sidebar derivation, optimistic update and
/// project grouping already reads (`V1.OrchestrationThreadShell`). Port of `presentThreadShell`
/// (client-runtime `state/models.ts`): the run becomes the latest turn, the activity status becomes
/// the session, and a pending runtime request becomes the approval / user-input flags.
///
/// This is the one place the two protocols meet for the sidebar: derivations stay single-sourced,
/// and anything V2 adds (queue, goal, visited watermark, ...) is read from the V2 record itself
/// (`EnvironmentShellState.v2`).
public enum ShellPresentation {
  /// Work that wakes the agent (subagents, monitors, background tasks) holds a run's completion;
  /// a dev server does not. Kinds this build does not know hold, the conservative choice.
  public static func backgroundWorkHoldsCompletion(_ tasks: [OrchestrationV2PendingBackgroundTask]) -> Bool {
    tasks.contains { task in
      if case .orchestrationV2ThreadShellPendingBackgroundTasksItemOption2 = task { return false }
      return true
    }
  }

  static func isTerminal(_ status: OrchestrationV2ShellThreadStatus) -> Bool {
    switch status {
    case .completed, .interrupted, .failed, .cancelled, .rolled_back: true
    default: false
    }
  }

  /// Whether a run is queued, preparing or starting (work the server accepted but has not begun).
  public static func isPending(_ status: OrchestrationV2ShellThreadStatus) -> Bool {
    switch status {
    case .preparing, .queued, .starting: true
    default: false
    }
  }

  private static func turnState(_ status: OrchestrationV2ShellThreadStatus) -> V1.OrchestrationLatestTurnState {
    switch status {
    case .idle, .completed: .completed
    case .interrupted, .cancelled, .rolled_back: .interrupted
    case .failed: .error
    default: .running
    }
  }

  private static func sessionStatus(_ status: OrchestrationV2ShellThreadStatus) -> V1.OrchestrationSessionStatus {
    switch status {
    case .idle: .idle
    case .preparing, .queued, .starting: .starting
    case .running, .waiting: .running
    case .completed, .rolled_back: .ready
    case .interrupted: .interrupted
    case .cancelled: .stopped
    case .failed: .error
    case .unknown(let raw): .unknown(raw)
    }
  }

  private static func status(_ activity: OrchestrationV2ThreadShellActivityRunStatus) -> OrchestrationV2ShellThreadStatus {
    OrchestrationV2ShellThreadStatus(rawValue: activity.rawValue)
  }

  private static func latestTurn(_ thread: OrchestrationV2ThreadShell) -> V1.OrchestrationLatestTurn? {
    guard let runId = thread.latestRunId else { return nil }
    let status = thread.status == .idle ? OrchestrationV2ShellThreadStatus.completed : thread.status
    // `completedAt` absent (an older server) falls back to the shell's own stamp once the run is over.
    let completedAt: IsoDateTime?
    switch thread.latestRunCompletedAt {
    case .none: completedAt = (thread.status == .idle || isTerminal(thread.status)) ? thread.updatedAt : nil
    case .some(let value): completedAt = value
    }
    return V1.OrchestrationLatestTurn(
      turnId: V1.TurnId(rawValue: runId.rawValue), state: turnState(status),
      requestedAt: optionalValue(thread.latestRunRequestedAt) ?? thread.createdAt,
      startedAt: optionalValue(thread.latestRunStartedAt), completedAt: completedAt)
  }

  private static func session(_ thread: OrchestrationV2ThreadShell, parkAtIdle: Bool) -> V1.OrchestrationSession? {
    // A pull request watch can hold a thread that never ran.
    if thread.latestRunId == nil, thread.activeProviderThreadId == nil, !parkAtIdle { return nil }
    let current = parkAtIdle ? OrchestrationV2ShellThreadStatus.idle : (optionalValue(thread.activityRunStatus).map(status) ?? thread.status)
    return V1.OrchestrationSession(
      threadId: thread.id, status: sessionStatus(current), providerInstanceId: thread.providerInstanceId,
      runtimeMode: V1.OrchestrationSessionRuntimeMode(rawValue: thread.runtimeMode.rawValue),
      activeTurnId: thread.activeRunId.map { V1.TurnId(rawValue: $0.rawValue) }, lastError: optionalValue(thread.lastError),
      updatedAt: thread.updatedAt)
  }

  public static func thread(_ thread: OrchestrationV2ThreadShell) -> V1.OrchestrationThreadShell {
    let request = thread.pendingRuntimeRequest
    let parkAtIdle = backgroundWorkHoldsCompletion(thread.pendingBackgroundTasks) && thread.status != .failed
    var shell = V1.OrchestrationThreadShell(
      id: thread.id, projectId: thread.projectId, title: thread.title, modelSelection: thread.modelSelection,
      runtimeMode: thread.runtimeMode, interactionMode: thread.interactionMode, branch: thread.branch, worktreePath: thread.worktreePath,
      linkedPullRequest: thread.linkedPullRequest, branchPullRequest: thread.branchPullRequest,
      latestTurn: latestTurn(thread), createdAt: thread.createdAt, updatedAt: thread.updatedAt, archivedAt: thread.archivedAt,
      settledOverride: thread.settledOverride, settledAt: thread.settledAt, unsettledAt: thread.unsettledAt,
      snoozedUntil: thread.snoozedUntil, snoozedAt: thread.snoozedAt, pinnedAt: thread.pinnedAt, pinOrderKey: thread.pinOrderKey,
      activeOrderKey: thread.activeOrderKey, autoSettleDisabledAt: thread.autoSettleDisabledAt,
      titleRegeneration: thread.titleRegeneration.map {
        $0.map { V1.ThreadTitleRegeneration(requestId: $0.requestId, startedAt: $0.startedAt) }
      },
      session: session(thread, parkAtIdle: parkAtIdle), latestUserMessageAt: thread.latestUserMessageAt,
      hasPendingApprovals: request.map { $0.kind != .user_input && $0.kind != .auth_refresh } ?? false,
      hasPendingUserInput: request?.kind == .user_input, hasActionableProposedPlan: thread.hasActionableProposedPlan,
      backgroundLiveness: parkAtIdle ? .some(.monitoring) : nil)
    if let links = thread.pullRequests, !links.isEmpty { shell.pullRequests = bridge(links) ?? [] }
    return shell
  }

  public static func project(_ project: OrchestrationProjectShell) -> V1.OrchestrationProjectShell {
    // The two shells differ in one nested enum (`ReceivedProjectIcon`); a project list is small.
    if let bridged: V1.OrchestrationProjectShell = bridge(project) { return bridged }
    return V1.OrchestrationProjectShell(
      id: project.id, title: project.title, workspaceRoot: project.workspaceRoot, scripts: [], createdAt: project.createdAt,
      updatedAt: project.updatedAt)
  }

  /// Re-reads a value through its wire form where the generator declared structurally identical types twice.
  static func bridge<Source: Encodable, Target: Decodable>(_ value: Source) -> Target? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(Target.self, from: data)
  }

  public static func snapshot(_ snapshot: OrchestrationV2ShellSnapshot) -> V1.OrchestrationShellSnapshot {
    V1.OrchestrationShellSnapshot(
      snapshotSequence: snapshot.snapshotSequence, projects: snapshot.projects.map(project), threads: snapshot.threads.map(thread),
      updatedAt: snapshot.threads.map(\.updatedAt).max { $0.rawValue < $1.rawValue } ?? IsoDateTime(rawValue: "1970-01-01T00:00:00.000Z"))
  }
}
