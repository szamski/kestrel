import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// An in-process environment server behind `RpcTransport`: the real `RpcSession` and
/// `LiveEnvironmentSession` run on top of it, so tests exercise the wire format too.
final class FakeServer: RpcTransport {
  struct Request: @unchecked Sendable {
    let id: Int
    let tag: String
    let payload: [String: Any]
  }
  private struct State {
    var requests: [Request] = []
    var waiters: [(tag: String, count: Int, continuation: CheckedContinuation<Request, Never>)] = []
    var interrupted: [Int] = []
    var closed = false
  }

  let frames: AsyncThrowingStream<Data, any Error>
  private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
  private let state = Mutex(State())
  private let config: ServerConfig

  init(config: ServerConfig = Fixtures.serverConfig()) {
    self.config = config
    (frames, incoming) = AsyncThrowingStream.makeStream()
  }

  func send(_ text: String) async throws {
    guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
    switch json["_tag"] as? String {
    case "Ping": push(#"{"_tag":"Pong"}"#)
    case "Interrupt": state.withLock { $0.interrupted.append(json["requestId"] as? Int ?? -1) }
    case "Request":
      let request = Request(id: json["id"] as! Int, tag: json["tag"] as! String, payload: json["payload"] as? [String: Any] ?? [:])
      let ready = state.withLock { state -> [CheckedContinuation<Request, Never>] in
        state.requests.append(request)
        var ready: [CheckedContinuation<Request, Never>] = []
        state.waiters.removeAll { waiter in
          let matches = state.requests.filter { $0.tag == waiter.tag }
          guard matches.count >= waiter.count else { return false }
          ready.append(waiter.continuation)
          return true
        }
        return ready
      }
      if request.tag == "subscribeServerConfig" { chunk(request, [try configSnapshotJSON()]) }
      for waiter in ready { waiter.resume(returning: request) }
    default: break
    }
  }

  func close() { state.withLock { $0.closed = true }; incoming.finish() }
  var isClosed: Bool { state.withLock { $0.closed } }
  var interrupted: [Int] { state.withLock { $0.interrupted } }

  private func configSnapshotJSON() throws -> Any {
    let snapshot = ["version": 1, "type": "snapshot", "config": try toAny(config)] as [String: Any]
    return snapshot
  }

  // MARK: Test side

  func requests(_ tag: String) -> [Request] { state.withLock { $0.requests.filter { $0.tag == tag } } }

  /// The `count`-th (1-based) request with `tag`, suspending until the client sent it.
  func waitForRequest(_ tag: String, count: Int = 1) async -> Request {
    await withCheckedContinuation { (continuation: CheckedContinuation<Request, Never>) in
      let immediate = state.withLock { state -> Request? in
        let matches = state.requests.filter { $0.tag == tag }
        if matches.count >= count { return matches[count - 1] }
        state.waiters.append((tag, count, continuation))
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }

  private func push(_ text: String) { incoming.yield(Data(text.utf8)) }
  private func encode(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
  }

  func chunk(_ request: Request, _ values: [Any]) {
    push(encode(["_tag": "Chunk", "requestId": request.id, "values": values] as [String: Any]))
  }
  func chunk<T: Encodable>(_ request: Request, items: [T]) throws { chunk(request, try items.map { try toAny($0) }) }
  func succeed(_ request: Request, _ value: Any) {
    push(encode(["_tag": "Exit", "requestId": request.id, "exit": ["_tag": "Success", "value": value]] as [String: Any]))
  }
  func fail(_ request: Request, error: [String: Any]) {
    push(encode(["_tag": "Exit", "requestId": request.id, "exit": ["_tag": "Failure", "cause": [["_tag": "Fail", "error": error]]]] as [String: Any]))
  }
  func endStream(_ request: Request) { succeed(request, NSNull()) }
}

/// A driver that opens a `LiveEnvironmentSession` over a `FakeServer` for each attempt.
final class FakeServerDriver: ConnectionDriving {
  private let servers = Mutex<[FakeServer]>([])
  private let created = Mutex<[FakeServer]>([])
  init(_ servers: [FakeServer]) { self.servers.withLock { $0 = servers } }
  var connections: [FakeServer] { created.withLock { $0 } }

  func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    progress(.preparing)
    guard let server = servers.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ConnectionAttemptError.transient(.network, detail: "no server") }
    created.withLock { $0.append(server) }
    let prepared = PreparedConnection(
      environmentId: entry.environmentId, label: entry.label, httpBaseURL: entry.httpBaseURL, socketURL: entry.wsBaseURL, authorization: .bearer("t"))
    progress(.opening(prepared))
    progress(.synchronizing(prepared))
    let session = try await LiveEnvironmentSession.open(
      transport: server, label: entry.label, expectedEnvironmentId: entry.environmentId, pingInterval: .seconds(3600), onConfigEvent: onConfigEvent)
    return ConnectionLease(prepared: prepared, session: session)
  }
}

/// Canned HTTP snapshots with call counters.
final class FakeLoader: SnapshotLoading {
  private struct State { var shell: OrchestrationShellSnapshot?; var thread: OrchestrationThreadDetailSnapshot?; var shellCalls = 0; var threadCalls: [ThreadSnapshotWindow?] = [] }
  private let state = Mutex(State())
  init(shell: OrchestrationShellSnapshot? = nil, thread: OrchestrationThreadDetailSnapshot? = nil) { state.withLock { $0.shell = shell; $0.thread = thread } }
  var shellCalls: Int { state.withLock { $0.shellCalls } }
  var threadCalls: [ThreadSnapshotWindow?] { state.withLock { $0.threadCalls } }
  func set(shell: OrchestrationShellSnapshot?) { state.withLock { $0.shell = shell } }
  func set(thread: OrchestrationThreadDetailSnapshot?) { state.withLock { $0.thread = thread } }
  func loadShell(_ prepared: PreparedConnection) async -> OrchestrationShellSnapshot? { state.withLock { $0.shellCalls += 1; return $0.shell } }
  func loadThread(_ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool) async -> OrchestrationThreadDetailSnapshot? {
    state.withLock { $0.threadCalls.append(window); return $0.thread }
  }
}

enum Data2 {
  static func shell() -> OrchestrationShellSnapshot { try! JSONDecoder().decode(OrchestrationShellSnapshot.self, from: Fixtures.contractFixture("shell.json")) }
  static func threadDetail() -> OrchestrationThreadDetailSnapshot {
    try! JSONDecoder().decode(OrchestrationThreadDetailSnapshot.self, from: Fixtures.contractFixture("threads/thread-4.json"))
  }
  /// A thread-upserted shell item for a (possibly new) thread, derived from the first fixture thread.
  static func threadUpserted(_ sequence: Int, id: String, edit: (inout OrchestrationThreadShell) -> Void = { _ in }) -> OrchestrationShellStreamItem {
    var thread = shell().threads[0]
    thread.id = ThreadId(rawValue: id)
    edit(&thread)
    return .threadUpserted(OrchestrationShellStreamItemThreadUpserted(sequence: sequence, thread: thread))
  }
}
