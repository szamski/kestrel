import AppKit
import Foundation
import Observation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// First-run setup: when to show it (the web's `FirstRunGate`), its step, the project scans and the history import.
/// Skipping or finishing is saved as `onboardingCompletedAt` in the client settings; Settings › General reopens it.
@MainActor @Observable
final class OnboardingModel {
  enum Step: Int, CaseIterable {
    case connection, agents, projects
    var title: String {
      switch self {
      case .connection: "Connect"
      case .agents: "Agents"
      case .projects: "Projects"
      }
    }
  }

  struct Scan: Equatable {
    var candidates: [ImportCandidate] = []
    var truncated = false
    var failure: String?
    var loading = true
  }

  var isPresented = false
  var step = Step.connection
  private(set) var scans: [EnvironmentId: Scan] = [:]
  var selection: Set<String> = []
  private(set) var importing = false
  private(set) var importProgress: String?
  private(set) var importWarning: String?

  @ObservationIgnored weak var app: AppModel?
  @ObservationIgnored private let runtime: ClientRuntime
  @ObservationIgnored private let store: ClientSettingsStore
  @ObservationIgnored private var gate: Task<Void, Never>?
  @ObservationIgnored private var scanTasks: [EnvironmentId: Task<Void, Never>] = [:]
  @ObservationIgnored private var selectionTouched = false
  /// Debug launch with `-T3ForceOnboarding 1`: shows the wizard whatever the saved state, and never saves its outcome.
  @ObservationIgnored private var forced = false

  init(runtime: ClientRuntime, store: ClientSettingsStore = .shared) {
    self.runtime = runtime
    self.store = store
  }

  // MARK: Gate

  /// Waits for the workspace evidence the decision needs. ponytail: polls four times a second for at most ten seconds
  /// (an unreachable saved server never goes live); past that the app opens and the wizard stays reachable from Settings.
  func startGate() {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "T3ForceOnboarding") {
      forced = true
      present()
      return
    }
    #endif
    gate = Task { [self] in
      let deadline = ContinuousClock.now + .seconds(10)
      while !Task.isCancelled, ContinuousClock.now < deadline {
        let result = FirstRunLogic.decide(gateInput())
        switch result.decision {
        case .app:
          if result.persistCompletion { markCompleted() }
          return
        case .wizard:
          present()
          return
        case .pending:
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    }
  }

  private func gateInput() -> FirstRunLogic.Input {
    let enabled = runtime.environments.filter(\.enabled)
    let threads = runtime.shells.values.flatMap { $0.v2?.threads ?? [] }
    let localId = AppModel.storedLocalEnvironmentId
    let serverCwd = localId.flatMap { runtime.serverConfigs[$0]?.config.cwd } ?? runtime.serverConfigs.values.first?.config.cwd
    var pending = false
    if let server = app?.localServer, app?.runsLocalServer == true {
      switch server.state {
      case .starting, .running, .stopping: pending = runtime.environments.isEmpty
      default: break
      }
    }
    return FirstRunLogic.Input(
      completed: store.client.onboardingCompletedAt != nil, environmentCount: runtime.environments.count, localServerPending: pending,
      shellsLive: enabled.allSatisfy { runtime.shells[$0.environmentId]?.status == .live },
      workspaceFresh: FirstRunLogic.isFreshWorkspace(projectRoots: runtime.projects.map { $0.project.workspaceRoot }, threads: threads, serverCwd: serverCwd),
      projectCount: runtime.projects.count, threadCount: threads.count)
  }

  private func markCompleted() {
    guard !forced else { return }
    let stamp = IsoTimestamp.format(milliseconds: (Date.now.timeIntervalSince1970 * 1000).rounded(.down)).rawValue
    store.update { $0.onboardingCompletedAt = stamp }
  }

  // MARK: Presentation

  func present() {
    gate?.cancel()
    step = .connection
    importWarning = nil
    isPresented = true
    app?.showMainWindow()
  }

  /// Skip and Finish both end the setup for good (until it is opened again from Settings).
  func close() {
    markCompleted()
    isPresented = false
    scanTasks.values.forEach { $0.cancel() }
    scanTasks = [:]
    scans = [:]
    selectionTouched = false
    selection = []
  }

  func go(to next: Step) {
    guard !importing else { return }
    step = next
    if next == .projects { scanAll() }
  }

  // MARK: Environments

  /// Computers setup applies to: the saved ones that are connected right now.
  var connected: [EnvironmentStatus] { runtime.environments.filter { $0.enabled && $0.connection.phase == .connected } }

  // MARK: Scan

  func scanAll() {
    for status in connected where scans[status.environmentId] == nil || scans[status.environmentId]?.failure != nil { scan(status.environmentId) }
  }

  private func scan(_ id: EnvironmentId) {
    scans[id] = Scan()
    scanTasks[id]?.cancel()
    scanTasks[id] = Task { [self] in
      guard let session = await runtime.runtime(for: id)?.supervisor.session.value else {
        scans[id] = Scan(failure: "This computer is not connected.", loading: false)
        return
      }
      do {
        let result = try await session.call(Rpc.agentSessionsScan, EmptyObject())
        guard !Task.isCancelled else { return }
        scans[id] = Scan(candidates: result.candidates.map { ImportCandidate(environmentId: id, candidate: $0) }, truncated: result.truncated == true, loading: false)
        applyDefaultSelection()
      } catch {
        guard !Task.isCancelled else { return }
        scans[id] = Scan(failure: "This computer could not scan its agent history.", loading: false)
      }
    }
  }

  var candidates: [ImportCandidate] { scans.values.flatMap(\.candidates) }
  var scanning: Bool { scans.values.contains { $0.loading } }

  private func applyDefaultSelection() {
    guard !selectionTouched else { return }
    selection = ProjectImportLogic.defaultSelection(candidates)
  }

  func setSelection(_ ids: Set<String>) {
    selectionTouched = true
    selection = ids
  }

  var selected: [ImportCandidate] { candidates.filter { selection.contains($0.id) } }

  // MARK: Import

  /// Creates the missing projects of the selection and imports each one's agent history, one project at a time.
  func runImport() {
    let chosen = selected
    guard !importing, !chosen.isEmpty else { return }
    importing = true
    importWarning = nil
    Task { [self] in
      var completed = 0, imported = 0, skipped = 0
      var landing: EnvironmentProject?
      for (index, item) in chosen.enumerated() {
        importProgress = "Importing \(index + 1) of \(chosen.count): \(item.candidate.title)"
        guard let environment = await runtime.runtime(for: item.environmentId), let session = environment.supervisor.session.value else { continue }
        do {
          let path = ProjectGrouping.normalizePath(item.candidate.path)
          var projectId = item.candidate.projectId
            ?? runtime.projects.first { $0.environmentId == item.environmentId && ProjectGrouping.normalizePath($0.project.workspaceRoot) == path }?.projectId
          if projectId == nil {
            let meta = CommandMeta.fresh()
            let created = ProjectId(rawValue: UUID().uuidString.lowercased())
            _ = try await environment.dispatch(
              .projectCreate(V1.ProjectCreateCommand(commandId: meta.commandId, projectId: created, title: item.candidate.title, workspaceRoot: path, createdAt: meta.createdAt)))
            projectId = created
          }
          guard let projectId else { continue }
          let result = try await session.call(Rpc.agentSessionsImport, AgentSessionImportInput(projectId: projectId, expectedWorkspaceRoot: item.candidate.path))
          imported += result.importedCount
          skipped += result.skippedCount
          if result.skippedCount == 0 { completed += 1 }
          if result.importedCount > 0, landing == nil { landing = runtime.projects.first { $0.environmentId == item.environmentId && $0.projectId == projectId } }
        } catch {
          // One failed project does not stop the rest; the warning below says something did not land.
        }
      }
      importing = false
      importProgress = nil
      importWarning = ProjectImportLogic.warning(completedProjects: completed, selectedProjects: chosen.count, importedThreads: imported, skippedThreads: skipped)
      guard importWarning == nil else { return }
      close()
      if let landing { app?.startNewThread(in: landing, label: landing.project.title) }
    }
  }
}
