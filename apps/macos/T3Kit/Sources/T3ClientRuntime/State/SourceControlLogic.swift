import Foundation
import T3Contracts

// Pure rules of the branch toolbar, the git actions menu and project scripts, ported from the web client
// (`BranchToolbar.logic.ts`, `GitActionsControl.logic.ts`, `projectScripts.ts`, `@t3tools/shared/git`).

/// Where a draft thread runs: the project checkout, or a worktree created with its first turn.
public enum EnvMode: String, Sendable, Equatable {
  case local, worktree
}

/// The two halves of `subscribeVcsStatus`, folded like the web's `applyGitStatusStreamEvent`.
public struct VcsStatus: Sendable, Equatable {
  public var local: VcsStatusLocalResult
  public var remote: VcsStatusRemoteResult?

  public init(local: VcsStatusLocalResult, remote: VcsStatusRemoteResult? = nil) {
    self.local = local
    self.remote = remote
  }

  public var isRepo: Bool { local.isRepo }
  public var refName: String? { local.refName }
  public var isDefaultRef: Bool { local.isDefaultRef }
  public var hasPrimaryRemote: Bool { local.hasPrimaryRemote }
  public var hasWorkingTreeChanges: Bool { local.hasWorkingTreeChanges }
  public var files: [VcsStatusLocalResultWorkingTreeFilesItem] { local.workingTree.files }
  public var hasUpstream: Bool { remote?.hasUpstream ?? false }
  public var aheadCount: Int { remote?.aheadCount ?? 0 }
  public var behindCount: Int { remote?.behindCount ?? 0 }
  public var aheadOfDefaultCount: Int? { remote?.aheadOfDefaultCount }
  public var pr: VcsStatusRemoteResultPr? { remote?.pr }
  public var openPr: VcsStatusRemoteResultPr? { pr.flatMap { $0.state == .open ? $0 : nil } }

  public static func applying(_ event: VcsStatusStreamEvent, to current: VcsStatus?) -> VcsStatus? {
    switch event {
    case .snapshot(let e): return VcsStatus(local: e.local, remote: e.remote)
    case .localUpdated(let e): return VcsStatus(local: e.local, remote: current?.remote)
    case .remoteUpdated(let e):
      let local = current?.local ?? VcsStatusLocalResult(
        isRepo: true, hasPrimaryRemote: false, isDefaultRef: false, hasWorkingTreeChanges: false,
        workingTree: VcsStatusLocalResultWorkingTree(files: [], insertions: 0, deletions: 0))
      return VcsStatus(local: local, remote: e.remote)
    case .unknown: return current
    }
  }
}

public struct PreviousWorktreeSeed: Sendable, Equatable {
  public var branch: String?
  public var worktreePath: String
}

public struct BranchSelectionTarget: Sendable, Equatable {
  public var checkoutCwd: String
  public var nextWorktreePath: String?
  public var reuseExistingWorktree: Bool
}

public enum BranchToolbarLogic {
  public static let worktreeBranchPrefix = "t3code"

  /// Git rejects ASCII whitespace in ref names; a typed "new branch" becomes "new-branch".
  public static func sanitizeNewRefName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/[ \t\n\r\f\v]+/, with: "-")
  }

  /// `origin/feature/x` -> `feature/x`.
  public static func deriveLocalBranchName(fromRemoteRef name: String) -> String {
    guard let slash = name.firstIndex(of: "/"), slash != name.startIndex, name.index(after: slash) != name.endIndex else { return name }
    return String(name[name.index(after: slash)...])
  }

  /// `t3code/<8 hex>`: the temporary branch a new worktree starts on, before the agent names it.
  public static func temporaryWorktreeBranchName(randomHex: String = UUID().uuidString) -> String {
    let token = randomHex.lowercased().filter { $0.isHexDigit }.prefix(8)
    return "\(worktreeBranchPrefix)/\(token)"
  }

  public struct ThreadWorkspace: Sendable {
    public var branch: String?
    public var worktreePath: String?
    public var updatedAt: String
    public var archived: Bool
    public init(branch: String?, worktreePath: String?, updatedAt: String, archived: Bool) {
      self.branch = branch
      self.worktreePath = worktreePath
      self.updatedAt = updatedAt
      self.archived = archived
    }
  }

  /// The most recently touched worktree of the project that the draft is not already pointing at.
  public static func resolvePreviousWorktreeSeed(threads: [ThreadWorkspace], currentWorktreePath: String?) -> PreviousWorktreeSeed? {
    var latest: (seed: PreviousWorktreeSeed, at: Double)?
    for thread in threads {
      guard let path = thread.worktreePath, !path.isEmpty, path != currentWorktreePath, !thread.archived,
        let at = IsoTimestamp.parse(thread.updatedAt)
      else { continue }
      if latest == nil || at > latest!.at { latest = (PreviousWorktreeSeed(branch: thread.branch, worktreePath: path), at) }
    }
    return latest?.seed
  }

  public static func previousWorktreeLabel(_ seed: PreviousWorktreeSeed) -> String {
    seed.branch.map { "Previous worktree (\($0))" } ?? "Previous worktree"
  }

  /// A started thread is in a worktree once it has a path (or is still creating one); a draft pointing at an existing worktree reads as local.
  public static func resolveEffectiveEnvMode(activeWorktreePath: String?, hasServerThread: Bool, draftEnvMode: EnvMode?, preparingWorktree: Bool = false) -> EnvMode {
    if !hasServerThread { return activeWorktreePath != nil ? .local : (draftEnvMode == .worktree ? .worktree : .local) }
    return activeWorktreePath != nil || preparingWorktree ? .worktree : .local
  }

  public static func resolveDraftEnvModeAfterBranchChange(nextWorktreePath: String?, currentWorktreePath: String?, effectiveEnvMode: EnvMode) -> EnvMode {
    if nextWorktreePath != nil { return .worktree }
    return effectiveEnvMode == .worktree && currentWorktreePath == nil ? .worktree : .local
  }

  public static func resolveBranchToolbarValue(envMode: EnvMode, activeWorktreePath: String?, activeThreadBranch: String?, currentGitBranch: String?) -> String? {
    if envMode == .worktree && activeWorktreePath == nil { return activeThreadBranch ?? currentGitBranch }
    return currentGitBranch ?? activeThreadBranch
  }

  public static func resolveBranchTriggerLabel(
    activeWorktreePath: String?, envMode: EnvMode, activeBranch: String?, activeBranchIsRemote: Bool?, startFromOrigin: Bool
  ) -> String {
    guard let activeBranch else { return "Select ref" }
    if envMode == .worktree && activeWorktreePath == nil {
      return "From \(startFromOrigin && activeBranchIsRemote == false ? "origin/\(activeBranch)" : activeBranch)"
    }
    return activeBranch
  }

  public static func resolveBranchSelectionTarget(activeProjectCwd: String, activeWorktreePath: String?, ref: VcsRef) -> BranchSelectionTarget {
    if let path = ref.worktreePath {
      return BranchSelectionTarget(checkoutCwd: path, nextWorktreePath: path == activeProjectCwd ? nil : path, reuseExistingWorktree: true)
    }
    let next = activeWorktreePath != nil && ref.isDefault ? nil : activeWorktreePath
    return BranchSelectionTarget(checkoutCwd: next ?? activeProjectCwd, nextWorktreePath: next, reuseExistingWorktree: false)
  }

  /// The draft's recorded branch follows the checkout, except that a temporary worktree branch never replaces a chosen one.
  public static func resolveLiveDraftBranchUpdate(draftBranch: String?, status: VcsStatus?) -> String?? {
    guard let status else { return nil }
    if status.refName == nil && draftBranch != nil { return nil }
    if draftBranch == status.refName { return nil }
    if let draftBranch, let ref = status.refName, !isTemporaryWorktreeBranch(draftBranch), isTemporaryWorktreeBranch(ref) { return nil }
    return .some(status.refName)
  }

  public static func isTemporaryWorktreeBranch(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespaces).lowercased().wholeMatch(of: /t3code\/[0-9a-f]{8}/) != nil
  }
}

// MARK: - Git actions

public struct ChangeRequestTerminology: Sendable, Equatable {
  public var shortLabel: String
  public var singular: String
  public static let `default` = ChangeRequestTerminology(shortLabel: "PR", singular: "pull request")

  public init(provider: SourceControlProviderInfo?) {
    guard let provider else { self = .default; return }
    switch provider.kind {
    case .github, .forgejo, .azureDevops, .bitbucket: self = .default
    case .gitlab: self = ChangeRequestTerminology(shortLabel: "MR", singular: "merge request")
    default: self = ChangeRequestTerminology(shortLabel: "change request", singular: "change request")
    }
  }

  init(shortLabel: String, singular: String) {
    self.shortLabel = shortLabel
    self.singular = singular
  }
}

public struct GitActionMenuItem: Sendable, Equatable, Identifiable {
  public enum ID: String, Sendable { case commit, push, pr }
  public enum Kind: Sendable { case openDialog, openPr }
  public var id: ID
  public var label: String
  public var disabled: Bool
  public var kind: Kind
  public var action: GitStackedAction?
}

public struct GitQuickAction: Sendable, Equatable {
  public enum Kind: Sendable { case runAction, runPull, openPr, openPublish, showHint }
  public var label: String
  public var disabled: Bool
  public var kind: Kind
  public var action: GitStackedAction?
  public var hint: String?
}

public struct DefaultBranchActionCopy: Sendable, Equatable {
  public var title: String
  public var description: String
  public var continueLabel: String
}

public enum GitActionsLogic {
  public static func menuItems(_ status: VcsStatus?, isBusy: Bool, hasPrimaryRemote: Bool = true) -> [GitActionMenuItem] {
    guard let status else { return [] }
    let terminology = ChangeRequestTerminology(provider: status.local.sourceControlProvider)
    let hasBranch = status.refName != nil
    let hasChanges = status.hasWorkingTreeChanges
    let hasOpenPr = status.openPr != nil
    let isBehind = status.behindCount > 0
    let hasDefaultBranchDelta = (status.aheadOfDefaultCount ?? status.aheadCount) > 0
    let canPushWithoutUpstream = hasPrimaryRemote && !status.hasUpstream
    let canCommit = !isBusy && hasChanges
    let canPush = !isBusy && hasBranch && !isBehind && status.aheadCount > 0 && (status.hasUpstream || canPushWithoutUpstream)
    let canCreatePr =
      !isBusy && hasBranch && !hasChanges && !hasOpenPr && hasDefaultBranchDelta && !isBehind && (status.hasUpstream || canPushWithoutUpstream)
    let commit = GitActionMenuItem(id: .commit, label: "Commit", disabled: !canCommit, kind: .openDialog, action: .commit)
    guard hasPrimaryRemote else { return [commit] }
    let push = GitActionMenuItem(id: .push, label: "Push", disabled: !canPush, kind: .openDialog, action: .push)
    let pr =
      hasOpenPr
      ? GitActionMenuItem(id: .pr, label: "View \(terminology.shortLabel)", disabled: isBusy, kind: .openPr, action: nil)
      : GitActionMenuItem(id: .pr, label: "Create \(terminology.shortLabel)", disabled: !canCreatePr, kind: .openDialog, action: .create_pr)
    return [commit, push, pr]
  }

  public static func quickAction(_ status: VcsStatus?, isBusy: Bool, isDefaultRef: Bool = false, hasPrimaryRemote: Bool = true) -> GitQuickAction {
    func hint(_ text: String, label: String = "Commit") -> GitQuickAction { GitQuickAction(label: label, disabled: true, kind: .showHint, hint: text) }
    if isBusy { return hint("Git action in progress.") }
    guard let status else { return hint("Git status is unavailable.") }
    let terminology = ChangeRequestTerminology(provider: status.local.sourceControlProvider)
    let hasChanges = status.hasWorkingTreeChanges
    let hasOpenPr = status.openPr != nil
    let isAhead = status.aheadCount > 0
    let isBehind = status.behindCount > 0
    let hasDefaultBranchDelta = (status.aheadOfDefaultCount ?? status.aheadCount) > 0
    func run(_ label: String, _ action: GitStackedAction) -> GitQuickAction { GitQuickAction(label: label, disabled: false, kind: .runAction, action: action) }
    let viewPr = GitQuickAction(label: "View \(terminology.shortLabel)", disabled: false, kind: .openPr)

    guard status.refName != nil else {
      return hint("Create and checkout a ref before pushing or opening a \(terminology.singular).")
    }
    if hasChanges {
      if !status.hasUpstream && !hasPrimaryRemote { return run("Commit", .commit) }
      if hasOpenPr || isDefaultRef { return run("Commit & push", .commit_push) }
      return run("Commit, push & \(terminology.shortLabel)", .commit_push_pr)
    }
    if !status.hasUpstream {
      if !hasPrimaryRemote {
        if hasOpenPr && !isAhead { return viewPr }
        return GitQuickAction(label: "Publish repository", disabled: false, kind: .openPublish)
      }
      if !isAhead { return hasOpenPr ? viewPr : hint("No local commits to push.", label: "Push") }
      if hasOpenPr || isDefaultRef { return run("Push", isDefaultRef ? .commit_push : .push) }
      return run("Push & create \(terminology.shortLabel)", .create_pr)
    }
    if isAhead && isBehind { return hint("Branch has diverged from upstream. Rebase/merge first.", label: "Sync ref") }
    if isBehind { return GitQuickAction(label: "Pull", disabled: false, kind: .runPull) }
    if isAhead {
      if hasOpenPr || isDefaultRef { return run("Push", isDefaultRef ? .commit_push : .push) }
      return run("Push & create \(terminology.shortLabel)", .create_pr)
    }
    if hasOpenPr { return viewPr }
    if hasDefaultBranchDelta && !isDefaultRef { return run("Create \(terminology.shortLabel)", .create_pr) }
    return hint("Branch is up to date. No action needed.")
  }

  /// Pushing from the default ref asks first (the web's "default branch" dialog).
  public static func requiresDefaultBranchConfirmation(_ action: GitStackedAction, isDefaultRef: Bool) -> Bool {
    guard isDefaultRef else { return false }
    switch action {
    case .push, .create_pr, .commit_push, .commit_push_pr: return true
    default: return false
    }
  }

  public static func defaultBranchCopy(action: GitStackedAction, branch: String, includesCommit: Bool, terminology: ChangeRequestTerminology = .default) -> DefaultBranchActionCopy {
    let suffix = " on \"\(branch)\". You can continue on this ref or create a feature ref and run the same action there."
    if action == .push || action == .commit_push {
      return includesCommit
        ? DefaultBranchActionCopy(
          title: "Commit & push to default ref?", description: "This action will commit and push changes\(suffix)", continueLabel: "Commit & push to \(branch)")
        : DefaultBranchActionCopy(title: "Push to default ref?", description: "This action will push local commits\(suffix)", continueLabel: "Push to \(branch)")
    }
    return includesCommit
      ? DefaultBranchActionCopy(
        title: "Commit, push & create \(terminology.shortLabel) from default ref?",
        description: "This action will commit, push, and create a \(terminology.singular)\(suffix)",
        continueLabel: "Commit, push & create \(terminology.shortLabel)")
      : DefaultBranchActionCopy(
        title: "Push & create \(terminology.shortLabel) from default ref?",
        description: "This action will push local commits and create a \(terminology.singular)\(suffix)",
        continueLabel: "Push & create \(terminology.shortLabel)")
  }

  /// The stages the HUD shows until the server's first progress event.
  public static func progressStages(
    action: GitStackedAction, hasCustomCommitMessage: Bool, hasWorkingTreeChanges: Bool, featureBranch: Bool, shouldPushBeforePr: Bool,
    terminology: ChangeRequestTerminology = .default
  ) -> [String] {
    let branchStages = featureBranch ? ["Preparing feature ref..."] : []
    let push = "Pushing..."
    let prStages = ["Preparing \(terminology.shortLabel)...", "Generating \(terminology.shortLabel) content...", "Creating \(terminology.singular)..."]
    if action == .push { return [push] }
    if action == .create_pr { return shouldPushBeforePr ? [push] + prStages : prStages }
    let commitStages =
      action == .commit || hasWorkingTreeChanges ? (hasCustomCommitMessage ? ["Committing..."] : ["Generating commit message...", "Committing..."]) : []
    if action == .commit { return branchStages + commitStages }
    if action == .commit_push { return branchStages + commitStages + [push] }
    return branchStages + commitStages + [push] + prStages
  }
}

// MARK: - Project scripts

public enum ProjectScriptsLogic {
  public static let maxIDLength = 24

  /// `Run tests` -> `run-tests`, then `run-tests-2` while taken.
  public static func nextID(for name: String, existing: [String]) -> String {
    let taken = Set(existing)
    var base = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "script" }
    if base.count > maxIDLength { base = String(base.prefix(maxIDLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
    if base.isEmpty { base = "script" }
    if !taken.contains(base) { return base }
    for suffix in 2..<10_000 {
      let tail = "-\(suffix)"
      let candidate = base.count + tail.count <= maxIDLength ? base + tail : String(base.prefix(max(1, maxIDLength - tail.count))) + tail
      if !taken.contains(candidate) { return candidate }
    }
    return String("\(base)-\(Int(Date().timeIntervalSince1970))".prefix(maxIDLength))
  }

  /// `script.<id>.run`; legacy ids the keybinding grammar rejects return nil (the script stays usable without a shortcut).
  public static func command(forScriptID id: String) -> KeybindingCommand? {
    id.count <= maxIDLength && id.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil ? KeybindingCommand(rawValue: "script.\(id).run") : nil
  }

  /// The one-click script of the toolbar: a regular script, else the first.
  public static func primary(_ scripts: [ProjectScript]) -> ProjectScript? { scripts.first { !$0.runOnWorktreeCreate } ?? scripts.first }
}
