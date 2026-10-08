import Foundation
import T3Contracts

/// Effect RPC client over one socket. Mirrors `RpcClient.makeProtocolSocket` +
/// `RpcClient.make` from effect-smol: numeric request ids, Ack after every Chunk,
/// Interrupt on cancellation, Ping every interval with Pong tracking.
///
/// A session never reconnects; when it closes every pending request fails with
/// `RpcError.transportClosed` and the owner (stage B supervisor) opens a new one.
public actor RpcSession {
  /// Runs after the pump started and before `open` returns. Throw to reject the
  /// connection, e.g. when the first `subscribeServerConfig` snapshot reports another
  /// environmentId. The session is closed when it throws.
  public typealias Readiness = @Sendable (RpcSession) async throws -> Void

  private let transport: any RpcTransport
  private let registry = RpcRegistry()
  private var closedReason: RpcConnectionError?
  private var closeWaiters: [CheckedContinuation<RpcConnectionError, Never>] = []
  private var receivedPong = true
  private var pumpTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?

  private init(transport: any RpcTransport) {
    self.transport = transport
  }

  /// Starts the receive pump and ping loop on `transport`, then runs `ready`.
  /// `pingInterval` matches Effect's 5 s; a Pong missing for one full interval closes the session.
  public static func open(
    transport: any RpcTransport,
    pingInterval: Duration = .seconds(5),
    ready: Readiness? = nil
  ) async throws -> RpcSession {
    let session = RpcSession(transport: transport)
    await session.start(pingInterval: pingInterval)
    if let ready {
      do {
        try await ready(session)
      } catch {
        await session.close()
        throw error
      }
    }
    return session
  }

  // MARK: Public API

  public func call<Payload, Success, Failure>(
    _ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload
  ) async throws(RpcError<Failure>) -> Success {
    if spec.isStream { throw .defect(.string("\(spec.tag) is a stream; use subscribe")) }
    if Task.isCancelled { throw .interrupted }
    let (events, continuation) = AsyncStream<RpcEvent>.makeStream()
    let registered = registry.register(codec: SpecCodec<Success, Failure>(isStream: false)) { event in
      continuation.yield(event)
      if case .chunk = event { return }
      continuation.finish()
    }
    guard case .success(let id) = registered else {
      if case .failure(let reason) = registered { throw .transportClosed(reason) }
      throw .interrupted
    }
    do {
      await sendRequest(id: id, frame: try ClientFrame.request(id: id, tag: spec.tag, payload: payload))
    } catch {
      _ = registry.remove(id)
      throw .defect(.string("Could not encode payload for \(spec.tag): \(error)"))
    }
    var iterator = events.makeAsyncIterator()
    let event = await withTaskCancellationHandler {
      await iterator.next(isolation: nil)
    } onCancel: {
      Task { await self.cancel(id) }
    }
    switch event {
    case .exit(.success(let value)):
      guard let value = value as? Success else { throw .defect(.string("Unexpected result type for \(spec.tag)")) }
      return value
    case .exit(.failure(let causes)): throw Self.error(from: causes)
    case .closed(let reason): throw .transportClosed(reason)
    case .chunk, .cancelled, nil: throw .interrupted
    }
  }

  /// Items arrive in order; every Chunk is Acked on receipt. Cancelling the consumer
  /// (or dropping the stream) sends Interrupt. The stream throws `RpcError<Failure>`.
  public nonisolated func subscribe<Payload, Success, Failure>(
    _ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload
  ) -> AsyncThrowingStream<Success, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Success, any Error>.makeStream()
    let registered = registry.register(codec: SpecCodec<Success, Failure>(isStream: true)) { event in
      switch event {
      case .chunk(let values):
        for case let value as Success in values { continuation.yield(value) }
      case .exit(.success), .cancelled:
        continuation.finish()
      case .exit(.failure(let causes)):
        continuation.finish(throwing: Self.error(from: causes) as RpcError<Failure>)
      case .closed(let reason):
        continuation.finish(throwing: RpcError<Failure>.transportClosed(reason))
      }
    }
    guard case .success(let id) = registered else {
      if case .failure(let reason) = registered {
        continuation.finish(throwing: RpcError<Failure>.transportClosed(reason))
      }
      return stream
    }
    let frame: String
    do {
      frame = try ClientFrame.request(id: id, tag: spec.tag, payload: payload)
    } catch {
      _ = registry.remove(id)
      continuation.finish(
        throwing: RpcError<Failure>.defect(.string("Could not encode payload for \(spec.tag): \(error)")))
      return stream
    }
    continuation.onTermination = { _ in Task { await self.cancel(id) } }
    Task { await self.sendRequest(id: id, frame: frame) }
    return stream
  }

  /// Suspends until the session closed and returns why.
  public func waitUntilClosed() async -> RpcConnectionError {
    if let closedReason { return closedReason }
    return await withCheckedContinuation { closeWaiters.append($0) }
  }

  public var isOpen: Bool { closedReason == nil }

  public func close() {
    fail(.closedByClient)
  }

  // MARK: Pump and ping

  private func start(pingInterval: Duration) {
    let frames = transport.frames
    let registry = registry
    pumpTask = Task.detached { [self] in
      do {
        for try await frame in frames {
          let messages: [ServerMessage]
          do {
            messages = try ServerMessage.decodeFrame(frame, registry: registry)
          } catch {
            await fail(.protocolError("Undecodable frame: \(error)"))
            return
          }
          await handle(messages)
        }
        await fail(.closed("socket closed"))
      } catch {
        await fail(.closed("\(error)"))
      }
    }
    pingTask = Task { [self] in
      while true {
        do { try await Task.sleep(for: pingInterval) } catch { return }
        await pingTick()
      }
    }
  }

  private func pingTick() async {
    guard closedReason == nil else { return }
    // Same rule as Effect's makePinger: no Pong since the previous Ping fails the connection.
    guard receivedPong else { return fail(.pingTimeout) }
    receivedPong = false
    do { try await transport.send(ClientFrame.ping) } catch { fail(.sendFailed("\(error)")) }
  }

  private func handle(_ messages: [ServerMessage]) async {
    for message in messages {
      switch message {
      case .pong:
        receivedPong = true
      case .chunk(let id, let values):
        guard let entry = registry.entry(id) else { continue }
        entry.deliver(.chunk(values))
        // Without this the server stops sending after its first unacknowledged chunk.
        // ponytail: acked on receipt, consumer buffer is unbounded; ack on consumption if that matters.
        await send(ClientFrame.ack(id: id))
      case .exit(let id, let value):
        registry.remove(id)?.deliver(.exit(value))
      case .decodeFailure(let id, let description):
        guard let entry = registry.remove(id) else { continue }
        entry.deliver(.exit(.failure([.die(.string(description))])))
        if entry.sent { await send(ClientFrame.interrupt(id: id)) }
      case .defect(let defect):
        for entry in registry.drain() { entry.deliver(.exit(.failure([.die(defect)]))) }
      case .ignored:
        break
      }
    }
  }

  // MARK: Sending

  private func sendRequest(id: Int, frame: String) async {
    guard registry.markSent(id) else { return }  // cancelled before it left
    await send(frame)
  }

  private func cancel(_ id: Int) async {
    guard let entry = registry.remove(id) else { return }
    entry.deliver(.cancelled)
    if entry.sent { await send(ClientFrame.interrupt(id: id)) }
  }

  private func send(_ frame: String) async {
    guard closedReason == nil else { return }
    do { try await transport.send(frame) } catch { fail(.sendFailed("\(error)")) }
  }

  private func fail(_ reason: RpcConnectionError) {
    guard closedReason == nil else { return }
    closedReason = reason
    pingTask?.cancel()
    pumpTask?.cancel()
    transport.close()
    for entry in registry.close(reason) { entry.deliver(.closed(reason)) }
    for waiter in closeWaiters { waiter.resume(returning: reason) }
    closeWaiters = []
  }

  private static func error<Failure>(from causes: [CauseItem]) -> RpcError<Failure> {
    for case .fail(let error) in causes {
      if let failure = error as? Failure { return .failure(failure) }
    }
    for case .die(let defect) in causes { return .defect(defect) }
    return causes.isEmpty ? .defect(.string("Exit failed with an empty cause")) : .interrupted
  }
}
