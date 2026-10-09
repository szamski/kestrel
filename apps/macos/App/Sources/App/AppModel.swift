import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Protocol

enum AppSheet: Identifiable, Equatable {
  case addEnvironment
  case snooze(ScopedThreadKey)
  case rename(ScopedThreadKey)

  var id: String {
    switch self {
    case .addEnvironment: "add-environment"
    case .snooze(let key): "snooze:\(key)"
    case .rename(let key): "rename:\(key)"
    }
  }
}

/// A destructive action waiting for the user's answer.
struct ConfirmRequest: Identifiable {
  let id = UUID()
  var title: String
  var message: String
  var confirmTitle: String
  var perform: @MainActor () async -> Void
}

/// A project's unsent new thread. The thread is created on the server with its first turn, so the
/// id is only reserved here (and remembered per project, so the draft text survives).
struct DraftThread: Equatable {
  var key: ScopedThreadKey
  var projectId: ProjectId
  var projectTitle: String
}

/// App-level state: the runtime, what is selected and which thread detail is open. Thin by design;
/// every thread rule lives in `ClientRuntime`.
@MainActor @Observable
final class AppModel {
  let runtime: ClientRuntime
  let assets: AssetStore
  let composer: ComposerStore
  /// Branch and worktree choices, git actions and project scripts of the thread in view.
  let sourceControl: SourceControlStore
  /// The server this app starts itself (Settings › Connections › Run local server).
  let localServer: LocalServer
  private(set) var runsLocalServer: Bool
  /// Host to prefill in the add-environment sheet (the foreign server found on this Mac).
  var addEnvironmentHost: String?

  /// The thread shown in the reading window. Changing it opens its live detail and marks it read.
  var selection: ScopedThreadKey? {
    didSet {
      guard selection != oldValue else { return }
      UserDefaults.standard.set(selection?.description, forKey: Self.selectionDefaultsKey)
      selectionChanged()
    }
  }
  private(set) var detail: ThreadDetailModel?
  /// The new-thread composer shown while no thread is selected.
  private(set) var draft: DraftThread?
  var sheet: AppSheet?
  var confirmation: ConfirmRequest?
  var errorMessage: String?
  /// Bumps once a minute so relative times and clock-derived sidebar boundaries refresh.
  private(set) var minuteTick = 0

  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var started = false
  @ObservationIgnored private var openGeneration = 0
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  private static let selectionDefaultsKey = "app.selectedThread"
  private static let draftThreadsDefaultsKey = "app.draftThreads"
  private static let runsLocalServerKey = "localServer.enabled"
  private static let localEnvironmentKey = "localServer.environmentId"

  /// `~/Library/Application Support/T3 Code Dev/` in Debug, `T3 Code` otherwise.
  static var dataDirectory: URL {
    #if DEBUG
    let name = "T3 Code Dev"
    #else
    let name = "T3 Code"
    #endif
    return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  init(runtime: ClientRuntime? = nil) {
    #if DEBUG
    let service = "codes.t3.macos.dev"
    #else
    let service = KeychainCredentialStore.defaultService
    #endif
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let runtime = runtime ?? ClientRuntime.live(directory: Self.dataDirectory, keychainService: service, appVersion: version)
    self.runtime = runtime
    assets = AssetStore(runtime: runtime)
    composer = ComposerStore(runtime: runtime, directory: Self.dataDirectory)
    sourceControl = SourceControlStore(runtime: runtime)
    localServer = LocalServer(dataDirectory: Self.dataDirectory)
    runsLocalServer = UserDefaults.standard.object(forKey: Self.runsLocalServerKey) as? Bool ?? true
    composer.environment.onThreadStarted = { [weak self] key in self?.draftStarted(key) }
    composer.environment.draftSend = { [weak self] target in try self?.sourceControl.draftSend(for: target) ?? .init() }
    sourceControl.app = self
    localServer.register = { [weak self] url, token in try await self?.registerLocalEnvironment(baseURL: url, token: token) }
    localServer.unavailable = { [weak self] in await self?.disableLocalEnvironment() }
  }

  // MARK: Local server

  func setRunsLocalServer(_ enabled: Bool) {
    guard enabled != runsLocalServer else { return }
    runsLocalServer = enabled
    UserDefaults.standard.set(enabled, forKey: Self.runsLocalServerKey)
    if enabled {
      localServer.start()
    } else {
      Task {
        await localServer.stop()
        await disableLocalEnvironment()
      }
    }
  }

  /// Exchanges the server's bootstrap token for a bearer and registers it as the local environment. The environment id
  /// follows the server's home; when the home changed (dev seed, `T3CODE_HOME`) the previous local environment is dropped.
  private func registerLocalEnvironment(baseURL: URL, token: String) async throws {
    let entry = try await runtime.addLocalEnvironment(baseURL: baseURL, bootstrapToken: token, label: "This Mac", clientLabel: "Kestrel")
    let previous = UserDefaults.standard.string(forKey: Self.localEnvironmentKey)
    UserDefaults.standard.set(entry.environmentId.rawValue, forKey: Self.localEnvironmentKey)
    if let previous, previous != entry.environmentId.rawValue { await runtime.removeEnvironment(EnvironmentId(rawValue: previous)) }
  }

  /// No local server runs: keep the environment saved (threads stay readable) but stop its reconnect attempts.
  private func disableLocalEnvironment() async {
    guard let id = UserDefaults.standard.string(forKey: Self.localEnvironmentKey) else { return }
    await runtime.setEnvironmentEnabled(EnvironmentId(rawValue: id), false)
  }

  // MARK: Lifecycle

  func start() async {
    guard !started else { return }
    started = true
    await runtime.start()
    if runsLocalServer { localServer.start() } else { await disableLocalEnvironment() }
    restoreSelection()
    observePresence()
    tasks.append(
      Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
          guard let self else { return }
          minuteTick += 1
          runtime.refreshNow()
        }
      })
    #if DEBUG
    await addDevEnvironmentIfRequested()
    DebugDriver.startIfRequested(self)
    #endif
  }

  func stop() async {
    tasks.forEach { $0.cancel() }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    await detail?.close()
    await composer.services.persistDraftsNow()
    await runtime.stop()
    await localServer.stop()
  }

  /// Visibility and focus feed the server's background-activity lease. Wake-from-sleep and
  /// activation probes are already wired inside `ClientRuntime.live`.
  private func observePresence() {
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
    ]
    for name in names {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.reportPresence() }
        })
    }
    reportPresence()
  }

  private func reportPresence() {
    let visible = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    let focused = NSApp.isActive
    Task { [runtime] in await runtime.activity.update(visible: visible, focused: focused) }
  }

  #if DEBUG
  /// `-T3DevPairingURL <url>` adds the environment on launch when none is saved yet (automated runs).
  private func addDevEnvironmentIfRequested() async {
    guard let url = UserDefaults.standard.string(forKey: "T3DevPairingURL"), !url.isEmpty else { return }
    for _ in 0..<30 where runtime.environments.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    guard runtime.environments.isEmpty else { return }
    do { try await runtime.addEnvironment(pairingURL: url) } catch { errorMessage = Self.describe(error) }
  }
  #endif

  // MARK: Selection

  private func restoreSelection() {
    guard selection == nil, let stored = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey),
      let split = stored.firstIndex(of: ":")
    else { return }
    // The key is `environmentId:threadId`; environment ids contain no colon.
    selection = ScopedThreadKey(
      environmentId: EnvironmentId(rawValue: String(stored[..<split])), threadId: ThreadId(rawValue: String(stored[stored.index(after: split)...])))
  }

  private func selectionChanged() {
    openGeneration += 1
    let generation = openGeneration
    let previous = detail
    detail = nil
    if selection != nil { draft = nil }
    composer.environment.activeEnvironmentId = selection?.environmentId ?? draft?.key.environmentId
    guard let key = selection else {
      Task { await previous?.close() }
      return
    }
    Task { [weak self] in
      await previous?.close()
      guard let self else { return }
      let opened = await runtime.openThread(key)
      guard generation == openGeneration else {
        await opened.close()
        return
      }
      detail = opened
    }
    Task { await runtime.markThreadRead(key) }
    Task { await runtime.acknowledgeWoke(key) }
  }

  // MARK: Commands

  /// Runs a runtime command and shows its failure as an alert.
  func run(_ operation: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await operation() } catch { errorMessage = Self.describe(error) }
    }
  }

  static func describe(_ error: any Error) -> String {
    switch error {
    case let error as CommandError: error.message
    case let error as AddEnvironmentError: error.message
    default: error.localizedDescription
    }
  }

  func confirm(_ title: String, message: String, confirmTitle: String, perform: @escaping @MainActor () async -> Void) {
    confirmation = ConfirmRequest(title: title, message: message, confirmTitle: confirmTitle, perform: perform)
  }

  /// Settings › General › Confirmations (`confirmThreadArchive`, `confirmThreadDelete`, `confirmThreadUnpin`).
  var confirmsArchive: Bool { ClientSettingsStore.shared.client.confirmThreadArchive }

  func archive(_ thread: EnvironmentThreadShell) {
    let key = thread.key
    let go: @MainActor () async -> Void = { [self] in
      if selection == key { selection = nil }
      run { [runtime] in try await runtime.archiveThread(key) }
    }
    if confirmsArchive {
      confirm("Archive thread \u{201C}\(thread.shell.title)\u{201D}?", message: "You can unarchive it later.", confirmTitle: "Archive", perform: go)
    } else {
      Task { await go() }
    }
  }

  func delete(_ thread: EnvironmentThreadShell) {
    let key = thread.key
    let go: @MainActor () async -> Void = { [self] in
      if selection == key { selection = nil }
      run { [runtime] in try await runtime.deleteThread(key) }
    }
    if ClientSettingsStore.shared.client.confirmThreadDelete {
      confirm(
        "Delete thread \u{201C}\(thread.shell.title)\u{201D}?", message: "This permanently clears the conversation history of this thread.",
        confirmTitle: "Delete", perform: go)
    } else {
      Task { await go() }
    }
  }

  /// Pins or unpins a thread; unpinning asks first when Settings › Confirmations says so.
  func setPinned(_ pinned: Bool, _ key: ScopedThreadKey) {
    let go: @MainActor () async -> Void = { [self] in
      run { [runtime] in pinned ? try await runtime.pinThread(key) : try await runtime.unpinThread(key) }
    }
    if !pinned, ClientSettingsStore.shared.client.confirmThreadUnpin {
      let title = runtime.threadShell(key)?.shell.title ?? "this thread"
      confirm("Unpin thread \u{201C}\(title)\u{201D}?", message: "It moves back to the other threads.", confirmTitle: "Unpin", perform: go)
    } else {
      Task { await go() }
    }
  }

  /// Creates an empty thread in `group` (a project the user can start work in) and opens it.
  @discardableResult
  func newThread(in group: ProjectGroup, title: String = "New thread") async -> ScopedThreadKey? {
    let project = group.representative
    guard let model = defaultModel(for: project) else {
      errorMessage = "No model is available for \(group.label) yet. Open the project in another T3 Code client once to pick one."
      return nil
    }
    do {
      let id = try await runtime.createThread(
        environmentId: project.environmentId, projectId: project.projectId, title: title, modelSelection: model)
      let key = ScopedThreadKey(environmentId: project.environmentId, threadId: id)
      selection = key
      return key
    } catch {
      errorMessage = Self.describe(error)
      return nil
    }
  }

  /// Opens the project's draft composer; the thread is created when its first message is sent.
  func startNewThread(in group: ProjectGroup) { startNewThread(in: group.representative, label: group.label) }

  /// The same, in one environment's project (a draft can move between the environments of its logical project).
  func startNewThread(in project: EnvironmentProject, label: String) {
    let defaults = UserDefaults.standard
    var reserved = defaults.dictionary(forKey: Self.draftThreadsDefaultsKey) as? [String: String] ?? [:]
    let reservation = "\(project.environmentId.rawValue):\(project.projectId.rawValue)"
    let threadId = reserved[reservation] ?? UUID().uuidString.lowercased()
    reserved[reservation] = threadId
    defaults.set(reserved, forKey: Self.draftThreadsDefaultsKey)
    draft = DraftThread(
      key: ScopedThreadKey(environmentId: project.environmentId, threadId: ThreadId(rawValue: threadId)), projectId: project.projectId,
      projectTitle: label)
    selection = nil
    composer.environment.activeEnvironmentId = project.environmentId
  }

  /// The draft's first turn was accepted: forget the reservation and show the new thread.
  private func draftStarted(_ key: ScopedThreadKey) {
    var reserved = UserDefaults.standard.dictionary(forKey: Self.draftThreadsDefaultsKey) as? [String: String] ?? [:]
    reserved = reserved.filter { $0.value != key.threadId.rawValue }
    UserDefaults.standard.set(reserved, forKey: Self.draftThreadsDefaultsKey)
    selection = key
  }

  /// The project of the open thread, else the filtered or first project: what ⌘N targets.
  var currentGroup: ProjectGroup? {
    if let key = selection, let shell = runtime.threadShell(key),
      let group = runtime.projectGroups.first(where: {
        $0.memberProjectRefs.contains { $0.environmentId == key.environmentId && $0.projectId == shell.shell.projectId }
      })
    {
      return group
    }
    if let refs = runtime.filter.projectRefs, let group = runtime.projectGroups.first(where: { $0.memberProjectRefs == refs }) { return group }
    return runtime.projectGroups.first
  }

  /// Project default, else the model of the project's most recent thread.
  private func defaultModel(for project: EnvironmentProject) -> ModelSelection? {
    if let model = project.project.defaultModelSelection { return model }
    // ponytail: falls back to the model of the environment's latest thread; the full composer will own model choice.
    let threads = runtime.shells[project.environmentId]?.snapshot?.threads ?? []
    let inProject = threads.filter { $0.projectId == project.projectId }
    return (inProject.isEmpty ? threads : inProject).max { $0.updatedAt.rawValue < $1.updatedAt.rawValue }?.modelSelection
  }

  // MARK: Environment helpers

  func projectTitle(of thread: EnvironmentThreadShell) -> String {
    runtime.projects.first { $0.environmentId == thread.environmentId && $0.projectId == thread.shell.projectId }?.project.title ?? ""
  }

  func workspaceRoot(of key: ScopedThreadKey) -> String? {
    guard let shell = runtime.threadShell(key)?.shell else { return nil }
    return runtime.projects.first { $0.environmentId == key.environmentId && $0.projectId == shell.projectId }?.project.workspaceRoot
  }

  func environmentLabel(_ id: EnvironmentId) -> String { runtime.environments.first { $0.environmentId == id }?.label ?? id.rawValue }
}
