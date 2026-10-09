import Foundation
import Synchronization
import T3Contracts
import T3Protocol
import Testing

@testable import T3Terminal

private let target = TerminalTarget(threadId: "thread-1", terminalId: "term-1", cwd: "/repo")

private func snapshot(_ history: String = "", status: TerminalSessionStatus = .running) -> TerminalSessionSnapshot {
  TerminalSessionSnapshot(
    threadId: "thread-1", terminalId: "term-1", cwd: "/repo", worktreePath: nil, status: status, pid: 1, history: history,
    exitCode: nil, exitSignal: nil, label: "Terminal 1", updatedAt: "2026-04-01T00:00:00.000Z")
}

private func output(_ data: String) -> TerminalAttachStreamEvent {
  .output(TerminalAttachStreamEventOutput(threadId: "thread-1", terminalId: "term-1", data: data))
}

/// Scriptable transport: each `attach` hands its continuation to the test, writes and resizes can
/// be held open to exercise ordering and "latest size wins".
final class FakeTerminalTransport: TerminalTransport {
  struct State {
    var attachInputs: [TerminalAttachInput] = []
    var attachStreams: [AsyncThrowingStream<TerminalAttachStreamEvent, any Error>.Continuation] = []
    var writes: [String] = []
    var resizes: [(Int, Int)] = []
    var lifecycle: [String] = []
    var holdWrites = false
    var heldWrites: [CheckedContinuation<Void, Never>] = []
    var holdResizes = false
    var heldResizes: [CheckedContinuation<Void, Never>] = []
    var metadata: AsyncThrowingStream<TerminalMetadataStreamEvent, any Error>.Continuation?
  }
  let state = Mutex(State())

  func attach(_ input: TerminalAttachInput) -> AsyncThrowingStream<TerminalAttachStreamEvent, any Error> {
    let (stream, continuation) = AsyncThrowingStream<TerminalAttachStreamEvent, any Error>.makeStream()
    state.withLock {
      $0.attachInputs.append(input)
      $0.attachStreams.append(continuation)
    }
    return stream
  }

  func write(_ input: TerminalWriteInput) async throws {
    if state.withLock({ $0.holdWrites }) {
      await withCheckedContinuation { continuation in state.withLock { $0.heldWrites.append(continuation) } }
    }
    state.withLock { $0.writes.append(input.data) }
  }

  func resize(_ input: TerminalResizeInput) async throws {
    state.withLock { $0.resizes.append((input.cols, input.rows)) }
    if state.withLock({ $0.holdResizes }) {
      await withCheckedContinuation { continuation in state.withLock { $0.heldResizes.append(continuation) } }
    }
  }

  func open(_ input: TerminalOpenInput) async throws -> TerminalSessionSnapshot { state.withLock { $0.lifecycle.append("open \(input.cwd)") }; return snapshot() }
  func clear(_ input: TerminalClearInput) async throws { state.withLock { $0.lifecycle.append("clear") } }
  func restart(_ input: TerminalRestartInput) async throws -> TerminalSessionSnapshot { state.withLock { $0.lifecycle.append("restart \(input.cols)x\(input.rows)") }; return snapshot() }
  func close(_ input: TerminalCloseInput) async throws { state.withLock { $0.lifecycle.append("close deleteHistory=\(input.deleteHistory.map(String.init) ?? "nil")") } }
  func events() -> AsyncThrowingStream<TerminalEvent, any Error> { AsyncThrowingStream { _ in } }

  func metadata() -> AsyncThrowingStream<TerminalMetadataStreamEvent, any Error> {
    let (stream, continuation) = AsyncThrowingStream<TerminalMetadataStreamEvent, any Error>.makeStream()
    state.withLock { $0.metadata = continuation }
    return stream
  }

  func releaseWrites() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.holdWrites = false
      defer { state.heldWrites = [] }
      return state.heldWrites
    }
    held.forEach { $0.resume() }
  }

  func releaseResizes() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.holdResizes = false
      defer { state.heldResizes = [] }
      return state.heldResizes
    }
    held.forEach { $0.resume() }
  }

  var attachCount: Int { state.withLock { $0.attachStreams.count } }
  func stream(_ index: Int) -> AsyncThrowingStream<TerminalAttachStreamEvent, any Error>.Continuation { state.withLock { $0.attachStreams[index] } }
}

/// Polls a condition on the main actor, bounded; failures name what never happened.
@MainActor
func until(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while !condition(), clock.now < deadline { try? await clock.sleep(for: .milliseconds(2)) }
  #expect(condition(), Comment(rawValue: "timed out waiting for \(what)"))
}

@MainActor
@Suite struct TerminalSessionTests {
  @Test func attachBuildsTheOutputBufferAndStatus() async {
    let transport = FakeTerminalTransport()
    let session = TerminalSession(target: target, transport: transport)
    session.start()
    await until("attach") { transport.attachCount == 1 }
    let input = transport.state.withLock { $0.attachInputs[0] }
    #expect(input.threadId == "thread-1" && input.terminalId == "term-1" && input.cwd == "/repo")

    let stream = transport.stream(0)
    stream.yield(.snapshot(.init(snapshot: snapshot("hello"))))
    stream.yield(output(" world"))
    await until("output") { session.buffer.output.text == "hello world" }
    #expect(session.buffer.status == .running)

    let first = session.readOutput(since: .initial)
    #expect(first.kind == .reset && first.data == "hello world")
    stream.yield(output("!"))
    await until("append") { session.buffer.output.text == "hello world!" }
    let next = session.readOutput(since: first.cursor)
    #expect(next.kind == .append && next.data == "!")
    session.stop()
  }

  @Test func notifiesTheRendererOnlyWhenSomethingChanged() async {
    let transport = FakeTerminalTransport()
    let session = TerminalSession(target: target, transport: transport)
    var notifications = 0
    session.onOutputChanged = { notifications += 1 }
    session.start()
    await until("attach") { transport.attachCount == 1 }
    let stream = transport.stream(0)
    stream.yield(.snapshot(.init(snapshot: snapshot("a"))))
    await until("snapshot") { notifications == 1 }
    stream.yield(.activity(.init(threadId: "thread-1", terminalId: "term-1", hasRunningSubprocess: true, label: "x")))
    stream.yield(output("b"))
    await until("output") { notifications == 2 }
    #expect(notifications == 2)
    session.stop()
  }

  @Test func exitRunsTheExitHandlerOncePerLifecycle() async {
    let transport = FakeTerminalTransport()
    let session = TerminalSession(target: target, transport: transport)
    var exits = 0
    session.onSessionExited = { exits += 1 }
    session.start()
    await until("attach") { transport.attachCount == 1 }
    let stream = transport.stream(0)
    stream.yield(.snapshot(.init(snapshot: snapshot("x"))))
    stream.yield(.exited(.init(threadId: "thread-1", terminalId: "term-1", exitCode: 0)))
    stream.yield(.closed(.init(threadId: "thread-1", terminalId: "term-1")))
    await until("closed") { session.buffer.version == 3 }
    #expect(exits == 1)
    #expect(session.buffer.status == .closed)
    session.stop()
  }

  @Test func aDroppedConnectionReattachesAndTheRendererResyncs() async {
    let transport = FakeTerminalTransport()
    let session = TerminalSession(target: target, transport: transport)
    session.start()
    await until("attach") { transport.attachCount == 1 }
    transport.stream(0).yield(.snapshot(.init(snapshot: snapshot("same"))))
    await until("snapshot") { session.buffer.version == 1 }
    let cursor = session.readOutput(since: .initial).cursor

    transport.stream(0).finish(throwing: URLError(.networkConnectionLost))
    await until("reattach") { transport.attachCount == 2 }
    #expect(session.buffer.status == .error || session.buffer.version == 0)
    transport.stream(1).yield(.snapshot(.init(snapshot: snapshot("same"))))
    await until("fresh snapshot") { session.buffer.status == .running }
    // Identical counters and text, yet the old cursor must not be trusted: a new attach starts a new generation.
    let update = session.readOutput(since: cursor)
    #expect(update.kind == .reset && update.data == "same")
    session.stop()
  }

  @Test func aServerRejectionIsShownAndNotRetried() async {
    struct Rejecting: TerminalTransport {
      func attach(_ input: TerminalAttachInput) -> AsyncThrowingStream<TerminalAttachStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: TerminalRejected(description: "cwd not found")) }
      }
      func open(_ input: TerminalOpenInput) async throws -> TerminalSessionSnapshot { fatalError() }
      func write(_ input: TerminalWriteInput) async throws {}
      func resize(_ input: TerminalResizeInput) async throws {}
      func clear(_ input: TerminalClearInput) async throws {}
      func restart(_ input: TerminalRestartInput) async throws -> TerminalSessionSnapshot { fatalError() }
      func close(_ input: TerminalCloseInput) async throws {}
      func events() -> AsyncThrowingStream<TerminalEvent, any Error> { AsyncThrowingStream { _ in } }
      func metadata() -> AsyncThrowingStream<TerminalMetadataStreamEvent, any Error> { AsyncThrowingStream { _ in } }
    }
    let session = TerminalSession(target: target, transport: Rejecting())
    session.start()
    await until("error") { session.buffer.status == .error }
    #expect(session.buffer.error == "cwd not found")
  }

  @Test func inputKeepsOrderAndCoalescesWhileAWriteIsInFlight() async {
    let transport = FakeTerminalTransport()
    transport.state.withLock { $0.holdWrites = true }
    let session = TerminalSession(target: target, transport: transport)
    session.send("a")
    await until("first write in flight") { transport.state.withLock { !$0.heldWrites.isEmpty } }
    session.send("b")
    session.send("c")
    session.send("d")
    transport.releaseWrites()
    await until("all writes") { transport.state.withLock { $0.writes.joined() == "abcd" } }
    // Everything typed while the first write was in flight went out as one ordered write.
    #expect(transport.state.withLock { $0.writes } == ["a", "bcd"])
  }

  @Test func resizeSendsOnlyTheLatestSizeAndWaitsForTheFirstSnapshot() async {
    let transport = FakeTerminalTransport()
    transport.state.withLock { $0.holdResizes = true }
    let session = TerminalSession(target: target, transport: transport)
    session.resize(cols: 100, rows: 30)  // before attach: rides on the attach input instead
    session.start()
    await until("attach") { transport.attachCount == 1 }
    let input = transport.state.withLock { $0.attachInputs[0] }
    #expect(input.cols == 100 && input.rows == 30)
    #expect(transport.state.withLock { $0.resizes.isEmpty })

    transport.stream(0).yield(.snapshot(.init(snapshot: snapshot())))
    await until("snapshot") { session.buffer.version == 1 }
    session.resize(cols: 120, rows: 40)
    await until("first resize in flight") { transport.state.withLock { $0.resizes.count == 1 } }
    session.resize(cols: 121, rows: 41)
    session.resize(cols: 130, rows: 50)
    transport.releaseResizes()
    await until("latest resize") { transport.state.withLock { $0.resizes.count == 2 } }
    let sent = transport.state.withLock { $0.resizes.map { "\($0.0)x\($0.1)" } }
    #expect(sent == ["120x40", "130x50"])
    session.stop()
  }

  @Test func lifecycleCommandsMapToTheTerminalRpcs() async throws {
    let transport = FakeTerminalTransport()
    let session = TerminalSession(target: target, transport: transport)
    session.resize(cols: 90, rows: 25)
    try await session.open()
    try await session.restart()
    try await session.clear()
    try await session.close(deleteHistory: true)
    #expect(transport.state.withLock { $0.lifecycle } == ["open /repo", "restart 90x25", "clear", "close deleteHistory=true"])
  }

  @Test func metadataModelFollowsSnapshotsUpsertsAndRemovals() async {
    let transport = FakeTerminalTransport()
    let model = TerminalMetadataModel(transport: transport)
    model.start()
    await until("metadata stream") { transport.state.withLock { $0.metadata != nil } }
    let summary = TerminalSummary(
      threadId: "thread-1", terminalId: "term-1", cwd: "/repo", worktreePath: nil, status: .running, pid: 1, exitCode: nil,
      exitSignal: nil, hasRunningSubprocess: false, label: "Terminal 1", updatedAt: "2026-04-01T00:00:00.000Z")
    var other = summary
    other.threadId = "thread-2"
    let continuation = transport.state.withLock { $0.metadata! }
    continuation.yield(.snapshot(.init(terminals: [summary, other])))
    await until("snapshot") { model.isSynchronized && model.terminals.count == 2 }
    #expect(model.terminals(for: "thread-1").map(\.terminalId) == ["term-1"])
    var busy = summary
    busy.hasRunningSubprocess = true
    continuation.yield(.upsert(.init(terminal: busy)))
    await until("upsert") { model.terminals(for: "thread-1").first?.hasRunningSubprocess == true }
    continuation.yield(.remove(.init(threadId: "thread-1", terminalId: "term-1")))
    await until("remove") { model.terminals(for: "thread-1").isEmpty }
    model.stop()
  }
}

// MARK: RPC adapter

private final class FakeRpcClient: TerminalRpcClient {
  let calls = Mutex<[String]>([])
  let failure: TerminalOpenFailure?

  init(failure: TerminalOpenFailure? = nil) { self.failure = failure }

  func call<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) async throws(RpcError<Failure>) -> Success {
    calls.withLock { $0.append(spec.tag) }
    if let failure = failure as? Failure { throw .failure(failure) }
    if let value = VoidValue() as? Success { return value }
    return snapshot() as! Success
  }

  func subscribe<Payload, Success, Failure>(_ spec: RpcSpec<Payload, Success, Failure>, _ payload: Payload) -> AsyncThrowingStream<Success, any Error> {
    calls.withLock { $0.append(spec.tag) }
    return AsyncThrowingStream { $0.finish(throwing: RpcError<Failure>.failure(self.failure as! Failure)) }
  }
}

@Suite struct RpcTerminalTransportTests {
  @Test func callsTheGeneratedTerminalSpecs() async throws {
    let client = FakeRpcClient()
    let transport = RpcTerminalTransport(client)
    _ = try await transport.open(TerminalOpenInput(threadId: "t", terminalId: "x", cwd: "/"))
    try await transport.write(TerminalWriteInput(threadId: "t", terminalId: "x", data: "ls\r"))
    try await transport.resize(TerminalResizeInput(threadId: "t", terminalId: "x", cols: 80, rows: 24))
    try await transport.clear(TerminalClearInput(threadId: "t", terminalId: "x"))
    _ = try await transport.restart(TerminalRestartInput(threadId: "t", terminalId: "x", cwd: "/", cols: 80, rows: 24))
    try await transport.close(TerminalCloseInput(threadId: "t", terminalId: "x"))
    #expect(client.calls.withLock { $0 } == ["terminal.open", "terminal.write", "terminal.resize", "terminal.clear", "terminal.restart", "terminal.close"])
  }

  @Test func aTypedServerFailureBecomesANonRetriableRejection() async {
    let client = FakeRpcClient(failure: .terminalCwdNotFoundError(.init(cwd: "/missing")))
    let transport = RpcTerminalTransport(client)
    await #expect(throws: TerminalRejected.self) { try await transport.write(TerminalWriteInput(threadId: "t", terminalId: "x", data: "a")) }
    do {
      for try await _ in transport.attach(TerminalAttachInput(threadId: "t", terminalId: "x")) {}
      Issue.record("attach should fail")
    } catch {
      #expect(error is TerminalRejected)
    }
  }
}
