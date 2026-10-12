import Foundation
import T3Contracts

/// One server call of a protocol-2 command plan.
enum V2Step: Sendable, Equatable {
  case command(OrchestrationV2Command)
  /// `orchestration.launchThread`: creates the thread (and worktree) together with its first message.
  case launch(OrchestrationV2ThreadLaunchInput)
  /// Project mutations are their own RPC on protocol-2 servers.
  case project(ProjectMutation)
  /// Needs the run id: the active run (or the one whose background work still runs) when none was named.
  case interrupt(threadId: ThreadId, runId: RunId?, meta: CommandMeta)
  /// Resolved against the thread projection: the ready checkpoint of the run ordinal `turnCount`.
  case rollback(threadId: ThreadId, turnCount: Int, restoreFiles: Bool, meta: CommandMeta)
  /// Detaches every provider session of the thread.
  case detachSessions(threadId: ThreadId, meta: CommandMeta)
}

/// The V1-shaped commands the composer, the lifecycle menus and the project actions still build, as the
/// protocol-2 calls that do the same. The V2-only concepts (steer, queue, rollback by checkpoint, answers with
/// attachments) have their own `ClientRuntime` methods and never pass through here. Nothing here is replayed:
/// the first failing call ends the plan and its error reaches the caller.
enum CommandTranslation {
  static func plan(for command: V1.ClientOrchestrationCommand) throws(CommandError) -> [V2Step] {
    switch command {
    case .projectCreate(let c):
      return [
        .project(
          .projectCreate(
            ProjectMutationProjectCreate(
              commandId: c.commandId, projectId: c.projectId, title: c.title, workspaceRoot: c.workspaceRoot,
              createWorkspaceRootIfMissing: c.createWorkspaceRootIfMissing, defaultModelSelection: c.defaultModelSelection)))
      ]
    case .projectDelete(let c):
      return [.project(.projectDelete(ProjectMutationProjectDelete(commandId: c.commandId, projectId: c.projectId, force: c.force)))]
    case .threadCreate(let c):
      return [
        .command(
          ThreadCommandV2.create(
            threadId: c.threadId, projectId: c.projectId, title: c.title, modelSelection: c.modelSelection, runtimeMode: c.runtimeMode,
            interactionMode: c.interactionMode, branch: c.branch, worktreePath: c.worktreePath, meta: CommandMeta(commandId: c.commandId, createdAt: c.createdAt)))
      ]
    case .threadDelete(let c): return [.command(ThreadCommandV2.delete(c.threadId, meta: meta(c.commandId)))]
    case .threadArchive(let c): return [.command(ThreadCommandV2.archive(c.threadId, meta: meta(c.commandId)))]
    case .threadUnarchive(let c): return [.command(ThreadCommandV2.unarchive(c.threadId, meta: meta(c.commandId)))]
    case .threadSettle(let c): return [.command(ThreadCommandV2.settle(c.threadId, meta: meta(c.commandId)))]
    case .threadUnsettle(let c): return [.command(ThreadCommandV2.unsettle(c.threadId, meta: meta(c.commandId)))]
    case .threadSnooze(let c): return [.command(ThreadCommandV2.snooze(c.threadId, until: c.snoozedUntil, meta: meta(c.commandId)))]
    case .threadUnsnooze(let c): return [.command(ThreadCommandV2.unsnooze(c.threadId, meta: meta(c.commandId)))]
    case .threadPin(let c): return [.command(ThreadCommandV2.pin(c.threadId, orderKey: c.orderKey, meta: meta(c.commandId)))]
    case .threadUnpin(let c): return [.command(ThreadCommandV2.unpin(c.threadId, meta: meta(c.commandId)))]
    case .threadPinReorder(let c): return [.command(ThreadCommandV2.reorderPinned(c.threadId, orderKey: c.orderKey, meta: meta(c.commandId)))]
    case .threadActiveReorder(let c): return [.command(ThreadCommandV2.reorderActive(c.threadId, orderKey: c.orderKey, meta: meta(c.commandId)))]
    case .threadAutoSettleSet(let c): return [.command(ThreadCommandV2.setAutoSettle(c.threadId, enabled: c.enabled, meta: meta(c.commandId)))]
    case .threadMetaUpdate(let c):
      var steps: [V2Step] = []
      if c.title != nil || c.regenerateTitle != nil || c.branch != nil || c.worktreePath != nil || c.linkedPullRequest != nil {
        steps.append(
          .command(
            ThreadCommandV2.updateMetadata(
              c.threadId, title: c.title, regenerateTitle: c.regenerateTitle, branch: c.branch, worktreePath: c.worktreePath,
              linkedPullRequest: c.linkedPullRequest, meta: meta(c.commandId))))
      }
      if let selection = c.modelSelection {
        // A second command keeps the first one's id retry-safe.
        let id = steps.isEmpty ? c.commandId : CommandId(rawValue: "\(c.commandId.rawValue):model-selection")
        steps.append(.command(ThreadCommandV2.setModelSelection(c.threadId, selection, meta: meta(id))))
      }
      return steps
    case .threadRuntimeModeSet(let c): return [.command(ThreadCommandV2.setRuntimeMode(c.threadId, c.runtimeMode, meta: meta(c.commandId)))]
    case .threadInteractionModeSet(let c): return [.command(ThreadCommandV2.setInteractionMode(c.threadId, c.interactionMode, meta: meta(c.commandId)))]
    case .threadTurnStart(let c): return [try turnStart(c)]
    case .threadTurnInterrupt(let c):
      return [.interrupt(threadId: c.threadId, runId: c.turnId.map { RunId(rawValue: $0.rawValue) }, meta: meta(c.commandId))]
    case .threadApprovalRespond(let c):
      return [
        .command(
          ThreadCommandV2.respondToApproval(c.threadId, requestId: RuntimeRequestId(rawValue: c.requestId.rawValue), decision: c.decision, meta: meta(c.commandId)))
      ]
    case .threadUserInputRespond(let c):
      return [
        .command(
          ThreadCommandV2.respondToUserInput(
            c.threadId, requestId: RuntimeRequestId(rawValue: c.requestId.rawValue), answers: c.answers,
            attachmentsByQuestionId: c.attachmentsByQuestionId.flatMap(userInputAttachments), meta: meta(c.commandId)))
      ]
    case .threadUserInputDismiss(let c):
      return [.command(ThreadCommandV2.dismissUserInput(c.threadId, requestId: RuntimeRequestId(rawValue: c.requestId.rawValue), meta: meta(c.commandId)))]
    case .threadCheckpointRevert(let c): return [.rollback(threadId: c.threadId, turnCount: c.turnCount, restoreFiles: true, meta: meta(c.commandId))]
    case .threadConversationRevert(let c): return [.rollback(threadId: c.threadId, turnCount: c.turnCount, restoreFiles: false, meta: meta(c.commandId))]
    case .threadSessionStop(let c): return [.detachSessions(threadId: c.threadId, meta: meta(c.commandId))]
    case .projectMetaUpdate(let c):
      return [
        .project(
          .projectUpdate(
            ProjectMutationProjectUpdate(
              commandId: c.commandId, projectId: c.projectId, title: c.title, workspaceRoot: c.workspaceRoot, defaultModelSelection: c.defaultModelSelection,
              autoPull: c.autoPull, projectIcon: Transcode.optional(c.projectIcon), faviconPath: c.faviconPath, defaultThreadEnvMode: c.defaultThreadEnvMode,
              scripts: c.scripts.flatMap { Transcode.value($0) })))
      ]
    case .threadPullRequestLink, .threadPullRequestUnlink, .unknown:
      throw .rejected(message: "This action is not available for this environment.")
    }
  }

  private static func meta(_ id: CommandId) -> CommandMeta { CommandMeta(commandId: id, createdAt: IsoDateTime(date: Date())) }

  private static func attachment(_ item: V1.ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem) throws(CommandError) -> ChatAttachment {
    switch item {
    case .chatImageAttachment(let image): .image(image)
    case .chatFileAttachment(let file): .file(file)
    case .chatUnknownAttachment(let other): .other(other)
    case .option1, .unknown: throw .rejected(message: "This attachment has not been uploaded.")
    }
  }

  private static func userInputAttachments(
    _ value: [String: [V1.ClientOrchestrationCommandThreadUserInputRespondAttachmentsByQuestionIdValueItem]]
  ) -> [String: [OrchestrationV2CommandRuntimeRequestRespondAttachmentsByQuestionIdValueItem]]? {
    let bridged = value.compactMapValues { items -> [OrchestrationV2CommandRuntimeRequestRespondAttachmentsByQuestionIdValueItem]? in
      let converted = items.compactMap { ShellPresentation.bridge($0) as OrchestrationV2CommandRuntimeRequestRespondAttachmentsByQuestionIdValueItem? }
      return converted.isEmpty ? nil : converted
    }
    return bridged.isEmpty ? nil : bridged
  }

  /// The first message of a draft launches the thread; any other message is a plain dispatch.
  private static func turnStart(_ c: V1.ClientOrchestrationCommandThreadTurnStart) throws(CommandError) -> V2Step {
    var attachments: [ChatAttachment] = []
    for item in c.message.attachments { attachments.append(try attachment(item)) }
    if let bootstrap = c.bootstrap, bootstrap.createThread != nil || bootstrap.prepareWorktree != nil {
      guard let thread = bootstrap.createThread else {
        throw .rejected(message: "Preparing a worktree for an existing thread is not supported by this environment yet.")
      }
      let strategy: OrchestrationV2ThreadLaunchWorkspaceStrategy2
      if let prepare = bootstrap.prepareWorktree {
        strategy = .worktree(.init(baseRef: prepare.baseBranch, branch: prepare.branch, startFromOrigin: prepare.startFromOrigin))
      } else if let path = thread.worktreePath {
        strategy = .existingWorktree(.init(worktreePath: path, branch: thread.branch))
      } else {
        strategy = .root(.init(branch: thread.branch))
      }
      return .launch(
        OrchestrationV2ThreadLaunchInput(
          commandId: c.commandId, creationSource: ThreadCommandV2.creationSource, threadId: c.threadId, projectId: thread.projectId,
          title: c.titleSeed ?? thread.title, generateTitle: c.titleSeed != nil, modelSelection: c.modelSelection ?? thread.modelSelection,
          runtimeMode: c.runtimeMode, interactionMode: c.interactionMode, workspaceStrategy: strategy,
          initialMessage: OrchestrationV2ThreadLaunchInputInitialMessage(
            messageId: c.message.messageId, text: c.message.text, context: c.message.context, attachments: attachments)))
    }
    return .command(
      ThreadCommandV2.send(
        c.threadId, messageId: c.message.messageId, text: c.message.text, attachments: attachments, context: c.message.context, delivery: .auto,
        titleSeed: c.titleSeed, modelSelection: c.modelSelection,
        sourcePlan: c.sourceProposedPlan.map { OrchestrationV2CommandMessageDispatchSourcePlanRef(threadId: $0.threadId, planId: PlanId(rawValue: $0.planId)) },
        meta: meta(c.commandId)))
  }
}
