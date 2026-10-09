import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Protocol

/// What a failed request says, in words for the user.
struct SourceControlError: LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// A typed server failure reads as its `detail` / `message` field; the wire shape is the same for every failure type.
protocol FailureMessage { var failureMessage: String { get } }

extension RpcError: FailureMessage where Failure: Encodable {
  var failureMessage: String {
    switch self {
    case .failure(let failure):
      if let data = try? JSONEncoder().encode(failure), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        for key in ["detail", "message"] { if let text = object[key] as? String, !text.isEmpty { return text } }
        if let tag = object["_tag"] as? String { return tag }
      }
      return "The server refused the request."
    case .interrupted: return "The request was interrupted."
    case .transportClosed: return "The connection closed before the request completed."
    case .defect: return "The server could not complete the request."
    }
  }
}

/// A directory on an environment that git actions run in, and the thread (or draft) they report back to.
struct GitContext: Hashable, Identifiable {
  var environmentId: EnvironmentId
  var projectId: ProjectId
  var cwd: String
  /// The thread, or the draft's reserved thread id.
  var key: ScopedThreadKey
  var isDraft: Bool
  var id: String { "\(environmentId.rawValue):\(cwd)" }
}

/// Where a draft thread will run, chosen before its first send.
struct DraftWorkspace: Equatable {
  var envMode: EnvMode = .local
  /// Base branch in worktree mode, else the branch the thread follows.
  var branch: String?
  /// An existing worktree the draft points at ("previous worktree", or a branch that lives in one).
  var worktreePath: String?
  var startFromOrigin = false
}

/// Everything the strip needs to know about the thread or draft in view.
struct WorkspaceInfo {
  var project: EnvironmentProject
  var key: ScopedThreadKey
  var isDraft: Bool
  var shell: OrchestrationThreadShell?
  var workspace: DraftWorkspace
  var preparingWorktree: Bool

  var worktreePath: String? { isDraft ? workspace.worktreePath : shell?.worktreePath }
  var threadBranch: String? { isDraft ? workspace.branch : shell?.branch }
  var envMode: EnvMode {
    BranchToolbarLogic.resolveEffectiveEnvMode(
      activeWorktreePath: worktreePath, hasServerThread: !isDraft, draftEnvMode: workspace.envMode, preparingWorktree: preparingWorktree)
  }
  /// The checkout git runs in: the worktree, else the project root.
  var cwd: String { worktreePath ?? project.project.workspaceRoot }
  var context: GitContext { GitContext(environmentId: key.environmentId, projectId: project.projectId, cwd: cwd, key: key, isDraft: isDraft) }
}

/// The toast: a git action's progress and outcome, or a script that started.
struct SourceControlHUD: Identifiable, Equatable {
  enum Kind { case loading, success, error, info }
  enum Cta: Equatable {
    case open(label: String, url: URL)
    case run(label: String, action: GitStackedAction, context: GitContext)
  }
  var id = UUID()
  var kind: Kind
  var title: String
  var detail: String?
  var cta: Cta?
}

struct PendingGitAction: Identifiable {
  var id = UUID()
  var context: GitContext
  var action: GitStackedAction
  var branch: String
  var includesCommit: Bool
  var commitMessage: String?
  var filePaths: [String]?
}

enum SourceControlDialog: Identifiable {
  case commit(GitContext)
  case publish(GitContext)
  case defaultBranch(PendingGitAction)
  case script(ScriptEditorRequest)

  var id: String {
    switch self {
    case .commit(let context): "commit:\(context.id)"
    case .publish(let context): "publish:\(context.id)"
    case .defaultBranch(let pending): "default-branch:\(pending.id)"
    case .script(let request): "script:\(request.id)"
    }
  }
}

/// Source control next to the chat: draft workspace choices, git status, git actions and project scripts.
/// Server state is read through the environment's own session; nothing here is cached beyond what is on screen.
@MainActor @Observable
final class SourceControlStore {
  @ObservationIgnored let runtime: ClientRuntime
  /// Set by `AppModel` (the store opens drafts in other environments through it).
  @ObservationIgnored weak var app: AppModel?

  var workspaces: [String: DraftWorkspace] = [:]
  private(set) var worktreeSetups: [String: WorktreeSetupSnapshot] = [:]
  /// Contexts with a git action in flight.
  private(set) var running: Set<String> = []
  var hud: SourceControlHUD?
  var dialog: SourceControlDialog?

  // Key bindings ask the strip on screen to open its pickers.
  var branchPickerRequest = 0
  var workspaceMenuRequest = 0
  var environmentMenuRequest = 0
  var previousWorktreeRequest = 0
  /// Strips on screen; the strip commands are unavailable without one.
  var visibleStrips = 0

  @ObservationIgnored private var statusModels: [String: VcsStatusModel] = [:]
  @ObservationIgnored private var hudDismissal: Task<Void, Never>?

  init(runtime: ClientRuntime) { self.runtime = runtime }

  // MARK: Lookup

  func project(_ environmentId: EnvironmentId, _ projectId: ProjectId) -> EnvironmentProject? {
    runtime.projects.first { $0.environmentId == environmentId && $0.projectId == projectId }
  }

  /// The thread (or draft) in view, nil until its project is known.
  func info(for key: ScopedThreadKey, draft: DraftThread?) -> WorkspaceInfo? {
    let shell = draft == nil ? runtime.threadShell(key)?.shell : nil
    guard let projectId = draft?.projectId ?? shell?.projectId, let project = project(key.environmentId, projectId) else { return nil }
    let setup = worktreeSetups[key.description]
    let preparing = draft == nil && shell?.worktreePath == nil && setup?.phase == .running
    return WorkspaceInfo(
      project: project, key: key, isDraft: draft != nil, shell: shell, workspace: workspace(key, project: project), preparingWorktree: preparing)
  }

  func settings(_ environmentId: EnvironmentId) -> ServerSettings? { runtime.serverConfigs[environmentId]?.config.settings }

  // MARK: Failures and the toast

  static func describe(_ error: any Error) -> String {
    if let error = error as? SourceControlError { return error.message }
    if let error = error as? any FailureMessage { return error.failureMessage }
    return error.localizedDescription
  }

  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case .interrupted? = error as? RpcError<VcsPullFailure> { return true }
    return false
  }

  func show(_ next: SourceControlHUD) {
    hudDismissal?.cancel()
    hud = next
    guard next.kind == .success || next.kind == .info else { return }
    // Outcomes fade after a while; progress and errors wait for the user.
    hudDismissal = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled, self?.hud?.id == next.id else { return }
      self?.hud = nil
    }
  }

  func fail(_ title: String, _ error: any Error) {
    guard !Self.isCancellation(error) else {
      hud = nil
      return
    }
    show(SourceControlHUD(kind: .error, title: title, detail: Self.describe(error)))
  }

  func dismissHUD() {
    hudDismissal?.cancel()
    hud = nil
  }

  // MARK: Requests

  func session(_ id: EnvironmentId) async throws -> any EnvironmentSession {
    guard let environment = await runtime.runtime(for: id), let session = environment.supervisor.session.value else {
      throw SourceControlError("The environment is not connected.")
    }
    return session
  }

  func call<P, S, F>(_ environmentId: EnvironmentId, _ spec: RpcSpec<P, S, F>, _ payload: P) async throws -> S {
    try await session(environmentId).call(spec, payload)
  }

  /// Runs `body` for each ready session of the environment (a reconnect replaces the session) until cancelled.
  func forEachSession(of id: EnvironmentId, _ body: @escaping @MainActor (any EnvironmentSession) async -> Void) async {
    guard let environment = await runtime.runtime(for: id) else { return }
    var current: Task<Void, Never>?
    defer { current?.cancel() }
    for await session in environment.supervisor.session.changes() {
      current?.cancel()
      current = nil
      if let session { current = Task { @MainActor in await body(session) } }
    }
  }

  // MARK: Status

  func statusModel(_ environmentId: EnvironmentId, cwd: String) -> VcsStatusModel {
    let key = "\(environmentId.rawValue)\u{0}\(cwd)"
    if let model = statusModels[key] { return model }
    let model = VcsStatusModel(store: self, environmentId: environmentId, cwd: cwd)
    statusModels[key] = model
    return model
  }

  func isRunning(_ context: GitContext) -> Bool { running.contains(context.id) }
  func setRunning(_ context: GitContext, _ value: Bool) {
    if value { running.insert(context.id) } else { running.remove(context.id) }
  }

  // MARK: Worktree setup

  /// Feeds `subscribeWorktreeSetup` of a started thread into the timeline's setup card.
  func followWorktreeSetup(_ key: ScopedThreadKey, publish: @escaping @MainActor (WorktreeSetupSnapshot?) -> Void) async {
    await forEachSession(of: key.environmentId) { [weak self] session in
      while !Task.isCancelled {
        do {
          for try await snapshot in session.subscribe(Rpc.subscribeWorktreeSetup, WorktreeSetupSubscribeInput(threadId: key.threadId)) {
            self?.worktreeSetups[key.description] = snapshot
            publish(snapshot)
          }
        } catch {}
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  func cancelWorktreeSetup(_ key: ScopedThreadKey) {
    Task {
      do { _ = try await call(key.environmentId, Rpc.worktreeSetupCancel, WorktreeSetupCancelInput(threadId: key.threadId)) } catch { fail("Could not cancel the worktree setup", error) }
    }
  }
}

/// The live `subscribeVcsStatus` of one checkout. Views `retain` it while they show it.
@MainActor @Observable
final class VcsStatusModel {
  @ObservationIgnored private unowned let store: SourceControlStore
  let environmentId: EnvironmentId
  let cwd: String
  private(set) var status: VcsStatus?
  private(set) var failure: String?
  @ObservationIgnored private var users = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var activation: NSObjectProtocol?

  init(store: SourceControlStore, environmentId: EnvironmentId, cwd: String) {
    self.store = store
    self.environmentId = environmentId
    self.cwd = cwd
  }

  func retain() {
    users += 1
    guard task == nil else { return }
    task = Task { [weak self] in
      guard let self else { return }
      await store.forEachSession(of: environmentId) { [weak self] session in await self?.consume(session) }
    }
    // Like the web: the window coming back to the front re-reads the checkout.
    activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func release() {
    users -= 1
    guard users <= 0 else { return }
    task?.cancel()
    task = nil
    if let activation { NotificationCenter.default.removeObserver(activation) }
    activation = nil
  }

  private func consume(_ session: any EnvironmentSession) async {
    while !Task.isCancelled {
      do {
        for try await event in session.subscribe(Rpc.subscribeVcsStatus, VcsStatusInput(cwd: cwd)) {
          status = VcsStatus.applying(event, to: status)
          failure = nil
        }
      } catch {
        failure = SourceControlStore.describe(error)
      }
      try? await Task.sleep(for: .seconds(3))
    }
  }

  func refresh() {
    Task { [store, environmentId, cwd] in _ = try? await store.call(environmentId, Rpc.vcsRefreshStatus, VcsStatusInput(cwd: cwd)) }
  }
}

/// Keeps a status model subscribed while the view is on screen (and the model is the one it shows).
struct FollowsStatus: ViewModifier {
  let model: VcsStatusModel

  func body(content: Content) -> some View {
    content.task(id: ObjectIdentifier(model)) {
      model.retain()
      await withTaskCancellationHandler {
        try? await Task.sleep(for: .seconds(86_400 * 365))
      } onCancel: {
        Task { @MainActor in model.release() }
      }
    }
  }
}
