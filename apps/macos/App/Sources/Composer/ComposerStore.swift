import SwiftUI
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Markdown

/// What the composer needs the app for: the shared services (drafts, queue, uploads) and the
/// composer targets of threads. Each open thread owns its `ComposerModel`; drafts live in the
/// services, so they survive switching threads and relaunching.
@MainActor
final class ComposerStore {
  let environment: RuntimeComposerEnvironment
  let services: ComposerServices

  init(runtime: ClientRuntime, directory: URL) {
    let root = directory.appending(path: "composer", directoryHint: .isDirectory)
    environment = RuntimeComposerEnvironment(runtime: runtime, directory: root)
    services = ComposerServices(environment: environment, storageDirectory: root.appending(path: "attachments", directoryHint: .isDirectory))
  }

  func model(for target: ComposerTarget) -> ComposerModel { ComposerModel(target: target, services: services) }
}

extension AppModel {
  /// The composer target of a thread, or of a project's draft thread (`draft`). Nil until the shell
  /// of the thread (and so its project) is known.
  func composerTarget(for key: ScopedThreadKey, draft: DraftThread? = nil) -> ComposerTarget? {
    let shell = runtime.threadShell(key)?.shell
    guard let projectId = draft?.projectId ?? shell?.projectId,
      let project = runtime.projects.first(where: { $0.environmentId == key.environmentId && $0.projectId == projectId })
    else { return nil }
    var repository: String?
    if let identity = project.project.repositoryIdentity.flatMap({ $0 }), let owner = identity.owner, let name = identity.name { repository = "\(owner)/\(name)" }
    let host = runtime.environments.isEmpty ? nil : environmentHost(key.environmentId)
    return ComposerTarget(
      key: key.description, environmentId: key.environmentId.rawValue, threadId: key.threadId.rawValue, projectId: projectId.rawValue,
      cwd: shell?.worktreePath ?? project.project.workspaceRoot, repository: repository, isDraftThread: draft != nil,
      isLocalEnvironment: ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? ""))
  }

  private func environmentHost(_ id: EnvironmentId) -> String? { runtime.connectionEntry(id)?.httpBaseURL.host(percentEncoded: false) }

  /// A file chip opens like a file link: locally when the environment runs on this Mac, else through the server.
  func activateChip(_ atom: RichAtom, in key: ScopedThreadKey, cwd: String?) {
    guard case .mention(let path, _) = atom else { return }
    let absolute = path.hasPrefix("/") ? path : (cwd.map { ($0 as NSString).appendingPathComponent(path) } ?? path)
    open(.file(MarkdownFileTarget(path: absolute)), in: key)
  }
}
