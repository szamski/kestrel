import Foundation
import Synchronization
import Testing
import T3Contracts
import T3Protocol
@testable import T3ClientRuntime

/// Deterministic clock: sleepers wake only when the test advances time. `advance` first waits
/// until a sleeper exists, so a test that reacts to a state change can never advance before the
/// code under test has started waiting.
final class ManualClock: RuntimeClock {
  private struct Sleeper { let deadline: Int64; let continuation: CheckedContinuation<Void, any Error> }
  private struct State {
    var now: Int64 = 1_700_000_000_000
    var sleepers: [Int: Sleeper] = [:]
    var nextID = 0
    var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())

  func nowMilliseconds() -> Int64 { state.withLock { $0.now } }
  var sleeperCount: Int { state.withLock { $0.sleepers.count } }

  func sleep(for duration: Duration) async throws {
    let ms = Int64(duration.components.seconds) * 1000 + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    let id = state.withLock { state -> Int in state.nextID += 1; return state.nextID }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let (cancelled, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
          if Task.isCancelled { return (true, []) }
          state.sleepers[id] = Sleeper(deadline: state.now + ms, continuation: continuation)
          defer { state.arrivalWaiters = [] }
          return (false, state.arrivalWaiters)
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        for waiter in waiters { waiter.resume() }
      }
    } onCancel: {
      let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Suspends until at least `count` sleepers are registered.
  func waitForSleepers(_ count: Int = 1) async {
    while sleeperCount < count {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = state.withLock { state -> Bool in
          if state.sleepers.count >= count { return true }
          state.arrivalWaiters.append(continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    }
  }

  /// Moves time forward and wakes every sleeper whose deadline passed.
  func advance(by duration: Duration, waitForSleeper: Bool = true) async {
    if waitForSleeper { await waitForSleepers() }
    let ms = Int64(duration.components.seconds) * 1000 + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    let due = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
      state.now += ms
      let ids = state.sleepers.filter { $0.value.deadline <= state.now }.keys
      return ids.compactMap { state.sleepers.removeValue(forKey: $0)?.continuation }
    }
    for continuation in due { continuation.resume() }
  }
}

/// A session that is only a lifetime: closed on demand, probe scripted.
final class StubSession: EnvironmentSession {
  enum Probe: Sendable { case ok, fail, hang }
  let id: Int
  let initialConfig: ServerConfig
  let orchestrationProtocol: OrchestrationProtocol = .v1
  private let closedDeferred = Deferred<ConnectionAttemptError>()
  private let probeBehavior = Mutex(Probe.ok)
  let probes = Mutex(0)
  let closeCount = Mutex(0)
  private static let ids = Mutex(1000)

  init(config: ServerConfig = Fixtures.serverConfig()) {
    id = Self.ids.withLock { $0 += 1; return $0 }
    initialConfig = config
  }

  func setProbe(_ behavior: Probe) { probeBehavior.withLock { $0 = behavior } }
  func drop(_ detail: String = "socket lost") { closedDeferred.complete(.success(.transient(.transport, detail: detail))) }

  func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success {
    throw .defect(.string("StubSession cannot call \(spec.tag)"))
  }
  func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error> {
    AsyncThrowingStream { $0.finish(throwing: RpcError<Failure>.defect(.string("StubSession cannot subscribe \(spec.tag)"))) }
  }
  func probe() async throws(ConnectionAttemptError) {
    probes.withLock { $0 += 1 }
    switch probeBehavior.withLock({ $0 }) {
    case .ok: return
    case .fail: throw .transient(.transport, detail: "probe failed")
    case .hang:
      try? await Task.sleep(for: .seconds(3600))
    }
  }
  func waitUntilClosed() async -> ConnectionAttemptError {
    (try? await closedDeferred.value()) ?? .transient(.transport, detail: "closed")
  }
  func close() async {
    closeCount.withLock { $0 += 1 }
    closedDeferred.complete(.success(.transient(.transport, detail: "closed by client")))
  }
}

/// Scripted driver: each `connect` consumes the next behaviour.
final class ScriptedDriver: ConnectionDriving {
  enum Step: Sendable {
    case succeed(any EnvironmentSession)
    case fail(ConnectionAttemptError)
    /// Never completes on its own (until cancelled).
    case hang
  }
  private struct State { var script: [Step] = []; var attempts = 0; var waiters: [(Int, CheckedContinuation<Void, Never>)] = [] }
  private let state = Mutex(State())

  init(_ steps: [Step] = []) { state.withLock { $0.script = steps } }
  var attempts: Int { state.withLock { $0.attempts } }
  func append(_ step: Step) { state.withLock { $0.script.append(step) } }

  /// Suspends until `count` connect attempts have started.
  func waitForAttempts(_ count: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = state.withLock { state -> Bool in
        if state.attempts >= count { return true }
        state.waiters.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func connect(
    _ entry: EnvironmentConnectionEntry, progress: @Sendable (ConnectionAttemptProgress) -> Void,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void
  ) async throws -> ConnectionLease {
    let (step, ready) = state.withLock { state -> (Step, [CheckedContinuation<Void, Never>]) in
      state.attempts += 1
      let step = state.script.isEmpty ? Step.hang : state.script.removeFirst()
      let ready = state.waiters.filter { state.attempts >= $0.0 }.map(\.1)
      state.waiters.removeAll { state.attempts >= $0.0 }
      return (step, ready)
    }
    for waiter in ready { waiter.resume() }
    progress(.preparing)
    switch step {
    case .succeed(let session):
      let prepared = PreparedConnection(
        environmentId: entry.environmentId, label: entry.label, httpBaseURL: entry.httpBaseURL,
        socketURL: entry.wsBaseURL, authorization: .bearer("t"))
      progress(.opening(prepared))
      return ConnectionLease(prepared: prepared, session: session)
    case .fail(let error): throw error
    case .hang:
      try await Task.sleep(for: .seconds(3600))
      throw CancellationError()
    }
  }
}

/// Waits on a hub until `predicate` holds for its (current or future) value.
func waitFor<Value: Sendable>(_ hub: ValueHub<Value>, _ predicate: @Sendable (Value) -> Bool) async -> Value {
  for await value in hub.changes() where predicate(value) { return value }
  fatalError("hub finished")
}

enum Fixtures {
  static let environmentId = EnvironmentId(rawValue: "env-test")
  static func entry(id: String = "env-test") -> EnvironmentConnectionEntry {
    EnvironmentConnectionEntry(
      environmentId: EnvironmentId(rawValue: id), label: "Test", httpBaseURL: URL(string: "http://localhost:1")!,
      wsBaseURL: URL(string: "ws://localhost:1")!)
  }

  /// A decoded server config (the committed contract fixture), so sessions carry realistic capabilities.
  static func serverConfig(markers: Bool = true) -> ServerConfig {
    var config = try! JSONDecoder().decode(ServerConfig.self, from: load("rpc/server.getConfig.json", unwrapExit: true))
    config.shellResumeCompletionMarker = markers
    config.threadResumeCompletionMarker = markers
    config.threadSnapshotPagination = true
    return config
  }

  static func contractFixture(_ path: String) -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/contracts/\(path)")
    return try! Data(contentsOf: url)
  }

  static func load(_ path: String, unwrapExit: Bool) -> Data {
    let data = contractFixture(path)
    guard unwrapExit else { return data }
    let messages = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let exit = messages.first { $0["_tag"] as? String == "Exit" }!["exit"] as! [String: Any]
    return try! JSONSerialization.data(withJSONObject: exit["value"]!, options: [.fragmentsAllowed])
  }
}
