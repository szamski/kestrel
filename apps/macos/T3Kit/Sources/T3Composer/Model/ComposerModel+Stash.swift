import Foundation
import T3Contracts

extension ComposerModel {
  // MARK: Saving

  /// A stash needs something in the composer: text, an attachment or context.
  public var canStash: Bool { !draft.prompt.jsTrim().isEmpty || !draft.attachments.isEmpty || !draft.records.isEmpty }

  /// ⌘S: saves the prompt and its attachments for later; with an empty composer the same key
  /// restores a single stash or opens the menu when there are several.
  public func stashShortcut() async {
    if canStash {
      await stashCurrent()
    } else if stashEntries.count == 1, let only = stashEntries.first {
      await restoreStash(id: only.id)
    } else if !stashEntries.isEmpty {
      isStashMenuOpen.toggle()
    }
  }

  public func stashCurrent() async {
    guard canStash else { return }
    let snapshot = draft
    if services.uploads.values.contains(where: { if case .uploading = $0 { true } else { false } }) {
      services.post(ComposerNotice(kind: .warning, title: "Wait for uploads to finish first"))
      return
    }
    var files: [PersistedFileAttachment] = []
    for attachment in snapshot.attachments where attachment.kind == .file {
      var serverId = attachment.uploadedAttachmentId
      if serverId == nil, case .ready(let id)? = services.uploads[attachment.id] { serverId = id }
      guard let serverId else {
        services.post(ComposerNotice(kind: .error, title: "Can't stash '\(attachment.name)'", message: "Retry the upload or remove the file, then stash again."))
        return
      }
      files.append(PersistedFileAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes, attachmentId: serverId, environmentId: target.environmentId, source: attachment.source))
    }
    let images = snapshot.attachments.filter { $0.kind == .image }
    let entry = PromptStashEntry(
      id: ComposerServices.newId(), createdAt: IsoDateTime(date: Date()).rawValue, prompt: snapshot.prompt, attachments: [], files: files.isEmpty ? nil : files,
      droppedImageNames: [], unreadableImageNames: nil, pendingImageCount: images.isEmpty ? nil : images.count, records: snapshot.records.isEmpty ? nil : snapshot.records)
    // The entry is saved before its images so a crash mid-encode cannot lose the prompt.
    let previous = services.stash
    let evicted = services.editStash { $0.stash(entry) }
    guard await services.persistStash() else {
      services.replaceStash(previous)
      services.post(ComposerNotice(kind: .error, title: "Couldn't stash the prompt", message: "Storage rejected the write. The prompt stays in the composer."))
      return
    }
    if let evicted {
      services.post(ComposerNotice(kind: .info, title: "Oldest stashed prompt removed", message: "The stash keeps \(PromptStash.maxEntries) prompts."))
      for file in evicted.files ?? [] { if let id = file.attachmentId { Task { await services.environment.deleteUploadedAttachment(id: id) } } }
    }
    clearDraftContent(releaseAttachments: false)
    for attachment in snapshot.attachments where attachment.kind == .file {
      if let path = attachment.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
      services.cancelUploadStateOnly(attachment.id)
    }
    stashPulse += 1
    if !images.isEmpty { Task { await finalizeStashImages(entryId: entry.id, images: images) } }
  }

  /// Encodes the stashed images off the main thread and attaches them to the saved entry.
  private func finalizeStashImages(entryId: String, images: [ComposerAttachment]) async {
    var persisted: [PersistedImageAttachment] = []
    var unreadable: [String] = []
    var oversized: [String] = []
    for image in images {
      guard let path = image.localPath else {
        unreadable.append(image.name)
        continue
      }
      let outcome = await Task.detached(priority: .utility) { () -> Result<ImageCompression.Output, ImageCompression.Failure> in
        guard let data = FileManager.default.contents(atPath: path) else { return .failure(.unreadable) }
        return ImageCompression.compressForStash(data: data, name: image.name, mimeType: image.mimeType)
      }.value
      switch outcome {
      case .success(let output):
        persisted.append(
          PersistedImageAttachment(
            id: image.id, name: output.name, mimeType: output.mimeType, sizeBytes: output.data.count, source: image.source,
            dataUrl: ImageCompression.dataURL(data: output.data, mimeType: output.mimeType)))
      case .failure(.unreadable): unreadable.append(image.name)
      case .failure(.tooLarge): oversized.append(image.name)
      }
      try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
    let split = PromptStash.partition(persisted)
    var next = services.stash
    let attached = next.finalizeImages(entryId, attachments: split.kept, droppedImageNames: oversized + split.droppedNames, unreadableImageNames: unreadable)
    services.replaceStash(next)
    if !attached {
      services.post(ComposerNotice(kind: .warning, title: "Stashed images were not saved", message: "The entry was restored or deleted while its images were still encoding."))
      return
    }
    await services.persistStash()
  }

  // MARK: Restoring

  /// Brings a stash back: text appends after what is in the composer, chips and files follow, and
  /// whatever could not come back is reported by name.
  public func restoreStash(id: String) async {
    guard let entry = stashEntries.first(where: { $0.id == id }) else { return }
    if (entry.files ?? []).contains(where: { $0.environmentId != nil && $0.environmentId != target.environmentId }) {
      services.post(ComposerNotice(kind: .error, title: "Stashed files belong to another environment", message: "Restore this prompt in the environment that received its files."))
      return
    }
    isStashMenuOpen = false
    // The server sweeps pending uploads after 24 hours: verify before taking, so a quit during the
    // await still finds the entry.
    var expired = Set<String>()
    for file in entry.files ?? [] {
      if let attachmentId = file.attachmentId, await services.environment.verifyUploadedAttachment(id: attachmentId) == .missing { expired.insert(attachmentId) }
    }
    guard let taken = services.editStash({ $0.take(id) }) else { return }
    if !(await services.persistStash()) {
      services.post(ComposerNotice(kind: .warning, title: "Restored prompt may reappear in the stash", message: "Storage rejected the update, so this entry could still be there after a restart."))
    }

    // Records come back through the same importer a paste uses; links keep their ids.
    for record in taken.records ?? [] { services.editDrafts { $0.addRecord(target.key, record) } }
    let current = draft.prompt
    let restoredPrompt = taken.prompt
    let next = restoredPrompt.isEmpty ? current : (current.jsTrim().isEmpty ? restoredPrompt : "\(current.jsTrimEnd())\n\n\(restoredPrompt)")
    var promptChanged = next != current
    if promptChanged { services.editDrafts { $0.setPrompt(target.key, next) } }

    var notes: [String] = []
    var unrestoredFiles: [String] = []
    var expiredNames: [String] = []
    var restoredFiles: [ComposerAttachment] = []
    for file in taken.files ?? [] {
      let isExpired = file.attachmentId.map { expired.contains($0) } ?? false
      if isExpired { expiredNames.append(file.name) }
      restoredFiles.append(
        ComposerAttachment(
          id: file.id, kind: .file, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes, source: file.source,
          uploadedAttachmentId: isExpired ? nil : file.attachmentId, uploadEnvironmentId: isExpired ? nil : target.environmentId))
    }
    if !restoredFiles.isEmpty {
      let stored = Set(services.editDraftsReturning { $0.addAttachments(target.key, restoredFiles) })
      unrestoredFiles = restoredFiles.filter { !stored.contains($0.id) }.map(\.name)
      let kept = restoredFiles.filter { stored.contains($0.id) }
      for attachment in kept where attachment.uploadedAttachmentId != nil { services.startUpload(attachment, target: target) }
      // Files exist only as chips.
      let withChips = ComposerContextReferences.ensure(prompt: draft.prompt, references: kept.map(ContextRecords.fileReference))
      if withChips != draft.prompt {
        services.editDrafts { $0.setPrompt(target.key, withChips) }
        promptChanged = true
      }
    }

    var unrestoredImages: [String] = []
    var restoredImages: [ComposerAttachment] = []
    let room = max(0, ModelConstants.maxAttachments - draft.attachments.count)
    let pending = taken.attachments.filter { stored in !draft.attachments.contains { $0.id == stored.id || $0.dedupeKey == "\(stored.mimeType)\u{0}\(stored.sizeBytes)\u{0}\(stored.name)" } }
    unrestoredImages = pending.dropFirst(room).map(\.name)
    for image in pending.prefix(room) {
      guard let data = ImageCompression.data(fromDataURL: image.dataUrl), let url = try? stage(data: data, name: image.name) else { continue }
      restoredImages.append(ComposerAttachment(id: image.id, kind: .image, name: image.name, mimeType: image.mimeType, sizeBytes: image.sizeBytes, source: image.source, localPath: url.path))
    }
    if !restoredImages.isEmpty {
      services.editDrafts { _ = $0.addAttachments(target.key, restoredImages) }
      for attachment in restoredImages { services.startUpload(attachment, target: target) }
    }

    if !taken.droppedImageNames.isEmpty { notes.append("\(taken.droppedImageNames.joined(separator: ", ")) exceeded the stash size limit when this prompt was saved.") }
    if let unreadable = taken.unreadableImageNames, !unreadable.isEmpty { notes.append("\(unreadable.joined(separator: ", ")) could not be read when this prompt was saved.") }
    if !unrestoredImages.isEmpty { notes.append("\(unrestoredImages.joined(separator: ", ")) could not be restored: the composer is at its \(ModelConstants.maxAttachments)-attachment limit.") }
    if !unrestoredFiles.isEmpty { notes.append("\(unrestoredFiles.joined(separator: ", ")) could not be restored: the composer is at its \(ModelConstants.maxAttachments)-attachment limit.") }
    if !expiredNames.isEmpty { notes.append("\(expiredNames.joined(separator: ", ")): stashed files are kept for 24 hours and this upload expired. Attach the file again.") }
    if !notes.isEmpty { services.post(ComposerNotice(kind: .warning, title: "Some attachments were not restored", message: notes.joined(separator: " "))) }

    // Only move the caret when text was actually inserted.
    if promptChanged {
      reloadEditor(markdown: draft.prompt, cursor: ComposerLogic.collapseExpandedCursor(draft.prompt, draft.prompt.jsLength), undoable: true, focus: true)
    }
  }

  public func deleteStash(id: String) async {
    guard let removed = services.editStash({ $0.take(id) }) else { return }
    if stashEntries.isEmpty { isStashMenuOpen = false }
    if await services.persistStash() {
      for file in removed.files ?? [] { if let attachmentId = file.attachmentId { await services.environment.deleteUploadedAttachment(id: attachmentId) } }
    } else {
      services.post(ComposerNotice(kind: .warning, title: "Stash entry may come back", message: "Storage rejected the update."))
    }
  }
}

extension ComposerServices {
  /// Forgets an attachment's upload state without deleting the server copy (it now belongs to a stash).
  func cancelUploadStateOnly(_ id: String) { setUpload(id, nil) }
}
