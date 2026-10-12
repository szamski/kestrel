import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct ThreadNotificationTests {
  static let env = EnvironmentId(rawValue: "env-1")

  /// The fixture's thread, reset to a thread that finished its run.
  static func thread(_ edit: (inout OrchestrationV2ThreadShell) -> Void = { _ in }) throws -> OrchestrationV2ThreadShell {
    var thread = try WireFixture.decode(OrchestrationV2ShellSnapshot.self, "v2-shell-snapshot").threads[0]
    thread.pendingRuntimeRequest = nil
    thread.pendingBackgroundTasks = []
    thread.activityRunStatus = .some(nil)
    thread.lastErrorClass = .some(nil)
    thread.archivedAt = nil
    thread.status = .completed
    thread.latestRunCompletedAt = .some(IsoDateTime(rawValue: "2026-08-07T12:00:00.000Z"))
    edit(&thread)
    return thread
  }

  /// Seeds the tracker with `before`, then returns what `after` announces.
  static func transition(from before: OrchestrationV2ThreadShell, to after: OrchestrationV2ThreadShell) -> [ThreadNotificationEvent] {
    var tracker = ThreadNotificationTracker()
    _ = tracker.scan(environmentId: env, threads: [before])
    return tracker.scan(environmentId: env, threads: [after])
  }

  @Test func aTurnThatCompletesNotifiesOnce() throws {
    let running = try Self.thread { $0.status = .running; $0.activityRunStatus = .some(.running); $0.latestRunCompletedAt = .some(nil) }
    let done = try Self.thread { $0.latestRunCompletedAt = .some(IsoDateTime(rawValue: "2026-08-07T12:05:00.000Z")) }
    let events = Self.transition(from: running, to: done)
    #expect(events.map(\.kind) == [.completion])
    #expect(events.first?.threadTitle == done.title)
    var tracker = ThreadNotificationTracker()
    _ = tracker.scan(environmentId: Self.env, threads: [running])
    _ = tracker.scan(environmentId: Self.env, threads: [done])
    #expect(tracker.scan(environmentId: Self.env, threads: [done]).isEmpty)
  }

  @Test func approvalInputAndFailureNotifyWhenTheyAppear() throws {
    let idle = try Self.thread()
    #expect(Self.transition(from: idle, to: try Self.thread { $0.pendingRuntimeRequest = .init(id: "r1", kind: .command, createdAt: $0.updatedAt) }).map(\.kind) == [.approval])
    #expect(Self.transition(from: idle, to: try Self.thread { $0.pendingRuntimeRequest = .init(id: "r2", kind: .user_input, createdAt: $0.updatedAt) }).map(\.kind) == [.input])
    #expect(Self.transition(from: idle, to: try Self.thread { $0.status = .failed }).map(\.kind) == [.failed])
    let limited = try Self.thread { $0.status = .failed; $0.lastErrorClass = .some(.usage_limit) }
    #expect(Self.transition(from: idle, to: limited).map(\.kind) == [.limited])
  }

  @Test func firstSightingsSubagentsAndArchivedThreadsStayQuiet() throws {
    var tracker = ThreadNotificationTracker()
    #expect(tracker.scan(environmentId: Self.env, threads: [try Self.thread { $0.status = .failed }]).isEmpty)  // first sync
    let running = try Self.thread { $0.status = .running; $0.activityRunStatus = .some(.running); $0.latestRunCompletedAt = .some(nil) }
    let sub = try Self.thread { $0.lineage.relationshipToParent = .subagent; $0.status = .failed }
    #expect(Self.transition(from: running, to: sub).isEmpty)
    let archived = try Self.thread { $0.archivedAt = $0.updatedAt; $0.status = .failed }
    #expect(Self.transition(from: running, to: archived).isEmpty)
  }

  @Test func workStillHeldByBackgroundTasksIsNotACompletion() throws {
    let running = try Self.thread { $0.status = .running; $0.activityRunStatus = .some(.running); $0.latestRunCompletedAt = .some(nil) }
    let monitoring = try Self.thread {
      $0.latestRunCompletedAt = .some(IsoDateTime(rawValue: "2026-08-07T12:05:00.000Z"))
      $0.pendingBackgroundTasks = [.unknown(.string("monitor"))]  // a kind this build does not know holds the completion
    }
    #expect(ThreadNotificationTracker.status(of: monitoring) == .waiting)
    #expect(Self.transition(from: running, to: monitoring).isEmpty)
  }

  @Test func anOfflineEnvironmentForgetsItsThreads() throws {
    let running = try Self.thread { $0.status = .running; $0.activityRunStatus = .some(.running); $0.latestRunCompletedAt = .some(nil) }
    var tracker = ThreadNotificationTracker()
    _ = tracker.scan(environmentId: Self.env, threads: [running])
    _ = tracker.scan(environmentId: Self.env, threads: nil)
    #expect(tracker.scan(environmentId: Self.env, threads: [try Self.thread()]).isEmpty)
  }

  @Test func deliveryFollowsModeFocusAndTheOpenThread() {
    typealias D = ThreadNotificationDelivery
    #expect(D.decide(mode: .off, inApp: false, appFocused: false, isOpenThread: false) == D(sound: false, surface: .none))
    #expect(D.decide(mode: .notifications, inApp: false, appFocused: false, isOpenThread: false) == D(sound: false, surface: .system))
    #expect(D.decide(mode: .notificationsAndSound, inApp: true, appFocused: false, isOpenThread: false) == D(sound: true, surface: .system))
    #expect(D.decide(mode: .sound, inApp: true, appFocused: true, isOpenThread: false) == D(sound: true, surface: .banner))
    #expect(D.decide(mode: .notifications, inApp: true, appFocused: true, isOpenThread: true) == D(sound: false, surface: .none))
    #expect(D.decide(mode: .off, inApp: true, appFocused: true, isOpenThread: false) == D(sound: false, surface: .banner))
  }
}

@Suite struct AppRouteTests {
  @Test func threadLinksCarryEnvironmentAndThread() {
    #expect(AppRouteParser.parse("kestrel://threads/env-1/thread-2") == .thread(environmentId: "env-1", threadId: "thread-2"))
    #expect(AppRouteParser.parse("kestrel://thread?environment=env-1&thread=thread-2") == .thread(environmentId: "env-1", threadId: "thread-2"))
    #expect(AppRouteParser.parse("https://app.t3.codes/env-1/thread-2") == .thread(environmentId: "env-1", threadId: "thread-2"))
    #expect(AppRouteParser.parse("t3-thread://v1/thread-2") == .thread(environmentId: nil, threadId: "thread-2"))
    #expect(AppRouteParser.parse("t3-thread://v1/env%201/thread-2") == .thread(environmentId: "env 1", threadId: "thread-2"))
    #expect(AppRouteParser.parse("kestrel://projects/env-1/project-9") == .project(environmentId: "env-1", projectId: "project-9"))
  }

  @Test func notificationLinksRoundTripAwkwardIds() throws {
    let route = AppRoute.thread(environmentId: "env/1 a", threadId: "t#2?")
    let url = try #require(AppRouteParser.url(for: route))
    #expect(AppRouteParser.parse(url) == route)
  }

  @Test func pairingLinksNeedAWebURL() {
    #expect(AppRouteParser.parse("https://t3.codes/pair#token=abc") == .pairing(url: "https://t3.codes/pair#token=abc"))
    #expect(AppRouteParser.parse("kestrel://pair?pairingUrl=https%3A%2F%2Fhost%3A3773%2Fpair%23token%3Dabc") == .pairing(url: "https://host:3773/pair#token=abc"))
    #expect(AppRouteParser.parse("kestrel://pair?pairingUrl=file%3A%2F%2F%2Fetc%2Fpasswd") == nil)
  }

  @Test func foreignHostsAndMalformedIdsAreRejected() {
    #expect(AppRouteParser.parse("https://evil.example/env-1/thread-2") == nil)
    #expect(AppRouteParser.parse("mailto:a@b.c") == nil)
    #expect(AppRouteParser.parse("kestrel://threads/env-1/..") == nil)
    #expect(AppRouteParser.parse("kestrel://threads") == nil)
    #expect(AppRouteParser.parse("kestrel://threads/env-1/a%00b") == nil)
    #expect(AppRouteParser.parse("t3-thread://v1/a/b/c") == nil)
  }
}

@Suite struct OnboardingLogicTests {
  typealias Input = FirstRunLogic.Input
  static func input(_ edit: (inout Input) -> Void = { _ in }) -> Input {
    var input = Input(completed: false, environmentCount: 1, localServerPending: false, shellsLive: true, workspaceFresh: true, projectCount: 0, threadCount: 0)
    edit(&input)
    return input
  }

  @Test func theGateWaitsForEvidenceThenOpensTheWizardOnlyForAFreshWorkspace() {
    #expect(FirstRunLogic.decide(Self.input { $0.completed = true }).decision == .app)
    #expect(FirstRunLogic.decide(Self.input { $0.environmentCount = 0; $0.localServerPending = true }).decision == .pending)
    #expect(FirstRunLogic.decide(Self.input { $0.environmentCount = 0 }).decision == .wizard)
    #expect(FirstRunLogic.decide(Self.input { $0.shellsLive = false }).decision == .pending)
    #expect(FirstRunLogic.decide(Self.input()).decision == .wizard)
    let used = FirstRunLogic.decide(Self.input { $0.workspaceFresh = false; $0.projectCount = 3 })
    #expect(used.decision == .app && used.persistCompletion)
    let several = FirstRunLogic.decide(Self.input { $0.projectCount = 2 })
    #expect(several.decision == .app && several.persistCompletion)
  }

  @Test func onlyTheServersOwnUntouchedBootstrapCountsAsFresh() throws {
    let thread = try ThreadNotificationTests.thread { $0.latestRunId = nil; $0.activeProviderThreadId = nil; $0.latestUserMessageAt = nil }
    #expect(FirstRunLogic.isFreshWorkspace(projectRoots: [], threads: [], serverCwd: "/Users/me"))
    #expect(FirstRunLogic.isFreshWorkspace(projectRoots: ["/Users/me/"], threads: [thread], serverCwd: "/Users/me"))
    #expect(!FirstRunLogic.isFreshWorkspace(projectRoots: ["/Users/me/code"], threads: [], serverCwd: "/Users/me"))
    #expect(!FirstRunLogic.isFreshWorkspace(projectRoots: [], threads: [thread], serverCwd: "/Users/me"))
    let used = try ThreadNotificationTests.thread()
    #expect(!FirstRunLogic.isFreshWorkspace(projectRoots: ["/Users/me"], threads: [used], serverCwd: "/Users/me"))
  }

  static func candidate(_ path: String, threads: Int, active: String?, git: AgentSessionProjectGit??, env: String = "env-1") -> ImportCandidate {
    ImportCandidate(
      environmentId: EnvironmentId(rawValue: env),
      candidate: AgentSessionProjectCandidate(
        path: path, title: (path as NSString).lastPathComponent, sources: [], threadCount: threads, lastActiveAt: active.map { IsoDateTime(rawValue: $0) },
        alreadyImported: false, git: git))
  }

  @Test func theDefaultSelectionIsRecentRepositoriesWithRealWork() {
    let now = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
    let repo = AgentSessionProjectGit(remoteKey: "github.com/a/b", repository: "a/b")
    let items = [
      Self.candidate("/p/busy", threads: 5, active: "2026-10-10T00:00:00.000Z", git: .some(repo)),
      Self.candidate("/p/old", threads: 9, active: "2026-08-01T00:00:00.000Z", git: .some(repo)),
      Self.candidate("/p/oneoff", threads: 2, active: "2026-10-10T00:00:00.000Z", git: .some(repo)),
      Self.candidate("/p/folder", threads: 9, active: "2026-10-10T00:00:00.000Z", git: .some(nil)),
      Self.candidate("/p/legacy", threads: 4, active: "2026-10-11T00:00:00.000Z", git: nil),
    ]
    let selected = ProjectImportLogic.defaultSelection(items, now: now)
    #expect(selected == Set([items[0].id, items[4].id]))
  }

  @Test func clonesShareAGroupAndNonRepositoriesFoldAway() {
    let repo = AgentSessionProjectGit(remoteKey: "github.com/a/b", repository: "a/b")
    let items = [
      Self.candidate("/p/b", threads: 2, active: "2026-10-01T00:00:00.000Z", git: .some(repo)),
      Self.candidate("/q/b", threads: 3, active: "2026-10-05T00:00:00.000Z", git: .some(repo), env: "env-2"),
      Self.candidate("/p/z", threads: 1, active: "2026-10-09T00:00:00.000Z", git: .some(AgentSessionProjectGit(remoteKey: nil, repository: nil))),
      Self.candidate("/p/notes", threads: 7, active: nil, git: .some(nil)),
    ]
    let (repositories, other) = ProjectImportLogic.group(items)
    #expect(repositories.map(\.label) == ["z", "a/b"])
    #expect(repositories[1].threadCount == 5 && repositories[1].candidates.count == 2)
    #expect(repositories[1].lastActiveAt?.rawValue == "2026-10-05T00:00:00.000Z")
    #expect(other.map(\.candidate.path) == ["/p/notes"])
  }

  @Test func importWarningsSayWhatDidNotLand() {
    #expect(ProjectImportLogic.warning(completedProjects: 2, selectedProjects: 2, importedThreads: 9, skippedThreads: 0) == nil)
    #expect(ProjectImportLogic.warning(completedProjects: 1, selectedProjects: 2, importedThreads: 1, skippedThreads: 2) == "Imported 1 thread. 2 threads could not be imported.")
    #expect(ProjectImportLogic.warning(completedProjects: 0, selectedProjects: 1, importedThreads: 0, skippedThreads: 0) == "Could not import thread history.")
  }

  @Test func providerReadinessPicksTheBestInstanceAndTheRightCommand() throws {
    #expect(ProviderReadiness.of(nil) == .checking)
    #expect(ProviderReadiness.installCommand(driver: "codex", windows: false)?.hasPrefix("curl") == true)
    #expect(ProviderReadiness.installCommand(driver: "claudeAgent", windows: true)?.hasPrefix("irm") == true)
    #expect(ProviderReadiness.loginCommand(driver: "claudeAgent") == "claude auth login")
    #expect(ProviderReadiness.installCommand(driver: "opencode", windows: false) == nil)
  }
}
