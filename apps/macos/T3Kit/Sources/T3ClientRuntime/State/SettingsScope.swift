import Foundation
import T3Contracts

/// Port of the web settings target model (`settingsScope.ts`, `scopedSettings.ts`). Two axes: `machine` narrows the
/// environment (absent = all connected environments), `project` and `checkout` narrow the project (absent = the
/// environment defaults). A target that no longer exists is `unavailable` and never falls back to a broader one.
public struct SettingsScopeSearch: Sendable, Equatable {
  /// `ProjectGroup.key`.
  public var project: String?
  /// `EnvironmentId.rawValue`.
  public var machine: String?
  /// `ProjectGroup.Member.physicalProjectKey`.
  public var checkout: String?
  public init(project: String? = nil, machine: String? = nil, checkout: String? = nil) {
    self.project = project
    self.machine = machine
    self.checkout = checkout
  }
}

public struct SettingsScopeMember: Sendable, Equatable {
  public let environmentId: EnvironmentId
  public let projectId: ProjectId
  public let physicalProjectKey: String
  public let workspaceRoot: String
}

public struct SettingsScope: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case all, environment, project, checkout, unavailable }
  public var kind: Kind
  public var label: String
  public var members: [SettingsScopeMember]
  public var environmentIds: [EnvironmentId]
  /// Why the target is unavailable.
  public var message: String?

  public var isProject: Bool { kind == .project || kind == .checkout }

  private static func unavailable(_ message: String) -> SettingsScope {
    SettingsScope(kind: .unavailable, label: "Unavailable selection", members: [], environmentIds: [], message: message)
  }

  /// Resolves only existing targets: an unavailable selection never broadens a later write.
  public static func resolve(_ search: SettingsScopeSearch, groups: [ProjectGroup], environments: [EnvironmentStatus]) -> SettingsScope {
    if search.checkout != nil, search.project == nil { return unavailable("Select a project to choose one of its checkouts.") }
    let environment = environments.first { $0.environmentId.rawValue == search.machine }
    if search.machine != nil, environment == nil { return unavailable("This environment is no longer available.") }

    if let projectKey = search.project {
      guard let group = groups.first(where: { $0.key == projectKey }) else { return unavailable("This project is no longer available.") }
      let members = group.members.filter {
        (search.machine == nil || $0.project.environmentId.rawValue == search.machine)
          && (search.checkout == nil || $0.physicalProjectKey == search.checkout)
      }.map {
        SettingsScopeMember(
          environmentId: $0.project.environmentId, projectId: $0.project.projectId, physicalProjectKey: $0.physicalProjectKey,
          workspaceRoot: $0.project.project.workspaceRoot)
      }
      guard let first = members.first else {
        return unavailable(
          search.checkout != nil
            ? "This checkout is no longer available in the selected project and environment." : "This project has no checkout on this environment.")
      }
      if search.checkout != nil {
        guard let owner = environments.first(where: { $0.environmentId == first.environmentId }) else {
          return unavailable("This checkout's environment is no longer available.")
        }
        let shares = group.members.contains { $0.project.environmentId == first.environmentId && $0.physicalProjectKey != first.physicalProjectKey }
        return SettingsScope(
          kind: .checkout, label: "\(group.label) / \(owner.label)\(shares ? " \u{00B7} \(first.workspaceRoot)" : "")", members: members,
          environmentIds: [first.environmentId], message: nil)
      }
      var seen = Set<EnvironmentId>()
      return SettingsScope(
        kind: .project, label: "\(group.label) / \(environment?.label ?? "All checkouts")", members: members,
        environmentIds: members.map(\.environmentId).filter { seen.insert($0).inserted }, message: nil)
    }
    if let environment {
      return SettingsScope(kind: .environment, label: environment.label, members: [], environmentIds: [environment.environmentId], message: nil)
    }
    return SettingsScope(kind: .all, label: "All environments", members: [], environmentIds: environments.map(\.environmentId), message: nil)
  }
}

/// What the planner needs to know about one environment.
public struct SettingsTargetEnvironment: Sendable {
  public var environmentId: EnvironmentId
  public var label: String
  public var connected: Bool
  public var settings: ServerSettings?
  public var capabilities: ExecutionEnvironmentCapabilities?

  public init(
    environmentId: EnvironmentId, label: String, connected: Bool, settings: ServerSettings?, capabilities: ExecutionEnvironmentCapabilities? = nil
  ) {
    self.environmentId = environmentId
    self.label = label
    self.connected = connected
    self.settings = settings
    self.capabilities = capabilities
  }

  /// Connected with its settings loaded: the only kind of environment a write may target.
  public var isReady: Bool { connected && settings != nil }
}

/// One (environment, project) pair a scope writes to, with that project's effective settings.
public struct SettingsTarget {
  public var environmentId: EnvironmentId
  public var label: String
  /// Nil at environment scope.
  public var projectId: ProjectId?
  public var settings: ServerSettings
  /// Project-scoped keys this project overrides.
  public var overridden: Set<String>
}

public struct SettingsWrite: Equatable, Sendable {
  public var environmentId: EnvironmentId
  public var label: String
  public var patch: ServerSettingsPatch
}

public struct SettingsPlan: Equatable, Sendable {
  public var writes: [SettingsWrite]
  /// Set when nothing can be written; the caller shows it instead of saving.
  public var unavailableReason: String?
}

public extension ClientRuntime {
  /// Every saved environment with the settings its config carries, for scope planning.
  var settingsEnvironments: [SettingsTargetEnvironment] {
    environments.map { status in
      let config = serverConfigs[status.environmentId]?.config
      return SettingsTargetEnvironment(
        environmentId: status.environmentId, label: status.label, connected: status.connection.phase == .connected, settings: config?.settings,
        capabilities: config?.environment.capabilities)
    }
  }
}
