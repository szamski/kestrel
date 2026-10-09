import AppKit
import Foundation
import Observation
import T3ClientRuntime

/// One opened file (a `file:<path>` tab): what was loaded, the edit buffer, and save state. It lives in
/// `FileSurfaces` so switching tabs or threads keeps unsaved edits.
@MainActor
@Observable
final class FileDocument {
  enum Phase: Equatable {
    case loading
    /// Source text (editable unless truncated).
    case text
    /// Bytes behind a signed URL: image, PDF, audio or video.
    case asset(URL)
    case binary
    case folder
    case failed(String)
  }

  let key: ScopedThreadKey
  /// Workspace-relative path.
  let path: String
  let kind: FilePreviewKind
  private(set) var phase = Phase.loading
  /// The text on disk as last loaded or saved.
  private(set) var saved = ""
  /// The buffer the editor shows; differs from `saved` while the file has unsaved edits.
  var text = ""
  private(set) var truncated = false
  private(set) var byteLength = 0
  var isEditing = false
  private(set) var isSaving = false
  var saveError: String?

  @ObservationIgnored private weak var app: AppModel?
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  init(app: AppModel, key: ScopedThreadKey, path: String) {
    self.app = app
    self.key = key
    self.path = path
    kind = FileLogic.kind(of: path)
  }

  var isDirty: Bool { phase == .text && text != saved }
  var canEdit: Bool { phase == .text && !truncated }
  var name: String { FileLogic.basename(path) }

  /// Reads the file again unless the buffer holds unsaved edits.
  func load() {
    guard !isDirty, !isSaving else { return }
    loadTask?.cancel()
    loadTask = Task { [weak self] in await self?.performLoad() }
  }

  private func performLoad() async {
    guard let app, let service = await app.fileService(for: key) else {
      phase = .failed("The environment is not connected.")
      return
    }
    if phase != .text { phase = .loading }
    if kind.isBinaryAsset {
      do { phase = .asset(try await service.assetURL(path)) } catch { if !Task.isCancelled { phase = .failed(error.localizedDescription) } }
      return
    }
    do throws(FileService.Failure) {
      let result = try await service.read(path)
      if Task.isCancelled { return }
      saved = result.contents
      text = result.contents
      truncated = result.truncated
      byteLength = result.byteLength
      phase = .text
    } catch {
      if Task.isCancelled { return }
      switch error {
      case .binary: phase = .binary
      case .notFile: phase = .folder
      case .message(let message): phase = .failed(message)
      }
    }
  }

  /// The bytes of an image or PDF.
  func assetData() async throws -> Data {
    guard let app, let service = await app.fileService(for: key) else { throw FileService.Failure.message("The environment is not connected.") }
    return try await service.assetData(path)
  }

  /// Writes the buffer; true on success.
  @discardableResult
  func save() async -> Bool {
    guard canEdit, isDirty, !isSaving, let app, let service = await app.fileService(for: key) else { return false }
    isSaving = true
    saveError = nil
    defer { isSaving = false }
    let contents = text
    do {
      try await service.write(path, contents: contents)
      saved = contents
      return true
    } catch {
      saveError = error.localizedDescription
      return false
    }
  }

  func discardEdits() {
    text = saved
    isEditing = false
    saveError = nil
  }
}

/// The open documents and file trees by thread, so tabs keep their state while another tab or thread is shown
/// (same lifetime idea as `LiveComposers`).
@MainActor
final class FileSurfaces {
  static let shared = FileSurfaces()
  private var documents: [String: FileDocument] = [:]
  private var trees: [String: FilesTreeModel] = [:]

  func document(_ path: String, in key: ScopedThreadKey, app: AppModel) -> FileDocument {
    let id = "\(key.description)|\(path)"
    if let existing = documents[id] { return existing }
    let document = FileDocument(app: app, key: key, path: path)
    documents[id] = document
    return document
  }

  func existingDocument(_ path: String, in key: ScopedThreadKey) -> FileDocument? { documents["\(key.description)|\(path)"] }

  func closeDocument(_ path: String, in key: ScopedThreadKey) { documents["\(key.description)|\(path)"] = nil }

  func tree(in key: ScopedThreadKey, app: AppModel) -> FilesTreeModel {
    let id = key.description
    if let existing = trees[id] { return existing }
    let tree = FilesTreeModel(app: app, key: key)
    trees[id] = tree
    return tree
  }
}
