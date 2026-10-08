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
    composer.environment.onThreadStarted = { [weak self] key in self?.draftStarted(key) }
  }

  // MARK: Lifecycle

  func start() async {
    guard !started else { return }
    started = true
    await runtime.start()
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

  /// Whether the web defaults ask before archiving / deleting (`confirmThreadArchive` false, `confirmThreadDelete` true).
  var confirmsArchive: Bool { UserDefaults.standard.bool(forKey: "confirmThreadArchive") }

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
    confirm(
      "Delete thread \u{201C}\(thread.shell.title)\u{201D}?", message: "This permanently clears the conversation history of this thread.",
      confirmTitle: "Delete"
    ) { [self] in
      if selection == key { selection = nil }
      run { [runtime] in try await runtime.deleteThread(key) }
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
  func startNewThread(in group: ProjectGroup) {
    let project = group.representative
    let defaults = UserDefaults.standard
    var reserved = defaults.dictionary(forKey: Self.draftThreadsDefaultsKey) as? [String: String] ?? [:]
    let reservation = "\(project.environmentId.rawValue):\(project.projectId.rawValue)"
    let threadId = reserved[reservation] ?? UUID().uuidString.lowercased()
    reserved[reservation] = threadId
    defaults.set(reserved, forKey: Self.draftThreadsDefaultsKey)
    draft = DraftThread(
      key: ScopedThreadKey(environmentId: project.environmentId, threadId: ThreadId(rawValue: threadId)), projectId: project.projectId,
      projectTitle: group.label)
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
