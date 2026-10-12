import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Settings › Archived: how an archived snapshot (either protocol) becomes project groups.
@Suite struct ArchivedThreadsTests {
  let environment = EnvironmentId(rawValue: "env-1")

  private func thread(_ id: String, project: String, created: String, archived: String?) -> (id: ThreadId, projectId: ProjectId, title: String, createdAt: IsoDateTime, archivedAt: IsoDateTime?) {
    (ThreadId(rawValue: id), ProjectId(rawValue: project), "Thread \(id)", IsoDateTime(rawValue: created), archived.map { IsoDateTime(rawValue: $0) })
  }

  @Test func groupsByProjectNewestArchiveFirstAndSkipsProjectsWithoutThreads() {
    let projects = [
      (id: ProjectId(rawValue: "p1"), title: "One", workspaceRoot: "/one"),
      (id: ProjectId(rawValue: "p2"), title: "Empty", workspaceRoot: "/empty"),
      (id: ProjectId(rawValue: "p3"), title: "Three", workspaceRoot: "/three"),
    ]
    let groups = ArchivedThreads.projects(
      environmentId: environment, projects: projects,
      threads: [
        thread("a", project: "p1", created: "2026-01-01T00:00:00.000Z", archived: "2026-02-01T00:00:00.000Z"),
        thread("b", project: "p1", created: "2026-03-01T00:00:00.000Z", archived: nil),  // falls back to createdAt
        thread("c", project: "p1", created: "2026-01-05T00:00:00.000Z", archived: "2026-02-01T00:00:00.000Z"),  // ties break by id, descending
        thread("d", project: "p3", created: "2026-01-01T00:00:00.000Z", archived: "2026-01-02T00:00:00.000Z"),
        thread("x", project: "gone", created: "2026-01-01T00:00:00.000Z", archived: "2026-01-02T00:00:00.000Z"),  // project not in the snapshot
      ])
    #expect(groups.map(\.title) == ["One", "Three"])
    #expect(groups[0].threads.map(\.key.threadId.rawValue) == ["b", "c", "a"])
    #expect(groups[0].threads[0].key == ScopedThreadKey(environmentId: environment, threadId: ThreadId(rawValue: "b")))
    #expect(groups[0].id == "env-1:p1" && groups[0].workspaceRoot == "/one")
  }

  @Test func mapsAProtocol1Snapshot() throws {
    let snapshot = Data2.shell()
    let first = try #require(snapshot.threads.first)
    let groups = ArchivedThreads.projects(environmentId: environment, snapshot: snapshot)
    let group = try #require(groups.first { $0.projectId == first.projectId })
    #expect(group.threads.contains { $0.key.threadId == first.id && $0.title == first.title })
    #expect(groups.flatMap(\.threads).count == snapshot.threads.count)
  }

  @Test func mapsAProtocol2Snapshot() throws {
    let live = try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot")
    let snapshot = OrchestrationV2ArchivedShellSnapshot(
      schemaVersion: live.schemaVersion, snapshotSequence: live.snapshotSequence, projects: live.projects, threads: live.threads)
    let groups = ArchivedThreads.projects(environmentId: environment, snapshot: snapshot)
    #expect(groups.map(\.title) == live.projects.map(\.title))
    #expect(groups.first?.threads.map(\.key.threadId) == live.threads.map(\.id))
  }
}
