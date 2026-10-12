import Foundation
import Synchronization
import T3Preview

/// One viewer socket to `/api/preview-stream/ws` for one server tab: mints a ticket for each (re)connect, acknowledges every
/// binary frame the moment it arrives (the server's flow control), hands the JPEG to the frame pipeline, decodes the JSON
/// messages, and reconnects with backoff. Frames never touch the main actor here; `events` carries everything else, in order.
final class PreviewStreamSession: Sendable {
  enum Event: Sendable {
    case connecting
    case connected
    /// The socket dropped and is being retried; the text says why when it is known.
    case disconnected(String?)
    case message(PreviewStreamMessage)
    /// The server's host cannot start its browser until its operator runs a command. The session stopped.
    case hostSetup(PreviewStreamHostSetup)
    /// The tab is gone on the server. The session stopped.
    case gone
  }

  private struct State {
    var stopped = false
    var cap: (width: Int, height: Int)
    var task: URLSessionWebSocketTask?
    var outbox: AsyncStream<String>.Continuation?
    var reconnect = false
  }

  #if DEBUG
  /// The last close the socket reported, for the driver's status line.
  nonisolated(unsafe) static var lastClose = "-"
  #endif
  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let state: Mutex<State>
  private let threadId: String
  private let tabId: String
  private let access: @Sendable () async throws -> PreviewStreamAccess
  private let pipeline: PreviewFramePipeline
  private let runner = Mutex<Task<Void, Never>?>(nil)

  init(
    threadId: String, tabId: String, cap: (width: Int, height: Int), pipeline: PreviewFramePipeline,
    access: @escaping @Sendable () async throws -> PreviewStreamAccess
  ) {
    (events, continuation) = AsyncStream.makeStream()
    state = Mutex(State(cap: cap))
    self.threadId = threadId
    self.tabId = tabId
    self.pipeline = pipeline
    self.access = access
  }

  func start() {
    runner.withLock { runner in
      guard runner == nil else { return }
      runner = Task.detached { [self] in await run() }
    }
  }

  func stop() {
    let task = state.withLock { state -> URLSessionWebSocketTask? in
      state.stopped = true
      state.outbox?.finish()
      return state.task
    }
    task?.cancel(with: .goingAway, reason: nil)
    runner.withLock { $0?.cancel() }
    pipeline.stop()
    continuation.finish()
  }

  /// The largest frame this viewer can show. The server never sends larger ones, so outgrowing the cap reconnects.
  func setCap(_ cap: (width: Int, height: Int)) {
    let task = state.withLock { state -> URLSessionWebSocketTask? in
      guard PreviewFrameCap.outgrown(cap: state.cap, wanted: cap) else { return nil }
      state.cap = (max(cap.width, state.cap.width), max(cap.height, state.cap.height))
      state.reconnect = true
      return state.task
    }
    task?.cancel(with: .goingAway, reason: nil)
  }

  /// False when no socket is open and the message was dropped (input sent while disconnected is never queued).
  @discardableResult
  func send(_ input: PreviewStreamInput) -> Bool {
    state.withLock { state in
      guard let outbox = state.outbox else { return false }
      if case .terminated = outbox.yield(input.encoded()) { return false }
      return true
    }
  }

  // MARK: Connection loop

  private func run() async {
    var failures = 0
    while !Task.isCancelled, !state.withLock({ $0.stopped }) {
      continuation.yield(.connecting)
      let delegate = SocketDelegate { [continuation] in continuation.yield(.connected) }
      var reason: String?
      do {
        let access = try await access()
        let cap = state.withLock { $0.cap }
        let url = PreviewStream.socketURL(httpBase: access.httpBase, threadId: threadId, tabId: tabId, maxWidth: cap.width, maxHeight: cap.height, ticket: access.ticket)
        var request = URLRequest(url: url)
        // The upgrade waits while the server starts its browser, and the first start downloads it.
        request.timeoutInterval = 900
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        try await receive(task, delegate: delegate, failures: &failures)
      } catch {
        reason = (error as? PreviewFailure)?.message
      }
      if Task.isCancelled || state.withLock({ $0.stopped }) { break }
      // Why the socket closed decides whether to retry at all.
      let close = await delegate.closure()
      #if DEBUG
      Self.lastClose = "\(close.map { "\($0.code) \($0.reason ?? "-")" } ?? "none")"
      #endif
      if close?.code == PreviewStream.goneCloseCode {
        continuation.yield(.gone)
        stop()
        return
      }
      if let setup = PreviewStreamHostSetup.decode(reason: close?.reason) ?? (close?.code == PreviewStream.hostSetupCloseCode ? .fallback : nil) {
        continuation.yield(.hostSetup(setup))
        stop()
        return
      }
      let immediate = state.withLock { state -> Bool in defer { state.reconnect = false }; return state.reconnect } || close?.code == 1012
      continuation.yield(.disconnected(reason))
      if immediate { continue }
      failures += 1
      try? await Task.sleep(for: .milliseconds(min(500 << min(failures - 1, 5), 10_000)))
    }
  }

  /// Reads the socket until it ends or fails; throws what ended it.
  private func receive(_ task: URLSessionWebSocketTask, delegate: SocketDelegate, failures: inout Int) async throws {
    let (outbox, outboxContinuation) = AsyncStream<String>.makeStream()
    state.withLock { $0.task = task; $0.outbox = outboxContinuation }
    // A stop that raced the connect must not leave a live socket behind.
    if state.withLock({ $0.stopped }) { task.cancel(with: .goingAway, reason: nil); return }
    task.resume()
    let sender = Task { for await text in outbox { try? await task.send(.string(text)) } }
    defer {
      sender.cancel()
      outboxContinuation.finish()
      state.withLock { $0.task = nil; $0.outbox = nil }
    }
    while true {
      let message: URLSessionWebSocketTask.Message
      do { message = try await task.receive() } catch is CancellationError { task.cancel(with: .goingAway, reason: nil); return } catch { throw PreviewFailure(error.localizedDescription) }
      failures = 0
      switch message {
      case .data(let jpeg):
        // Acknowledged on arrival, before the decode: the viewer keeps only the newest frame anyway.
        try? await task.send(.string(PreviewStream.ack))
        pipeline.submit(jpeg)
      case .string(let text):
        if let message = PreviewStreamMessage.decode(text) { continuation.yield(.message(message)) }
      @unknown default: break
      }
    }
  }
}

/// Reports the socket's open and what its close said (`URLSessionWebSocketTask` fails `receive` without the close code).
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
  struct Closure: Sendable { var code: Int; var reason: String? }

  private let onOpen: @Sendable () -> Void
  private let closed = Mutex<Closure?>(nil)

  init(onOpen: @escaping @Sendable () -> Void) { self.onOpen = onOpen }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { onOpen() }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    closed.withLock { $0 = Closure(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }) }
  }

  /// The close, given a moment to arrive: the failed `receive` can be delivered before the delegate callback.
  func closure() async -> Closure? {
    for _ in 0..<4 {
      if let closure = closed.withLock({ $0 }) { return closure }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return closed.withLock { $0 }
  }
}
