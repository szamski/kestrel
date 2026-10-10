import Foundation
import T3Contracts
import T3Protocol

/// Command methods of the UI-facing runtime. Each builds a typed command, dispatches it through
/// `orchestration.dispatchCommand` on the owning environment and, for the lifecycle commands the web
/// client applies optimistically, shows the change at once and rolls it back if the dispatch fails.
/// Nothing is retried automatically: a thrown `CommandError.transport` means the outcome is unknown.
extension ClientRuntime {
  @discardableResult
  private func dispatch(
    _ command: V1.ClientOrchestrationCommand, on environmentId: EnvironmentId, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> V1.DispatchResult {
    guard let runtime = await registry.runtime(for: environmentId) else {
      throw .notConnected(environment: environmentId.rawValue)
    }
    return try await runtime.dispatch(command, thread: thread, optimistic: optimistic)
  }

  @discardableResult
  private func dispatch(
    _ command: OrchestrationV2Command, on environmentId: EnvironmentId, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> Int {
    guard let runtime = await registry.runtime(for: environmentId) else {
      throw .notConnected(environment: environmentId.rawValue)
    }
    return try await runtime.dispatch(command, thread: thread, optimistic: optimistic)
  }

  /// The wire protocol of an environment's live connection; nil while it is not connected.
  public func orchestrationProtocol(_ environmentId: EnvironmentId) async -> OrchestrationProtocol? {
    await registry.runtime(for: environmentId)?.orchestrationProtocol
  }

  // MARK: Thread lifecycle

  /// Creates an empty thread in `projectId` and returns its id (generated here, like the web client).
  @discardableResult
  public func createThread(
    environmentId: EnvironmentId, projectId: ProjectId, title: String, modelSelection: ModelSelection, runtimeMode: RuntimeMode = .fullAccess,
    interactionMode: ProviderInteractionMode = .default, branch: String? = nil, worktreePath: String? = nil
  ) async throws(CommandError) -> ThreadId {
    let threadId = ThreadId(rawValue: UUID().uuidString.lowercased())
    try await dispatch(
      ThreadCommand.create(
        threadId: threadId, projectId: projectId, title: title, modelSelection: modelSelection, runtimeMode: runtimeMode,
        interactionMode: interactionMode, branch: branch, worktreePath: worktreePath, meta: .fresh(clock: clock)),
      on: environmentId, thread: threadId)
    return threadId
  }

  public func deleteThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.delete(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func archiveThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.archive(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func unarchiveThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.unarchive(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }

  public func settleThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.settle(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId, optimistic: .settle)
  }
  public func unsettleThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.unsettle(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId, optimistic: .unsettle)
  }

  public func snoozeThread(_ key: ScopedThreadKey, until: IsoDateTime) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.snooze(key.threadId, until: until, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId,
      optimistic: .snooze(until: until))
  }
  public func snoozeThread(_ key: ScopedThreadKey, preset: ThreadSettled.Preset) async throws(CommandError) {
    try await snoozeThread(key, until: preset.snoozedUntil)
  }
  /// "Pick a date" / "In N minutes": rejects times in the past and invalid input before any round trip.
  public func snoozeThread(_ key: ScopedThreadKey, custom: ThreadSettled.CustomSnoozeInput, calendar: Calendar = .current) async throws(CommandError) {
    guard let until = ThreadSettled.resolveCustomSnooze(custom, now: Date(timeIntervalSince1970: Double(clock.nowMilliseconds()) / 1000), calendar: calendar) else {
      throw .rejected(message: "Choose a snooze time in the future.")
    }
    try await snoozeThread(key, until: until)
  }
  /// The snooze menu entries for "now" (hour, three hours, evening, tomorrow, next week).
  public func snoozePresets(calendar: Calendar = .current) -> [ThreadSettled.Preset] {
    ThreadSettled.resolveSnoozePresets(now: Date(timeIntervalSince1970: Double(clock.nowMilliseconds()) / 1000), calendar: calendar)
  }
  public func unsnoozeThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.unsnooze(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId, optimistic: .unsnooze)
  }

  public func pinThread(_ key: ScopedThreadKey, orderKey: String? = nil) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.pin(key.threadId, orderKey: orderKey, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId,
      optimistic: .pin(orderKey: orderKey))
  }
  public func unpinThread(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.unpin(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId, optimistic: .unpin)
  }
  public func reorderPinnedThread(_ key: ScopedThreadKey, orderKey: String) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.reorderPinned(key.threadId, orderKey: orderKey, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId,
      optimistic: .reorderPinned(orderKey: orderKey))
  }
  public func reorderActiveThread(_ key: ScopedThreadKey, orderKey: String) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.reorderActive(key.threadId, orderKey: orderKey, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId,
      optimistic: .reorderActive(orderKey: orderKey))
  }

  /// Moves a pinned thread one step; the key plan writes one thread (or the section when keys are missing).
  public func movePinnedThread(_ key: ScopedThreadKey, up: Bool) async throws(CommandError) {
    let pinned = sidebar.pinned
    let ids = pinned.map(\.id)
    var keys: [String: String?] = [:]
    for row in pinned { keys[row.id] = .some(optionalValue(row.thread.shell.pinOrderKey)) }
    guard let plan = ThreadSort.planPinnedMove(orderedIds: ids, keysById: keys, movedId: key.description, up: up) else { return }
    for assignment in plan {
      guard let target = pinned.first(where: { $0.id == assignment.id })?.thread else { continue }
      try await reorderPinnedThread(target.key, orderKey: assignment.orderKey)
    }
  }

  /// `enabled == false` keeps the server from auto-settling this thread.
  public func setAutoSettle(_ key: ScopedThreadKey, enabled: Bool) async throws(CommandError) {
    try await dispatch(ThreadCommand.setAutoSettle(key.threadId, enabled: enabled, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }

  public func renameThread(_ key: ScopedThreadKey, title: String) async throws(CommandError) {
    try await dispatch(ThreadCommand.updateMetadata(key.threadId, title: title, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }

  // MARK: Turns

  /// Sends a user message and starts a turn. `runtimeMode` and `interactionMode` default to the thread's current ones.
  /// On a protocol-2 environment `delivery` decides what happens while a run is active: the server steers, queues or
  /// restarts (`.auto` lets it decide).
  @discardableResult
  public func sendMessage(
    _ key: ScopedThreadKey, text: String, attachments: [UploadedAttachment] = [], runtimeMode: RuntimeMode? = nil,
    interactionMode: ProviderInteractionMode? = nil, modelSelection: ModelSelection? = nil, titleSeed: String? = nil,
    sourceProposedPlan: V1.ClientOrchestrationCommandThreadTurnStartSourceProposedPlan? = nil, delivery: SendDelivery = .auto
  ) async throws(CommandError) -> MessageId {
    let shell = threadShell(key)?.shell
    let messageId = MessageId(rawValue: UUID().uuidString.lowercased())
    if await orchestrationProtocol(key.environmentId) == .v2 {
      // Protocol 2 has no modes on the message: change them first, as the web composer does.
      if let runtimeMode, runtimeMode != shell?.runtimeMode { try await setRuntimeMode(key, runtimeMode) }
      if let interactionMode, interactionMode.rawValue != shell?.interactionMode.rawValue { try await setInteractionMode(key, interactionMode) }
      try await dispatch(
        ThreadCommandV2.send(
          key.threadId, messageId: messageId, text: text, attachments: attachments.map(\.chatAttachment), delivery: delivery, titleSeed: titleSeed,
          modelSelection: modelSelection,
          sourcePlan: sourceProposedPlan.map { OrchestrationV2CommandMessageDispatchSourcePlanRef(threadId: $0.threadId, planId: PlanId(rawValue: $0.planId)) },
          meta: .fresh(clock: clock)),
        on: key.environmentId, thread: key.threadId)
      return messageId
    }
    let message = V1.ClientOrchestrationCommandThreadTurnStartMessage(
      messageId: messageId, text: text, attachments: attachments.map(\.messageAttachment))
    try await dispatch(
      ThreadCommand.startTurn(
        key.threadId, message: message, runtimeMode: runtimeMode ?? shell?.runtimeMode ?? .fullAccess,
        interactionMode: interactionMode ?? shell.map { ProviderInteractionMode(rawValue: $0.interactionMode.rawValue) } ?? .default,
        modelSelection: modelSelection, titleSeed: titleSeed, sourceProposedPlan: sourceProposedPlan, meta: .fresh(clock: clock)),
      on: key.environmentId, thread: key.threadId)
    return messageId
  }

  // MARK: Queue and rollback (protocol 2)

  /// Hands a queued message to the active run (it joins the turn instead of waiting behind it).
  public func steerQueuedMessage(_ key: ScopedThreadKey, runId: RunId, into targetRunId: RunId) async throws(CommandError) {
    try await dispatch(
      ThreadCommandV2.promoteQueuedToSteer(key.threadId, queuedRunId: runId, targetRunId: targetRunId, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }
  /// Replaces a queued message's text; `attachments == nil` keeps its attachments.
  public func editQueuedMessage(
    _ key: ScopedThreadKey, runId: RunId, text: String, attachments: [UploadedAttachment]? = nil, context: OrchestrationMessageContext? = nil
  ) async throws(CommandError) {
    try await dispatch(
      ThreadCommandV2.editQueued(
        key.threadId, runId: runId, text: text, attachments: attachments?.map(\.chatAttachment), context: context, meta: .fresh(clock: clock)),
      on: key.environmentId, thread: key.threadId)
  }
  /// Moves a queued message in front of `beforeRunId` (nil moves it to the end).
  public func reorderQueuedMessage(_ key: ScopedThreadKey, runId: RunId, before beforeRunId: RunId?) async throws(CommandError) {
    try await dispatch(
      ThreadCommandV2.reorderQueued(key.threadId, runId: runId, before: beforeRunId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func cancelQueuedMessage(_ key: ScopedThreadKey, runId: RunId) async throws(CommandError) {
    try await dispatch(ThreadCommandV2.cancelQueued(key.threadId, runId: runId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  /// Releases a queue that Stop held.
  public func resumeQueue(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommandV2.resumeQueue(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  /// Puts a run whose workspace preparation failed back into preparation.
  public func retryWorkspacePreparation(_ key: ScopedThreadKey, runId: RunId) async throws(CommandError) {
    try await dispatch(ThreadCommandV2.retryPreparedRun(key.threadId, runId: runId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  /// Rolls the thread back to a ready checkpoint of its projection; `restoreFiles == false` reverts only the conversation.
  public func rollbackThread(_ key: ScopedThreadKey, to checkpoint: OrchestrationV2Checkpoint, restoreFiles: Bool = true) async throws(CommandError) {
    try await dispatch(
      ThreadCommandV2.rollback(key.threadId, scopeId: checkpoint.scopeId, checkpointId: checkpoint.id, restoreFiles: restoreFiles, meta: .fresh(clock: clock)),
      on: key.environmentId, thread: key.threadId)
  }
  /// Answers a user-input request, with attachments per question (protocol 2).
  public func respondToUserInput(
    _ key: ScopedThreadKey, requestId: V1.ApprovalRequestId, answers: [String: JSONValue], attachmentsByQuestionId: [String: [UploadedAttachment]]
  ) async throws(CommandError) {
    let attachments = attachmentsByQuestionId.mapValues { items in
      items.compactMap { item -> OrchestrationV2CommandRuntimeRequestRespondAttachmentsByQuestionIdValueItem? in
        switch item.chatAttachment {
        case .image(let image): .image(image)
        case .file(let file): .file(file)
        default: nil
        }
      }
    }
    try await dispatch(
      ThreadCommandV2.respondToUserInput(
        key.threadId, requestId: RuntimeRequestId(rawValue: requestId.rawValue), answers: answers, attachmentsByQuestionId: attachments, meta: .fresh(clock: clock)),
      on: key.environmentId, thread: key.threadId)
  }

  public func interruptTurn(_ key: ScopedThreadKey, turnId: V1.TurnId? = nil) async throws(CommandError) {
    try await dispatch(ThreadCommand.interruptTurn(key.threadId, turnId: turnId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func stopSession(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.stopSession(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func respondToApproval(_ key: ScopedThreadKey, requestId: V1.ApprovalRequestId, decision: ProviderApprovalDecision) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.respondToApproval(key.threadId, requestId: requestId, decision: decision, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }
  public func respondToUserInput(_ key: ScopedThreadKey, requestId: V1.ApprovalRequestId, answers: [String: JSONValue]) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.respondToUserInput(key.threadId, requestId: requestId, answers: answers, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }
  public func dismissUserInput(_ key: ScopedThreadKey, requestId: V1.ApprovalRequestId) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.dismissUserInput(key.threadId, requestId: requestId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func setInteractionMode(_ key: ScopedThreadKey, _ mode: ProviderInteractionMode) async throws(CommandError) {
    try await dispatch(ThreadCommand.setInteractionMode(key.threadId, mode, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func setRuntimeMode(_ key: ScopedThreadKey, _ mode: RuntimeMode) async throws(CommandError) {
    try await dispatch(ThreadCommand.setRuntimeMode(key.threadId, mode, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  /// Reverts to the state after `turnCount` turns; `restoreFiles == false` reverts only the conversation.
  public func revertThread(_ key: ScopedThreadKey, toTurnCount turnCount: Int, restoreFiles: Bool = true) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.revert(key.threadId, toTurnCount: turnCount, restoreFiles: restoreFiles, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }

  // MARK: Attachments

  /// Uploads bytes for the next `sendMessage`. Cancelling the calling task deletes the pending upload it created.
  public func uploadAttachment(environmentId: EnvironmentId, data: Data, name: String, mimeType: String) async throws(AttachmentUploadError) -> UploadedAttachment {
    guard let runtime = await registry.runtime(for: environmentId) else { throw .notConnected }
    return try await runtime.uploadAttachment(data: data, name: name, mimeType: mimeType)
  }

  /// Discards an uploaded attachment the user removed before sending.
  public func discardAttachment(environmentId: EnvironmentId, attachmentId: String) async {
    await registry.runtime(for: environmentId)?.deletePendingAttachment(attachmentId)
  }
}
