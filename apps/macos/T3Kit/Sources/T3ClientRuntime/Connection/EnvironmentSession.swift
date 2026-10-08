import Foundation
import Synchronization
import T3Contracts
import T3Protocol

/// One ready connection to an environment: an RPC session whose first `subscribeServerConfig`
/// snapshot already arrived (and named the expected environment). Sessions are never reopened;
/// the supervisor replaces them and durable subscriptions follow the replacement.
public protocol EnvironmentSession: Sendable {
  /// Distinguishes replacement sessions: a cursor is only trusted on the session that produced it.
  var id: Int { get }
  var initialConfig: ServerConfig { get }
  func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success
  func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error>
  /// Health check of an established connection (server.probe, or getConfig on older servers).
  func probe() async throws(ConnectionAttemptError)
  /// Suspends until the session closed and says why.
  func waitUntilClosed() async -> ConnectionAttemptError
  func close() async
}

private let nextSessionID = Mutex(0)

/// `EnvironmentSession` over the Effect RPC `RpcSession` of T3Protocol.
public final class LiveEnvironmentSession: EnvironmentSession {
  public let id: Int
  public let initialConfig: ServerConfig
  private let rpc: RpcSession
  private let label: String
  private let pump: Task<Void, Never>
  /// `RpcSession.waitUntilClosed` cannot be cancelled, so waiters wait on this instead.
  private let closed = Deferred<ConnectionAttemptError>()

  private init(rpc: RpcSession, label: String, config: ServerConfig, pump: Task<Void, Never>) {
    id = nextSessionID.withLock { $0 += 1; return $0 }
    self.rpc = rpc
    self.label = label
    initialConfig = config
    self.pump = pump
    let closed = closed
    Task {
      let reason = await rpc.waitUntilClosed()
      closed.complete(.success(.transient(.transport, detail: "\(label) disconnected (\(reason)).")))
    }
  }

  /// Opens the session and waits for the first config snapshot. The config subscription stays open
  /// for the session's lifetime and feeds `onConfigEvent`; if it ends, the session closes (a
  /// healthy socket without server config is not a usable environment).
  public static func open(
    transport: any RpcTransport, label: String, expectedEnvironmentId: EnvironmentId,
    pingInterval: Duration = .seconds(5),
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> LiveEnvironmentSession {
    let rpc = try await RpcSession.open(transport: transport, pingInterval: pingInterval)
    let ready = Deferred<ServerConfig>()
    let pump = Task {
      do {
        var validated = false
        for try await event in rpc.subscribe(Rpc.subscribeServerConfig, SubscribeServerConfigPayload()) {
          if !validated {
            // Updates before the first snapshot are meaningless; the snapshot names the environment.
            guard case .snapshot(let snapshot) = event else { continue }
            let actual = snapshot.config.environment.environmentId
            guard actual == expectedEnvironmentId else {
              ready.complete(.failure(ConnectionAttemptError.blocked(.configuration, detail: "Connected environment \(actual.rawValue) does not match \(expectedEnvironmentId.rawValue).")))
              await rpc.close()
              return
            }
            validated = true
            ready.complete(.success(snapshot.config))
          }
          onConfigEvent(event)
        }
        ready.complete(.failure(ConnectionAttemptError.transient(.remoteUnavailable, detail: "\(label) config subscription ended.")))
      } catch {
        ready.complete(.failure(Self.map(error, label: label)))
      }
      await rpc.close()
    }
    do {
      let config = try await withTaskCancellationHandler {
        try await ready.value()
      } onCancel: {
        pump.cancel()
      }
      return LiveEnvironmentSession(rpc: rpc, label: label, config: config, pump: pump)
    } catch {
      pump.cancel()
      await rpc.close()
      throw error
    }
  }

  static func map(_ error: any Error, label: String) -> ConnectionAttemptError {
    switch error {
    case let error as ConnectionAttemptError: return error
    case let error as RpcError<SubscribeServerConfigFailure>:
      switch error {
      case .failure(.environmentAuthorizationError(let e)): return .blocked(.permission, detail: "\(e)")
      case .failure: return .transient(.remoteUnavailable, detail: "\(label) could not provide its configuration.")
      case .transportClosed(let reason): return .transient(.transport, detail: "\(label) disconnected (\(reason)).")
      case .defect, .interrupted: return .transient(.transport, detail: "\(label) config subscription failed.")
      }
    default: return .transient(.transport, detail: "\(label) connection failed: \(error)")
    }
  }

  public func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success {
    try await rpc.call(spec, payload)
  }

  public func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error> {
    rpc.subscribe(spec, payload)
  }

  public func probe() async throws(ConnectionAttemptError) {
    do {
      if initialConfig.environment.capabilities.connectionProbe == true {
        _ = try await rpc.call(Rpc.serverProbe, EmptyObject())
      } else {
        _ = try await rpc.call(Rpc.serverGetConfig, EmptyObject())
      }
    } catch {
      throw .transient(.transport, detail: "\(label) did not respond to a connection health check.")
    }
  }

  public func waitUntilClosed() async -> ConnectionAttemptError {
    (try? await closed.value()) ?? .transient(.transport, detail: "\(label) is no longer observed.")
  }

  public func close() async {
    pump.cancel()
    await rpc.close()
  }
}
