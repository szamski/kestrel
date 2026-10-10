import Foundation
import T3Contracts

/// A queued message the composer is editing. The composer's own draft is parked here while the message's text
/// takes its place (the web keeps it under a separate draft key); saving or leaving edit mode gives it back.
public struct EditingQueuedRun {
  public var runId: RunId
  public var messageId: MessageId
  public var originalText: String
  /// The message's attachments, kept as they are; files added in the composer join them on save.
  public var attachments: [ChatAttachment]
  public var context: OrchestrationMessageContext?
  var savedDraft: ComposerThreadDraft
}

/// The server-side queue of protocol-2 threads (`QueuedRunsControl.tsx`): edit, reorder, remove, steer, resume.
extension ComposerModel {
  public var serverQueue: ComposerServerQueue? { thread.serverQueue }

  /// Stop held the queue and nothing is running: the primary button resumes it.
  public var canResumeQueue: Bool { thread.serverQueue?.isHeld == true && !isRunning }

  // MARK: Queue commands

  private func runQueueCommand(_ runId: RunId?, _ command: @escaping @MainActor () async throws -> Void) {
    guard busyQueueRunId == nil else { return }
    busyQueueRunId = runId ?? RunId(rawValue: "queue")
    Task {
      defer { busyQueueRunId = nil }
      do { try await command() } catch { errorMessage = error.localizedDescription.isEmpty ? "The queue command failed." : error.localizedDescription }
    }
  }

  /// Hands the message to the active run instead of waiting behind it.
  public func steerServerQueued(_ runId: RunId) {
    guard let queue = thread.serverQueue, queue.canPromoteToSteer, let active = queue.activeRunId else { return }
    let environment = services.environment, target = target
    runQueueCommand(runId) { try await environment.steerQueued(runId: runId, into: active, target: target) }
  }

  public func cancelServerQueued(_ runId: RunId) {
    let environment = services.environment, target = target
    runQueueCommand(runId) { try await environment.cancelQueued(runId: runId, target: target) }
  }

  /// Moves a message in front of `beforeRunId` (nil: to the end).
  public func moveServerQueued(_ runId: RunId, before beforeRunId: RunId?) {
    guard thread.serverQueue?.canReorder == true, runId != beforeRunId else { return }
    let environment = services.environment, target = target
    runQueueCommand(runId) { try await environment.reorderQueued(runId: runId, before: beforeRunId, target: target) }
  }

  /// Drop target semantics of a row: dropping onto a later row lands after it, onto an earlier one lands before it.
  public func dropServerQueued(_ runId: RunId, onto rowRunId: RunId) {
    guard let items = thread.serverQueue?.items, let from = items.firstIndex(where: { $0.runId == runId }),
      let to = items.firstIndex(where: { $0.runId == rowRunId }), from != to
    else { return }
    moveServerQueued(runId, before: from < to ? (to + 1 < items.count ? items[to + 1].runId : nil) : rowRunId)
  }

  public func moveServerQueued(_ runId: RunId, by offset: Int) {
    guard let items = thread.serverQueue?.items, let from = items.firstIndex(where: { $0.runId == runId }) else { return }
    let to = from + offset
    guard items.indices.contains(to) else { return }
    dropServerQueued(runId, onto: items[to].runId)
  }

  /// Releases a queue that Stop held.
  public func resumeServerQueue() {
    let environment = services.environment, target = target
    runQueueCommand(nil) { try await environment.resumeQueue(target: target) }
  }

  // MARK: Editing a queued message

  /// Loads the message into the composer; sending now saves it in place.
  public func editServerQueued(_ runId: RunId) {
    guard let item = thread.serverQueue?.items.first(where: { $0.runId == runId }), busyQueueRunId == nil, !isSending else { return }
    if editingQueued?.runId == runId { return }
    finishQueuedEdit()
    let saved = draft
    clearDraftContent(releaseAttachments: false)
    services.editDrafts { $0.setPrompt(target.key, item.text) }
    editingQueued = EditingQueuedRun(
      runId: item.runId, messageId: item.messageId, originalText: item.text, attachments: item.attachments, context: item.context, savedDraft: saved)
    reloadEditor(markdown: item.text, cursor: ComposerLogic.collapseExpandedCursor(item.text, item.text.jsLength), undoable: false, focus: true)
  }

  /// The newest queued message (`editLatest` of the web control); declines while one is being edited.
  @discardableResult public func editLatestServerQueued() -> Bool {
    guard editingQueued == nil, let latest = thread.serverQueue?.items.last else { return false }
    editServerQueued(latest.runId)
    return true
  }

  public func cancelQueuedEdit() { finishQueuedEdit() }

  /// Leaves edit mode: what was typed for the edit goes away and the parked draft comes back.
  func finishQueuedEdit() {
    guard let edit = editingQueued else { return }
    editingQueued = nil
    clearDraftContent(releaseAttachments: true)
    putBack(edit.savedDraft)
  }

  private func putBack(_ saved: ComposerThreadDraft) {
    services.editDrafts { state in
      state.setPrompt(target.key, saved.prompt)
      state.addAttachments(target.key, saved.attachments)
      for record in saved.records { state.addRecord(target.key, record) }
    }
    reloadEditor(markdown: saved.prompt, cursor: ComposerLogic.collapseExpandedCursor(saved.prompt, saved.prompt.jsLength), undoable: false)
  }

  /// The edited run started or was removed elsewhere. An unsaved edit moves into the thread's own draft when that is
  /// empty; otherwise it is dropped with a notice.
  func recoverQueuedEditIfGone() {
    guard let edit = editingQueued, thread.isDetailLoaded, let queue = thread.serverQueue, !queue.items.contains(where: { $0.runId == edit.runId }) else { return }
    let dirty = draft.prompt != edit.originalText || !draft.attachments.isEmpty
    if dirty && !edit.savedDraft.hasUserContent {
      editingQueued = nil
      services.post(ComposerNotice(kind: .info, title: "Queued message is no longer queued", message: "Your unsaved edit was kept in the composer."))
      return
    }
    finishQueuedEdit()
    if dirty { services.post(ComposerNotice(kind: .warning, title: "Queued message is no longer queued", message: "Your unsaved edit was discarded.")) }
  }

  /// Saves the edit: uploads new files, keeps the message's own attachments and context records, then replaces the
  /// queued message. A failure keeps the edit.
  func saveQueuedEdit() async {
    guard let edit = editingQueued, !isSending else { return }
    let snapshot = draft
    guard edit.attachments.count + snapshot.attachments.count <= ModelConstants.maxAttachments else {
      errorMessage = "A message can have at most \(ModelConstants.maxAttachments) attachments."
      return
    }
    guard hasSendableContent || !edit.attachments.isEmpty else { return }
    if let reason = sendDisabledReason ?? validationMessage {
      errorMessage = reason
      return
    }
    errorMessage = nil
    isSending = true
    defer { isSending = false }
    do {
      let turn = try await services.prepareTurn(
        target: target, prompt: snapshot.prompt, attachments: snapshot.attachments, records: snapshot.records, promptEffort: nil)
      var added: [ChatAttachment] = []
      for item in turn.attachments {
        switch item {
        case .chatImageAttachment(let image): added.append(.image(image))
        case .chatFileAttachment(let file): added.append(.file(file))
        default: throw ComposerTurnError("This message's attachments need an upload-capable server.")
        }
      }
      let keptIds = Set(edit.attachments.compactMap(Self.attachmentId))
      let kept = (edit.context?.records ?? []).filter { record in
        switch record {
        case .image(let image): keptIds.contains(image.attachmentId)
        case .file(let file): keptIds.contains(file.attachmentId)
        default: true
        }
      }
      // Later records win, each id keeps the position of its first appearance (a `Map` in the web).
      var merged: [ComposerContextRecord] = []
      for record in kept + (turn.context?.records ?? []) {
        if let index = merged.firstIndex(where: { $0.contextIdentifier == record.contextIdentifier }) { merged[index] = record } else { merged.append(record) }
      }
      try await services.environment.editQueued(
        runId: edit.runId, text: turn.text, attachments: edit.attachments + added, context: OrchestrationMessageContext(records: merged), target: target)
      services.releaseAttachments(snapshot.attachments)
      // Sent: leave edit mode without releasing the attachments twice.
      editingQueued = nil
      clearDraftContent(releaseAttachments: false)
      putBack(edit.savedDraft)
      requestFocus()
    } catch {
      errorMessage = error.localizedDescription.isEmpty ? "Could not save the edited queued message." : error.localizedDescription
    }
  }

  private static func attachmentId(_ attachment: ChatAttachment) -> String? {
    switch attachment {
    case .image(let image): image.id
    case .file(let file): file.id
    default: nil
    }
  }

  /// Resumes a held server queue (the primary button when there is nothing to send).
  public func resumeIfHeld() { if canResumeQueue { resumeServerQueue() } }
}
