import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct SourceControlLogicTests {
  static func status(
    branch: String? = "feature", changes: Bool = false, upstream: Bool = true, ahead: Int = 0, behind: Int = 0, isDefault: Bool = false, openPr: Bool = false
  ) -> VcsStatus {
    let local = VcsStatusLocalResult(
      isRepo: true, hasPrimaryRemote: true, isDefaultRef: isDefault, refName: branch, hasWorkingTreeChanges: changes,
      workingTree: VcsStatusLocalResultWorkingTree(files: [], insertions: 0, deletions: 0))
    let pr = openPr ? VcsStatusRemoteResultPr(number: 4, title: "t", url: "https://x/4", baseRef: "main", headRef: "feature", state: .open) : nil
    return VcsStatus(local: local, remote: VcsStatusRemoteResult(hasUpstream: upstream, aheadCount: ahead, behindCount: behind, pr: pr))
  }

  @Test func quickActionFollowsTheWebRules() {
    func quick(_ status: VcsStatus, isDefault: Bool = false) -> GitQuickAction { GitActionsLogic.quickAction(status, isBusy: false, isDefaultRef: isDefault) }
    #expect(quick(Self.status(changes: true)).action == .commit_push_pr)
    #expect(quick(Self.status(changes: true, openPr: true)).action == .commit_push)
    #expect(quick(Self.status(ahead: 2)).action == .create_pr)
    #expect(quick(Self.status(ahead: 2, openPr: true)).action == .push)
    #expect(quick(Self.status(behind: 1)).kind == .runPull)
    #expect(quick(Self.status(ahead: 1, behind: 1)).disabled)
    #expect(quick(Self.status(upstream: false)).label == "Push" && quick(Self.status(upstream: false)).disabled)
    #expect(quick(Self.status(branch: nil)).disabled)
    #expect(GitActionsLogic.quickAction(Self.status(changes: true), isBusy: true).disabled)
  }

  @Test func menuItemsGateOnState() {
    let items = GitActionsLogic.menuItems(Self.status(changes: true, ahead: 1), isBusy: false)
    #expect(items.map(\.disabled) == [false, false, true])
    #expect(GitActionsLogic.menuItems(Self.status(ahead: 1, openPr: true), isBusy: false).last?.kind == .openPr)
    #expect(GitActionsLogic.menuItems(Self.status(changes: true), isBusy: false, hasPrimaryRemote: false).count == 1)
    #expect(GitActionsLogic.requiresDefaultBranchConfirmation(.commit_push, isDefaultRef: true))
    #expect(!GitActionsLogic.requiresDefaultBranchConfirmation(.commit, isDefaultRef: true))
  }

  @Test func statusEventsFoldLikeTheWeb() throws {
    let base = Self.status(ahead: 3)
    let local = VcsStatusLocalResult(
      isRepo: true, hasPrimaryRemote: true, isDefaultRef: false, refName: "other", hasWorkingTreeChanges: true,
      workingTree: VcsStatusLocalResultWorkingTree(files: [], insertions: 0, deletions: 0))
    let updated = VcsStatus.applying(.localUpdated(.init(local: local)), to: base)
    #expect(updated?.refName == "other" && updated?.aheadCount == 3)
    #expect(VcsStatus.applying(.remoteUpdated(.init(remote: nil)), to: nil)?.isRepo == true)
  }

  @Test func branchRules() {
    #expect(BranchToolbarLogic.sanitizeNewRefName("  new branch\tname ") == "new-branch-name")
    #expect(BranchToolbarLogic.deriveLocalBranchName(fromRemoteRef: "origin/feat/x") == "feat/x")
    #expect(BranchToolbarLogic.temporaryWorktreeBranchName(randomHex: "AB12-cd34ef56") == "t3code/ab12cd34")
    #expect(BranchToolbarLogic.isTemporaryWorktreeBranch("t3code/ab12cd34") && !BranchToolbarLogic.isTemporaryWorktreeBranch("feature/x"))
    let target = BranchToolbarLogic.resolveBranchSelectionTarget(
      activeProjectCwd: "/p", activeWorktreePath: "/p-wt", ref: VcsRef(name: "main", current: false, isDefault: true))
    #expect(target.nextWorktreePath == nil && target.checkoutCwd == "/p")
    #expect(
      BranchToolbarLogic.resolveBranchTriggerLabel(activeWorktreePath: nil, envMode: .worktree, activeBranch: "main", activeBranchIsRemote: false, startFromOrigin: true)
        == "From origin/main")
  }

  @Test func previousWorktreePicksTheNewestUnarchived() {
    typealias W = BranchToolbarLogic.ThreadWorkspace
    let seed = BranchToolbarLogic.resolvePreviousWorktreeSeed(
      threads: [
        W(branch: "a", worktreePath: "/wt/a", updatedAt: "2026-01-01T00:00:00.000Z", archived: false),
        W(branch: "b", worktreePath: "/wt/b", updatedAt: "2026-02-01T00:00:00.000Z", archived: true),
        W(branch: "c", worktreePath: "/wt/c", updatedAt: "2026-01-15T00:00:00.000Z", archived: false),
        W(branch: nil, worktreePath: nil, updatedAt: "2026-03-01T00:00:00.000Z", archived: false),
      ], currentWorktreePath: nil)
    #expect(seed?.worktreePath == "/wt/c")
    #expect(BranchToolbarLogic.previousWorktreeLabel(seed!) == "Previous worktree (c)")
  }

  @Test func scriptIDs() {
    #expect(ProjectScriptsLogic.nextID(for: "Run tests!", existing: []) == "run-tests")
    #expect(ProjectScriptsLogic.nextID(for: "Run tests", existing: ["run-tests"]) == "run-tests-2")
    #expect(ProjectScriptsLogic.command(forScriptID: "dev")?.rawValue == "script.dev.run")
    #expect(ProjectScriptsLogic.command(forScriptID: "Bad_ID") == nil)
  }
}
