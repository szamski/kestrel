import Foundation

/// One WebSocket carrying Effect RPC JSON frames.
public protocol RpcTransport: Sendable {
  /// Incoming text frames. Finishes normally or with an error when the socket closes.
  var frames: AsyncThrowingStream<Data, any Error> { get }
  /// Frames must hit the wire in call order: the implementation enqueues
  /// synchronously before its first suspension. `RpcSession` relies on this to
  /// keep Interrupt behind its Request.
  func send(_ text: String) async throws
  func close()
}

/// The server closed the socket (or the network dropped it).
public struct WebSocketClosedError: Error, Sendable, CustomStringConvertible {
  public let closeCode: Int
  public let reason: String?
  public let underlying: String

  public var description: String {
    "WebSocket closed (code \(closeCode)\(reason.map { ", \($0)" } ?? "")): \(underlying)"
  }
}

public enum WebSocketOpenError: Error, Sendable, Equatable {
  case timeout
  /// Handshake failed; `httpStatus` is the upgrade response status when there was one.
  case rejected(httpStatus: Int?, message: String)
}

/// `URLSessionWebSocketTask` transport. permessage-deflate is negotiated by URLSession.
public final class URLSessionWebSocketTransport: RpcTransport {
  public let frames: AsyncThrowingStream<Data, any Error>
  private let task: URLSessionWebSocketTask
  private let session: URLSession

  private init(task: URLSessionWebSocketTask, session: URLSession) {
    self.task = task
    self.session = session
    frames = AsyncThrowingStream { continuation in
      let reader = Task {
        do {
          while true {
            switch try await task.receive() {
            case .string(let text): continuation.yield(Data(text.utf8))
            case .data(let data): continuation.yield(data)
            @unknown default: break
            }
          }
        } catch {
          continuation.finish(
            throwing: WebSocketClosedError(
              closeCode: task.closeCode.rawValue,
              reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) },
              underlying: error.localizedDescription))
        }
      }
      continuation.onTermination = { _ in reader.cancel() }
    }
  }

  /// Opens the socket and waits until the handshake completed (probed with a ping).
  /// `request` carries the ticket URL and, later, any `Authorization: DPoP` header.
  public static func open(
    _ request: URLRequest,
    openTimeout: Duration = .seconds(15),
    // URLSession's default of 1 MiB is below real shell snapshots.
    maximumMessageSize: Int = 64 << 20
  ) async throws -> URLSessionWebSocketTransport {
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = maximumMessageSize
    task.resume()
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
              if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
          }
        }
        group.addTask {
          try await Task.sleep(for: openTimeout)
          throw WebSocketOpenError.timeout
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch {
      let status = (task.response as? HTTPURLResponse)?.statusCode
      task.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
      if error as? WebSocketOpenError == .timeout { throw error }
      throw WebSocketOpenError.rejected(httpStatus: status, message: error.localizedDescription)
    }
    return URLSessionWebSocketTransport(task: task, session: session)
  }

  public func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  public func close() {
    task.cancel(with: .goingAway, reason: nil)
    session.finishTasksAndInvalidate()
  }
}
