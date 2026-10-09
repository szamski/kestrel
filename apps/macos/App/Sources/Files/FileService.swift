import Foundation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// The file RPCs of one thread's workspace (`projects.*`, `assets.createUrl`), the same calls the web file
/// surfaces make. `cwd` is the thread's worktree, else its project's workspace root.
struct FileService: Sendable {
  let threadId: ThreadId
  let session: any EnvironmentSession
  let baseURL: URL
  let cwd: String

  enum Failure: Error, LocalizedError {
    case binary, notFile, message(String)

    var errorDescription: String? {
      switch self {
      case .binary: "This file contains binary data and cannot be shown as text."
      case .notFile: "This path is a folder."
      case .message(let text): text
      }
    }
  }

  /// Direct children of `directory` (nil: the workspace root), folders first.
  func list(_ directory: String?) async throws(Failure) -> (entries: [ProjectEntry], truncated: Bool) {
    let result = try await call(Rpc.projectsListEntries, ProjectListEntriesInput(cwd: cwd, directoryPath: directory)) {
      if case .projectListEntriesError(let e) = $0 { return .message(e.message) }
      return nil
    }
    let sorted = result.entries.sorted { a, b in
      if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
      return FileLogic.basename(a.path).localizedStandardCompare(FileLogic.basename(b.path)) == .orderedAscending
    }
    return (sorted, result.truncated)
  }

  func read(_ path: String) async throws(Failure) -> ProjectReadFileResult {
    try await call(Rpc.projectsReadFile, ProjectReadFileInput(cwd: cwd, relativePath: path)) {
      guard case .projectReadFileError(let e) = $0 else { return nil }
      switch e.failure {
      case .binary_file?: return .binary
      case .path_not_file?: return .notFile
      default: return .message(e.message)
      }
    }
  }

  func write(_ path: String, contents: String) async throws(Failure) {
    _ = try await call(Rpc.projectsWriteFile, ProjectWriteFileInput(cwd: cwd, relativePath: path, contents: contents)) {
      if case .projectWriteFileError(let e) = $0 { return .message(e.message) }
      return nil
    }
  }

  func searchEntries(_ query: String, limit: Int, kind: ProjectEntryKind? = nil) async throws(Failure) -> [ProjectEntry] {
    try await call(Rpc.projectsSearchEntries, ProjectSearchEntriesInput(cwd: cwd, query: query, limit: limit, kind: kind)) {
      if case .projectSearchEntriesError(let e) = $0 { return .message(e.message) }
      return nil
    }.entries
  }

  func searchContents(_ query: String, caseSensitive: Bool, wholeWord: Bool, useRegex: Bool) async throws(Failure) -> ProjectSearchContentsResult {
    try await call(
      Rpc.projectsSearchContents,
      ProjectSearchContentsInput(cwd: cwd, query: query, limit: 500, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)
    ) {
      if case .projectSearchContentsError(let e) = $0 { return .message(e.message) }
      return nil
    }
  }

  /// Signed, short-lived URL of the file's bytes: images, PDFs, audio and video load from it with plain GETs.
  func assetURL(_ path: String) async throws(Failure) -> URL {
    let resource = AssetResource.workspaceFile(AssetResourceWorkspaceFile(threadId: threadId, path: FileLogic.absolutePath(path, root: cwd)))
    let result = try await call(Rpc.assetsCreateUrl, AssetCreateUrlInput(resource: resource)) { _ in nil }
    guard let url = URL(string: result.relativeUrl, relativeTo: baseURL)?.absoluteURL else { throw .message("The server returned an unusable file URL.") }
    return url
  }

  /// The bytes behind `assetURL`.
  func assetData(_ path: String) async throws(Failure) -> Data {
    let url = try await assetURL(path)
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { throw Failure.message("The file could not be loaded (HTTP \(status)).") }
      return data
    } catch let failure as Failure {
      throw failure
    } catch {
      throw .message(error.localizedDescription)
    }
  }

  /// One RPC; `describe` turns the spec's own typed error into a `Failure`, everything else gets a generic message.
  private func call<P: Encodable & Sendable, S: Decodable & Sendable, F: Decodable & Sendable & Error>(
    _ spec: RpcSpec<P, S, F>, _ payload: P, _ describe: (F) -> Failure?
  ) async throws(Failure) -> S {
    do throws(RpcError<F>) {
      return try await session.call(spec, payload)
    } catch {
      switch error {
      case .failure(let typed): throw describe(typed) ?? .message("The server refused the request.")
      case .interrupted: throw .message("Cancelled.")
      case .defect, .transportClosed: throw .message("The environment could not complete the request. Check the connection and try again.")
      }
    }
  }
}

extension AppModel {
  /// The roots a file link can be relative to, worktree first.
  func fileRoots(of key: ScopedThreadKey) -> [String] {
    [runtime.threadShell(key)?.shell.worktreePath, workspaceRoot(of: key)].compactMap { $0 }
  }

  func fileService(for key: ScopedThreadKey) async -> FileService? {
    guard let cwd = fileRoots(of: key).first, let environment = await runtime.runtime(for: key.environmentId),
      let session = environment.supervisor.session.value
    else { return nil }
    return FileService(threadId: key.threadId, session: session, baseURL: environment.entry.httpBaseURL, cwd: cwd)
  }
}
