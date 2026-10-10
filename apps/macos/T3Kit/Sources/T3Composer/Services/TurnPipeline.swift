import Foundation
import T3Contracts

/// A message the composer wants the user to see (web toasts).
public struct ComposerNotice: Identifiable, Sendable, Hashable {
  public enum Kind: String, Sendable { case info, warning, error }

  public var id = UUID()
  public var kind: Kind
  public var title: String
  public var message: String?

  public init(kind: Kind, title: String, message: String? = nil) {
    self.kind = kind
    self.title = title
    self.message = message
  }
}

public struct ComposerTurnError: Error, LocalizedError, Sendable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// A draft turned into the pieces of `thread.turn.start`.
struct OutgoingTurn {
  var text: String
  var attachments: [V1.ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem]
  var context: OrchestrationMessageContext?
  var titleSeed: String
  /// Local attachment id to the id the server will know it by.
  var attachmentIds: [String: String]
}

extension ComposerServices {
  // MARK: Preparing a turn

  static func newId(_ prefix: String? = nil) -> String {
    let id = UUID().uuidString.lowercased()
    return prefix.map { "\($0)-\(id)" } ?? id
  }

  /// The seed for a new thread's title: the prose, else the first thing attached.
  static func titleSeed(prompt: String, attachments: [ComposerAttachment], records: [ComposerContextRecord]) -> String {
    let prose = AssistantCitations.toPlainText(ComposerContextReferences.stripInlineReferences(prompt.jsTrim())).jsTrim()
    var seed = prose
    if seed.isEmpty {
      if let image = attachments.first(where: { $0.kind == .image }) {
        seed = "Image: \(image.name)"
      } else if let file = attachments.first(where: { $0.kind == .file }) {
        seed = "File: \(file.name)"
      } else if let record = records.first {
        switch record {
        case .terminal(let terminal): seed = terminal.label
        case .reviewComment(let comment): seed = "Review: \(ContextRecords.reviewCommentLabel(comment))"
        case .previewAnnotation(let annotation): seed = ContextRecords.previewAnnotationLabel(comment: annotation.comment, pageTitle: annotation.pageTitle)
        default: seed = record.contextLabel
        }
      } else {
        seed = "New thread"
      }
    }
    let trimmed = seed.jsTrim()
    return trimmed.jsLength <= 50 ? trimmed : trimmed.jsSlice(0, 50) + "..."
  }

  /// Whether the draft has anything to send: prose, an attachment, or sendable context.
  static func hasSendableContent(prompt: String, attachments: [ComposerAttachment], records: [ComposerContextRecord]) -> Bool {
    if !ComposerContextReferences.stripInlineReferences(prompt).jsTrim().isEmpty || !attachments.isEmpty { return true }
    return records.contains { record in
      if case .terminal(let terminal) = record { return !ContextRecords.normalizeTerminalText(terminal.text).isEmpty }
      return true
    }
  }

  /// Uploads attachments, builds the wire attachments and the message context. Throws a user-facing
  /// error; the caller keeps the draft.
  func prepareTurn(
    target: ComposerTarget, prompt: String, attachments: [ComposerAttachment], records: [ComposerContextRecord], promptEffort: String?
  ) async throws -> OutgoingTurn {
    var text = prompt
    var sendableRecords = records
    // Expired terminal excerpts are not sent; their chips leave the text with them.
    for record in records {
      guard case .terminal(let terminal) = record, ContextRecords.normalizeTerminalText(terminal.text).isEmpty else { continue }
      text = ComposerContextReferences.remove(prompt: text, contextId: terminal.contextId.rawValue).prompt
      sendableRecords.removeAll { $0.contextIdentifier == terminal.contextId.rawValue }
    }
    text = text.jsTrim()
    let outgoing = ComposerSubmission.applyClaudePromptEffortPrefix(text.isEmpty ? ComposerSubmission.attachmentOnlyBootstrapPrompt : text, effort: promptEffort)
    if let message = ComposerSubmission.promptLengthValidationMessage(outgoing) { throw ComposerTurnError(message) }

    let capabilities = catalog.capabilities.attachments
    let files = attachments.filter { $0.kind == .file }
    if let reason = AttachmentRules.capabilityBlockReason(files: files.map { ($0.name, $0.sizeBytes) }, capabilities: capabilities) { throw ComposerTurnError(reason) }
    let usesUploads = capabilities.supportsAttachmentUploads
    if usesUploads && !attachments.isEmpty {
      for attachment in attachments { startUpload(attachment, target: target) }
      await awaitUploads(attachments.map(\.id))
    }
    var wire: [V1.ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem] = []
    var ids: [String: String] = [:]
    for attachment in attachments {
      if usesUploads {
        guard case .ready(let serverId)? = uploads[attachment.id] else {
          throw ComposerTurnError("Retry or remove failed uploads before sending.")
        }
        ids[attachment.id] = serverId
        wire.append(
          attachment.kind == .image
            ? .chatImageAttachment(ChatImageAttachment(id: serverId, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes))
            : .chatFileAttachment(ChatFileAttachment(id: serverId, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)))
      } else {
        guard attachment.kind == .image else { throw ComposerTurnError("This server does not support file attachments.") }
        guard let path = attachment.localPath, let data = FileManager.default.contents(atPath: path) else {
          throw ComposerTurnError("Attachment '\(attachment.name)' is no longer available.")
        }
        ids[attachment.id] = attachment.id
        wire.append(
          .option1(
            V1.ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItemOption1(
              id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes,
              dataUrl: ImageCompression.dataURL(data: data, mimeType: attachment.mimeType))))
      }
    }
    if let limit = AttachmentRules.providerLimitError(attachments.map { ($0.kind, $0.mimeType, $0.sizeBytes) }) { throw ComposerTurnError(limit) }
    let context = ContextRecords.messageContext(records: sendableRecords, attachments: attachments.map { ($0, ids[$0.id] ?? $0.id) })
    return OutgoingTurn(
      text: outgoing, attachments: wire, context: context, titleSeed: Self.titleSeed(prompt: text, attachments: attachments, records: sendableRecords), attachmentIds: ids)
  }

  func turnCommand(
    target: ComposerTarget, turn: OutgoingTurn, settings: QueuedMessageSendSettings, includeTitleSeed: Bool
  ) -> V1.ClientOrchestrationCommandThreadTurnStart {
    let createdAt = IsoDateTime(date: Date())
    return V1.ClientOrchestrationCommandThreadTurnStart(
      commandId: CommandId(Self.newId("cmd")), threadId: ThreadId(target.threadId),
      message: V1.ClientOrchestrationCommandThreadTurnStartMessage(
        messageId: MessageId(Self.newId()), text: turn.text, attachments: turn.attachments,
        context: catalog.capabilities.inlineMessageContext ? turn.context : nil),
      modelSelection: settings.modelSelection, titleSeed: includeTitleSeed ? turn.titleSeed : nil, runtimeMode: settings.runtimeMode,
      interactionMode: settings.interactionMode, createdAt: createdAt)
  }

  static func dispatchSnapshot(from input: QueuedMessages.DispatchInput, intent: ComposerSubmissionIntent = .foreground) -> ThreadDispatchSnapshot {
    ThreadDispatchSnapshot(
      startedAt: IsoDateTime(date: Date()).rawValue, submissionIntent: intent, latestUserMessageId: input.latestUserMessageId,
      latestTurnTurnId: input.latestTurn?.turnId, latestTurnRequestedAt: input.latestTurn?.requestedAt, latestTurnStartedAt: input.latestTurn?.startedAt,
      latestTurnCompletedAt: input.latestTurn?.completedAt, sessionStatus: input.session?.status, sessionUpdatedAt: input.session?.updatedAt,
      latestTurnStartFailureId: input.latestTurnStartFailureId)
  }

  /// Forgets what a finished send held: its uploads and staged bytes.
  func releaseAttachments(_ attachments: [ComposerAttachment]) {
    for attachment in attachments {
      uploadsRemove(attachment.id)
      if let path = attachment.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    }
  }

  private func uploadsRemove(_ id: String) { setUpload(id, nil) }

  // MARK: Notices

  public func post(_ notice: ComposerNotice) { notices.append(notice) }
  public func dismissNotice(_ id: UUID) { notices.removeAll { $0.id == id } }

  // MARK: The queue

  /// Starts following a thread with queued messages so they go out at tool boundaries and at the
  /// end of the turn, whether or not the thread is on screen.
  func ensureDispatcher(for target: ComposerTarget) {
    registerQueueTarget(target)
    guard !dispatcherRunning(target.key) else { return }
    let stream = environment.threadSnapshots(for: target)
    let key = target.key
    trackDispatcher(
      key,
      Task { [weak self] in
        for await snapshot in stream {
          guard let self, !Task.isCancelled else { return }
          if self.queue.queue(key).isEmpty { break }
          await self.evaluateQueue(target, snapshot: snapshot)
        }
        self?.endDispatcher(key)
      })
  }

  /// Sends the head of the queue when it is due and nothing blocks it.
  func evaluateQueue(_ target: ComposerTarget, snapshot: ComposerThreadSnapshot) async {
    let key = target.key
    let current = queue.queue(key)
    guard let next = current.first else { return }
    let sending = current.contains { $0.sending != nil }
    // A send that starts a new turn leaves the thread idle until the server picks it up; hold the
    // next message until then.
    let waitingForServer = queue.lastDispatchByThreadKey[key].map { !QueuedMessages.hasServerAcknowledged($0.thread, snapshot.dispatch) } ?? false
    // Approvals and questions block the agent: a steer landing on top would answer nothing.
    let blocked =
      snapshot.unavailableReason != nil || snapshot.isRewinding || sending || waitingForServer || !snapshot.pending.approvals.isEmpty
      || !snapshot.pending.userInputs.isEmpty
    guard !blocked, QueuedMessages.isDue(
      holdUntilUserAction: next.holdUntilUserAction, queuedAfterToolActivityId: next.queuedAfterToolActivityId, phase: snapshot.phase,
      latestToolActivityId: snapshot.latestToolActivityId)
    else { return }
    await sendQueued(target, id: next.id, snapshot: snapshot)
  }

  /// Sends one queued message as a turn on its thread. It reads nothing from the composer, so it
  /// works for threads that are not on screen. A failed send stays at the head, held for Send now.
  func sendQueued(_ target: ComposerTarget, id: String, snapshot: ComposerThreadSnapshot) async {
    let key = target.key
    guard let message = editQueue({ $0.beginSend(key, id: id, toolActivityId: snapshot.latestToolActivityId) }) else { return }
    do {
      guard Self.hasSendableContent(prompt: message.prompt, attachments: message.attachments, records: message.records) else {
        editQueue { $0.finishSend(key, id: id) }
        return
      }
      let turn = try await prepareTurn(
        target: target, prompt: message.prompt, attachments: message.attachments, records: message.records, promptEffort: message.sendSettings.promptEffort)
      let command = turnCommand(target: target, turn: turn, settings: message.sendSettings, includeTitleSeed: snapshot.isFirstMessage)
      // Stop hands a preparing message back to the composer; past this point it cannot be taken back.
      guard editQueue({ $0.markDispatching(key, id: id, thread: Self.dispatchSnapshot(from: snapshot.dispatch)) }) else { return }
      try await environment.sendTurn(command, target: target, titleSeed: snapshot.isFirstMessage ? turn.titleSeed : nil, isFirstMessage: snapshot.isFirstMessage)
      editQueue { $0.finishSend(key, id: id) }
      releaseAttachments(message.attachments)
    } catch {
      guard editQueue({ $0.failSend(key, id: id) }) else { return }
      post(ComposerNotice(kind: .error, title: "Queued message not sent", message: error.localizedDescription.isEmpty ? "Use Send now to try again." : error.localizedDescription))
    }
  }
}
