import Foundation
import T3Contracts

/// Identity and timestamp of one dispatch. `commandId` is a UUIDv4; the server uses it to make
/// retries of the same command idempotent, so retry with the same `CommandMeta`.
public struct CommandMeta: Sendable, Equatable {
  public var commandId: CommandId
  public var createdAt: IsoDateTime

  public init(commandId: CommandId, createdAt: IsoDateTime) {
    self.commandId = commandId
    self.createdAt = createdAt
  }

  public static func fresh(clock: any RuntimeClock = SystemClock()) -> CommandMeta {
    CommandMeta(commandId: CommandId(rawValue: UUID().uuidString.lowercased()), createdAt: clock.nowISO())
  }
}

/// Typed builders for the orchestration commands a client dispatches
/// (`operations/commands.ts`). They only build values; dispatch and optimistic updates live in
/// `EnvironmentRuntime`.
public enum ThreadCommand {
  public static func create(
    threadId: ThreadId, projectId: ProjectId, title: String, modelSelection: ModelSelection, runtimeMode: RuntimeMode,
    interactionMode: ProviderInteractionMode = .default, branch: String? = nil, worktreePath: String? = nil, meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .threadCreate(
      V1.ClientOrchestrationCommandThreadCreate(
        commandId: meta.commandId, threadId: threadId, projectId: projectId, title: title, modelSelection: modelSelection,
        runtimeMode: runtimeMode, interactionMode: ProviderInteractionMode(rawValue: interactionMode.rawValue),
        branch: branch, worktreePath: worktreePath, createdAt: meta.createdAt))
  }

  public static func delete(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadDelete(V1.ClientOrchestrationCommandThreadDelete(commandId: meta.commandId, threadId: threadId))
  }
  public static func archive(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadArchive(V1.ClientOrchestrationCommandThreadArchive(commandId: meta.commandId, threadId: threadId))
  }
  public static func unarchive(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadUnarchive(V1.ClientOrchestrationCommandThreadUnarchive(commandId: meta.commandId, threadId: threadId))
  }
  public static func settle(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadSettle(V1.ClientOrchestrationCommandThreadSettle(commandId: meta.commandId, threadId: threadId))
  }
  public static func unsettle(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadUnsettle(V1.ClientOrchestrationCommandThreadUnsettle(commandId: meta.commandId, threadId: threadId))
  }
  public static func snooze(_ threadId: ThreadId, until: IsoDateTime, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadSnooze(V1.ClientOrchestrationCommandThreadSnooze(commandId: meta.commandId, threadId: threadId, snoozedUntil: until))
  }
  public static func unsnooze(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadUnsnooze(V1.ClientOrchestrationCommandThreadUnsnooze(commandId: meta.commandId, threadId: threadId))
  }
  public static func pin(_ threadId: ThreadId, orderKey: String? = nil, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadPin(V1.ClientOrchestrationCommandThreadPin(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  public static func unpin(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadUnpin(V1.ClientOrchestrationCommandThreadUnpin(commandId: meta.commandId, threadId: threadId))
  }
  public static func reorderPinned(_ threadId: ThreadId, orderKey: String, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadPinReorder(V1.ClientOrchestrationCommandThreadPinReorder(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  public static func reorderActive(_ threadId: ThreadId, orderKey: String, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadActiveReorder(V1.ClientOrchestrationCommandThreadActiveReorder(commandId: meta.commandId, threadId: threadId, orderKey: orderKey))
  }
  /// `enabled == false` opts the thread out of auto-settling.
  public static func setAutoSettle(_ threadId: ThreadId, enabled: Bool, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadAutoSettleSet(V1.ClientOrchestrationCommandThreadAutoSettleSet(commandId: meta.commandId, threadId: threadId, enabled: enabled))
  }
  /// Rename (`title`), or ask the server to regenerate the title.
  public static func updateMetadata(
    _ threadId: ThreadId, title: String? = nil, regenerateTitle: Bool? = nil, modelSelection: ModelSelection? = nil, meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .threadMetaUpdate(
      V1.ClientOrchestrationCommandThreadMetaUpdate(
        commandId: meta.commandId, threadId: threadId, title: title, regenerateTitle: regenerateTitle, modelSelection: modelSelection))
  }
  public static func setRuntimeMode(_ threadId: ThreadId, _ mode: RuntimeMode, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadRuntimeModeSet(V1.ClientOrchestrationCommandThreadRuntimeModeSet(commandId: meta.commandId, threadId: threadId, runtimeMode: mode, createdAt: meta.createdAt))
  }
  public static func setInteractionMode(_ threadId: ThreadId, _ mode: ProviderInteractionMode, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadInteractionModeSet(
      V1.ClientOrchestrationCommandThreadInteractionModeSet(commandId: meta.commandId, threadId: threadId, interactionMode: mode, createdAt: meta.createdAt))
  }
  public static func startTurn(
    _ threadId: ThreadId, message: V1.ClientOrchestrationCommandThreadTurnStartMessage, runtimeMode: RuntimeMode,
    interactionMode: ProviderInteractionMode, modelSelection: ModelSelection? = nil, titleSeed: String? = nil,
    bootstrap: V1.ClientOrchestrationCommandThreadTurnStartBootstrap? = nil,
    sourceProposedPlan: V1.ClientOrchestrationCommandThreadTurnStartSourceProposedPlan? = nil, meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .threadTurnStart(
      V1.ClientOrchestrationCommandThreadTurnStart(
        commandId: meta.commandId, threadId: threadId, message: message, modelSelection: modelSelection, titleSeed: titleSeed,
        runtimeMode: runtimeMode, interactionMode: interactionMode, bootstrap: bootstrap, sourceProposedPlan: sourceProposedPlan,
        createdAt: meta.createdAt))
  }
  public static func interruptTurn(_ threadId: ThreadId, turnId: V1.TurnId? = nil, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadTurnInterrupt(V1.ClientOrchestrationCommandThreadTurnInterrupt(commandId: meta.commandId, threadId: threadId, turnId: turnId, createdAt: meta.createdAt))
  }
  public static func respondToApproval(
    _ threadId: ThreadId, requestId: V1.ApprovalRequestId, decision: ProviderApprovalDecision, meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .threadApprovalRespond(
      V1.ClientOrchestrationCommandThreadApprovalRespond(commandId: meta.commandId, threadId: threadId, requestId: requestId, decision: decision, createdAt: meta.createdAt))
  }
  public static func respondToUserInput(
    _ threadId: ThreadId, requestId: V1.ApprovalRequestId, answers: [String: JSONValue], meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .threadUserInputRespond(
      V1.ClientOrchestrationCommandThreadUserInputRespond(commandId: meta.commandId, threadId: threadId, requestId: requestId, answers: answers, createdAt: meta.createdAt))
  }
  public static func dismissUserInput(_ threadId: ThreadId, requestId: V1.ApprovalRequestId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadUserInputDismiss(
      V1.ClientOrchestrationCommandThreadUserInputDismiss(commandId: meta.commandId, threadId: threadId, requestId: requestId, createdAt: meta.createdAt))
  }
  /// `restoreFiles == false` reverts only the conversation (`thread.conversation.revert`).
  public static func revert(_ threadId: ThreadId, toTurnCount turnCount: Int, restoreFiles: Bool = true, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    restoreFiles
      ? .threadCheckpointRevert(V1.ClientOrchestrationCommandThreadCheckpointRevert(commandId: meta.commandId, threadId: threadId, turnCount: turnCount, createdAt: meta.createdAt))
      : .threadConversationRevert(V1.ClientOrchestrationCommandThreadConversationRevert(commandId: meta.commandId, threadId: threadId, turnCount: turnCount, createdAt: meta.createdAt))
  }
  public static func stopSession(_ threadId: ThreadId, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .threadSessionStop(V1.ClientOrchestrationCommandThreadSessionStop(commandId: meta.commandId, threadId: threadId, createdAt: meta.createdAt))
  }
}
