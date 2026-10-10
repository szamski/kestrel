import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Timeline

/// One table row: the derived timeline row plus the reader's local disclosure state, so toggling a
/// thinking block changes the item (and re-measures its height) like any other content change.
struct TimelineItem: Hashable, Identifiable {
  var row: TimelineRow
  var expanded: Bool
  var id: String { row.id }
}

/// Derives the rows of one open thread off the main actor and publishes them. Streaming deltas
/// arrive as new `ThreadDetailModel.thread` values; derivation reuses the work-log part while the
/// activity log is unchanged (`ThreadTimelineDeriver`), and bursts coalesce into the latest value.
@MainActor @Observable
final class TimelineModel {
  let detail: ThreadDetailModel
  private(set) var items: [TimelineItem] = []
  private(set) var timeline: ThreadTimeline?
  /// The checkpoints the diff panel lists as turns: the V1 thread's, or one per run of the V2 projection.
  private(set) var checkpoints: [V1.OrchestrationCheckpointSummary] = []
  /// Live stages of the thread's worktree bootstrap, fed by `subscribeWorktreeSetup`.
  var worktreeSetup: WorktreeSetupSnapshot? {
    didSet { if worktreeSetup != oldValue { schedule() } }
  }

  /// Folds ("Worked for ..."), work groups and reasoning blocks the reader opened.
  private var expandedTurnIds: Set<V1.TurnId> = []
  private var expandedWorkGroupIds: Set<String> = []
  private var expandedAttemptIds: Set<String> = []
  private var expandedLocal: Set<String> = []

  @ObservationIgnored private let worker = DeriveWorker()
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var running = false

  var key: ScopedThreadKey { detail.key }

  init(detail: ThreadDetailModel) {
    self.detail = detail
    let detail = detail
    observation = Task { [weak self] in
      // A protocol-2 thread's rows come from the projection (it also grows when older pages merge in);
      // the V1-shaped `thread` carries the shell's session, which says when background work parks the run.
      for await _ in Observations({ (detail.thread, detail.projection) }) {
        guard let self else { return }
        schedule()
      }
    }
  }

  isolated deinit { observation?.cancel() }

  func toggleTurn(_ id: V1.TurnId) {
    if !expandedTurnIds.insert(id).inserted { expandedTurnIds.remove(id) }
    schedule()
  }

  func toggleAttempt(_ id: String) {
    if !expandedAttemptIds.insert(id).inserted { expandedAttemptIds.remove(id) }
    schedule()
  }

  func toggleWorkGroup(_ id: String) {
    if !expandedWorkGroupIds.insert(id).inserted { expandedWorkGroupIds.remove(id) }
    schedule()
  }

  func toggleLocal(_ id: String) {
    if !expandedLocal.insert(id).inserted { expandedLocal.remove(id) }
    items = items.map { TimelineItem(row: $0.row, expanded: expandedLocal.contains($0.id)) }
  }

  private func schedule() {
    dirty = true
    guard !running else { return }
    running = true
    Task {
      while dirty {
        dirty = false
        let local = expandedLocal
        if let projection = detail.projection {
          // A shell session at idle while the projection still runs is background work parking the run.
          let parked = detail.thread?.session?.status == .idle
          let context = TimelineContextV2(
            isWorking: parked ? false : nil, expandedRunIds: Set(expandedTurnIds.map(\.rawValue)), expandedAttemptIds: expandedAttemptIds,
            expandedWorkGroupIds: expandedWorkGroupIds, worktreeSetup: worktreeSetup)
          let derived = await worker.derive(projection, context: context)
          timeline = nil
          checkpoints = derived.checkpoints
          items = derived.rows.map { TimelineItem(row: $0, expanded: local.contains($0.id)) }
        } else if let thread = detail.thread {
          let context = TimelineContext(expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds, worktreeSetup: worktreeSetup)
          let derived = await worker.derive(thread, context: context)
          timeline = derived
          checkpoints = thread.checkpoints
          items = derived.rows.map { TimelineItem(row: $0, expanded: local.contains($0.id)) }
        } else {
          items = []
          timeline = nil
          checkpoints = []
          continue
        }
        #if DEBUG
        if Self.debugRepeat > 1 { items = Self.repeated(items, Self.debugRepeat) }
        #endif
      }
      running = false
    }
  }
}

private actor DeriveWorker {
  private var deriver = ThreadTimelineDeriver()
  func derive(_ thread: V1.OrchestrationThread, context: TimelineContext) -> ThreadTimeline { deriver.derive(thread, context: context) }
  func derive(_ projection: OrchestrationV2ThreadProjection, context: TimelineContextV2) -> ThreadTimelineV2 {
    deriveThreadTimeline(projection: projection, context: context)
  }
}

#if DEBUG
extension TimelineModel {
  /// Stress input for scroll measurements: the thread's rows repeated with unique ids.
  nonisolated(unsafe) static var debugRepeat = UserDefaults.standard.integer(forKey: "T3BenchRepeat")

  static func repeated(_ items: [TimelineItem], _ times: Int) -> [TimelineItem] {
    var out: [TimelineItem] = []
    for copy in 0..<times {
      let suffix = "#\(copy)"
      for item in items {
        var row = item.row
        switch row {
        case .activityGroup(var r): r.id += suffix; row = .activityGroup(r)
        case .work(var r): r.id += suffix; row = .work(r)
        case .workLive(var r): r.id += suffix; row = .workLive(r)
        case .workToggle(var r): r.id += suffix; row = .workToggle(r)
        case .turnFold(var r): r.id += suffix; row = .turnFold(r)
        case .contextCompaction(var r): r.id += suffix; row = .contextCompaction(r)
        case .message(var r): r.id += suffix; row = .message(r)
        case .assistantMeta(var r): r.id += suffix; row = .assistantMeta(r)
        case .proposedPlan(var r): r.id += suffix; row = .proposedPlan(r)
        case .working(var r): r.id += suffix; row = .working(r)
        case .thinking(var r): r.id += suffix; row = .thinking(r)
        case .worktreeSetup(var r): r.id += suffix; row = .worktreeSetup(r)
        case .queuedMessage(var r): r.id += suffix; row = .queuedMessage(r)
        case .attemptFold(var r): r.id += suffix; row = .attemptFold(r)
        case .event(var r): r.id += suffix; row = .event(r)
        case .htmlRender(var r): r.id += suffix; row = .htmlRender(r)
        case .mcpApp(var r): r.id += suffix; row = .mcpApp(r)
        }
        out.append(TimelineItem(row: row, expanded: item.expanded))
      }
    }
    return out
  }
}
#endif
