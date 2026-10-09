import Foundation
import T3Contracts
import T3Protocol

/// The terminal RPCs a session needs. The app adapts its live environment connection to this;
/// tests provide a fake. Streams end with an error when the connection drops.
public protocol TerminalTransport: Sendable {
  func open(_ input: TerminalOpenInput) async throws -> TerminalSessionSnapshot
  func attach(_ input: TerminalAttachInput) -> AsyncThrowingStream<TerminalAttachStreamEvent, any Error>
  func write(_ input: TerminalWriteInput) async throws
  func resize(_ input: TerminalResizeInput) async throws
  func clear(_ input: TerminalClearInput) async throws
  func restart(_ input: TerminalRestartInput) async throws -> TerminalSessionSnapshot
  func close(_ input: TerminalCloseInput) async throws
  func events() -> AsyncThrowingStream<TerminalEvent, any Error>
  func metadata() -> AsyncThrowingStream<TerminalMetadataStreamEvent, any Error>
}

/// The server refused the request (bad cwd, unknown provider instance, ...). Retrying the same
/// request cannot help, unlike a dropped connection.
public struct TerminalRejected: Error, Sendable, CustomStringConvertible {
  public let description: String
}

/// Anything that can run RPC specs: `RpcSession`, or an environment session wrapper in the app.
public protocol TerminalRpcClient: Sendable {
  func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success
  func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error>
}

extension RpcSession: TerminalRpcClient {}

/// `TerminalTransport` over any `TerminalRpcClient` (the generated `Rpc.terminal*` specs).
public struct RpcTerminalTransport<Client: TerminalRpcClient>: TerminalTransport {
  private let client: Client

  public init(_ client: Client) { self.client = client }

  public func open(_ input: TerminalOpenInput) async throws -> TerminalSessionSnapshot { try await run { try await client.call(Rpc.terminalOpen, input) } }
  public func write(_ input: TerminalWriteInput) async throws { _ = try await run { try await client.call(Rpc.terminalWrite, input) } }
  public func resize(_ input: TerminalResizeInput) async throws { _ = try await run { try await client.call(Rpc.terminalResize, input) } }
  public func clear(_ input: TerminalClearInput) async throws { _ = try await run { try await client.call(Rpc.terminalClear, input) } }
  public func restart(_ input: TerminalRestartInput) async throws -> TerminalSessionSnapshot { try await run { try await client.call(Rpc.terminalRestart, input) } }
  public func close(_ input: TerminalCloseInput) async throws { _ = try await run { try await client.call(Rpc.terminalClose, input) } }

  public func attach(_ input: TerminalAttachInput) -> AsyncThrowingStream<TerminalAttachStreamEvent, any Error> {
    Self.mapFailures(client.subscribe(Rpc.terminalAttach, input), failure: TerminalAttachFailure.self)
  }
  public func events() -> AsyncThrowingStream<TerminalEvent, any Error> {
    Self.mapFailures(client.subscribe(Rpc.subscribeTerminalEvents, EmptyObject()), failure: SubscribeTerminalEventsFailure.self)
  }
  public func metadata() -> AsyncThrowingStream<TerminalMetadataStreamEvent, any Error> {
    Self.mapFailures(client.subscribe(Rpc.subscribeTerminalMetadata, EmptyObject()), failure: SubscribeTerminalMetadataFailure.self)
  }

  private func run<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as RpcError<TerminalOpenFailure> { throw Self.map(error) }
  }

  private static func map<F: Error & Sendable>(_ error: RpcError<F>) -> any Error {
    if case .failure(let failure) = error { return TerminalRejected(description: "\(failure)") }
    return error
  }

  private static func mapFailures<Element: Sendable, F: Error & Sendable>(
    _ stream: AsyncThrowingStream<Element, any Error>, failure: F.Type
  ) -> AsyncThrowingStream<Element, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await element in stream { continuation.yield(element) }
          continuation.finish()
        } catch let error as RpcError<F> {
          continuation.finish(throwing: map(error))
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
