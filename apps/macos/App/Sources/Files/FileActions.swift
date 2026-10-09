import AppKit
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Diff
import T3Protocol

/// What a file row, a preview header or a search hit can do with a workspace-relative path. Shared by the Files
/// tab, the preview, the picker and the content search so each surface offers the same actions.
extension AppModel {
  /// True when the environment's server runs on this Mac, so its paths are paths on this disk.
  func isLocalEnvironment(_ key: ScopedThreadKey) -> Bool {
    guard let host = runtime.connectionEntry(key.environmentId)?.httpBaseURL.host(percentEncoded: false) else { return false }
    return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
  }

  func absoluteFilePath(_ relative: String, in key: ScopedThreadKey) -> String {
    FileLogic.absolutePath(relative, root: fileRoots(of: key).first ?? "")
  }

  /// Through the server's `shell.openInEditor` when it offers an editor, else the default app for a local file,
  /// else the path lands on the pasteboard.
  func openInEditor(_ relative: String, line: Int? = nil, in key: ScopedThreadKey) {
    let absolute = absoluteFilePath(relative, in: key)
    Task {
      if let editor = runtime.serverConfigs[key.environmentId]?.config.availableEditors.first,
        let session = await runtime.runtime(for: key.environmentId)?.supervisor.session.value
      {
        let place = line.map { "\(absolute):\($0)" } ?? absolute
        if (try? await session.call(Rpc.shellOpenInEditor, LaunchEditorInput(cwd: place, editor: editor))) != nil { return }
      }
      if isLocalEnvironment(key), FileManager.default.fileExists(atPath: absolute) {
        NSWorkspace.shared.open(URL(fileURLWithPath: absolute))
      } else {
        copyToPasteboard(absolute)
        errorMessage = "No editor is available for this environment; the path was copied."
      }
    }
  }

  func revealInFinder(_ relative: String, in key: ScopedThreadKey) {
    let url = URL(fileURLWithPath: absoluteFilePath(relative, in: key))
    guard isLocalEnvironment(key), FileManager.default.fileExists(atPath: url.path) else {
      errorMessage = "\(FileLogic.basename(relative)) is not on this Mac."
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// The file as a link chip at the caret of the thread's composer (the web's `composerMentionFromTreePath`).
  @discardableResult
  func addFileToComposer(_ relative: String, in key: ScopedThreadKey) -> Bool {
    guard let model = LiveComposers.shared.model(for: key.description) else {
      errorMessage = "Open the thread's composer to attach a file."
      return false
    }
    return model.insertText("\(ComposerMenu.fileLink(forPath: relative)) ", at: .cursor, ensureLeadingBoundary: true)
  }

  /// Selected lines of a file as a `review-comment` chip (the web's `buildFileReviewComment`).
  @discardableResult
  func addFileSelectionToComposer(path: String, contents: String, start: Int, end: Int, comment: String, in key: ScopedThreadKey) -> Bool {
    let draft = ReviewCommentDraft(
      id: UUID().uuidString, sectionId: "file:\(path)", sectionTitle: "File comment", filePath: path, startIndex: start - 1, endIndex: end - 1,
      rangeLabel: FileLogic.rangeLabel(start: start, end: end), text: comment.trimmingCharacters(in: .whitespacesAndNewlines),
      diff: FileLogic.lines(contents, from: start, to: end), fenceLanguage: FileLogic.fenceLanguage(forPath: path))
    guard insertReviewComment(draft, in: key) else {
      errorMessage = "Open the thread's composer to attach a file comment."
      return false
    }
    return true
  }
}
