import AppKit
import SwiftUI
import T3ClientRuntime
import T3Composer
import T3Contracts

// Git actions (commit, push, pull, pull request, publish) and the branch and worktree choices.
extension SourceControlStore {
  // MARK: Git actions

  /// Runs a stacked action with progress in the toast. From the default ref it asks first, like the web client.
  func runAction(
    _ context: GitContext, _ action: GitStackedAction, commitMessage: String? = nil, featureBranch: Bool = false, filePaths: [String]? = nil,
    skipDefaultBranchPrompt: Bool = false
  ) {
    let status = statusModel(context.environmentId, cwd: context.cwd).status
    let isDefaultRef = featureBranch ? false : (status?.isDefaultRef ?? false)
    let includesCommit =
      [.commit, .commit_push, .commit_push_pr].contains(action) && (action == .commit || status?.hasWorkingTreeChanges == true || featureBranch)
    if !skipDefaultBranchPrompt, GitActionsLogic.requiresDefaultBranchConfirmation(action, isDefaultRef: isDefaultRef), let branch = status?.refName {
      dialog = .defaultBranch(
        PendingGitAction(context: context, action: action, branch: branch, includesCommit: includesCommit, commitMessage: commitMessage, filePaths: filePaths))
      return
    }
    guard !isRunning(context) else { return }
    Task { await perform(context, action, status: status, commitMessage: commitMessage, featureBranch: featureBranch, filePaths: filePaths) }
  }

  private func perform(
    _ context: GitContext, _ action: GitStackedAction, status: VcsStatus?, commitMessage: String?, featureBranch: Bool, filePaths: [String]?
  ) async {
    setRunning(context, true)
    defer { setRunning(context, false) }
    let terminology = ChangeRequestTerminology(provider: status?.local.sourceControlProvider)
    let message = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let stages = GitActionsLogic.progressStages(
      action: action, hasCustomCommitMessage: message != nil, hasWorkingTreeChanges: status?.hasWorkingTreeChanges == true, featureBranch: featureBranch,
      shouldPushBeforePr: action == .create_pr && (status?.hasUpstream != true || (status?.aheadCount ?? 0) > 0), terminology: terminology)
    var title = stages.first ?? "Running git action..."
    var phase = title
    let progress = SourceControlHUD(kind: .loading, title: title, detail: "Waiting for Git...")
    show(progress)
    func update(_ title: String, _ detail: String?) {
      guard hud?.id == progress.id else { return }
      hud = SourceControlHUD(id: progress.id, kind: .loading, title: title, detail: detail)
    }
    let actionId = UUID().uuidString.lowercased()
    do {
      let session = try await session(context.environmentId)
      let input = GitRunStackedActionInput(
        actionId: actionId, cwd: context.cwd, action: action, commitMessage: message, featureBranch: featureBranch ? true : nil, filePaths: filePaths,
        threadId: context.isDraft ? nil : context.key.threadId)
      var result: GitRunStackedActionResult?
      for try await event in session.subscribe(Rpc.gitRunStackedAction, input) {
        switch event {
        case .phaseStarted(let e) where e.actionId == actionId:
          phase = e.label
          title = e.label
          update(title, nil)
        case .hookStarted(let e) where e.actionId == actionId: update("Running \(e.hookName)...", nil)
        case .hookOutput(let e) where e.actionId == actionId: update(title, e.text)
        case .hookFinished(let e) where e.actionId == actionId:
          title = phase
          update(title, nil)
        case .actionFinished(let e) where e.actionId == actionId: result = e.result
        case .actionFailed(let e) where e.actionId == actionId: throw SourceControlError(e.message)
        default: break
        }
      }
      guard let result else { throw SourceControlError("The git action ended without a result.") }
      if result.branch.status == .created, let name = result.branch.name { setBranch(context, name) }
      statusModel(context.environmentId, cwd: context.cwd).refresh()
      show(Self.outcome(of: result, context: context))
    } catch {
      fail("Action failed", error)
    }
  }

  private static func outcome(of result: GitRunStackedActionResult, context: GitContext) -> SourceControlHUD {
    var hud = SourceControlHUD(kind: .success, title: result.toast.title, detail: result.toast.description)
    switch result.toast.cta {
    case .openPr(let cta): hud.cta = URL(string: cta.url).map { .open(label: cta.label, url: $0) }
    case .runAction(let cta): hud.cta = .run(label: cta.label, action: cta.action.kind, context: context)
    default: break
    }
    return hud
  }

  func pull(_ context: GitContext) {
    guard !isRunning(context) else { return }
    Task {
      setRunning(context, true)
      defer { setRunning(context, false) }
      let progress = SourceControlHUD(kind: .loading, title: "Pulling...")
      show(progress)
      do {
        let result = try await call(context.environmentId, Rpc.vcsPull, VcsPullInput(cwd: context.cwd))
        let pulled = result.status == .pulled
        show(
          SourceControlHUD(
            id: progress.id, kind: .success, title: pulled ? "Pulled" : "Already up to date",
            detail: pulled ? "Updated \(result.refName) from \(result.upstreamRef ?? "upstream")" : "\(result.refName) is already synchronized."))
        statusModel(context.environmentId, cwd: context.cwd).refresh()
      } catch {
        fail("Pull failed", error)
      }
    }
  }

  func openPullRequest(_ status: VcsStatus?) {
    guard let url = status?.openPr.flatMap({ URL(string: $0.url) }) else {
      show(SourceControlHUD(kind: .error, title: "No open pull request found."))
      return
    }
    NSWorkspace.shared.open(url)
  }

  func run(_ quick: GitQuickAction, _ context: GitContext, status: VcsStatus?) {
    switch quick.kind {
    case .openPr: openPullRequest(status)
    case .openPublish: dialog = .publish(context)
    case .runPull: pull(context)
    case .showHint: show(SourceControlHUD(kind: .info, title: quick.label, detail: quick.hint))
    case .runAction: if let action = quick.action { runAction(context, action) }
    }
  }

  func publish(_ context: GitContext, _ input: SourceControlPublishRepositoryInput) async throws -> SourceControlPublishRepositoryResult {
    let result = try await call(context.environmentId, Rpc.sourceControlPublishRepository, input)
    statusModel(context.environmentId, cwd: context.cwd).refresh()
    return result
  }

  // MARK: Draft workspace

  func workspace(_ key: ScopedThreadKey, project: EnvironmentProject?) -> DraftWorkspace {
    if let stored = workspaces[key.description] { return stored }
    // A new draft starts where the project (or environment) says new threads start.
    var workspace = DraftWorkspace()
    if let project {
      let settings = settings(project.environmentId)
      let envMode = project.project.defaultThreadEnvMode.flatMap { $0 } ?? settings?.defaultThreadEnvMode
      workspace.envMode = envMode == .worktree ? .worktree : .local
      workspace.startFromOrigin = workspace.envMode == .worktree && settings?.newWorktreesStartFromOrigin == true
    }
    return workspace
  }

  func updateWorkspace(_ info: WorkspaceInfo, _ change: (inout DraftWorkspace) -> Void) {
    var next = info.workspace
    change(&next)
    workspaces[info.key.description] = next
  }

  func setEnvMode(_ info: WorkspaceInfo, _ mode: EnvMode) {
    guard info.isDraft else { return }
    updateWorkspace(info) {
      $0.envMode = mode
      $0.startFromOrigin = mode == .worktree && settings(info.key.environmentId)?.newWorktreesStartFromOrigin == true
      // A base branch and an existing worktree do not mix: the next pick starts over.
      if mode == .worktree, $0.worktreePath != nil {
        $0.worktreePath = nil
        $0.branch = nil
      }
    }
  }

  func usePreviousWorktree(_ info: WorkspaceInfo, _ seed: PreviousWorktreeSeed) {
    guard info.isDraft else { return }
    updateWorkspace(info) {
      $0.branch = seed.branch
      $0.worktreePath = seed.worktreePath
      $0.envMode = .worktree
    }
  }

  /// The worktree this draft could hop back into: the project's most recently touched one.
  func previousWorktree(_ info: WorkspaceInfo) -> PreviousWorktreeSeed? {
    guard info.isDraft else { return nil }
    let threads = (runtime.shells[info.key.environmentId]?.snapshot?.threads ?? []).filter { $0.projectId == info.project.projectId }
    return BranchToolbarLogic.resolvePreviousWorktreeSeed(
      threads: threads.map {
        BranchToolbarLogic.ThreadWorkspace(branch: $0.branch, worktreePath: $0.worktreePath, updatedAt: $0.updatedAt.rawValue, archived: $0.archivedAt != nil)
      },
      currentWorktreePath: info.worktreePath)
  }

  // MARK: Branch

  /// Records the thread's (or draft's) branch and worktree; a started thread's running session cannot follow a changed worktree.
  func setBranch(_ context: GitContext, _ branch: String?, worktreePath: String?? = nil) {
    if context.isDraft {
      let project = project(context.key.environmentId, context.projectId)
      var next = workspace(context.key, project: project)
      let path = worktreePath ?? next.worktreePath
      let mode = BranchToolbarLogic.resolveEffectiveEnvMode(activeWorktreePath: next.worktreePath, hasServerThread: false, draftEnvMode: next.envMode)
      next.envMode = BranchToolbarLogic.resolveDraftEnvModeAfterBranchChange(nextWorktreePath: path, currentWorktreePath: next.worktreePath, effectiveEnvMode: mode)
      next.branch = branch
      next.worktreePath = path
      workspaces[context.key.description] = next
      return
    }
    guard let shell = runtime.threadShell(context.key)?.shell else { return }
    guard branch != shell.branch || (worktreePath != nil && worktreePath! != shell.worktreePath) else { return }
    Task {
      do {
        guard let environment = await runtime.runtime(for: context.key.environmentId) else { throw SourceControlError("The environment is not connected.") }
        if let worktreePath, worktreePath != shell.worktreePath, shell.session != nil {
          try await environment.dispatch(ThreadCommand.stopSession(context.key.threadId), thread: context.key.threadId)
        }
        let meta = CommandMeta.fresh()
        try await environment.dispatch(
          .threadMetaUpdate(
            ClientOrchestrationCommandThreadMetaUpdate(
              commandId: meta.commandId, threadId: context.key.threadId, branch: .some(branch), expectedBranch: .some(shell.branch),
              worktreePath: worktreePath)),
          thread: context.key.threadId)
      } catch {
        fail("Could not update the thread's branch", error)
      }
    }
  }

  /// Picks a ref in the branch picker: the base of a new worktree, a branch that already has a worktree, or a checkout.
  func select(_ ref: VcsRef, in info: WorkspaceInfo) async {
    let context = info.context
    let projectCwd = info.project.project.workspaceRoot
    if info.envMode == .worktree && info.worktreePath == nil && info.isDraft {
      updateWorkspace(info) { $0.branch = ref.name }
      return
    }
    let target = BranchToolbarLogic.resolveBranchSelectionTarget(activeProjectCwd: projectCwd, activeWorktreePath: info.worktreePath, ref: ref)
    if target.reuseExistingWorktree {
      setBranch(context, ref.name, worktreePath: .some(target.nextWorktreePath))
      return
    }
    do {
      let result = try await call(context.environmentId, Rpc.vcsSwitchRef, VcsSwitchRefInput(cwd: target.checkoutCwd, refName: ref.name))
      let local = ref.isRemote == true ? BranchToolbarLogic.deriveLocalBranchName(fromRemoteRef: ref.name) : ref.name
      setBranch(context, ref.isRemote == true ? (result.refName ?? local) : local, worktreePath: .some(target.nextWorktreePath))
      statusModel(context.environmentId, cwd: target.checkoutCwd).refresh()
    } catch {
      fail("Failed to switch ref.", error)
    }
  }

  func createRef(_ rawName: String, in info: WorkspaceInfo) async {
    let name = BranchToolbarLogic.sanitizeNewRefName(rawName)
    guard !name.isEmpty else { return }
    do {
      let result = try await call(info.key.environmentId, Rpc.vcsCreateRef, VcsCreateRefInput(cwd: info.cwd, refName: name, switchRef: true))
      setBranch(info.context, result.refName)
      statusModel(info.key.environmentId, cwd: info.cwd).refresh()
    } catch {
      fail("Failed to create and switch ref.", error)
    }
  }

  func listRefs(_ environmentId: EnvironmentId, cwd: String, query: String, cursor: Int?) async throws -> VcsListRefsResult {
    try await call(environmentId, Rpc.vcsListRefs, VcsListRefsInput(cwd: cwd, query: query.isEmpty ? nil : query, cursor: cursor, limit: 100))
  }

  // MARK: First send

  /// What the first send of a draft carries: its branch, an existing worktree, or the worktree to create.
  struct DraftSend {
    var branch: String?
    var worktreePath: String?
    var prepare: ClientOrchestrationCommandThreadTurnStartBootstrapPrepareWorktree?
  }

  func draftSend(for target: ComposerTarget) throws -> DraftSend {
    let key = ScopedThreadKey(environmentId: EnvironmentId(target.environmentId), threadId: ThreadId(target.threadId))
    guard let projectId = target.projectId, let project = project(key.environmentId, ProjectId(projectId)) else { return DraftSend() }
    let workspace = workspace(key, project: project)
    let mode = BranchToolbarLogic.resolveEffectiveEnvMode(activeWorktreePath: workspace.worktreePath, hasServerThread: false, draftEnvMode: workspace.envMode)
    guard mode == .worktree else { return DraftSend(branch: workspace.branch, worktreePath: workspace.worktreePath) }
    // Worktree mode needs an explicit base so a missing choice never silently runs in the project checkout.
    guard let base = workspace.branch else { throw ComposerEnvironmentError("Select a base branch before sending in New worktree mode.") }
    return DraftSend(
      branch: base,
      prepare: ClientOrchestrationCommandThreadTurnStartBootstrapPrepareWorktree(
        projectCwd: project.project.workspaceRoot, baseBranch: base, branch: BranchToolbarLogic.temporaryWorktreeBranchName(),
        startFromOrigin: workspace.startFromOrigin ? true : nil))
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
