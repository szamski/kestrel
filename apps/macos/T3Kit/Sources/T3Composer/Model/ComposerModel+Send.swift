import Foundation
import T3Contracts
import T3Timeline

extension ComposerModel {
  // MARK: What can be sent

  public var hasSendableContent: Bool {
    ComposerServices.hasSendableContent(prompt: draft.prompt, attachments: draft.attachments, records: draft.records)
  }

  /// Length validation of what a send would carry (shown under the editor).
  public var validationMessage: String? {
    guard userInputProgress == nil else { return nil }
    return ComposerSubmission.promptLengthValidationMessage(ComposerSubmission.applyClaudePromptEffortPrefix(draft.prompt, effort: providerState.promptEffort))
  }

  /// Why the send button is disabled right now; nil when a send can go out.
  public var sendDisabledReason: String? {
    if let reason = thread.unavailableReason { return reason }
    if providerCatalogPending { return "Waiting for the provider list" }
    if selectedEntry == nil { return "Enable a provider in Settings to send a message" }
    if let blocked = ModelPicker.antigravitySendBlockReason(selectedEntry?.snapshot, model: selectedModel) { return blocked }
    return attachmentBlockReason
  }

  /// Uploads that are not done or failed block the send.
  public var attachmentBlockReason: String? {
    AttachmentRules.uploadBlockReason(attachmentIds: draft.attachments.map(\.id), uploads: services.uploads)
  }

  public var canSend: Bool {
    !isSending && !isConnecting && sendDisabledReason == nil && hasSendableContent && validationMessage == nil
  }

  /// What the primary button does for the draft at hand.
  public enum PrimaryAction: Sendable, Equatable {
    case send
    /// A turn is running and the follow-up behavior queues the message.
    case queue
    /// A turn is running and the message goes out immediately (steer).
    case steer
    case stop
    /// Stop with a sendable draft: both buttons show.
    case stopAndQueue
    case submitAnswer(isLast: Bool, isComplete: Bool)
  }

  public var primaryAction: PrimaryAction {
    if let progress = userInputProgress { return .submitAnswer(isLast: progress.isLastQuestion, isComplete: progress.isComplete) }
    if isRunning { return hasSendableContent ? .stopAndQueue : .stop }
    return .send
  }

  /// Whether a send now would queue (rather than steer) given the follow-up behavior.
  public var sendsAsQueue: Bool { settings.followUpBehavior == .queue }

  // MARK: Sending

  /// Sends the draft, queues it behind a running turn or steers it into the turn, depending on the
  /// follow-up behavior and the key (`alternate` flips it). The draft clears at once and comes
  /// back with an error if the send fails.
  public func submit(intent: ComposerSubmissionIntent = .foreground) async {
    guard !isSending else { return }
    if isApprovalState { return }
    if userInputProgress != nil {
      await advanceUserInput()
      return
    }
    let prompt = draft.prompt
    let trimmed = prompt.jsTrim()
    // A standalone /plan or /default switches mode instead of starting a turn.
    if planModeUiEnabled, draft.attachments.isEmpty, draft.records.isEmpty, let command = ComposerLogic.parseStandaloneSlashCommand(trimmed) {
      setInteractionMode(command == .plan ? .plan : .default)
      clearDraftContent()
      return
    }
    guard hasSendableContent else { return }
    if let reason = sendDisabledReason {
      errorMessage = reason
      return
    }
    if let message = validationMessage {
      errorMessage = message
      return
    }
    errorMessage = nil

    // A queued message that will still leave on its own goes first, so a new send lines up behind it.
    let queueStillSending = queuedMessages.contains { $0.sending != nil || !$0.holdUntilUserAction }
    if queueStillSending || (isRunning && (settings.followUpBehavior == .queue) != (intent == .alternate)) {
      enqueueCurrentDraft()
      return
    }

    let snapshot = draft
    let settingsForSend = sendSettings
    isSending = true
    defer { isSending = false }
    do {
      let turn = try await services.prepareTurn(
        target: target, prompt: snapshot.prompt, attachments: snapshot.attachments, records: snapshot.records, promptEffort: settingsForSend.promptEffort)
      let command = services.turnCommand(target: target, turn: turn, settings: settingsForSend, includeTitleSeed: thread.isFirstMessage)
      // The composer clears before the send resolves; a failure gives the draft back.
      clearDraftContent(releaseAttachments: false)
      do {
        try await services.environment.sendTurn(command, target: target, titleSeed: thread.isFirstMessage ? turn.titleSeed : nil, isFirstMessage: thread.isFirstMessage)
        services.releaseAttachments(snapshot.attachments)
        historyPosition = nil
      } catch {
        restoreDraft(snapshot)
        errorMessage = error.localizedDescription
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearDraftContent(releaseAttachments: Bool = true) {
    let before = draft.attachments
    services.editDrafts { $0.clearContent(target.key) }
    if releaseAttachments { releaseDroppedAttachments(before: before) }
    reloadEditor(markdown: "", cursor: 0, undoable: false)
    historyPosition = nil
  }

  /// Puts a snapshot back (failed send), keeping whatever the user typed meanwhile after it.
  func restoreDraft(_ snapshot: ComposerThreadDraft) {
    let current = draft
    let merged = [snapshot.prompt, current.prompt].filter { !$0.jsTrim().isEmpty }.joined(separator: "\n\n")
    services.editDrafts { state in
      state.setPrompt(target.key, merged)
      state.addAttachments(target.key, snapshot.attachments)
      for record in snapshot.records { state.addRecord(target.key, record) }
    }
    reloadEditor(markdown: merged, cursor: ComposerLogic.collapseExpandedCursor(merged, merged.jsLength), undoable: false)
  }

  // MARK: Queue

  func enqueueCurrentDraft() {
    let snapshot = draft
    let message = QueuedComposerMessage(
      id: ComposerServices.newId(), prompt: snapshot.prompt, attachments: snapshot.attachments, records: snapshot.records, sendSettings: sendSettings,
      queuedAfterToolActivityId: thread.latestToolActivityId, createdAt: IsoDateTime(date: Date()).rawValue)
    services.editQueue { $0.enqueue(target.key, message) }
    // Attachments move with the message; their uploads stay pending.
    clearDraftContent(releaseAttachments: false)
    services.ensureDispatcher(for: target)
  }

  /// Send now: skips the wait for a tool boundary. Approvals and questions still hold it.
  public func steerQueued(id: String) {
    guard activeApproval == nil, activeUserInput == nil else { return }
    let services = services
    let target = target
    let snapshot = thread
    Task { await services.sendQueued(target, id: id, snapshot: snapshot) }
  }

  /// The oldest queued message goes now (`thread.steerQueuedMessage`).
  public func steerNextQueued() {
    if let next = queuedMessages.first(where: { $0.sending == nil }) { steerQueued(id: next.id) }
  }

  /// Takes a queued message back into the composer for editing.
  public func editQueued(id: String) {
    guard let message = services.editQueue({ $0.remove(target.key, id: id) }) else { return }
    restoreQueuedMessages([message])
  }

  /// Discards a queued message and its attachments.
  public func discardQueued(id: String) {
    guard let message = services.editQueue({ $0.remove(target.key, id: id) }) else { return }
    services.releaseAttachments(message.attachments)
  }

  /// Returns messages to the composer: prompts join with blank lines, attachments past the
  /// per-message cap stay queued (held for the user), records follow.
  func restoreQueuedMessages(_ messages: [QueuedComposerMessage]) {
    guard let first = messages.first else { return }
    let prompts = ([draft.prompt] + messages.map(\.prompt)).map { $0.jsTrim() }.filter { !$0.isEmpty }
    let next = prompts.joined(separator: "\n\n")
    let room = max(0, ModelConstants.maxAttachments - draft.attachments.count)
    let attachments = messages.flatMap(\.attachments)
    let restored = Array(attachments.prefix(room))
    let overflow = Array(attachments.dropFirst(room))
    services.editDrafts { state in
      state.setPrompt(target.key, next)
      state.addAttachments(target.key, restored)
      for record in messages.flatMap(\.records) { state.addRecord(target.key, record) }
    }
    if !overflow.isEmpty {
      let held = QueuedComposerMessage(
        id: ComposerServices.newId(), prompt: "", attachments: overflow, records: [], sendSettings: first.sendSettings,
        queuedAfterToolActivityId: thread.latestToolActivityId, holdUntilUserAction: true, createdAt: IsoDateTime(date: Date()).rawValue)
      services.editQueue { $0.enqueue(target.key, held) }
      services.post(
        ComposerNotice(
          kind: .info, title: "Some attachments stayed queued",
          message: "A message holds at most \(ModelConstants.maxAttachments) attachments. Use Send now on the queued row when you want the rest to go."))
    }
    reloadEditor(markdown: next, cursor: ComposerLogic.collapseExpandedCursor(next, next.jsLength), undoable: false)
  }

  // MARK: Stop

  public var canInterrupt: Bool { thread.phase == .running && thread.dispatch.session?.status == "running" }

  /// Stop: queued messages return to the composer instead of starting a new turn the moment the
  /// interrupted one settles.
  public func interrupt() async {
    guard canInterrupt else { return }
    restoreQueuedMessages(services.editQueue { $0.drain(target.key) })
    let command = ClientOrchestrationCommandThreadTurnInterrupt(
      commandId: CommandId(ComposerServices.newId("cmd")), threadId: ThreadId(target.threadId),
      turnId: thread.dispatch.session?.activeTurnId.map { TurnId($0) }, createdAt: IsoDateTime(date: Date()))
    do { try await services.environment.interruptTurn(command, target: target) } catch {
      errorMessage = error.localizedDescription.isEmpty ? "Failed to interrupt the current turn." : error.localizedDescription
    }
  }

  // MARK: Approvals

  public func respondToApproval(_ decision: ProviderApprovalDecision) async {
    guard let approval = activeApproval else { return }
    let requestId = approval.requestId
    respondingRequestIds.insert(requestId.rawValue)
    defer { respondingRequestIds.remove(requestId.rawValue) }
    let command = ClientOrchestrationCommandThreadApprovalRespond(
      commandId: CommandId(ComposerServices.newId("cmd")), threadId: ThreadId(target.threadId), requestId: requestId, decision: decision, createdAt: IsoDateTime(date: Date()))
    do { try await services.environment.respondToApproval(command, target: target) } catch {
      errorMessage = error.localizedDescription.isEmpty ? "Failed to submit approval decision." : error.localizedDescription
    }
  }

  // MARK: Questions

  /// The key of the draft that holds a question's attachments.
  public func questionAttachmentKey(requestId: String, questionId: String) -> String {
    "question:\(target.key):\(requestId):\(questionId)"
  }

  /// Picking an option replaces the custom answer; what was typed there goes back into the draft.
  public func selectUserInputOption(questionId: String, value: String) {
    guard let prompt = activeUserInput, let question = prompt.questions.first(where: { $0.id == questionId }) else { return }
    let key = prompt.id
    let displaced = userInputAnswers[key]?[questionId]?.customAnswer
    let carried = carryDisplacedCustomAnswerIntoPrompt(draft.prompt, customAnswer: displaced)
    if carried != draft.prompt { services.editDrafts { $0.setPrompt(target.key, carried) } }
    var answers = userInputAnswers[key] ?? [:]
    answers[questionId] = togglePendingUserInputOptionSelection(question, answers[questionId], optionValue: value)
    userInputAnswers[key] = answers
    reloadEditor(markdown: "", cursor: 0, undoable: false)
    // A single-select pick advances on its own after a beat.
    if !question.multiSelect {
      questionAutoAdvance?.cancel()
      questionAutoAdvance = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        await self?.advanceUserInput()
      }
    }
  }

  public func advanceUserInput() async {
    guard let prompt = activeUserInput, let progress = userInputProgress, progress.canAdvance, !respondingRequestIds.contains(prompt.id) else { return }
    if progress.isLastQuestion {
      guard let answers = buildPendingUserInputAnswers(prompt.questions, userInputAnswers[prompt.id] ?? [:]) else { return }
      await respondToUserInput(prompt: prompt, answers: answers)
      return
    }
    setUserInputQuestion(progress.questionIndex + 1)
  }

  public func previousUserInputQuestion() {
    guard let progress = userInputProgress else { return }
    setUserInputQuestion(max(progress.questionIndex - 1, 0))
  }

  private func setUserInputQuestion(_ index: Int) {
    guard let prompt = activeUserInput else { return }
    userInputQuestionIndex[prompt.id] = index
    reloadEditor(markdown: activeText, cursor: ComposerLogic.collapseExpandedCursor(activeText, activeText.jsLength), undoable: false)
  }

  func respondToUserInput(prompt: UserInputPrompt, answers: [String: PendingUserInputAnswer]) async {
    let requestId = prompt.requestId
    guard !respondingRequestIds.contains(requestId.rawValue) else { return }
    // Wait for question attachments, then bind them by question.
    var attachmentsByQuestion: [String: [ClientOrchestrationCommandThreadUserInputRespondAttachmentsByQuestionIdValueItem]] = [:]
    for question in prompt.questions {
      let key = questionAttachmentKey(requestId: requestId.rawValue, questionId: question.id)
      if (questionAttachmentPreparation[key] ?? 0) > 0 { return }
      let attachments = services.drafts.draft(key).attachments
      guard !attachments.isEmpty else { continue }
      for attachment in attachments { services.startUpload(attachment, target: target) }
      await services.awaitUploads(attachments.map(\.id))
      var wire: [ClientOrchestrationCommandThreadUserInputRespondAttachmentsByQuestionIdValueItem] = []
      for attachment in attachments {
        guard case .ready(let serverId)? = services.uploads[attachment.id] else {
          errorMessage = "Wait for attachments to finish uploading, or remove failed uploads."
          return
        }
        wire.append(
          attachment.kind == .image
            ? .image(ChatImageAttachment(id: serverId, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes))
            : .file(ChatFileAttachment(id: serverId, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)))
      }
      attachmentsByQuestion[question.id] = wire
    }
    respondingRequestIds.insert(requestId.rawValue)
    defer { respondingRequestIds.remove(requestId.rawValue) }
    var wireAnswers: [String: JSONValue] = [:]
    for (id, answer) in answers {
      switch answer {
      case .text(let text): wireAnswers[id] = .string(text)
      case .values(let values): wireAnswers[id] = .array(values.map(JSONValue.string))
      }
    }
    let command = ClientOrchestrationCommandThreadUserInputRespond(
      commandId: CommandId(ComposerServices.newId("cmd")), threadId: ThreadId(target.threadId), requestId: requestId, answers: wireAnswers,
      attachmentsByQuestionId: attachmentsByQuestion.isEmpty ? nil : attachmentsByQuestion, createdAt: IsoDateTime(date: Date()))
    do {
      try await services.environment.respondToUserInput(command, target: target)
      for question in prompt.questions { clearQuestionDraft(requestId: requestId.rawValue, questionId: question.id) }
      userInputAnswers[prompt.id] = nil
      userInputQuestionIndex[prompt.id] = nil
    } catch {
      errorMessage = error.localizedDescription.isEmpty ? "Failed to submit user input." : error.localizedDescription
    }
  }

  /// Closes a question without messaging the agent.
  public func dismissUserInput() async {
    guard let prompt = activeUserInput, prompt.dismissible else { return }
    respondingRequestIds.insert(prompt.id)
    defer { respondingRequestIds.remove(prompt.id) }
    do { try await services.environment.dismissUserInput(requestId: prompt.requestId, target: target) } catch {
      errorMessage = error.localizedDescription.isEmpty ? "Failed to dismiss the question." : error.localizedDescription
    }
  }

  func clearQuestionDraft(requestId: String, questionId: String) {
    let key = questionAttachmentKey(requestId: requestId, questionId: questionId)
    let before = services.drafts.draft(key).attachments
    services.editDrafts { $0.clearContent(key) }
    for attachment in before {
      services.cancelUpload(attachment.id)
      if let path = attachment.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    }
  }

  /// Applies a new thread snapshot; the editor reloads when the active text source changed (a
  /// question opened or closed, an approval appeared).
  func applyThread(_ snapshot: ComposerThreadSnapshot) {
    let hadText = activeText
    thread = snapshot
    if activeText != hadText || lastEditorValue != activeText {
      reloadEditor(markdown: activeText, cursor: ComposerLogic.collapseExpandedCursor(activeText, activeText.jsLength), undoable: false)
    } else {
      updateTrigger(for: activeText, expandedCursor: selection.lowerBound)
    }
  }
}
