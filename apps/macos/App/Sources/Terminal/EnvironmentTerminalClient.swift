import Foundation
import T3ClientRuntime
import T3Contracts
import T3Protocol
import T3Terminal

/// Runs terminal RPCs on whichever session the environment has right now. Sessions are replaced when the
/// connection drops, so a terminal must not hold one: its attach stream ends with the old session and the
/// next attempt resolves the new one here.
struct EnvironmentTerminalClient: TerminalRpcClient {
  let runtime: ClientRuntime
  let environmentId: EnvironmentId

  private func session() async -> (any EnvironmentSession)? {
    await runtime.runtime(for: environmentId)?.supervisor.session.value
  }

  func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success {
    guard let session = await session() else { throw .transportClosed(.closed("The environment is not connected.")) }
    return try await session.call(spec, payload)
  }

  func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        guard let session = await session() else {
          continuation.finish(throwing: RpcError<Failure>.transportClosed(.closed("The environment is not connected.")))
          return
        }
        do {
          for try await element in session.subscribe(spec, payload) { continuation.yield(element) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
