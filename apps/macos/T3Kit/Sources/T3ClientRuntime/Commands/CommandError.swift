import Foundation
import T3Contracts
import T3Protocol

/// Why a command did not reach the server or was refused. Nothing is replayed automatically:
/// a failed dispatch can be retried by the caller with the same `CommandMeta` (idempotent).
public enum CommandError: Error, Sendable, Equatable {
  case notConnected(environment: String)
  /// The server refused the command (invalid state, failed guard, ...).
  case rejected(message: String)
  case unauthorized(message: String)
  /// The socket closed or the reply was unreadable; the command may or may not have committed.
  case transport(message: String)

  public var message: String {
    switch self {
    case .notConnected(let environment): "\(environment) is not connected."
    case .rejected(let message), .unauthorized(let message), .transport(let message): message
    }
  }

  static func map(_ error: RpcError<OrchestrationDispatchCommandFailure>) -> CommandError {
    switch error {
    case .failure(.orchestrationDispatchCommandError(let e)): .rejected(message: e.message)
    case .failure(.environmentAuthorizationError(let e)): .unauthorized(message: "\(e)")
    case .failure(.unknown): .rejected(message: "The server refused the command.")
    case .transportClosed(let reason): .transport(message: "The connection closed before the command completed (\(reason)).")
    case .defect, .interrupted: .transport(message: "The command could not be completed.")
    }
  }
}

/// Runs operations one at a time per key (commands against one thread are serial; different threads run concurrently).
actor KeyedSerialExecutor {
  private var tails: [String: Task<Void, Never>] = [:]

  func run<T: Sendable>(key: String, _ operation: @escaping @Sendable () async -> T) async -> T {
    let previous = tails[key]
    let task = Task<T, Never> {
      await previous?.value
      return await operation()
    }
    tails[key] = Task { _ = await task.value }
    return await task.value
  }
}
