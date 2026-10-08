import Foundation
import T3Contracts

/// Command methods of the UI-facing runtime. Each builds a typed command, dispatches it through
/// `orchestration.dispatchCommand` on the owning environment and, for the lifecycle commands the web
/// client applies optimistically, shows the change at once and rolls it back if the dispatch fails.
/// Nothing is retried automatically: a thrown `CommandError.transport` means the outcome is unknown.
extension ClientRuntime {
  @discardableResult
  private func dispatch(
    _ command: ClientOrchestrationCommand, on environmentId: EnvironmentId, thread: ThreadId? = nil, optimistic: OptimisticAction? = nil
  ) async throws(CommandError) -> DispatchResult {
    guard let runtime = await registry.runtime(for: environmentId) else {
      throw .notConnected(environment: environmentId.rawValue)
    }
    return try await runtime.dispatch(command, thread: thread, optimistic: optimistic)
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
  @discardableResult
  public func sendMessage(
    _ key: ScopedThreadKey, text: String, attachments: [UploadedAttachment] = [], runtimeMode: RuntimeMode? = nil,
    interactionMode: ProviderInteractionMode? = nil, modelSelection: ModelSelection? = nil, titleSeed: String? = nil,
    sourceProposedPlan: ClientOrchestrationCommandThreadTurnStartSourceProposedPlan? = nil
  ) async throws(CommandError) -> MessageId {
    let shell = threadShell(key)?.shell
    let messageId = MessageId(rawValue: UUID().uuidString.lowercased())
    let message = ClientOrchestrationCommandThreadTurnStartMessage(
      messageId: messageId, text: text, attachments: attachments.map(\.messageAttachment))
    try await dispatch(
      ThreadCommand.startTurn(
        key.threadId, message: message, runtimeMode: runtimeMode ?? shell?.runtimeMode ?? .fullAccess,
        interactionMode: interactionMode ?? shell.map { ProviderInteractionMode(rawValue: $0.interactionMode.rawValue) } ?? .default,
        modelSelection: modelSelection, titleSeed: titleSeed, sourceProposedPlan: sourceProposedPlan, meta: .fresh(clock: clock)),
      on: key.environmentId, thread: key.threadId)
    return messageId
  }

  public func interruptTurn(_ key: ScopedThreadKey, turnId: TurnId? = nil) async throws(CommandError) {
    try await dispatch(ThreadCommand.interruptTurn(key.threadId, turnId: turnId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func stopSession(_ key: ScopedThreadKey) async throws(CommandError) {
    try await dispatch(ThreadCommand.stopSession(key.threadId, meta: .fresh(clock: clock)), on: key.environmentId, thread: key.threadId)
  }
  public func respondToApproval(_ key: ScopedThreadKey, requestId: ApprovalRequestId, decision: ProviderApprovalDecision) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.respondToApproval(key.threadId, requestId: requestId, decision: decision, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }
  public func respondToUserInput(_ key: ScopedThreadKey, requestId: ApprovalRequestId, answers: [String: JSONValue]) async throws(CommandError) {
    try await dispatch(
      ThreadCommand.respondToUserInput(key.threadId, requestId: requestId, answers: answers, meta: .fresh(clock: clock)), on: key.environmentId,
      thread: key.threadId)
  }
  public func dismissUserInput(_ key: ScopedThreadKey, requestId: ApprovalRequestId) async throws(CommandError) {
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
