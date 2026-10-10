import Foundation
import T3ClientRuntime
import T3Contracts
import T3Protocol

extension AppModel {
  /// The diff of a thread from its environment: per-turn and whole-thread checkpoints through the orchestration
  /// RPCs, working tree and branch through the review preview (the same calls as the web diff panel).
  func diffFetcher(for key: ScopedThreadKey) -> DiffFetcher {
    { [weak self] request in
      guard let self else { throw CancellationError() }
      let (session, cwd) = try await self.diffSession(for: key)
      switch request.source {
      case .turn(let count):
        let result = try await session.call(
          V1.Rpc.orchestrationGetTurnDiff,
          OrchestrationGetTurnDiffInput(fromTurnCount: max(0, count - 1), toTurnCount: count, threadId: key.threadId, ignoreWhitespace: request.ignoreWhitespace))
        return DiffFetchResult(patch: result.diff, truncated: false)
      case .allTurns(let count):
        let result = try await session.call(
          V1.Rpc.orchestrationGetFullThreadDiff,
          OrchestrationGetFullThreadDiffInput(threadId: key.threadId, toTurnCount: count, ignoreWhitespace: request.ignoreWhitespace))
        return DiffFetchResult(patch: result.diff, truncated: false)
      case .workingTree, .branch:
        guard let cwd else { throw DiffFetchError.noWorkspace }
        let preview: ReviewDiffPreviewResult
        do {
          preview = try await session.call(Rpc.reviewGetDiffPreview, ReviewDiffPreviewInput(cwd: cwd, ignoreWhitespace: request.ignoreWhitespace))
        } catch where "\(error)".contains("configured workspace root") {
          // The web panel does the same: a cwd outside the server's workspace root retries at the server's own cwd.
          guard let serverCwd = await self.runtime.serverConfigs[key.environmentId]?.config.cwd, serverCwd != cwd else { throw error }
          preview = try await session.call(Rpc.reviewGetDiffPreview, ReviewDiffPreviewInput(cwd: serverCwd, ignoreWhitespace: request.ignoreWhitespace))
        }
        let wanted: ReviewDiffPreviewSourceKind = request.source == .workingTree ? .workingTree : .branchRange
        guard let source = preview.sources.first(where: { $0.kind == wanted }) else { return DiffFetchResult(patch: "", truncated: false) }
        return DiffFetchResult(patch: source.diff, truncated: source.truncated)
      }
    }
  }

  @MainActor
  private func diffSession(for key: ScopedThreadKey) async throws -> (EnvironmentSession, String?) {
    guard let environment = await runtime.runtime(for: key.environmentId), let session = environment.supervisor.session.value else {
      throw DiffFetchError.notConnected
    }
    let cwd = runtime.threadShell(key)?.shell.worktreePath ?? workspaceRoot(of: key)
    return (session, cwd)
  }
}

enum DiffFetchError: Error, LocalizedError {
  case notConnected, noWorkspace

  var errorDescription: String? {
    switch self {
    case .notConnected: "The environment is not connected."
    case .noWorkspace: "This thread has no workspace to diff."
    }
  }
}
