import Foundation
import Observation
import T3Contracts

/// State shared by every composer: the server catalog, drafts, the stash, queued follow-ups and
/// attachment uploads. One instance per app; each `ComposerModel` is a view of one thread onto it.
///
/// Persistence goes through the environment's opaque storage (`composer-drafts`, `prompt-stash`):
/// drafts save debounced after edits, the stash saves immediately because stashing is deliberate
/// and the composer is cleared on the strength of the write.
@MainActor
@Observable
public final class ComposerServices {
  public static let draftsStorageKey = "composer-drafts-v1"
  public static let stashStorageKey = "prompt-stash-v2"
  static let persistDebounce: Duration = .milliseconds(300)
  static let maxConcurrentUploads = 3

  @ObservationIgnored public let environment: any ComposerEnvironment
  /// Where staged attachment bytes live until they are sent or removed.
  @ObservationIgnored public let storageDirectory: URL

  public private(set) var catalog: ComposerCatalog
  public private(set) var drafts: ComposerDraftState
  public private(set) var stash: PromptStash
  public private(set) var queue = QueuedMessageStore()
  public private(set) var queueTargets: [String: ComposerTarget] = [:]
  public private(set) var uploads: [String: AttachmentRules.UploadState] = [:]
  public internal(set) var notices: [ComposerNotice] = []
  /// Set when the last storage write failed, for the stash "could not save" message.
  public private(set) var storageError: String?

  @ObservationIgnored private var persistTask: Task<Void, Never>?
  @ObservationIgnored private var catalogTask: Task<Void, Never>?
  @ObservationIgnored private var dispatchers: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var uploadTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var uploadWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  @ObservationIgnored private var pendingUploads: [(attachment: ComposerAttachment, target: ComposerTarget)] = []
  @ObservationIgnored private var activeUploads = 0
  @ObservationIgnored private var started = false

  public init(environment: any ComposerEnvironment, storageDirectory: URL? = nil, catalog: ComposerCatalog = ComposerCatalog()) {
    self.environment = environment
    self.storageDirectory =
      storageDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("T3Composer/attachments", isDirectory: true)
    self.catalog = catalog
    self.drafts = ComposerDraftState()
    self.stash = PromptStash()
  }

  /// Loads persisted state and starts following the catalog. Idempotent.
  public func start() async {
    guard !started else { return }
    started = true
    catalog = await environment.catalog()
    drafts = ComposerDraftState.decode(await environment.loadStorage(key: Self.draftsStorageKey))
    if let data = await environment.loadStorage(key: Self.stashStorageKey), let entries = try? JSONDecoder().decode([PromptStashEntry].self, from: data) {
      stash = PromptStash(entries: entries)
    }
    let updates = environment.catalogUpdates()
    catalogTask = Task { [weak self] in
      for await next in updates { self?.catalog = next }
    }
  }

  public func stop() {
    catalogTask?.cancel()
    persistTask?.cancel()
    for task in dispatchers.values { task.cancel() }
    for task in uploadTasks.values { task.cancel() }
    started = false
  }

  // MARK: Drafts

  /// Applies an edit to the drafts and schedules the debounced save.
  public func editDrafts(_ edit: (inout ComposerDraftState) -> Void) {
    edit(&drafts)
    schedulePersist()
  }

  private func schedulePersist() {
    persistTask?.cancel()
    persistTask = Task { [weak self] in
      try? await Task.sleep(for: Self.persistDebounce)
      guard !Task.isCancelled else { return }
      await self?.persistDraftsNow()
    }
  }

  /// Writes the drafts immediately (app termination, thread switch).
  public func persistDraftsNow() async {
    persistTask?.cancel()
    guard let data = try? drafts.encoded() else { return }
    do { try await environment.saveStorage(key: Self.draftsStorageKey, data: data) } catch { storageError = error.localizedDescription }
  }

  // MARK: Stash

  /// Persists the stash; returns false when the write failed (nothing may be cleared then).
  @discardableResult
  func persistStash() async -> Bool {
    guard let data = try? JSONEncoder().encode(stash.entries) else { return false }
    do {
      try await environment.saveStorage(key: Self.stashStorageKey, data: data)
      storageError = nil
      return true
    } catch {
      storageError = error.localizedDescription
      return false
    }
  }

  func editStash<T>(_ edit: (inout PromptStash) -> T) -> T { edit(&stash) }

  func replaceStash(_ next: PromptStash) { stash = next }

  // MARK: Queue

  func editQueue<T>(_ edit: (inout QueuedMessageStore) -> T) -> T { edit(&queue) }

  func registerQueueTarget(_ target: ComposerTarget) { queueTargets[target.key] = target }

  // MARK: Uploads

  func setUpload(_ id: String, _ state: AttachmentRules.UploadState?) {
    uploads[id] = state
    if let state {
      switch state {
      case .ready, .failed: resumeWaiters(id)
      case .uploading: break
      }
    } else {
      resumeWaiters(id)
    }
  }

  private func resumeWaiters(_ id: String) {
    for continuation in uploadWaiters.removeValue(forKey: id) ?? [] { continuation.resume() }
  }

  /// Starts (or joins) the upload of an attachment. Uploads begin when the attachment is added;
  /// at most three run at a time.
  func startUpload(_ attachment: ComposerAttachment, target: ComposerTarget) {
    if case .ready? = uploads[attachment.id] { return }
    if case .failed? = uploads[attachment.id] { return }
    if uploadTasks[attachment.id] != nil || pendingUploads.contains(where: { $0.attachment.id == attachment.id }) { return }
    // A file that already carries a server copy from this environment needs no upload.
    if let uploadedId = attachment.uploadedAttachmentId, attachment.uploadEnvironmentId == target.environmentId {
      setUpload(attachment.id, .ready(attachmentId: uploadedId))
      return
    }
    setUpload(attachment.id, .uploading(progress: 0))
    pendingUploads.append((attachment, target))
    pumpUploads()
  }

  private func pumpUploads() {
    while activeUploads < Self.maxConcurrentUploads, !pendingUploads.isEmpty {
      let job = pendingUploads.removeFirst()
      activeUploads += 1
      uploadTasks[job.attachment.id] = Task { [weak self] in
        await self?.runUpload(job.attachment, target: job.target)
      }
    }
  }

  private func runUpload(_ attachment: ComposerAttachment, target: ComposerTarget) async {
    defer {
      uploadTasks[attachment.id] = nil
      activeUploads -= 1
      pumpUploads()
    }
    guard let path = attachment.localPath, FileManager.default.fileExists(atPath: path) else {
      setUpload(attachment.id, .failed(reason: "Original file is no longer available", attachmentId: nil))
      return
    }
    let request = ComposerUploadRequest(
      attachmentId: attachment.id, kind: attachment.kind, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes,
      fileURL: URL(fileURLWithPath: path))
    let steps = ProgressSteps()
    do {
      let uploadedId = try await environment.uploadAttachment(request) { [weak self] progress in
        // Report in 5% steps: a progress label does not need every byte.
        guard steps.advance(progress) else { return }
        Task { @MainActor in
          guard let self, case .uploading? = self.uploads[attachment.id] else { return }
          self.uploads[attachment.id] = .uploading(progress: progress)
        }
      }
      if Task.isCancelled {
        await environment.deleteUploadedAttachment(id: uploadedId)
        return
      }
      setUpload(attachment.id, .ready(attachmentId: uploadedId))
      if attachment.kind == .file {
        editDrafts { $0.setFileUpload(target.key, attachmentId: attachment.id, environmentId: target.environmentId, uploadedId: uploadedId) }
      }
    } catch is CancellationError {
      return
    } catch {
      setUpload(attachment.id, .failed(reason: error.localizedDescription.isEmpty ? "Upload failed" : error.localizedDescription, attachmentId: nil))
    }
  }

  /// Cancels and forgets an attachment's upload, deleting the server copy this session minted.
  func cancelUpload(_ id: String) {
    uploadTasks[id]?.cancel()
    pendingUploads.removeAll { $0.attachment.id == id }
    let state = uploads[id]
    setUpload(id, nil)
    if case .ready(let serverId)? = state {
      Task { await environment.deleteUploadedAttachment(id: serverId) }
    }
  }

  /// Retry after a failure.
  func retryUpload(_ attachment: ComposerAttachment, target: ComposerTarget) {
    guard case .failed? = uploads[attachment.id] else { return }
    setUpload(attachment.id, nil)
    startUpload(attachment, target: target)
  }

  /// Suspends until every id has settled (ready or failed). Ids with no upload settle at once.
  func awaitUploads(_ ids: [String]) async {
    for id in ids {
      while true {
        switch uploads[id] {
        case .uploading?:
          await withCheckedContinuation { uploadWaiters[id, default: []].append($0) }
        default: break
        }
        if case .uploading? = uploads[id] { continue }
        break
      }
    }
  }

  // MARK: Dispatch bookkeeping used by the queue dispatcher

  func trackDispatcher(_ key: String, _ task: Task<Void, Never>) { dispatchers[key] = task }
  func dispatcherRunning(_ key: String) -> Bool { dispatchers[key] != nil }
  func endDispatcher(_ key: String) { dispatchers[key] = nil }
}

/// Throttles upload progress to 5% steps.
final class ProgressSteps: @unchecked Sendable {
  private let lock = NSLock()
  private var last = -1

  func advance(_ progress: Double) -> Bool {
    let step = Int(progress * 20)
    lock.lock()
    defer { lock.unlock() }
    if step == last { return false }
    last = step
    return true
  }
}
