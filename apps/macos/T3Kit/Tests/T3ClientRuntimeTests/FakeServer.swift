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
  /// Each connection attempt speaks the next protocol of the list (the last one repeats): the descriptor is re-read per attempt.
  private let protocols: [OrchestrationProtocol]
  private let attempts = Mutex(0)
  init(_ servers: [FakeServer], orchestrationProtocol: OrchestrationProtocol = .v1) { self.servers.withLock { $0 = servers }; protocols = [orchestrationProtocol] }
  init(_ servers: [FakeServer], protocols: [OrchestrationProtocol]) { self.servers.withLock { $0 = servers }; self.protocols = protocols }
  var connections: [FakeServer] { created.withLock { $0 } }

  func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    progress(.preparing)
    guard let server = servers.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ConnectionAttemptError.transient(.network, detail: "no server") }
    created.withLock { $0.append(server) }
    let attempt = attempts.withLock { n -> Int in defer { n += 1 }; return n }
    let negotiated = protocols[min(attempt, protocols.count - 1)]
    let prepared = PreparedConnection(
      environmentId: entry.environmentId, label: entry.label, httpBaseURL: entry.httpBaseURL, socketURL: entry.wsBaseURL, authorization: .bearer("t"),
      orchestrationProtocol: negotiated)
    progress(.opening(prepared))
    progress(.synchronizing(prepared))
    let session = try await LiveEnvironmentSession.open(
      transport: server, label: entry.label, expectedEnvironmentId: entry.environmentId, orchestrationProtocol: negotiated,
      pingInterval: .seconds(3600), onConfigEvent: onConfigEvent)
    return ConnectionLease(prepared: prepared, session: session)
  }
}

/// Canned HTTP snapshots with call counters.
final class FakeLoader: SnapshotLoading {
  private struct State {
    var shell: V1.OrchestrationShellSnapshot?
    var thread: V1.OrchestrationThreadDetailSnapshot?
    var shellCalls = 0
    var threadCalls: [ThreadSnapshotWindow?] = []
    var shellV2: OrchestrationV2ShellSnapshot?
    var threadV2: ThreadSnapshotLoadResult = .unavailable
    var historyPages: [String: OrchestrationV2ThreadHistoryPage] = [:]
    var shellV2Calls = 0
    var threadV2Calls = 0
    var historyCursors: [String] = []
  }
  private let state = Mutex(State())
  init(shell: V1.OrchestrationShellSnapshot? = nil, thread: V1.OrchestrationThreadDetailSnapshot? = nil) { state.withLock { $0.shell = shell; $0.thread = thread } }
  init(shellV2: OrchestrationV2ShellSnapshot?, threadV2: ThreadSnapshotLoadResult = .unavailable, historyPages: [String: OrchestrationV2ThreadHistoryPage] = [:]) {
    state.withLock { $0.shellV2 = shellV2; $0.threadV2 = threadV2; $0.historyPages = historyPages }
  }
  var shellV2Calls: Int { state.withLock { $0.shellV2Calls } }
  var threadV2Calls: Int { state.withLock { $0.threadV2Calls } }
  var historyCursors: [String] { state.withLock { $0.historyCursors } }
  func loadShellV2(_ prepared: PreparedConnection) async -> OrchestrationV2ShellSnapshot? { state.withLock { $0.shellV2Calls += 1; return $0.shellV2 } }
  func loadThreadV2(_ prepared: PreparedConnection, threadId: ThreadId) async -> ThreadSnapshotLoadResult { state.withLock { $0.threadV2Calls += 1; return $0.threadV2 } }
  func loadHistoryPage(_ prepared: PreparedConnection, threadId: ThreadId, cursor: String) async -> Result<OrchestrationV2ThreadHistoryPage, HistoryLoadFailure> {
    state.withLock { state in
      state.historyCursors.append(cursor)
      return state.historyPages[cursor].map { .success($0) } ?? .failure(HistoryLoadFailure("no page"))
    }
  }
  var shellCalls: Int { state.withLock { $0.shellCalls } }
  var threadCalls: [ThreadSnapshotWindow?] { state.withLock { $0.threadCalls } }
  func set(shell: V1.OrchestrationShellSnapshot?) { state.withLock { $0.shell = shell } }
  func set(thread: V1.OrchestrationThreadDetailSnapshot?) { state.withLock { $0.thread = thread } }
  func loadShell(_ prepared: PreparedConnection) async -> V1.OrchestrationShellSnapshot? { state.withLock { $0.shellCalls += 1; return $0.shell } }
  func loadThread(_ prepared: PreparedConnection, threadId: ThreadId, window: ThreadSnapshotWindow?, reasoningMessages: Bool) async -> V1.OrchestrationThreadDetailSnapshot? {
    state.withLock { $0.threadCalls.append(window); return $0.thread }
  }
}

enum Data2 {
  static func shell() -> V1.OrchestrationShellSnapshot { try! JSONDecoder().decode(V1.OrchestrationShellSnapshot.self, from: Fixtures.contractFixture("shell.json")) }
  static func threadDetail() -> V1.OrchestrationThreadDetailSnapshot {
    try! JSONDecoder().decode(V1.OrchestrationThreadDetailSnapshot.self, from: Fixtures.contractFixture("threads/thread-4.json"))
  }
  /// A thread-upserted shell item for a (possibly new) thread, derived from the first fixture thread.
  static func threadUpserted(_ sequence: Int, id: String, edit: (inout V1.OrchestrationThreadShell) -> Void = { _ in }) -> V1.OrchestrationShellStreamItem {
    var thread = shell().threads[0]
    thread.id = ThreadId(rawValue: id)
    edit(&thread)
    return .threadUpserted(V1.OrchestrationShellStreamItemThreadUpserted(sequence: sequence, thread: thread))
  }
}
