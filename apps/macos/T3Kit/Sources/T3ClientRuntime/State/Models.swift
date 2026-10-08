import Foundation
import T3Contracts

/// A thread shell tagged with the environment that owns it. Thread ids are only unique per
/// environment, so every cross-environment list carries this pair.
public struct EnvironmentThreadShell: Sendable, Hashable, Identifiable {
  public let environmentId: EnvironmentId
  public var shell: OrchestrationThreadShell

  public init(environmentId: EnvironmentId, shell: OrchestrationThreadShell) {
    self.environmentId = environmentId
    self.shell = shell
  }

  public var threadId: ThreadId { shell.id }
  /// `environmentId:threadId`, the key used by every client-owned per-thread map.
  public var id: String { "\(environmentId.rawValue):\(shell.id.rawValue)" }
  public var key: ScopedThreadKey { ScopedThreadKey(environmentId: environmentId, threadId: shell.id) }
}

public struct EnvironmentProject: Sendable, Hashable, Identifiable {
  public let environmentId: EnvironmentId
  public var project: OrchestrationProjectShell
  public init(environmentId: EnvironmentId, project: OrchestrationProjectShell) {
    self.environmentId = environmentId
    self.project = project
  }
  public var projectId: ProjectId { project.id }
  public var id: String { "\(environmentId.rawValue):\(project.id.rawValue)" }
}

public struct ScopedThreadKey: Sendable, Hashable, CustomStringConvertible {
  public let environmentId: EnvironmentId
  public let threadId: ThreadId
  public init(environmentId: EnvironmentId, threadId: ThreadId) {
    self.environmentId = environmentId
    self.threadId = threadId
  }
  public var description: String { "\(environmentId.rawValue):\(threadId.rawValue)" }
}

public struct ScopedProjectRef: Sendable, Hashable {
  public let environmentId: EnvironmentId
  public let projectId: ProjectId
  public init(environmentId: EnvironmentId, projectId: ProjectId) {
    self.environmentId = environmentId
    self.projectId = projectId
  }
}
