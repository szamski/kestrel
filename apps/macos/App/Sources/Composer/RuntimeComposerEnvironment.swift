import Foundation
import Observation
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Protocol
import T3Timeline

/// `ComposerEnvironment` on top of `ClientRuntime`: the composer's catalog is the server config of
/// the active environment, thread state follows a shared `ThreadDetailModel` subscription, commands
/// go through `EnvironmentRuntime.dispatch` and drafts live as files in the app data directory.
@MainActor @Observable
final class RuntimeComposerEnvironment: ComposerEnvironment {
  @ObservationIgnored private let runtime: ClientRuntime
  @ObservationIgnored private let directory: URL
  /// The environment whose server config the (single, shared) catalog shows: the open thread's.
  var activeEnvironmentId: EnvironmentId?
  /// Called once a draft thread exists on the server (its first turn was accepted).
  @ObservationIgnored var onThreadStarted: (@MainActor (ScopedThreadKey) -> Void)?
  /// The branch and worktree a draft was set up with (source control strip); asked for at the draft's first send.
  @ObservationIgnored var draftSend: (@MainActor (ComposerTarget) throws -> SourceControlStore.DraftSend)?
  private var favorites: Set<String>

  init(runtime: ClientRuntime, directory: URL) {
    self.runtime = runtime
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    favorites = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appending(path: "favorites.json")))) ?? [])
  }

  // MARK: Catalog

  private var environmentId: EnvironmentId? { activeEnvironmentId ?? runtime.environments.first?.environmentId }

  private func buildCatalog() -> ComposerCatalog {
    // Device preferences come from the settings store; reading them here keeps the catalog live.
    let preferences = ClientSettingsStore.shared.client
    let config = environmentId.flatMap { runtime.serverConfigs[$0]?.config }
    let capabilities = config?.environment.capabilities
    let server = config?.settings
    var models = ComposerModelSettings(planModeEnabled: preferences.planModeEnabled, favoriteModelKeys: favorites)
    // Explicit `providerInstances` enable or disable instances (the legacy per-driver `providers` switches left the contracts).
    for (id, instance) in server?.providerInstances ?? [:] {
      models.instanceEnabled[id] = instance.enabled ?? true
      if case .object(let config)? = instance.config, case .array(let custom)? = config["customModels"] {
        models.instanceCustomModels[id] = custom.compactMap { value in
          switch value {
          case .string(let slug): CustomModelDefinition(slug: slug)
          case .object(let object): object["slug"].flatMap { if case .string(let slug) = $0 { slug } else { nil } }.map {
            CustomModelDefinition(slug: $0, name: object["name"].flatMap { if case .string(let name) = $0 { name } else { nil } })
          }
          default: nil
          }
        }
      }
    }
    let settings = ComposerSettings(
      sendShortcut: SendShortcut(rawValue: preferences.sendShortcut.rawValue) ?? .enter,
      followUpBehavior: FollowUpBehavior(rawValue: preferences.followUpBehavior.rawValue) ?? .queue,
      showSkillsInSlashMenu: preferences.showSkillsInSlashMenu, richTextEnabled: preferences.composerRichTextEnabled,
      collapseOnScroll: preferences.composerCollapseOnScroll, contextWindowMeterEnabled: preferences.contextWindowMeterEnabled, models: models)
    return ComposerCatalog(
      providers: config?.providers ?? [], settings: settings,
      capabilities: ComposerCapabilities(
        attachments: .init(
          attachmentUploadsCapabilityKnown: config != nil, supportsAttachmentUploads: capabilities?.attachmentUploads == true,
          maxFileAttachmentBytes: capabilities?.fileAttachments?.maxUploadBytes),
        inlineMessageContext: capabilities?.inlineMessageContext == true),
      defaultModelSelection: server?.defaultModelSelection.map { ModelSelection(instanceId: $0.instanceId, model: $0.model, options: $0.options) },
      defaultRuntimeMode: server.map { RuntimeMode(rawValue: $0.defaultRuntimeMode.rawValue) } ?? .fullAccess)
  }

  func catalog() async -> ComposerCatalog { buildCatalog() }

  nonisolated func catalogUpdates() -> AsyncStream<ComposerCatalog> {
    AsyncStream { continuation in
      let task = Task { @MainActor [self] in
        var last: ComposerCatalog?
        for await next in Observations({ self.buildCatalog() }) {
          if let last, last.providers == next.providers, last.settings == next.settings, last.capabilities == next.capabilities,
            last.defaultModelSelection == next.defaultModelSelection, last.defaultRuntimeMode == next.defaultRuntimeMode
          {
            continue
          }
          last = next
          continuation.yield(next)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func setFavoriteModel(instanceId: String, slug: String, isFavorite: Bool) async {
    let key = "\(instanceId):\(slug)"
    if isFavorite { favorites.insert(key) } else { favorites.remove(key) }
    if let data = try? JSONEncoder().encode(favorites.sorted()) { try? data.write(to: directory.appending(path: "favorites.json"), options: .atomic) }
  }

  // MARK: Thread state

  private struct Fingerprint: Equatable, Sendable {
    var unavailable: String?
    var hasThread = false
    var messages = 0
    var lastMessage = ""
    var activities = 0
    var lastActivity = ""
    var session = ""
    var latestTurn = ""
    var modes = ""
  }

  private func unavailableReason(_ id: EnvironmentId) -> String? {
    guard let status = runtime.environments.first(where: { $0.environmentId == id }) else { return "This environment is no longer available." }
    if status.connection.phase == .connected { return nil }
    return status.enabled ? "Reconnecting to \(status.label)…" : "\(status.label) is switched off."
  }

  nonisolated func threadSnapshots(for target: ComposerTarget) -> AsyncStream<ComposerThreadSnapshot> {
    AsyncStream { continuation in
      let task = Task { @MainActor [self] in await follow(target, continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func follow(_ target: ComposerTarget, _ out: AsyncStream<ComposerThreadSnapshot>.Continuation) async {
    let environmentId = EnvironmentId(target.environmentId)
    let key = ScopedThreadKey(environmentId: environmentId, threadId: ThreadId(target.threadId))
    let detail = target.isDraftThread ? nil : await runtime.openThread(key)
    guard !Task.isCancelled else {
      await detail?.close()
      return
    }
    let fingerprints = Observations { [self] () -> Fingerprint in
      var fingerprint = Fingerprint(unavailable: unavailableReason(environmentId))
      guard let thread = detail?.thread else { return fingerprint }
      fingerprint.hasThread = true
      fingerprint.messages = thread.messages.count
      fingerprint.lastMessage = thread.messages.last?.id.rawValue ?? ""
      fingerprint.activities = thread.activities.count
      fingerprint.lastActivity = thread.activities.last?.id.rawValue ?? ""
      if let session = thread.session {
        fingerprint.session = "\(session.status.rawValue)|\(session.updatedAt.rawValue)|\(session.activeTurnId?.rawValue ?? "")|\(session.providerInstanceId?.rawValue ?? "")"
      }
      if let turn = thread.latestTurn {
        fingerprint.latestTurn = "\(turn.turnId.rawValue)|\(turn.startedAt?.rawValue ?? "")|\(turn.completedAt?.rawValue ?? "")"
      }
      fingerprint.modes = "\(thread.runtimeMode.rawValue)|\(thread.interactionMode.rawValue)|\(thread.modelSelection.instanceId.rawValue)|\(thread.modelSelection.model)"
      return fingerprint
    }
    var last: Fingerprint?
    for await fingerprint in fingerprints {
      if Task.isCancelled { break }
      guard fingerprint != last else { continue }
      last = fingerprint
      if let thread = detail?.thread {
        out.yield(ComposerThreadSnapshot(thread: thread, unavailableReason: fingerprint.unavailable))
      } else if target.isDraftThread {
        let project = runtime.projects.first { $0.environmentId == environmentId && $0.projectId.rawValue == target.projectId }
        let unavailable = fingerprint.unavailable ?? (project == nil ? "This project is not available." : nil)
        out.yield(
          ComposerThreadSnapshot(
            phase: unavailable == nil ? .ready : .disconnected, projectModelSelection: project?.project.defaultModelSelection, isFirstMessage: true,
            unavailableReason: unavailable))
      } else {
        // Not loaded yet: never "ready" (a queued send must not go out) and never "first message" (it would retitle the thread).
        out.yield(
          ComposerThreadSnapshot(
            phase: fingerprint.unavailable == nil ? .connecting : .disconnected, isFirstMessage: false, isDetailLoaded: false,
            unavailableReason: fingerprint.unavailable))
      }
    }
    await detail?.close()
  }

  // MARK: Commands

  private func dispatch(_ command: V1.ClientOrchestrationCommand, _ environmentId: EnvironmentId, thread: ThreadId) async throws {
    guard let environment = await runtime.runtime(for: environmentId) else { throw ComposerEnvironmentError("The environment is not connected.") }
    do { try await environment.dispatch(command, thread: thread) } catch { throw ComposerEnvironmentError(error.message) }
  }

  func sendTurn(_ command: V1.ClientOrchestrationCommandThreadTurnStart, target: ComposerTarget, titleSeed: String?, isFirstMessage: Bool) async throws {
    let environmentId = EnvironmentId(target.environmentId)
    let key = ScopedThreadKey(environmentId: environmentId, threadId: command.threadId)
    var command = command
    if target.isDraftThread {
      guard let projectId = target.projectId else { throw ComposerEnvironmentError("This draft has no project.") }
      let project = runtime.projects.first { $0.environmentId == environmentId && $0.projectId.rawValue == projectId }
      guard let model = command.modelSelection ?? project?.project.defaultModelSelection else { throw ComposerEnvironmentError("Pick a model before sending.") }
      // The thread is created with its first turn, so an abandoned draft never leaves an empty thread behind.
      let send = try draftSend?(target) ?? .init()
      command.bootstrap = V1.ClientOrchestrationCommandThreadTurnStartBootstrap(
        createThread: V1.ClientOrchestrationCommandThreadTurnStartBootstrapCreateThread(
          projectId: ProjectId(projectId), title: titleSeed ?? "New thread", modelSelection: model, runtimeMode: command.runtimeMode,
          interactionMode: command.interactionMode, branch: send.branch, worktreePath: send.worktreePath, createdAt: command.createdAt),
        prepareWorktree: send.prepare, runSetupScript: send.prepare == nil ? nil : true)
      try await dispatch(.threadTurnStart(command), environmentId, thread: command.threadId)
      onThreadStarted?(key)
      return
    }
    // Same side effects as the web composer: title from the first message, then model and modes.
    let shell = runtime.threadShell(key)?.shell
    if isFirstMessage, let titleSeed {
      try await dispatch(ThreadCommand.updateMetadata(command.threadId, title: titleSeed), environmentId, thread: command.threadId)
    }
    if let model = command.modelSelection, let shell, model != shell.modelSelection {
      try await dispatch(ThreadCommand.updateMetadata(command.threadId, modelSelection: model), environmentId, thread: command.threadId)
    }
    if let shell, command.runtimeMode != shell.runtimeMode {
      try await dispatch(ThreadCommand.setRuntimeMode(command.threadId, command.runtimeMode), environmentId, thread: command.threadId)
    }
    if let shell, command.interactionMode.rawValue != shell.interactionMode.rawValue {
      try await dispatch(ThreadCommand.setInteractionMode(command.threadId, command.interactionMode), environmentId, thread: command.threadId)
    }
    try await dispatch(.threadTurnStart(command), environmentId, thread: command.threadId)
  }

  func interruptTurn(_ command: V1.ClientOrchestrationCommandThreadTurnInterrupt, target: ComposerTarget) async throws {
    try await dispatch(.threadTurnInterrupt(command), EnvironmentId(target.environmentId), thread: command.threadId)
  }

  func respondToApproval(_ command: V1.ClientOrchestrationCommandThreadApprovalRespond, target: ComposerTarget) async throws {
    try await dispatch(.threadApprovalRespond(command), EnvironmentId(target.environmentId), thread: command.threadId)
  }

  func respondToUserInput(_ command: V1.ClientOrchestrationCommandThreadUserInputRespond, target: ComposerTarget) async throws {
    try await dispatch(.threadUserInputRespond(command), EnvironmentId(target.environmentId), thread: command.threadId)
  }

  func dismissUserInput(requestId: V1.ApprovalRequestId, target: ComposerTarget) async throws {
    let threadId = ThreadId(target.threadId)
    try await dispatch(ThreadCommand.dismissUserInput(threadId, requestId: requestId), EnvironmentId(target.environmentId), thread: threadId)
  }

  // MARK: Context sources

  private func session(_ environmentId: EnvironmentId?) async throws -> any EnvironmentSession {
    guard let environmentId, let environment = await runtime.runtime(for: environmentId), let session = environment.supervisor.session.value else {
      throw ComposerEnvironmentError("The environment is not connected.")
    }
    return session
  }

  private func call<P, S, F>(_ environmentId: EnvironmentId?, _ spec: RpcSpec<P, S, F>, _ payload: P) async throws -> S {
    let session = try await session(environmentId)
    do { return try await session.call(spec, payload) } catch { throw ComposerEnvironmentError("The server could not complete the request: \(error)") }
  }

  func searchWorkspaceEntries(cwd: String, query: String, limit: Int) async throws -> ProjectSearchEntriesResult {
    try await call(environmentId, Rpc.projectsSearchEntries, ProjectSearchEntriesInput(cwd: cwd, query: query, limit: limit))
  }

  private func candidate(
    projectId: String, repository: String, number: Int, title: String, url: String, state: PullRequestState, isDraft: Bool, head: String, base: String,
    updatedAt: IsoDateTime, author: PullRequestActor?, hostSearched: Bool
  ) -> ComposerPullRequestCandidate {
    ComposerPullRequestCandidate(
      projectId: projectId, repository: repository, number: number, title: title, url: url,
      state: VcsStatusRemoteResultPrState(rawValue: state.rawValue), isDraft: isDraft, headBranch: head, baseBranch: base, updatedAt: updatedAt.rawValue,
      authorLogin: author?.login, hostSearched: hostSearched)
  }

  func listPullRequests(projectId: String, query: String?, limit: Int) async throws -> [ComposerPullRequestCandidate] {
    let owner = runtime.projects.first { $0.projectId.rawValue == projectId }?.environmentId ?? environmentId
    let result = try await call(
      owner, Rpc.pullRequestsList, PullRequestListInput(state: .all, projectId: ProjectId(projectId), limit: limit, query: query))
    return result.entries.map {
      candidate(
        projectId: $0.projectId.rawValue, repository: $0.repository, number: $0.number, title: $0.title, url: $0.url, state: $0.state, isDraft: $0.isDraft,
        head: $0.headBranch, base: $0.baseBranch, updatedAt: $0.updatedAt, author: $0.author, hostSearched: query != nil)
    }
  }

  func resolvePullRequest(projectId: String, repository: String, number: Int) async throws -> ComposerPullRequestCandidate? {
    let owner = runtime.projects.first { $0.projectId.rawValue == projectId }?.environmentId ?? environmentId
    let summary = try await call(owner, Rpc.pullRequestsSummary, PullRequestRef(projectId: ProjectId(projectId), repository: repository, number: number))
    return candidate(
      projectId: summary.projectId.rawValue, repository: summary.repository, number: summary.number, title: summary.title, url: summary.url,
      state: summary.state, isDraft: summary.isDraft ?? false, head: summary.headBranch, base: summary.baseBranch, updatedAt: summary.updatedAt,
      author: summary.author.flatMap { $0 }, hostSearched: true)
  }

  // MARK: Attachments

  func uploadAttachment(_ upload: ComposerUploadRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
    let url = upload.fileURL
    let data = try await Task.detached { try Data(contentsOf: url) }.value
    guard let environmentId else { throw ComposerEnvironmentError("The environment is not connected.") }
    do {
      // ponytail: the runtime upload has no byte progress; the composer shows the upload as pending until it settles.
      let uploaded = try await runtime.uploadAttachment(environmentId: environmentId, data: data, name: upload.name, mimeType: upload.mimeType)
      progress(1)
      return uploaded.attachmentId
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AttachmentUploadError {
      switch error {
      case .notConnected: throw ComposerEnvironmentError("The environment is not connected.")
      case .rejected(let message): throw ComposerEnvironmentError(message)
      case .uploadFailed(let status): throw ComposerEnvironmentError(status.map { "The upload failed (HTTP \($0))." } ?? "The upload failed.")
      case .cancelled: throw CancellationError()
      }
    }
  }

  func deleteUploadedAttachment(id: String) async {
    guard let environmentId else { return }
    await runtime.discardAttachment(environmentId: environmentId, attachmentId: id)
  }

  func verifyUploadedAttachment(id: String) async -> UploadVerification {
    guard let environment = await runtime.runtime(for: environmentId ?? ""), let session = environment.supervisor.session.value else { return .failed }
    do {
      let resource = AssetResource.attachment(AssetResourceAttachment(attachmentId: id, disposition: .inline))
      let minted = try await session.call(Rpc.assetsCreateUrl, AssetCreateUrlInput(resource: resource))
      guard let url = URL(string: minted.relativeUrl, relativeTo: environment.entry.httpBaseURL)?.absoluteURL else { return .failed }
      var request = URLRequest(url: url)
      request.httpMethod = "HEAD"
      let (_, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (200..<300).contains(status) ? .verified : status == 404 ? .missing : .failed
    } catch {
      return .failed
    }
  }

  // MARK: Persistence

  private func file(_ key: String) -> URL { directory.appending(path: "\(key.replacingOccurrences(of: "/", with: "_")).json") }

  func loadStorage(key: String) async -> Data? { try? Data(contentsOf: file(key)) }

  func saveStorage(key: String, data: Data) async throws { try data.write(to: file(key), options: .atomic) }
}
