import Foundation
import T3Contracts

/// Port of `state/shellReducer.ts` (protocol 2): deltas upsert whole objects and never move the cursor
/// backwards; archived threads are not part of the live shell.
public enum ShellReducerV2 {
  static func sequence(_ item: OrchestrationV2ShellStreamItem) -> Int? {
    switch item {
    case .projectUpdated(let e): e.sequence
    case .projectRemoved(let e): e.sequence
    case .threadUpdated(let e): e.sequence
    case .threadRemoved(let e): e.sequence
    default: nil
    }
  }

  private static func upsert<T, ID: Equatable>(_ items: inout [T], _ item: T, id: KeyPath<T, ID>) {
    if let index = items.firstIndex(where: { $0[keyPath: id] == item[keyPath: id] }) { items[index] = item } else { items.append(item) }
  }

  /// Enrichment is async: a project mutation can land with a null repository identity while an earlier
  /// snapshot already resolved it. Keep the prior identity for the same workspace root so grouping across
  /// environments does not split until a full snapshot refresh arrives.
  static func retainRepositoryIdentity(_ previous: OrchestrationProjectShell?, _ next: OrchestrationProjectShell) -> OrchestrationProjectShell {
    guard optionalValue(next.repositoryIdentity) == nil, let previous, let identity = optionalValue(previous.repositoryIdentity),
      previous.workspaceRoot == next.workspaceRoot
    else { return next }
    var project = next
    project.repositoryIdentity = .some(identity)
    return project
  }

  /// Merges an incoming full snapshot into prior client state. Authoritative snapshots replace structure and
  /// sequence (even when lower than the cache) while keeping a prior non-null identity the candidate has not
  /// resolved yet. Enrichment snapshots (`resolvedRoots` present) only patch repository identity.
  public static func mergeSnapshot(
    previous: OrchestrationV2ShellSnapshot?, _ next: OrchestrationV2ShellSnapshot, resolvedRoots: [String]?
  ) -> OrchestrationV2ShellSnapshot {
    guard let previous else { return next }
    let resolved = resolvedRoots.map(Set.init)
    if let resolved {
      var merged = previous
      let nextById = Dictionary(next.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      merged.projects = previous.projects.map { project in
        guard let candidate = nextById[project.id], candidate.workspaceRoot == project.workspaceRoot else { return project }
        var patched = project
        if resolved.contains(project.workspaceRoot) {
          patched.repositoryIdentity = candidate.repositoryIdentity
        } else if optionalValue(project.repositoryIdentity) == nil, optionalValue(candidate.repositoryIdentity) != nil {
          patched.repositoryIdentity = candidate.repositoryIdentity
        }
        return patched
      }
      return merged
    }
    let previousById = Dictionary(previous.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    var merged = next
    merged.projects = next.projects.map { retainRepositoryIdentity(previousById[$0.id], $0) }
    return merged
  }

  /// Applies one committed shell delta. Stale deltas (sequence <= cursor) change nothing.
  public static func apply(_ snapshot: OrchestrationV2ShellSnapshot, _ item: OrchestrationV2ShellStreamItem) -> OrchestrationV2ShellSnapshot {
    guard let sequence = sequence(item), sequence > snapshot.snapshotSequence else { return snapshot }
    var next = snapshot
    next.snapshotSequence = sequence
    switch item {
    case .projectUpdated(let e):
      upsert(&next.projects, retainRepositoryIdentity(snapshot.projects.first { $0.id == e.project.id }, e.project), id: \.id)
    case .projectRemoved(let e):
      next.projects.removeAll { $0.id == e.projectId }
    case .threadUpdated(let e):
      // An unchanged shell only moves the cursor.
      if e.location == .active, let existing = snapshot.threads.first(where: { $0.id == e.thread.id }), existing == e.thread { return next }
      if e.location == .active { upsert(&next.threads, e.thread, id: \.id) } else { next.threads.removeAll { $0.id == e.thread.id } }
      // The archive has its own bounded query; deltas never grow the live shell's archive again.
      next.archivedThreads.removeAll { $0.id == e.thread.id }
    case .threadRemoved(let e):
      next.threads.removeAll { $0.id == e.threadId }
      next.archivedThreads.removeAll { $0.id == e.threadId }
    default:
      return snapshot
    }
    return next
  }

  /// The presented (sidebar-shaped) snapshot after the same delta, touching only the rows it changed.
  static func presenting(
    _ presented: V1.OrchestrationShellSnapshot, _ item: OrchestrationV2ShellStreamItem, reduced: OrchestrationV2ShellSnapshot
  ) -> V1.OrchestrationShellSnapshot {
    var next = presented
    next.snapshotSequence = reduced.snapshotSequence
    switch item {
    case .projectUpdated(let e):
      guard let project = reduced.projects.first(where: { $0.id == e.project.id }) else { break }
      upsert(&next.projects, ShellPresentation.project(project), id: \.id)
    case .projectRemoved(let e):
      next.projects.removeAll { $0.id == e.projectId }
    case .threadUpdated(let e):
      if e.location == .active {
        let thread = ShellPresentation.thread(e.thread)
        if next.threads.first(where: { $0.id == thread.id }) != thread { upsert(&next.threads, thread, id: \.id) }
        if thread.updatedAt.rawValue > next.updatedAt.rawValue { next.updatedAt = thread.updatedAt }
      } else {
        next.threads.removeAll { $0.id == e.thread.id }
      }
    case .threadRemoved(let e):
      next.threads.removeAll { $0.id == e.threadId }
    default:
      break
    }
    return next
  }
}
