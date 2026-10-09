import Foundation
import Observation
import Synchronization
import T3Contracts

/// Where a terminal lives and how the server should start it.
public struct TerminalTarget: Sendable, Hashable {
  public var threadId: String
  public var terminalId: String
  public var cwd: String
  public var worktreePath: String?
  public var env: [String: String]?
  public var providerInstanceId: ProviderInstanceId?

  public init(threadId: String, terminalId: String, cwd: String, worktreePath: String? = nil, env: [String: String]? = nil, providerInstanceId: ProviderInstanceId? = nil) {
    self.threadId = threadId
    self.terminalId = terminalId
    self.cwd = cwd
    self.worktreePath = worktreePath
    self.env = env
    self.providerInstanceId = providerInstanceId
  }
}

/// Coalesces keystrokes and pastes into ordered `terminal.write` calls. Callable from any thread
/// (Ghostty's IO thread delivers input there) without a hop to the main actor.
final class TerminalInputPipe: Sendable {
  private struct State { var pending = ""; var flushing = false }
  private let state = Mutex(State())
  private let deliver: @Sendable (String) async -> Void

  init(deliver: @escaping @Sendable (String) async -> Void) { self.deliver = deliver }

  func send(_ data: String) {
    guard !data.isEmpty else { return }
    let startFlush = state.withLock { state -> Bool in
      state.pending += data
      if state.flushing { return false }
      state.flushing = true
      return true
    }
    guard startFlush else { return }
    Task { [self] in
      while true {
        let batch = state.withLock { state -> String? in
          if state.pending.isEmpty { state.flushing = false; return nil }
          defer { state.pending = "" }
          return state.pending
        }
        guard let batch else { return }
        await deliver(batch)
      }
    }
  }
}

/// One server-owned terminal: attach stream -> retained output buffer -> renderer, plus input,
/// resize and lifecycle commands. Mirrors terminalSession.ts / ThreadTerminalDrawer.tsx semantics:
/// the buffer is capped (512 KiB), a renderer resumes from a cursor, and every snapshot, clear or
/// restart makes cursors reset so the renderer replays from scratch.
@MainActor @Observable
public final class TerminalSession {
  public let target: TerminalTarget
  public private(set) var buffer = TerminalBufferState.empty
  /// Latest metadata summary for this terminal (label, running subprocess), set by the owner.
  public var summary: TerminalSummary?

  /// Called after the buffer changed; the renderer then reads `readOutput(since:)`.
  @ObservationIgnored public var onOutputChanged: (@MainActor () -> Void)?
  /// Called once when the process exits or the terminal is closed (the web drawer closes the tab).
  @ObservationIgnored public var onSessionExited: (@MainActor () -> Void)?

  @ObservationIgnored private let transport: any TerminalTransport
  @ObservationIgnored private let maxBufferBytes: Int
  @ObservationIgnored private var attachTask: Task<Void, Never>?
  @ObservationIgnored private var resizeTask: Task<Void, Never>?
  @ObservationIgnored private var grid: (cols: Int, rows: Int)?
  @ObservationIgnored private var sentGrid: (cols: Int, rows: Int)?
  @ObservationIgnored private var pendingResize: (cols: Int, rows: Int)?
  @ObservationIgnored private var exitHandled = false
  @ObservationIgnored private nonisolated let pipe: TerminalInputPipe

  public init(target: TerminalTarget, transport: any TerminalTransport, maxBufferBytes: Int = TerminalOutput.defaultMaxBufferBytes) {
    self.target = target
    self.transport = transport
    self.maxBufferBytes = maxBufferBytes
    let input = (threadId: target.threadId, terminalId: target.terminalId)
    pipe = TerminalInputPipe { data in
      // Failed writes are dropped like the web client's (`reportFailure: false`).
      try? await transport.write(TerminalWriteInput(threadId: input.threadId, terminalId: input.terminalId, data: data))
    }
  }

  isolated deinit { attachTask?.cancel() }

  public var state: TerminalSessionState { TerminalSessionState(summary: summary, buffer: buffer) }

  /// What the renderer must write since `cursor`: nothing, an append, or a full reset.
  public func readOutput(since cursor: TerminalOutputCursor) -> TerminalOutputUpdate {
    TerminalOutput.readUpdate(buffer.output, cursor: cursor)
  }

  // MARK: Attach

  /// Attaches (opening the terminal on the server if needed) and keeps the stream alive across
  /// connection drops until `stop()`.
  public func start() {
    guard attachTask == nil else { return }
    attachTask = Task { await self.runAttach() }
  }

  /// Detaches the stream. The terminal keeps running on the server; use `close` to end it.
  public func stop() {
    attachTask?.cancel()
    attachTask = nil
  }

  private func attachInput() -> TerminalAttachInput {
    TerminalAttachInput(
      threadId: target.threadId, terminalId: target.terminalId, cwd: target.cwd,
      worktreePath: target.worktreePath.map(Optional.some), cols: grid?.cols, rows: grid?.rows,
      env: target.env, providerInstanceId: target.providerInstanceId)
  }

  private func runAttach() async {
    var delay = Duration.milliseconds(500)
    while !Task.isCancelled {
      // A reinstalled attach must not reuse an old renderer's cursor.
      buffer = TerminalSessionReducer.nextAttachSeed()
      sentGrid = grid
      do {
        for try await event in transport.attach(attachInput()) {
          delay = .milliseconds(500)
          apply(event)
          if case .snapshot = event { flushGridIfNeeded() }
        }
        if buffer.status == .closed && buffer.version > 0 { return }
        throw Disconnected()
      } catch is CancellationError {
        return
      } catch let rejected as TerminalRejected {
        fail("\(rejected)")
        return  // retrying the same request cannot succeed
      } catch {
        if Task.isCancelled { return }
        fail(error is Disconnected ? "Terminal disconnected." : "Terminal disconnected: \(error)")
      }
      try? await Task.sleep(for: delay)
      delay = min(delay * 2, .seconds(5))
    }
  }

  private struct Disconnected: Error {}

  private func apply(_ event: TerminalAttachStreamEvent) {
    let before = buffer
    buffer = TerminalSessionReducer.apply(before, event, maxBufferBytes: maxBufferBytes)
    if buffer.output != before.output || buffer.status != before.status || buffer.error != before.error { onOutputChanged?() }
    switch buffer.status {
    case .running, .starting: exitHandled = false
    case .exited, .closed:
      if !exitHandled && before.status != buffer.status {
        exitHandled = true
        onSessionExited?()
      }
    case .error: break
    }
  }

  private func fail(_ message: String) {
    buffer.status = .error
    buffer.error = message
    buffer.version += 1
    onOutputChanged?()
  }

  // MARK: Input and size

  /// Thread-safe; ordered with every other `send`.
  public nonisolated func send(_ data: String) { pipe.send(data) }

  /// `send` as a closure for a renderer's write callback.
  public nonisolated var inputHandler: @Sendable (String) -> Void {
    let pipe = pipe
    return { pipe.send($0) }
  }

  /// Latest size wins: only one `terminal.resize` is in flight and older sizes are dropped.
  public func resize(cols: Int, rows: Int) {
    guard cols > 0, rows > 0 else { return }
    grid = (cols, rows)
    flushGridIfNeeded()
  }

  private func flushGridIfNeeded() {
    // Before the first snapshot the server may not know the terminal; the attach input carries the size.
    guard buffer.version > 0, let grid, sentGrid?.cols != grid.cols || sentGrid?.rows != grid.rows else { return }
    sentGrid = grid
    pendingResize = grid
    guard resizeTask == nil else { return }
    resizeTask = Task {
      while let next = pendingResize {
        pendingResize = nil
        try? await transport.resize(TerminalResizeInput(threadId: target.threadId, terminalId: target.terminalId, cols: next.cols, rows: next.rows))
      }
      resizeTask = nil
    }
  }

  // MARK: Lifecycle commands

  public func open() async throws {
    let snapshot = try await transport.open(
      TerminalOpenInput(
        threadId: target.threadId, terminalId: target.terminalId, cwd: target.cwd,
        worktreePath: target.worktreePath.map(Optional.some), cols: grid?.cols, rows: grid?.rows,
        env: target.env, providerInstanceId: target.providerInstanceId))
    _ = snapshot  // the attach stream delivers the same snapshot
  }

  /// Restarts the shell in place; the attach stream delivers `restarted` and the screen resets.
  public func restart() async throws {
    _ = try await transport.restart(
      TerminalRestartInput(
        threadId: target.threadId, terminalId: target.terminalId, cwd: target.cwd,
        worktreePath: target.worktreePath.map(Optional.some), cols: grid?.cols ?? 80, rows: grid?.rows ?? 24,
        env: target.env, providerInstanceId: target.providerInstanceId))
  }

  public func clear() async throws {
    try await transport.clear(TerminalClearInput(threadId: target.threadId, terminalId: target.terminalId))
  }

  /// Ends the server-side terminal and detaches.
  public func close(deleteHistory: Bool = true) async throws {
    stop()
    try await transport.close(TerminalCloseInput(threadId: target.threadId, terminalId: target.terminalId, deleteHistory: deleteHistory))
  }
}

/// The terminals of an environment, from `subscribeTerminalMetadata`. Shared by every drawer tab.
@MainActor @Observable
public final class TerminalMetadataModel {
  public private(set) var terminals: [TerminalSummary] = []
  public private(set) var isSynchronized = false

  @ObservationIgnored private let transport: any TerminalTransport
  @ObservationIgnored private var task: Task<Void, Never>?

  public init(transport: any TerminalTransport) { self.transport = transport }

  isolated deinit { task?.cancel() }

  public func terminals(for threadId: String) -> [TerminalSummary] { terminals.filter { $0.threadId == threadId } }

  public func start() {
    guard task == nil else { return }
    task = Task { await self.run() }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  private func run() async {
    var delay = Duration.milliseconds(500)
    while !Task.isCancelled {
      do {
        for try await event in transport.metadata() {
          delay = .milliseconds(500)
          terminals = TerminalSessionReducer.apply(terminals, event)
          if case .snapshot = event { isSynchronized = true }
        }
      } catch is CancellationError {
        return
      } catch {}
      isSynchronized = false
      try? await Task.sleep(for: delay)
      delay = min(delay * 2, .seconds(5))
    }
  }
}
