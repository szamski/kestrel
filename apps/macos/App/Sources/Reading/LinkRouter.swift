import AppKit
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Protocol

extension AppModel {
  /// Web links open in the browser. File links open locally when the environment runs on this Mac,
  /// else through the server's `shell.openInEditor`, else the path is copied. Citations, context
  /// chips, anchors and artifact actions do nothing yet.
  func open(_ link: MarkdownLink, in key: ScopedThreadKey) {
    switch link {
    case .web(let url):
      NSWorkspace.shared.open(url)
    case .file(let target):
      Task { await openFile(target, in: key) }
    case .citation, .context, .anchor, .artifactTemplate, .image:
      break
    }
  }

  private func openFile(_ target: MarkdownFileTarget, in key: ScopedThreadKey) async {
    guard let environment = await runtime.runtime(for: key.environmentId) else { return }
    let isLocal = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(environment.entry.httpBaseURL.host(percentEncoded: false) ?? "")
    if isLocal, FileManager.default.fileExists(atPath: target.path) {
      NSWorkspace.shared.open(URL(fileURLWithPath: target.path))
      return
    }
    if let editor = runtime.serverConfigs[key.environmentId]?.config.availableEditors.first, let session = environment.supervisor.session.value {
      var place = target.path
      if let line = target.line { place += ":\(line)" + (target.column.map { ":\($0)" } ?? "") }
      if (try? await session.call(Rpc.shellOpenInEditor, LaunchEditorInput(cwd: place, editor: editor))) != nil { return }
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(target.path, forType: .string)
  }
}
