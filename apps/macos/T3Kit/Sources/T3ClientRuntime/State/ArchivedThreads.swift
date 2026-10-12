import Foundation
import T3Contracts
import T3Protocol

/// An archived thread as Settings › Archived lists it: archived threads are not part of the live shell, so they are
/// loaded on demand with `orchestration.getArchivedShellSnapshot` (both protocols answer it).
public struct ArchivedThread: Sendable, Hashable, Identifiable {
  public let key: ScopedThreadKey
  public let title: String
  public let createdAt: IsoDateTime
  public let archivedAt: IsoDateTime?
  public var id: String { key.description }

  public init(key: ScopedThreadKey, title: String, createdAt: IsoDateTime, archivedAt: IsoDateTime?) {
    self.key = key
    self.title = title
    self.createdAt = createdAt
    self.archivedAt = archivedAt
  }
}

/// A project with at least one archived thread, newest archive first.
public struct ArchivedProject: Sendable, Hashable, Identifiable {
  public let environmentId: EnvironmentId
  public let projectId: ProjectId
  public let title: String
  public let workspaceRoot: String
  public let threads: [ArchivedThread]
  public var id: String { "\(environmentId.rawValue):\(projectId.rawValue)" }
}

public enum ArchivedThreads {
  /// Groups a snapshot's threads by project (web `ArchivedThreadsPanel`): projects keep the snapshot's order, those
  /// without archived threads are left out, threads sort by `archivedAt ?? createdAt` and then id, both descending.
  public static func projects(
    environmentId: EnvironmentId, projects: [(id: ProjectId, title: String, workspaceRoot: String)],
    threads: [(id: ThreadId, projectId: ProjectId, title: String, createdAt: IsoDateTime, archivedAt: IsoDateTime?)]
  ) -> [ArchivedProject] {
    projects.compactMap { project in
      let rows = threads.filter { $0.projectId == project.id }.map {
        ArchivedThread(key: ScopedThreadKey(environmentId: environmentId, threadId: $0.id), title: $0.title, createdAt: $0.createdAt, archivedAt: $0.archivedAt)
      }
      guard !rows.isEmpty else { return nil }
      let sorted = rows.sorted {
        let (left, right) = (($0.archivedAt ?? $0.createdAt).rawValue, ($1.archivedAt ?? $1.createdAt).rawValue)
        return left != right ? left > right : $0.key.threadId.rawValue > $1.key.threadId.rawValue
      }
      return ArchivedProject(environmentId: environmentId, projectId: project.id, title: project.title, workspaceRoot: project.workspaceRoot, threads: sorted)
    }
  }

  public static func projects(environmentId: EnvironmentId, snapshot: V1.OrchestrationShellSnapshot) -> [ArchivedProject] {
    projects(
      environmentId: environmentId, projects: snapshot.projects.map { ($0.id, $0.title, $0.workspaceRoot) },
      threads: snapshot.threads.map { ($0.id, $0.projectId, $0.title, $0.createdAt, $0.archivedAt) })
  }

  public static func projects(environmentId: EnvironmentId, snapshot: OrchestrationV2ArchivedShellSnapshot) -> [ArchivedProject] {
    projects(
      environmentId: environmentId, projects: snapshot.projects.map { ($0.id, $0.title, $0.workspaceRoot) },
      threads: snapshot.threads.map { ($0.id, $0.projectId, $0.title, $0.createdAt, $0.archivedAt) })
  }
}

extension ClientRuntime {
  /// The archived threads of one environment, grouped by project. Throws `.notConnected` while it is offline.
  /// Unarchiving and deleting go through `unarchiveThread` / `deleteThread`; reload afterwards.
  public func archivedProjects(environmentId: EnvironmentId) async throws(CommandError) -> [ArchivedProject] {
    guard let session = await registry.runtime(for: environmentId)?.supervisor.session.value else {
      throw .notConnected(environment: environmentId.rawValue)
    }
    do {
      if session.orchestrationProtocol == .v2 {
        return ArchivedThreads.projects(environmentId: environmentId, snapshot: try await session.call(Rpc.orchestrationGetArchivedShellSnapshot, EmptyObject()))
      }
      return ArchivedThreads.projects(environmentId: environmentId, snapshot: try await session.call(V1.Rpc.orchestrationGetArchivedShellSnapshot, EmptyObject()))
    } catch {
      throw .transport(message: "Failed to load archived threads.")
    }
  }
}
