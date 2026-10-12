import Foundation
import T3Contracts

/// The V1 and protocol-2 contracts declare structurally identical types twice; a JSON round trip moves a value across.
enum Transcode {
  static func value<A: Encodable, B: Decodable>(_ value: A) -> B? { (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(B.self, from: $0) } }

  /// Keeps the difference between "not sent" (`nil`) and "cleared" (`.some(nil)`).
  static func optional<A: Encodable, B: Decodable>(_ value: A??) -> B?? {
    switch value {
    case .none: .none
    case .some(.none): .some(.none)
    case .some(.some(let inner)): .some(Transcode.value(inner))
    }
  }
}

/// Project commands the settings page sends. Both protocols take them: protocol 2 as `projects.mutate`
/// (`CommandTranslation`), protocol 1 as the orchestration command.
public enum ProjectCommand {
  /// Only the fields passed change; `projectIcon: .some(nil)` / `faviconPath: .some(nil)` clear the choice.
  public static func metaUpdate(
    _ projectId: ProjectId, title: String? = nil, projectIcon: ProjectIconOverride?? = nil, faviconPath: String?? = nil, meta: CommandMeta = .fresh()
  ) -> V1.ClientOrchestrationCommand {
    .projectMetaUpdate(
      V1.ClientOrchestrationCommandProjectMetaUpdate(
        commandId: meta.commandId, projectId: projectId, title: title, faviconPath: faviconPath, projectIcon: Transcode.optional(projectIcon)))
  }

  /// `force` also removes the project's threads, as the web's "Remove project" does.
  public static func delete(_ projectId: ProjectId, force: Bool = true, meta: CommandMeta = .fresh()) -> V1.ClientOrchestrationCommand {
    .projectDelete(V1.ClientOrchestrationCommandProjectDelete(commandId: meta.commandId, projectId: projectId, force: force))
  }
}

extension ClientRuntime {
  public func updateProject(
    environmentId: EnvironmentId, projectId: ProjectId, title: String? = nil, projectIcon: ProjectIconOverride?? = nil, faviconPath: String?? = nil
  ) async throws(CommandError) {
    guard let runtime = await registry.runtime(for: environmentId) else { throw .notConnected(environment: environmentId.rawValue) }
    try await runtime.dispatch(ProjectCommand.metaUpdate(projectId, title: title, projectIcon: projectIcon, faviconPath: faviconPath, meta: .fresh(clock: clock)))
  }

  public func deleteProject(environmentId: EnvironmentId, projectId: ProjectId) async throws(CommandError) {
    guard let runtime = await registry.runtime(for: environmentId) else { throw .notConnected(environment: environmentId.rawValue) }
    try await runtime.dispatch(ProjectCommand.delete(projectId, meta: .fresh(clock: clock)))
  }
}
