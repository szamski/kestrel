import Foundation
import T3Contracts

/// How a message sent while a run is active is delivered (`StartThreadTurnInput.dispatchMode` in
/// client-runtime `operations/commands.ts`). The server resolves `auto` against its own serialized thread state.
public enum SendDelivery: Sendable, Equatable {
  /// Starts a run, or steers/queues the message when one is active, as the server decides.
  case auto
  /// Hands the message to the active run.
  case steer
  /// Interrupts the active run and restarts it with the message.
  case restart
  /// Holds the message in the server-side queue behind the active run.
  case queue
  /// Starts a run now, never steering; `continuing` resumes a stopped run.
  case start(continuing: RunId? = nil)
}

/// Typed builders for the protocol-2 commands a client dispatches (`operations/commands.ts`). They only
/// build values; dispatch and optimistic updates live in `EnvironmentRuntime`.
public enum ThreadCommandV2 {
  /// Commands this client creates are attributed to the web surface: the contract has no desktop source.
  static let creationSource = OrchestrationV2CreationSource.web

  // MARK: Lifecycle

  public static func create(
    threadId: ThreadId, projectId: ProjectId, title: String, modelSelection: ModelSelection, runtimeMode: RuntimeMode,
    interactionMode: ProviderInteractionMode, branch: String? = nil, worktreePath: String? = nil, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .threadCreate(
      OrchestrationV2CommandThreadCreate(
        createdBy: .user, creationSource: creationSource, commandId: meta.commandId, threadId: threadId, projectId: projectId, title: title,
        modelSelection: modelSelection, runtimeMode: runtimeMode, interactionMode: interactionMode, branch: branch, worktreePath: worktreePath))
  }
  public static func delete(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadDelete(OrchestrationV2CommandThreadDelete(commandId: meta.commandId, threadId: threadId))
  }
  public static func archive(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadArchive(OrchestrationV2CommandThreadArchive(commandId: meta.commandId, threadId: threadId))
  }
  public static func unarchive(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadUnarchive(OrchestrationV2CommandThreadUnarchive(commandId: meta.commandId, threadId: threadId))
  }
  public static func settle(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadSettle(OrchestrationV2CommandThreadSettle(commandId: meta.commandId, threadId: threadId))
  }
  public static func unsettle(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadUnsettle(OrchestrationV2CommandThreadUnsettle(commandId: meta.commandId, threadId: threadId))
  }
  public static func snooze(_ threadId: ThreadId, until: IsoDateTime, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadSnooze(OrchestrationV2CommandThreadSnooze(commandId: meta.commandId, threadId: threadId, snoozedUntil: until))
  }
  public static func unsnooze(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadUnsnooze(OrchestrationV2CommandThreadUnsnooze(commandId: meta.commandId, threadId: threadId))
  }
  public static func pin(_ threadId: ThreadId, orderKey: String? = nil, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadPin(OrchestrationV2CommandThreadPin(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  public static func unpin(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadUnpin(OrchestrationV2CommandThreadUnpin(commandId: meta.commandId, threadId: threadId))
  }
  public static func reorderPinned(_ threadId: ThreadId, orderKey: String, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadPinReorder(OrchestrationV2CommandThreadPinReorder(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  public static func reorderActive(_ threadId: ThreadId, orderKey: String, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadActiveReorder(OrchestrationV2CommandThreadActiveReorder(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  public static func setAutoSettle(_ threadId: ThreadId, enabled: Bool, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadAutoSettleSet(OrchestrationV2CommandThreadAutoSettleSet(commandId: meta.commandId, threadId: threadId, enabled: enabled))
  }
  /// The server-tracked visited watermark (`lastVisitedAt` on the shell).
  public static func visit(_ threadId: ThreadId, at visitedAt: IsoDateTime, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadVisit(OrchestrationV2CommandThreadVisit(commandId: meta.commandId, threadId: threadId, visitedAt: visitedAt))
  }
  public static func markUnread(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadMarkUnread(OrchestrationV2CommandThreadMarkUnread(commandId: meta.commandId, threadId: threadId))
  }
  /// Rename (`title`), or ask the server to regenerate the title.
  public static func updateMetadata(
    _ threadId: ThreadId, title: String? = nil, regenerateTitle: Bool? = nil, branch: String?? = nil, worktreePath: String?? = nil,
    linkedPullRequest: ThreadLinkedPullRequest?? = nil, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .threadMetadataUpdate(
      OrchestrationV2CommandThreadMetadataUpdate(
        commandId: meta.commandId, threadId: threadId, title: title, regenerateTitle: regenerateTitle, branch: branch, worktreePath: worktreePath,
        linkedPullRequest: linkedPullRequest))
  }
  public static func linkPullRequest(
    _ threadId: ThreadId, host: String, repository: String, number: Int, url: String, source: ThreadPullRequestLinkSource = .manual, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .threadPullRequestLink(
      OrchestrationV2CommandThreadPullRequestLink(
        commandId: meta.commandId, threadId: threadId, host: host, repository: repository, number: number, url: url, source: source))
  }
  public static func unlinkPullRequest(_ threadId: ThreadId, host: String, repository: String, number: Int, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadPullRequestUnlink(
      OrchestrationV2CommandThreadPullRequestUnlink(commandId: meta.commandId, threadId: threadId, host: host, repository: repository, number: number))
  }
  public static func setModelSelection(_ threadId: ThreadId, _ selection: ModelSelection, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadModelSelectionSet(OrchestrationV2CommandThreadModelSelectionSet(commandId: meta.commandId, threadId: threadId, modelSelection: selection))
  }
  public static func setRuntimeMode(_ threadId: ThreadId, _ mode: RuntimeMode, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadRuntimeModeSet(OrchestrationV2CommandThreadRuntimeModeSet(commandId: meta.commandId, threadId: threadId, runtimeMode: mode))
  }
  public static func setInteractionMode(_ threadId: ThreadId, _ mode: ProviderInteractionMode, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadInteractionModeSet(OrchestrationV2CommandThreadInteractionModeSet(commandId: meta.commandId, threadId: threadId, interactionMode: mode))
  }
  public static func detachProviderSession(_ threadId: ThreadId, sessionId: ProviderSessionId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .providerSessionDetach(
      OrchestrationV2CommandProviderSessionDetach(commandId: meta.commandId, threadId: threadId, providerSessionId: sessionId, reason: "client-requested"))
  }

  // MARK: Messages and runs

  /// `message.dispatch`. A `titleSeed` seeds the temporary title and has the server generate a durable one.
  public static func send(
    _ threadId: ThreadId, messageId: MessageId, text: String, attachments: [ChatAttachment] = [], context: OrchestrationMessageContext? = nil,
    delivery: SendDelivery = .auto, titleSeed: String? = nil, modelSelection: ModelSelection? = nil,
    sourcePlan: OrchestrationV2CommandMessageDispatchSourcePlanRef? = nil, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    let mode: OrchestrationV2CommandMessageDispatchDispatchMode
    var intent: OrchestrationV2CommandMessageDispatchDeliveryIntent?
    var continuing: RunId?
    switch delivery {
    case .auto:
      mode = .startImmediately
      intent = .auto
    case .steer:
      mode = .startImmediately
      intent = .steer
    case .restart:
      mode = .startImmediately
      intent = .restart
    case .queue:
      mode = .queueAfterActive
    case .start(let run):
      mode = .startImmediately
      continuing = run
    }
    return .messageDispatch(
      OrchestrationV2CommandMessageDispatch(
        createdBy: .user, creationSource: creationSource, commandId: meta.commandId, threadId: threadId, messageId: messageId, text: text,
        context: context, attachments: attachments, titleSeed: titleSeed, modelSelection: modelSelection, sourcePlanRef: sourcePlan,
        manualContinuationOfRunId: continuing, deliveryIntent: intent, dispatchMode: mode))
  }

  /// Stop: interrupts the run and holds the queue so queued messages do not start behind it.
  public static func interrupt(_ threadId: ThreadId, runId: RunId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .runInterrupt(OrchestrationV2CommandRunInterrupt(commandId: meta.commandId, threadId: threadId, runId: runId, holdQueue: true))
  }
  public static func promoteQueuedToSteer(_ threadId: ThreadId, queuedRunId: RunId, targetRunId: RunId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .queuedMessagePromoteToSteer(
      OrchestrationV2CommandQueuedMessagePromoteToSteer(commandId: meta.commandId, threadId: threadId, queuedRunId: queuedRunId, targetRunId: targetRunId))
  }
  public static func resumeQueue(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .queueResume(OrchestrationV2CommandQueueResume(commandId: meta.commandId, threadId: threadId))
  }
  /// Moves a queued run in front of `beforeRunId` (nil moves it to the end).
  public static func reorderQueued(_ threadId: ThreadId, runId: RunId, before beforeRunId: RunId?, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .queuedRunReorder(OrchestrationV2CommandQueuedRunReorder(commandId: meta.commandId, threadId: threadId, runId: runId, beforeRunId: beforeRunId))
  }
  public static func cancelQueued(_ threadId: ThreadId, runId: RunId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .queuedRunCancel(OrchestrationV2CommandQueuedRunCancel(commandId: meta.commandId, threadId: threadId, runId: runId))
  }
  /// `attachments == nil` is a text-only edit that leaves the attachments untouched.
  public static func editQueued(
    _ threadId: ThreadId, runId: RunId, text: String, attachments: [ChatAttachment]? = nil, context: OrchestrationMessageContext? = nil,
    meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .queuedRunEdit(
      OrchestrationV2CommandQueuedRunEdit(
        context: attachments == nil ? nil : context, commandId: meta.commandId, threadId: threadId, runId: runId, text: text, attachments: attachments))
  }
  public static func retryPreparedRun(_ threadId: ThreadId, runId: RunId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .preparedRunRetry(OrchestrationV2CommandPreparedRunRetry(commandId: meta.commandId, threadId: threadId, runId: runId))
  }

  // MARK: Runtime requests

  public static func respondToApproval(
    _ threadId: ThreadId, requestId: RuntimeRequestId, decision: ProviderApprovalDecision, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .runtimeRequestRespond(OrchestrationV2CommandRuntimeRequestRespond(commandId: meta.commandId, threadId: threadId, requestId: requestId, decision: decision))
  }
  public static func respondToUserInput(
    _ threadId: ThreadId, requestId: RuntimeRequestId, answers: [String: JSONValue],
    attachmentsByQuestionId: [String: [OrchestrationV2CommandRuntimeRequestRespondAttachmentsByQuestionIdValueItem]]? = nil, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .runtimeRequestRespond(
      OrchestrationV2CommandRuntimeRequestRespond(
        commandId: meta.commandId, threadId: threadId, requestId: requestId, answers: answers,
        attachmentsByQuestionId: attachmentsByQuestionId?.isEmpty == true ? nil : attachmentsByQuestionId))
  }
  public static func dismissUserInput(_ threadId: ThreadId, requestId: RuntimeRequestId, meta: CommandMeta = .fresh()) -> OrchestrationV2Command {
    .threadUserInputDismiss(OrchestrationV2CommandThreadUserInputDismiss(commandId: meta.commandId, threadId: threadId, requestId: requestId))
  }

  // MARK: Rollback

  /// Rolls the thread back to a ready checkpoint; `restoreFiles == false` reverts only the conversation.
  public static func rollback(
    _ threadId: ThreadId, scopeId: CheckpointScopeId, checkpointId: CheckpointId, restoreFiles: Bool = true, meta: CommandMeta = .fresh()
  ) -> OrchestrationV2Command {
    .checkpointRollback(
      OrchestrationV2CommandCheckpointRollback(restoreFiles: restoreFiles, commandId: meta.commandId, threadId: threadId, scopeId: scopeId, checkpointId: checkpointId))
  }
}
