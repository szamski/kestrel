import Foundation
import T3Contracts

/// Pure rules of the first-run setup, ported from the web's `onboarding/*.logic.ts`.

// MARK: First run

public enum FirstRunDecision: Sendable, Equatable { case pending, app, wizard }

public enum FirstRunLogic {
  public struct Input: Sendable {
    public var completed: Bool
    public var environmentCount: Int
    /// This app starts its own server and it has not registered yet: the empty catalog is not final.
    public var localServerPending: Bool
    /// Every enabled environment has live shell data, so the workspace counts below are real.
    public var shellsLive: Bool
    public var workspaceFresh: Bool
    public var projectCount: Int
    public var threadCount: Int

    public init(completed: Bool, environmentCount: Int, localServerPending: Bool, shellsLive: Bool, workspaceFresh: Bool, projectCount: Int, threadCount: Int) {
      self.completed = completed
      self.environmentCount = environmentCount
      self.localServerPending = localServerPending
      self.shellsLive = shellsLive
      self.workspaceFresh = workspaceFresh
      self.projectCount = projectCount
      self.threadCount = threadCount
    }
  }

  /// `persistCompletion` marks an install that is plainly in use, so the wizard never shows for it later.
  public static func decide(_ input: Input) -> (decision: FirstRunDecision, persistCompletion: Bool) {
    if input.completed { return (.app, false) }
    if input.environmentCount == 0 { return (input.localServerPending ? .pending : .wizard, false) }
    if !input.shellsLive { return (.pending, false) }
    if input.projectCount > 1 || input.threadCount > 1 { return (.app, true) }
    return input.workspaceFresh ? (.wizard, false) : (.app, true)
  }

  /// Only the server's own cwd project (and an untouched thread in it) counts as a fresh workspace.
  public static func isFreshWorkspace(projectRoots: [String], threads: [OrchestrationV2ThreadShell], serverCwd: String?) -> Bool {
    if projectRoots.count > 1 || threads.count > 1 { return false }
    if let root = projectRoots.first {
      guard let serverCwd, ProjectGrouping.normalizePath(root) == ProjectGrouping.normalizePath(serverCwd) else { return false }
    }
    guard let thread = threads.first else { return true }
    return !projectRoots.isEmpty && thread.latestRunId == nil && thread.activeProviderThreadId == nil && thread.latestUserMessageAt == nil
  }
}

// MARK: Provider readiness

public enum ProviderReadiness: Sendable, Equatable {
  case checking, disabled, install, signIn, attention, ready

  public static func of(_ provider: ServerConfigProvidersItem?) -> ProviderReadiness {
    guard let provider else { return .checking }
    if !provider.enabled || provider.status == .disabled { return .disabled }
    if !provider.installed, provider.status == .warning, provider.auth.status == .unknownValue { return .checking }
    if !provider.installed { return .install }
    if provider.auth.status == .unauthenticated { return .signIn }
    return provider.status == .ready ? .ready : .attention
  }

  private var priority: Int {
    switch self {
    case .checking: 0
    case .disabled: 1
    case .install: 2
    case .attention: 3
    case .signIn: 4
    case .ready: 5
    }
  }

  /// The most usable configured instance of each driver.
  public static func bestByDriver(_ providers: [ServerConfigProvidersItem]) -> [ProviderDriverKind: ServerConfigProvidersItem] {
    var best: [ProviderDriverKind: ServerConfigProvidersItem] = [:]
    for provider in providers {
      if let existing = best[provider.driver], of(existing).priority >= of(provider).priority { continue }
      best[provider.driver] = provider
    }
    return best
  }

  /// The vendors' own standalone installers (the ones the server's provider updater recognizes), by the environment's platform.
  public static func installCommand(driver: String, windows: Bool) -> String? {
    switch driver {
    case "claudeAgent": windows ? "irm https://claude.ai/install.ps1 | iex" : "curl -fsSL https://claude.ai/install.sh | bash"
    case "codex": windows ? "irm https://chatgpt.com/codex/install.ps1 | iex" : "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    default: nil
    }
  }

  /// ponytail: the default binary names; a provider instance with a custom binary path signs in with that binary (Settings › Providers).
  public static func loginCommand(driver: String) -> String? {
    switch driver {
    case "claudeAgent": "claude auth login"
    case "codex": "codex login"
    default: nil
    }
  }
}

// MARK: Project import

/// One directory a scan found, with the environment that scanned it (paths identify projects only within one computer).
public struct ImportCandidate: Sendable, Hashable, Identifiable {
  public let environmentId: EnvironmentId
  public let candidate: AgentSessionProjectCandidate
  public var id: String { "\(environmentId.rawValue)\u{1F}\(candidate.path)" }
  public init(environmentId: EnvironmentId, candidate: AgentSessionProjectCandidate) {
    self.environmentId = environmentId
    self.candidate = candidate
  }

  /// Servers that predate the git scan omit `git`; their directories are treated as repositories.
  public var isRepository: Bool { if case .some(nil) = candidate.git { false } else { true } }
  fileprivate var remoteKey: String? { optionalValue(candidate.git)?.remoteKey }
  fileprivate var repository: String? { optionalValue(candidate.git)?.repository }
}

public struct ImportGroup: Sendable, Identifiable {
  public let id: String
  /// GitHub `owner/name`, or the checkout's folder name when the origin is elsewhere.
  public let label: String
  public let repository: String?
  public var candidates: [ImportCandidate]
  public var threadCount: Int
  public var lastActiveAt: IsoDateTime?
}

public enum ProjectImportLogic {
  /// Git repositories active in the last 30 days with enough threads to look like real work: one or two threads in a
  /// directory is usually a one-off question, not a project.
  public static func defaultSelection(_ candidates: [ImportCandidate], now: Date = .now) -> Set<String> {
    let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
    return Set(
      candidates.filter { item in
        guard item.isRepository, item.candidate.threadCount >= 3, let active = item.candidate.lastActiveAt?.date else { return false }
        return active >= cutoff && active <= now
      }.map(\.id))
  }

  /// Clones of one repository share a group (by normalized origin); newest activity first. Directories that are not
  /// repositories are returned apart so the UI can fold them away.
  public static func group(_ candidates: [ImportCandidate]) -> (repositories: [ImportGroup], other: [ImportCandidate]) {
    var groups: [String: ImportGroup] = [:]
    var order: [String] = []
    var other: [ImportCandidate] = []
    for item in candidates {
      guard item.isRepository else { other.append(item); continue }
      let key = item.remoteKey.map { "remote:\($0)" } ?? "path:\(item.candidate.path)"
      if var group = groups[key] {
        group.candidates.append(item)
        group.threadCount += item.candidate.threadCount
        group.lastActiveAt = later(group.lastActiveAt, item.candidate.lastActiveAt)
        groups[key] = group
      } else {
        order.append(key)
        groups[key] = ImportGroup(
          id: key, label: item.repository ?? item.candidate.title, repository: item.repository, candidates: [item],
          threadCount: item.candidate.threadCount, lastActiveAt: item.candidate.lastActiveAt)
      }
    }
    let repositories = order.compactMap { groups[$0] }.sorted { left, right in
      switch (left.lastActiveAt?.rawValue, right.lastActiveAt?.rawValue) {
      case (let a?, let b?) where a != b: a > b
      case (nil, _?): false
      case (_?, nil): true
      default: left.label.localizedStandardCompare(right.label) == .orderedAscending
      }
    }
    return (repositories, other)
  }

  private static func later(_ a: IsoDateTime?, _ b: IsoDateTime?) -> IsoDateTime? {
    guard let a else { return b }
    guard let b else { return a }
    return a.rawValue > b.rawValue ? a : b
  }

  /// What to tell the user when not every selected project's history was imported; nil when all of it was.
  public static func warning(completedProjects: Int, selectedProjects: Int, importedThreads: Int, skippedThreads: Int) -> String? {
    guard completedProjects < selectedProjects else { return nil }
    func threads(_ count: Int) -> String { "\(count) \(count == 1 ? "thread" : "threads")" }
    if importedThreads > 0, skippedThreads > 0 { return "Imported \(threads(importedThreads)). \(threads(skippedThreads)) could not be imported." }
    if skippedThreads > 0 { return "\(threads(skippedThreads)) could not be imported." }
    if importedThreads > 0 { return "Imported \(threads(importedThreads)). Some thread history could not be imported." }
    return "Could not import thread history."
  }
}
