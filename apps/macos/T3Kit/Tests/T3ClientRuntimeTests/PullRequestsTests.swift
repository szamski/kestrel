import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct PullRequestsLinkingTests {
  @Test func parsesTheHostsItCanRead() {
    #expect(ChangeRequestURL.parse("https://github.com/Owner/Repo/pull/42/files") == ChangeRequestLink(host: "github.com", repository: "owner/repo", number: 42))
    #expect(ChangeRequestURL.parse("https://gitlab.example.com/group/sub/repo/-/merge_requests/7")?.repository == "group/sub/repo")
    #expect(ChangeRequestURL.parse("https://bitbucket.org/ws/repo/pull-requests/3")?.number == 3)
    #expect(ChangeRequestURL.parse("https://dev.azure.com/org/proj/_git/repo/pullrequest/9")?.repository == "org/proj/_git/repo")
    // Forgejo keeps its HTTP authority; a default port is dropped like `URL.host` does.
    #expect(ChangeRequestURL.parse("http://git.local:3000/team/app/pulls/5")?.authority == "git.local:3000")
    #expect(ChangeRequestURL.parse("https://git.local:443/team/app/pulls/5")?.authority == "git.local")
    // An issue, a commit or a lookalike is not a pull request.
    #expect(ChangeRequestURL.parse("https://github.com/o/r/issues/1") == nil)
    #expect(ChangeRequestURL.parse("https://example.com/o/r/pull/1") == nil)
    #expect(ChangeRequestURL.parse("javascript:alert(1)") == nil)
  }

  @Test func referenceAcceptsUrlsNumbersAndCliCheckouts() {
    #expect(ChangeRequestURL.reference(from: " #123 ") == "123")
    #expect(ChangeRequestURL.reference(from: "gh pr checkout https://github.com/o/r/pull/9") == "https://github.com/o/r/pull/9")
    #expect(ChangeRequestURL.reference(from: "az repos pr checkout --id 17") == "17")
    #expect(ChangeRequestURL.reference(from: "https://github.com/o/r/pull/9?x=1") == "https://github.com/o/r/pull/9?x=1")
    #expect(ChangeRequestURL.reference(from: "not a reference") == nil)

    let project = LinkPullRequestProject(host: "github.com", repository: "o/r") { "https://github.com/o/r/pull/\($0)" }
    #expect(LinkPullRequestInput.resolve("7", project: project, canLink: { _ in true }) == .link(ChangeRequestLink(host: "github.com", repository: "o/r", number: 7), url: "https://github.com/o/r/pull/7"))
    #expect(LinkPullRequestInput.resolve("7", project: nil, canLink: { _ in true }) == .invalid("Paste a full URL to link a pull request from another repository."))
    #expect(LinkPullRequestInput.resolve("https://github.com/x/y/pull/1", project: project, canLink: { _ in false }) == .invalid("No project in this environment can read github.com/x/y."))
  }

  @Test func capabilityNegotiationPicksTheLinkCommand() {
    var caps = ExecutionEnvironmentCapabilities()
    #expect(ThreadPullRequestLinkMode(caps) == .unsupported)
    #expect(ThreadPullRequestLinkMode(nil) == .unsupported)
    caps.threadPullRequestLinking = true
    #expect(ThreadPullRequestLinkMode(caps) == .single)
    caps.threadPullRequests = true
    #expect(ThreadPullRequestLinkMode(caps) == .multiple)

    let link = ChangeRequestLink(host: "github.com", repository: "o/r", number: 4)
    let url = "https://github.com/o/r/pull/4"
    let key = ThreadPullRequestKey(host: "github.com", repository: "o/r", number: 4)
    #expect(ThreadPullRequestMutation.plan(mode: .multiple, link: link, url: url, legacyProjectId: nil, linked: true) == .link(key, url: url))
    #expect(ThreadPullRequestMutation.plan(mode: .multiple, link: link, url: url, legacyProjectId: nil, linked: false) == .unlink(key))
    // The single link needs the exact checkout; unlinking clears it; no multi-link command is ever planned.
    #expect(ThreadPullRequestMutation.plan(mode: .single, link: link, url: url, legacyProjectId: nil, linked: true) == nil)
    #expect(
      ThreadPullRequestMutation.plan(mode: .single, link: link, url: url, legacyProjectId: "p1", linked: true)
        == .legacy(ThreadLinkedPullRequest(projectId: "p1", repository: "o/r", number: 4, url: url)))
    #expect(ThreadPullRequestMutation.plan(mode: .single, link: link, url: url, legacyProjectId: nil, linked: false) == .legacy(nil))
    #expect(ThreadPullRequestMutation.plan(mode: .unsupported, link: link, url: url, legacyProjectId: "p1", linked: true) == nil)
  }

  @Test func linkCommandsReachProtocolTwoServers() throws {
    let meta = CommandMeta(commandId: "c1", createdAt: "2026-08-07T12:00:00.000Z")
    let link = try CommandTranslation.plan(for: ThreadCommand.linkPullRequest("t1", host: "github.com", repository: "o/r", number: 4, url: "https://github.com/o/r/pull/4", meta: meta))
    guard case .command(.threadPullRequestLink(let linked))? = link.first else { Issue.record("not translated: \(link)"); return }
    #expect(linked.threadId == "t1" && linked.number == 4 && linked.source == .manual)
    let unlink = try CommandTranslation.plan(for: ThreadCommand.unlinkPullRequest("t1", host: "github.com", repository: "o/r", number: 4, meta: meta))
    guard case .command(.threadPullRequestUnlink(let removed))? = unlink.first else { Issue.record("not translated: \(unlink)"); return }
    #expect(removed.repository == "o/r")
  }

  // MARK: Chains

  static func item(_ number: Int, head: String? = nil, base: String = "main", state: PullRequestState = .open, linkedAt: String = "2026-08-01T10:00:00.000Z", stack: ThreadPullRequestStack? = nil, source: ThreadPullRequestLinkSource = .manual)
    -> ThreadPullRequestItem
  {
    ThreadPullRequestItem(
      host: "github.com", repository: "o/r", number: number, url: "https://github.com/o/r/pull/\(number)", source: source, linkedAt: IsoDateTime(linkedAt),
      snapshot: head.map { V1.OrchestrationThreadShellPullRequestsItemSnapshot(state: state, title: "PR \(number)", headBranch: $0, baseBranch: base, isDraft: false, syncedAt: IsoDateTime(linkedAt)) }, stack: stack)
  }

  @Test func chainsFollowBaseToHeadBranches() {
    let links = [Self.item(3, head: "c", base: "b"), Self.item(1, head: "a", base: "main"), Self.item(2, head: "b", base: "a"), Self.item(9, head: "z", base: "main")]
    let chains = ThreadPullRequests.chains(links)
    #expect(chains.count == 2)
    #expect(chains.first { $0.layers.count == 3 }?.layers.map(\.number) == [1, 2, 3])
    #expect(chains.allSatisfy { $0.kind == .derived })
    // A reused head name cannot name a parent unambiguously.
    let ambiguous = ThreadPullRequests.chains([Self.item(1, head: "a"), Self.item(2, head: "a"), Self.item(3, head: "c", base: "a")])
    #expect(ambiguous.allSatisfy { $0.layers.count == 1 })
  }

  @Test func nativeStacksWinAndKeepTheHostsOrder() {
    let layers = [ThreadPullRequestStackLayer(number: 5, headBranch: "x", state: .open), ThreadPullRequestStackLayer(number: 4, headBranch: "y", state: .open)]
    let stack = ThreadPullRequestStack(id: "s", number: 1, url: "https://github.com/o/r/stack/1", base: "main", layers: layers)
    let chains = ThreadPullRequests.chains([Self.item(4, head: "y", stack: stack), Self.item(5, head: "x", stack: stack), Self.item(8, head: "m")])
    #expect(chains.first?.kind == .native)
    #expect(chains.first?.layers.map(\.number) == [5, 4])
  }

  @Test func currentPrefersOpenWorkAndHidesDismissedLinks() {
    #expect(ThreadPullRequests.current([]) == nil)
    let merged = Self.item(1, head: "a", state: .merged)
    let open = Self.item(2, head: "b")
    #expect(ThreadPullRequests.current([merged, open])?.number == 2)
    #expect(ThreadPullRequests.current([merged, Self.item(3, head: "c", state: .closed, source: .stackDismissed)])?.number == 1)
    // Unsynced links count as open.
    #expect(ThreadPullRequests.current([merged, Self.item(4)])?.number == 4)
  }
}

@Suite struct PullRequestsListLogicTests {
  @Test func typedQueryBecomesQualifiersAndText() {
    let parsed = PullRequestListLogic.parseQuery(#"fix crash label:bug,"needs design" -label:wip author:me draft:false review:changes_requested status:success size:XXL"#)
    #expect(parsed.text == "fix crash")
    #expect(parsed.filters.labels == [["bug", "needs design"], ["size:XXL"]])
    #expect(parsed.filters.excludedLabels == ["wip"])
    #expect(parsed.filters.author == "me")
    #expect(parsed.filters.draft == .hide && parsed.filters.review == .changesRequested && parsed.filters.checks == .passing)
    // Quoting is the way back to plain text; a link is not a label.
    #expect(PullRequestListLogic.parseQuery(#""size:XXL" https://x.test/a"#).text == #""size:XXL" https://x.test/a"#)
    #expect(PullRequestListLogic.resolveAuthor("@me", viewer: "octo") == "octo")
  }

  @Test func readinessRankingPutsGreenApprovedWorkFirstAndConflictsLast() {
    func row(_ number: Int, state: PullRequestState = .open, checks: PullRequestChecksState? = nil, review: PullRequestReviewDecision? = nil, mergeability: PullRequestMergeability = .mergeable, size: Int = 10)
      -> EnvironmentPullRequestEntry
    {
      EnvironmentPullRequestEntry(
        environmentId: "e1",
        entry: PullRequestListEntry(
          provider: .github, host: "github.com", projectId: "p", projectTitle: "P", repository: "o/r", number: number, title: "t\(number)", url: "u", headBranch: "h", baseBranch: "main",
          state: state, isDraft: false, mergeability: mergeability, additions: size, deletions: 0, createdAt: "2026-08-01T00:00:00.000Z", updatedAt: "2026-08-02T00:00:00.000Z",
          viewerReviewRequested: false, labels: [], reviewDecision: review, checksState: checks))
    }
    let ordered = PullRequestListLogic.ranked(byReadiness: [
      row(1, mergeability: .conflicting, size: 1), row(2, state: .merged), row(3), row(4, checks: .passing), row(5, checks: .passing, review: .approved, size: 99),
    ])
    #expect(ordered.map(\.entry.number) == [5, 4, 3, 2, 1])
  }
}

@Suite struct PullRequestsDetailLogicTests {
  static func review(_ id: String, _ login: String?, _ state: String, at: String) -> PullRequestComment {
    PullRequestComment(
      id: id, kind: .review, author: login.map { PullRequestActor(login: $0) }, body: "", createdAt: IsoDateTime(at), reviewState: state)
  }

  @Test func lastReviewOfEachPersonIsTheirVerdict() {
    let commits = [PullRequestCommit(oid: "abc1234", messageHeadline: "later", committedDate: "2026-08-05T00:00:00.000Z")]
    let outcomes = PullRequestDetailLogic.latestReviewOutcomes(
      [
        Self.review("1", "ann", "APPROVED", at: "2026-08-01T10:00:00.000Z"),
        Self.review("2", "ann", "CHANGES_REQUESTED", at: "2026-08-02T10:00:00.000Z"),
        Self.review("3", "bob", "approved", at: "2026-08-06T10:00:00.000Z"),
        Self.review("4", "cy", "APPROVED", at: "2026-08-01T10:00:00.000Z"),
        Self.review("5", "cy", "DISMISSED", at: "2026-08-02T10:00:00.000Z"),
        Self.review("6", "dee", "COMMENTED", at: "2026-08-02T10:00:00.000Z"),
      ], commits: commits)
    #expect(outcomes.map(\.key) == ["ann", "bob"])
    #expect(outcomes.map(\.outcome) == [.changesRequested, .approved])
    // A verdict given before the newest commit speaks for code that is gone.
    #expect(outcomes.map(\.stale) == [true, false])
  }

  @Test func savedStackFillsTitlesFromTheLinks() {
    let layers = [ThreadPullRequestStackLayer(number: 1, headBranch: "a", state: .open), ThreadPullRequestStackLayer(number: 2, headBranch: "b", state: .open)]
    let stack = ThreadPullRequestStack(id: "s", number: 1, url: "u", base: "main", layers: layers)
    let links = [PullRequestsLinkingTests.item(2, head: "b", stack: stack), PullRequestsLinkingTests.item(1, head: "a")]
    let saved = PullRequestDetailLogic.savedStack(from: links, host: "github.com", repository: "o/r", number: 2)
    #expect(saved?.layers.map(\.title) == ["PR 1", "PR 2"])
    #expect(PullRequestDetailLogic.savedStack(from: links, host: "github.com", repository: "o/r", number: 9) == nil)
  }

  @Test func checksReadAsOneWord() {
    func check(_ status: PullRequestCheckStatus) -> PullRequestCheck { PullRequestCheck(name: "c", status: status) }
    #expect(PullRequestDetailLogic.classify([]) == .none)
    #expect(PullRequestDetailLogic.classify([check(.success), check(.pending)]) == .pending)
    #expect(PullRequestDetailLogic.classify([check(.pending), check(.failure)]) == .failing)
    #expect(PullRequestDetailLogic.describe([check(.pending), check(.pending), check(.failure), check(.success)]) == "2 of 4 running \u{00B7} 1 failed")
  }
}
