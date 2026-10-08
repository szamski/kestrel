import AppKit
import Foundation
import T3Contracts
import UniformTypeIdentifiers

extension ComposerModel {
  // MARK: Where attachments go

  /// While a question is open its attachments belong to that question, never to the thread draft.
  var questionDraftKey: String? {
    guard let prompt = activeUserInput, let question = userInputProgress?.activeQuestion else { return nil }
    return questionAttachmentKey(requestId: prompt.id, questionId: question.id)
  }

  public var supportsQuestionAttachments: Bool { catalog.capabilities.attachments.supportsAttachmentUploads }

  /// Attachments of the open question, for the answer panel.
  public var questionAttachments: [ComposerAttachment] { questionDraftKey.map { services.drafts.draft($0).attachments } ?? [] }

  var attachmentTargetKey: String { questionDraftKey ?? target.key }

  public var canAttachFiles: Bool {
    let limit = AttachmentRules.fileStagingLimit(catalog.capabilities.attachments)
    guard limit != nil else { return false }
    if userInputProgress != nil { return supportsQuestionAttachments && !isChoiceOnlyQuestion }
    return !isApprovalState
  }

  var reservedAttachmentCount: Int { services.drafts.draft(attachmentTargetKey).attachments.count + attachmentIntakes }

  // MARK: Staging

  nonisolated static func mimeType(for url: URL) -> String {
    (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
  }

  /// A private copy of the bytes: the original may move or change before the send.
  func stage(data: Data, name: String) throws -> URL {
    let directory = services.storageDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "-"))
    try data.write(to: url, options: .atomic)
    return url
  }

  func stage(copying source: URL, name: String) throws -> URL {
    let directory = services.storageDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "-"))
    try FileManager.default.copyItem(at: source, to: url)
    return url
  }

  // MARK: Adding

  /// Attaches files and images (picker, drop, paste). Validation is synchronous so concurrent
  /// intakes see each other's reserved slots; compression of images follows. Returns whether a chip
  /// was inserted.
  @discardableResult
  public func addFiles(urls: [URL], source: String? = nil, selection: Range<Int>? = nil, skipImageInlineChip: Bool = false) async -> Bool {
    guard !urls.isEmpty else { return false }
    if userInputProgress != nil && (!supportsQuestionAttachments || isChoiceOnlyQuestion || respondingRequestIds.contains(activeUserInput?.id ?? "")) {
      services.post(ComposerNotice(kind: .error, title: "This question cannot accept attachments."))
      return false
    }
    let key = attachmentTargetKey
    let inQuestion = questionDraftKey != nil
    let imagesGetChips =
      !skipImageInlineChip && !inQuestion
      && (selection != nil || isConnecting || isApprovalState || !ComposerContextReferences.stripInlineReferences(draft.prompt).jsTrim().isEmpty)
    let incoming = urls.map { url -> AttachmentRules.IncomingFile in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return AttachmentRules.IncomingFile(name: url.lastPathComponent, mimeType: Self.mimeType(for: url), sizeBytes: size, url: url)
    }
    let markers = services.drafts.draft(key).attachments.filter(\.needsReattach)
    let plan = AttachmentRules.plan(
      files: incoming, reservedCount: reservedAttachmentCount, reattachMarkers: markers, fileStagingLimit: AttachmentRules.fileStagingLimit(catalog.capabilities.attachments))
    errorMessage = plan.error
    var insertedAny = false

    var stagedFiles: [ComposerAttachment] = []
    for (file, mimeType) in plan.files {
      guard let url = file.url, let staged = try? stage(copying: url, name: file.name) else { continue }
      stagedFiles.append(
        ComposerAttachment(
          id: ComposerServices.newId(), kind: .file, name: file.name.isEmpty ? "file" : file.name, mimeType: mimeType, sizeBytes: file.sizeBytes, source: source,
          localPath: staged.path))
    }
    if !stagedFiles.isEmpty {
      let stored = Set(services.editDraftsReturning { $0.addAttachments(key, stagedFiles) })
      let kept = stagedFiles.filter { stored.contains($0.id) }
      for attachment in kept { services.startUpload(attachment, target: target) }
      if !kept.isEmpty && !inQuestion {
        insertedAny = insertAttachmentReferences(kept.map(ContextRecords.fileReference), selection: selection)
      }
      if source == "pasted-text", let attached = kept.first {
        services.post(ComposerNotice(kind: .info, title: "Large paste attached as \(attached.name)", message: "\(AttachmentRules.formatSize(attached.sizeBytes)) · Use ⌘⇧V to keep a large paste inline."))
      }
    }
    guard !plan.images.isEmpty else { return insertedAny }

    attachmentIntakes += plan.images.count
    defer { attachmentIntakes -= plan.images.count }
    let maxBytes = ModelConstants.maxImageBytes
    var prepared: [ComposerAttachment] = []
    var compressionError: String?
    for file in plan.images {
      guard let url = file.url else { continue }
      let name = file.name
      let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ImageCompression.Output, ImageCompression.Failure> in
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return ImageCompression.prepareForAttachment(data: data, name: name, mimeType: Self.mimeType(for: url), maxBytes: maxBytes)
      }.value
      switch outcome {
      case .failure(let failure):
        compressionError =
          failure == .unreadable ? "'\(file.name)' could not be read as an image." : "'\(file.name)' is too large to attach, even after compression."
      case .success(let output):
        let mime = AttachmentRules.inferImageMimeType(fromName: output.name) ?? output.mimeType
        guard let staged = try? stage(data: output.data, name: output.name) else { continue }
        prepared.append(
          ComposerAttachment(id: ComposerServices.newId(), kind: .image, name: output.name, mimeType: mime.isEmpty ? output.mimeType : mime, sizeBytes: output.data.count, localPath: staged.path))
      }
    }
    // The question may have closed while images were compressing.
    if inQuestion && questionDraftKey != key {
      for attachment in prepared { if let path = attachment.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) } }
      return insertedAny
    }
    let stored = Set(services.editDraftsReturning { $0.addAttachments(key, prepared) })
    let kept = prepared.filter { stored.contains($0.id) }
    for attachment in kept { services.startUpload(attachment, target: target) }
    if !kept.isEmpty && imagesGetChips {
      insertedAny = insertAttachmentReferences(kept.map(ContextRecords.imageReference), selection: nil) || insertedAny
    }
    if let compressionError { errorMessage = compressionError }
    return insertedAny
  }

  /// Image data from the pasteboard (screenshots, copied pictures) becomes a staged file first.
  @discardableResult
  public func addImageData(_ data: Data, name: String, mimeType: String, skipInlineChip: Bool = false) async -> Bool {
    guard let url = try? stage(data: data, name: name) else { return false }
    let added = await addFiles(urls: [url], skipImageInlineChip: skipInlineChip)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    return added
  }

  /// Chips for freshly attached files land at the caret; when the editor cannot take input they are
  /// appended so the file is never invisible.
  func insertAttachmentReferences(_ references: [ComposerContextReference], selection: Range<Int>?) -> Bool {
    guard !references.isEmpty, questionDraftKey == nil else { return false }
    if let selection {
      let edit = ComposerContextReferences.inlineReplacement(prompt: draft.prompt, start: selection.lowerBound, end: selection.upperBound, references: references)
      return applyReplacement(rangeStart: edit.start, rangeEnd: edit.end, replacement: edit.text)
    }
    let text = references.map(ComposerContextReferences.formatInline).joined(separator: " ")
    if insertText("\(text) ", at: .cursor, ensureLeadingBoundary: true) { return true }
    setActiveText(ComposerContextReferences.ensure(prompt: draft.prompt, references: references))
    reloadEditor(markdown: draft.prompt, cursor: ComposerLogic.collapseExpandedCursor(draft.prompt, draft.prompt.jsLength), undoable: true)
    return true
  }

  // MARK: Removing

  /// Deleting an image chip leaves the image on the shelf; removing a thumbnail asks first when the
  /// image is still mentioned in the text.
  public func imageIsReferenced(_ id: String) -> Bool {
    guard let image = draft.attachments.first(where: { $0.id == id }) else { return false }
    return ComposerContextReferences.collectInlineContextIds(draft.prompt).contains(ContextRecords.imageReference(image).contextId)
  }

  public func removeAttachment(id: String, in key: String? = nil) {
    let key = key ?? attachmentTargetKey
    guard let removed = services.editDraftsReturning({ $0.removeAttachment(key, id: id) }) else { return }
    services.cancelUpload(id)
    if let path = removed.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    if key == target.key { reloadEditor(markdown: draft.prompt, cursor: min(cursor, ComposerLogic.clampCollapsedCursor(draft.prompt, Int.max)), undoable: true) }
  }

  public func retryUpload(id: String) {
    guard let attachment = draft.attachments.first(where: { $0.id == id }) ?? questionAttachments.first(where: { $0.id == id }) else { return }
    services.retryUpload(attachment, target: target)
  }

  // MARK: Pasting and dropping

  /// The paste the editor may hand over: files and images become attachments, a large text folds
  /// into a file. False falls back to inserting text (which also imports copied chips).
  public func handlePaste(_ pasteboard: NSPasteboard, bypassAutoAttachment: Bool = false) -> Bool {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let text = pasteboard.string(forType: .string) ?? ""
    var imageFiles: [(name: String, mimeType: String)] = urls.map { ($0.lastPathComponent, Self.mimeType(for: $0)) }
    var imageData: Data?
    if urls.isEmpty, let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      imageData = png
      imageFiles = [("Pasted image.png", "image/png")]
    }
    if !imageFiles.isEmpty, AttachmentRules.shouldHandlePaste(files: imageFiles, plainText: text) {
      if let imageData {
        Task { await addImageData(imageData, name: imageFiles[0].name, mimeType: "image/png", skipInlineChip: bypassAutoAttachment) }
      } else {
        Task { await addFiles(urls: urls, skipImageInlineChip: bypassAutoAttachment) }
      }
      return true
    }
    // Copied chips need the structured importer to bring their records and files along.
    let fragment = pasteboard.string(forType: NSPasteboard.PasteboardType(ComposerContextClipboard.pasteboardType))
    if let read = ComposerContextClipboard.readPasted(text: text, fragment: fragment, html: pasteboard.string(forType: .html)), !read.records.isEmpty { return false }
    return foldPastedText(text, bypass: bypassAutoAttachment)
  }

  /// Large clipboard text becomes a text file so the agent can inspect it selectively.
  func foldPastedText(_ text: String, bypass: Bool, selectionOverride: Range<Int>? = nil) -> Bool {
    let selection = selectionOverride ?? self.selection
    let exceeds = TextPaste.wouldExceedLimit(
      valueLength: activeText.jsLength, start: selection.lowerBound, end: selection.upperBound, textLength: text.jsLength, maxLength: ModelConstants.maxInputChars)
    guard TextPaste.disposition(text: text, canAttach: true, bypassAutoAttachment: bypass, wouldExceedInputLimit: exceeds) == .attachment else { return false }
    let limit = AttachmentRules.fileStagingLimit(catalog.capabilities.attachments)
    let hasSlot = reservedAttachmentCount < ModelConstants.maxAttachments
    if !canAttachFiles || limit == nil || !hasSlot {
      if !exceeds { return false }
      services.post(ComposerNotice(kind: .error, title: "Pasted text is too large for this message", message: "Remove some text or an attachment, then paste again."))
      return true
    }
    let name = TextPaste.nextFileName(existing: draft.attachments.map(\.name))
    let data = Data(text.utf8)
    if let limit, data.count > limit {
      if !exceeds { return false }
      services.post(ComposerNotice(kind: .error, title: "Pasted text is too large to attach", message: "Reduce the clipboard contents or save a smaller excerpt as a file."))
      return true
    }
    guard let url = try? stage(data: data, name: name) else { return false }
    Task {
      await addFiles(urls: [url], source: "pasted-text", selection: selection)
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    return true
  }

  /// Files and folders dropped on the composer. Folders become path mentions (local environments only).
  public func handleDrop(urls: [URL]) async -> Bool {
    var files: [URL] = []
    for url in urls {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if isDirectory.boolValue {
        guard target.isLocalEnvironment else {
          services.post(ComposerNotice(kind: .error, title: "Folders can't be dropped into remote environments"))
          continue
        }
        insertText("\(ComposerMenu.fileLink(forPath: url.path)) ", at: .end, ensureLeadingBoundary: true)
      } else {
        files.append(url)
      }
    }
    if !files.isEmpty { await addFiles(urls: files) }
    requestFocus()
    return true
  }

  // MARK: Clipboard fragments

  /// The records behind the chips of a copy, with where they came from (never bytes or URLs).
  public func clipboardFragment(contextIds: [String]) -> ComposerContextClipboardFragment? {
    var records: [ComposerContextRecord] = []
    var seen = Set<String>()
    func add(_ record: ComposerContextRecord) {
      if seen.insert(record.contextIdentifier).inserted { records.append(record) }
    }
    let wanted = Set(contextIds)
    for record in draft.records where wanted.contains(record.contextIdentifier) {
      add(record)
      // A preview annotation travels with its screenshot.
      if case .previewAnnotation(let annotation) = record, let screenshot = annotation.screenshotContextId?.rawValue {
        if let image = draft.attachments.first(where: { ContextRecords.imageReference($0).contextId == screenshot }), case .ready(let id)? = services.uploads[image.id] {
          add(ContextRecords.attachmentRecord(image, attachmentId: id))
        }
      }
    }
    for attachment in draft.attachments {
      let reference = ContextRecords.attachmentReference(attachment)
      guard wanted.contains(reference.contextId) else { continue }
      // Clipboard payloads may only point at attachments that already exist on the server.
      let serverId: String? = attachment.uploadedAttachmentId ?? { if case .ready(let id)? = services.uploads[attachment.id] { id } else { nil } }()
      if let serverId { add(ContextRecords.attachmentRecord(attachment, attachmentId: serverId)) }
    }
    guard !records.isEmpty else { return nil }
    return ComposerContextClipboardFragment(source: .init(environmentId: target.environmentId, threadId: target.threadId), records: records)
  }

  /// Brings pasted records into this draft. Images and files are fetched again from the environment
  /// they came from and attached under fresh ids; until the bytes arrive the chip is unresolved.
  /// Returns the context ids that changed so the pasted links can be rewritten.
  public func importClipboardFragment(_ fragment: ComposerContextClipboardFragment) -> [String: String] {
    var rewritten: [String: String] = [:]
    var downloads: [(ComposerAttachment, String)] = []
    let existingIds = Set(draft.records.map(\.contextIdentifier) + draft.attachments.map { ContextRecords.attachmentReference($0).contextId })
    for record in fragment.records {
      switch record {
      case .image(let image):
        let local = ComposerServices.newId()
        let attachment = ComposerAttachment(id: local, kind: .image, name: image.name, mimeType: image.mimeType, sizeBytes: image.sizeBytes)
        rewritten[image.contextId.rawValue] = ContextRecords.imageReference(attachment).contextId
        downloads.append((attachment, image.attachmentId))
      case .file(let file):
        let local = ComposerServices.newId()
        let attachment = ComposerAttachment(id: local, kind: .file, name: file.name, mimeType: file.mimeType, sizeBytes: file.sizeBytes)
        rewritten[file.contextId.rawValue] = ContextRecords.fileReference(attachment).contextId
        downloads.append((attachment, file.attachmentId))
      default:
        let id = record.contextIdentifier
        if existingIds.contains(id) { continue }
        services.editDrafts { $0.addRecord(target.key, record) }
      }
    }
    guard !downloads.isEmpty else { return rewritten }
    services.editDrafts { _ = $0.addAttachments(target.key, downloads.map(\.0), allowDuplicates: true) }
    let environment = services.environment
    let sourceEnvironment = fragment.source.environmentId
    for (attachment, serverId) in downloads {
      Task { [weak self] in
        guard let self else { return }
        do {
          let directory = self.services.storageDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let url = directory.appendingPathComponent(attachment.name.isEmpty ? "file" : attachment.name)
          try await environment.downloadAttachment(id: serverId, sourceEnvironmentId: sourceEnvironment, to: url)
          self.services.editDrafts { state in
            state.update(self.target.key) { draft in
              guard let index = draft.attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
              draft.attachments[index].localPath = url.path
            }
          }
          if let resolved = self.draft.attachments.first(where: { $0.id == attachment.id }) { self.services.startUpload(resolved, target: self.target) }
        } catch {
          self.services.post(ComposerNotice(kind: .error, title: "Couldn't copy \(attachment.name)", message: error.localizedDescription))
        }
      }
    }
    return rewritten
  }
}

extension ComposerServices {
  /// Edits the drafts and returns a value computed by the edit (ids a draft actually took).
  func editDraftsReturning<T>(_ edit: (inout ComposerDraftState) -> T) -> T {
    var result: T!
    editDrafts { result = edit(&$0) }
    return result
  }
}
