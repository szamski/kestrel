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

  /// Folds ("Worked for ..."), work groups and reasoning blocks the reader opened.
  private var expandedTurnIds: Set<TurnId> = []
  private var expandedWorkGroupIds: Set<String> = []
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
      for await _ in Observations({ detail.thread }) {
        guard let self else { return }
        schedule()
      }
    }
  }

  isolated deinit { observation?.cancel() }

  func toggleTurn(_ id: TurnId) {
    if !expandedTurnIds.insert(id).inserted { expandedTurnIds.remove(id) }
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
        guard let thread = detail.thread else {
          items = []
          timeline = nil
          continue
        }
        let context = TimelineContext(expandedTurnIds: expandedTurnIds, expandedWorkGroupIds: expandedWorkGroupIds)
        let derived = await worker.derive(thread, context: context)
        let local = expandedLocal
        timeline = derived
        items = derived.rows.map { TimelineItem(row: $0, expanded: local.contains($0.id)) }
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
  func derive(_ thread: OrchestrationThread, context: TimelineContext) -> ThreadTimeline { deriver.derive(thread, context: context) }
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
        }
        out.append(TimelineItem(row: row, expanded: item.expanded))
      }
    }
    return out
  }
}
#endif
