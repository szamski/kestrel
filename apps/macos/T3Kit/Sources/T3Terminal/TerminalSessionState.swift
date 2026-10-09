import Foundation
import Synchronization
import T3Contracts

// Port of packages/client-runtime/src/state/terminalSession.ts: pure reducers over the attach and
// metadata streams. No transport, no UI.

public enum TerminalLifecycleStatus: Sendable, Hashable {
  case starting, running, exited, error, closed

  init(_ status: TerminalSessionStatus) {
    switch status {
    case .starting: self = .starting
    case .running: self = .running
    case .exited: self = .exited
    case .error: self = .error
    // A status this build does not know still describes a live session on the server.
    case .unknown: self = .running
    }
  }
}

public struct TerminalBufferState: Sendable, Hashable {
  public var output: TerminalOutputState
  public var status: TerminalLifecycleStatus
  public var error: String?
  public var updatedAt: IsoDateTime?
  public var version: Int
  public var lifecycleVersion: Int

  public static let empty = TerminalBufferState(output: .empty, status: .closed, error: nil, updatedAt: nil, version: 0, lifecycleVersion: 0)
}

private let attachGeneration = Mutex(0)

public enum TerminalSessionReducer {
  /// A reinstalled attach stream must not reuse an old renderer's output cursor.
  public static func nextAttachSeed() -> TerminalBufferState {
    var state = TerminalBufferState.empty
    state.output.generation = attachGeneration.withLock { $0 += 1; return $0 }
    return state
  }

  private static func state(from snapshot: TerminalSessionSnapshot, maxBufferBytes: Int, current: TerminalBufferState) -> TerminalBufferState {
    TerminalBufferState(
      output: TerminalOutput.reset(current.output, snapshot.history, maxBufferBytes: maxBufferBytes),
      status: TerminalLifecycleStatus(snapshot.status), error: nil, updatedAt: snapshot.updatedAt,
      version: current.version + 1, lifecycleVersion: current.lifecycleVersion)
  }

  public static func apply(_ current: TerminalBufferState, _ event: TerminalAttachStreamEvent, maxBufferBytes: Int = TerminalOutput.defaultMaxBufferBytes) -> TerminalBufferState {
    var next = current
    switch event {
    case .snapshot(let event):
      next = state(from: event.snapshot, maxBufferBytes: maxBufferBytes, current: current)
      next.lifecycleVersion = current.version == 0 ? current.lifecycleVersion : current.lifecycleVersion + 1
    case .restarted(let event):
      next = state(from: event.snapshot, maxBufferBytes: maxBufferBytes, current: current)
      next.lifecycleVersion = current.lifecycleVersion + 1
    case .output(let event):
      next.output = TerminalOutput.append(current.output, event.data, maxBufferBytes: maxBufferBytes)
      if current.status == .closed { next.status = .running }
      next.error = nil
      next.version += 1
    case .cleared:
      next.output = TerminalOutput.reset(current.output, "", maxBufferBytes: maxBufferBytes)
      next.error = nil
      next.version += 1
    case .exited:
      next.status = .exited
      next.error = nil
      next.version += 1
    case .closed:
      next.status = .closed
      next.error = nil
      next.version += 1
    case .error(let event):
      next.status = .error
      next.error = event.message
      next.version += 1
    case .activity, .unknown:
      break
    }
    return next
  }

  public static func apply(_ current: [TerminalSummary], _ event: TerminalMetadataStreamEvent) -> [TerminalSummary] {
    switch event {
    case .snapshot(let event):
      return event.terminals
    case .remove(let event):
      return current.filter { $0.threadId != event.threadId || $0.terminalId != event.terminalId }
    case .upsert(let event):
      var next = current.filter { $0.threadId != event.terminal.threadId || $0.terminalId != event.terminal.terminalId }
      next.append(event.terminal)
      return next
    case .unknown:
      return current
    }
  }
}

/// What a view of one terminal renders: the summary from metadata plus the attach buffer.
public struct TerminalSessionState: Sendable, Hashable {
  public var summary: TerminalSummary?
  public var output: TerminalOutputState
  public var status: TerminalLifecycleStatus
  public var error: String?
  public var hasRunningSubprocess: Bool
  public var updatedAt: IsoDateTime?
  public var version: Int
  public var lifecycleVersion: Int

  /// Live attach status wins once the attach stream has emitted; metadata covers the gap before.
  public init(summary: TerminalSummary?, buffer: TerminalBufferState) {
    self.summary = summary
    output = buffer.output
    status = buffer.version > 0 ? buffer.status : (summary.map { TerminalLifecycleStatus($0.status) } ?? buffer.status)
    error = buffer.error
    hasRunningSubprocess = summary?.hasRunningSubprocess ?? false
    updatedAt = Self.latest(summary?.updatedAt, buffer.updatedAt)
    version = buffer.version
    lifecycleVersion = buffer.lifecycleVersion
  }

  private static func latest(_ left: IsoDateTime?, _ right: IsoDateTime?) -> IsoDateTime? {
    guard let left else { return right }
    guard let right else { return left }
    guard let l = left.date, let r = right.date else { return left.rawValue >= right.rawValue ? left : right }
    return l >= r ? left : right
  }
}

public extension Collection where Element == TerminalSummary {
  /// Terminals whose shell has a foreground child; an idle shell does not count.
  var runningSubprocessTerminalIds: [String] { filter(\.hasRunningSubprocess).map(\.terminalId) }
}
