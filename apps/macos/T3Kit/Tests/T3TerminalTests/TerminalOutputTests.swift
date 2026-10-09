import Foundation
import T3Contracts
import Testing

@testable import T3Terminal

// Oracle: packages/client-runtime/src/state/terminalSession.test.ts. Case names follow the TS tests.

private let baseSnapshot = TerminalSessionSnapshot(
  threadId: "thread-1", terminalId: "term-1", cwd: "/repo", worktreePath: nil, status: .running, pid: 123,
  history: "hello", exitCode: nil, exitSignal: nil, label: "Terminal 1", updatedAt: "2026-04-01T00:00:00.000Z")

private func snapshot(_ history: String, pid: Int = 123) -> TerminalSessionSnapshot {
  var copy = baseSnapshot
  copy.history = history
  copy.pid = pid
  return copy
}

private func output(_ data: String) -> TerminalAttachStreamEvent {
  .output(TerminalAttachStreamEventOutput(threadId: "thread-1", terminalId: "term-1", data: data))
}

private func apply(_ state: TerminalBufferState, _ event: TerminalAttachStreamEvent, max: Int = TerminalOutput.defaultMaxBufferBytes) -> TerminalBufferState {
  TerminalSessionReducer.apply(state, event, maxBufferBytes: max)
}

private func summary(_ snapshot: TerminalSessionSnapshot = baseSnapshot, running: Bool = false) -> TerminalSummary {
  TerminalSummary(
    threadId: snapshot.threadId, terminalId: snapshot.terminalId, cwd: snapshot.cwd, worktreePath: snapshot.worktreePath,
    status: snapshot.status, pid: snapshot.pid, exitCode: snapshot.exitCode, exitSignal: snapshot.exitSignal,
    hasRunningSubprocess: running, label: snapshot.label, updatedAt: snapshot.updatedAt)
}

@Suite struct TerminalOutputTests {
  @Test func prefersLiveAttachStatusOverStaleMetadata() {
    let attached = apply(.empty, .error(TerminalAttachStreamEventError(threadId: "thread-1", terminalId: "term-1", message: "Terminal disconnected.")))
    let state = TerminalSessionState(summary: summary(), buffer: attached)
    #expect(state.status == .error)
    #expect(state.error == "Terminal disconnected.")
    #expect(state.version == 1)
  }

  @Test func usesMetadataStatusBeforeAttachEmitted() {
    #expect(TerminalSessionState(summary: summary(), buffer: .empty).status == .running)
  }

  @Test func idleRunningShellIsNotARunningSubprocess() {
    var busy = summary()
    busy.terminalId = "term-2"
    busy.hasRunningSubprocess = true
    #expect([summary(), busy].runningSubprocessTerminalIds == ["term-2"])
  }

  @Test func reducesAttachSnapshotsAndOutput() {
    let snap = apply(.empty, .snapshot(.init(snapshot: baseSnapshot)))
    let out = apply(snap, output(" world"), max: 8)
    #expect(out.status == .running)
    #expect(out.error == nil)
    #expect(out.version == 2)
    #expect(out.output.text == "lo world")
  }

  @Test func initialSnapshotDoesNotAdvanceLifecycleButLiveOnesDo() {
    let initial = apply(.empty, .snapshot(.init(snapshot: baseSnapshot)))
    #expect(initial.status == .running && initial.lifecycleVersion == 0)
    let started = apply(initial, .snapshot(.init(snapshot: snapshot("hello", pid: 456))))
    #expect(started.lifecycleVersion == 1)
    let restarted = apply(initial, .restarted(.init(threadId: "thread-1", terminalId: "term-1", snapshot: snapshot("hello", pid: 456))))
    #expect(restarted.lifecycleVersion == 1)
  }

  @Test func reducesMetadataSnapshotsUpsertsAndRemovals() {
    let initial = TerminalSessionReducer.apply([], .snapshot(.init(terminals: [summary()])))
    var busy = initial[0]
    busy.hasRunningSubprocess = true
    let updated = TerminalSessionReducer.apply(initial, .upsert(.init(terminal: busy)))
    let removed = TerminalSessionReducer.apply(updated, .remove(.init(threadId: "thread-1", terminalId: "term-1")))
    #expect(updated.count == 1 && updated[0].hasRunningSubprocess)
    #expect(removed.isEmpty)
  }

  @Test func capsRetainedOutputByUtf8ByteLength() {
    let state = apply(.empty, output("🙂🙂"), max: 4)
    #expect(state.output.text == "🙂")
  }

  @Test func preservesABomAtANewChunkBoundary() {
    let initial = apply(.empty, .snapshot(.init(snapshot: snapshot(""))))
    let cursor = TerminalOutput.readUpdate(initial.output, cursor: .initial).cursor
    let data = String(repeating: "x", count: 16_384) + "\u{FEFF}" + String(repeating: "y", count: 20)
    let state = apply(initial, output(data))
    #expect(state.output.text == data)
    let update = TerminalOutput.readUpdate(state.output, cursor: cursor)
    #expect(update.kind == .append && update.data == data)
    #expect(state.output.retainedBytes == data.utf8.count)
  }

  @Test func preservesALeadingBomInTheRetainedSnapshotTail() {
    let state = apply(.empty, .snapshot(.init(snapshot: snapshot("discard\u{FEFF}tail"))), max: 7)
    #expect(state.output.text == "\u{FEFF}tail")
    #expect(state.output.retainedBytes == 7)
  }

  @Test func trimsWholeCodePointsFromAPartiallyRetainedChunk() {
    var state = apply(.empty, .snapshot(.init(snapshot: snapshot("é界🙂end"))), max: 12)
    var cursor = TerminalOutput.readUpdate(state.output, cursor: .initial).cursor
    for (data, expected, retained) in [("x", "界🙂endx", 11), ("yz", "🙂endxyz", 10), ("abc", "endxyzabc", 9)] {
      state = apply(state, output(data), max: 12)
      let update = TerminalOutput.readUpdate(state.output, cursor: cursor)
      #expect(update.kind == .append && update.data == data)
      #expect(state.output.text == expected)
      #expect(state.output.retainedBytes == retained)
      cursor = update.cursor
    }
  }

  @Test func deliversAllOutputWhenSeveralEventsArriveBeforeARendererReads() {
    let initial = apply(.empty, .snapshot(.init(snapshot: baseSnapshot)))
    let cursor = TerminalOutput.readUpdate(initial.output, cursor: .initial).cursor
    var state = initial
    for data in [" one", " two", " three"] { state = apply(state, output(data)) }
    let update = TerminalOutput.readUpdate(state.output, cursor: cursor)
    #expect(update.kind == .append && update.data == " one two three")
    #expect(TerminalOutput.readUpdate(state.output, cursor: update.cursor).kind == .none)
  }

  @Test func resetsACursorBeforeAPartiallyTrimmedChunk() {
    let initial = apply(.empty, .snapshot(.init(snapshot: snapshot(""))))
    let stale = TerminalOutput.readUpdate(initial.output, cursor: .initial).cursor
    let first = apply(initial, output("hello"))
    let caughtUp = TerminalOutput.readUpdate(first.output, cursor: stale).cursor
    let state = apply(first, output(" world"), max: 8)
    let caught = TerminalOutput.readUpdate(state.output, cursor: caughtUp)
    #expect(caught.kind == .append && caught.data == " world")
    let late = TerminalOutput.readUpdate(state.output, cursor: stale)
    #expect(late.kind == .reset && late.data == "lo world")
    #expect(state.output.retainedBytes == 8)
  }

  @Test func appendingAtTheByteLimitEncodesOnlyNewOutput() {
    // The TS test spies on TextEncoder; here the observable contract is the retained window.
    var state = apply(.empty, .snapshot(.init(snapshot: snapshot(String(repeating: "x", count: TerminalOutput.defaultMaxBufferBytes)))))
    let data = String(repeating: "y", count: 8192)
    for _ in 0..<100 { state = apply(state, output(data)) }
    #expect(state.output.retainedBytes == TerminalOutput.defaultMaxBufferBytes)
    #expect(state.output.text.hasSuffix(data))
  }

  @Test(arguments: [0, -1]) func discardsOutputWhenTheByteBudgetIsNotPositive(budget: Int) {
    let initial = apply(.empty, .snapshot(.init(snapshot: baseSnapshot)))
    let cursor = TerminalOutput.readUpdate(initial.output, cursor: .initial).cursor
    let data = String(repeating: "x", count: 65_536)
    let discarded = apply(initial, output(data), max: budget)
    #expect(discarded.output.nextOffset == initial.output.nextOffset + data.utf16.count)
    #expect(discarded.output.retainedBytes == 0)
    let update = TerminalOutput.readUpdate(discarded.output, cursor: cursor)
    #expect(update.kind == .reset && update.data == "")
    #expect(apply(initial, output(""), max: budget).output == initial.output)
  }

  @Test func resetsForRepeatedSnapshotsClearAndRestartEvenWhenTextRepeats() {
    var state = apply(.empty, .snapshot(.init(snapshot: baseSnapshot)))
    var cursor = TerminalOutput.readUpdate(state.output, cursor: .initial).cursor
    state = apply(state, .snapshot(.init(snapshot: baseSnapshot)))
    let repeated = TerminalOutput.readUpdate(state.output, cursor: cursor)
    #expect(repeated.kind == .reset && repeated.data == "hello")
    #expect(state.version == 2)
    cursor = repeated.cursor
    state = apply(state, .cleared(.init(threadId: "thread-1", terminalId: "term-1")))
    let cleared = TerminalOutput.readUpdate(state.output, cursor: cursor)
    #expect(cleared.kind == .reset && cleared.data == "")
    state = apply(state, .restarted(.init(threadId: "thread-1", terminalId: "term-1", snapshot: baseSnapshot)))
    let restarted = TerminalOutput.readUpdate(state.output, cursor: cleared.cursor)
    #expect(restarted.kind == .reset && restarted.data == "hello")
    #expect(state.lifecycleVersion == 2)
  }

  @Test func doesNotReuseARendererCursorWhenAFreshAttachHasMatchingCounters() {
    let first = apply(TerminalSessionReducer.nextAttachSeed(), .snapshot(.init(snapshot: baseSnapshot)))
    let cursor = TerminalOutput.readUpdate(first.output, cursor: .initial).cursor
    let next = apply(TerminalSessionReducer.nextAttachSeed(), .snapshot(.init(snapshot: snapshot("other"))))
    #expect(next.output.resetVersion == first.output.resetVersion)
    #expect(next.output.nextOffset == first.output.nextOffset)
    let update = TerminalOutput.readUpdate(next.output, cursor: cursor)
    #expect(update.kind == .reset && update.data == "other")
    #expect(next.lifecycleVersion == 0)
  }

  @Test func keepsAppendingWhileCompactingMetadataForManySmallWrites() {
    var state = apply(.empty, .snapshot(.init(snapshot: snapshot(""))))
    var cursor = TerminalOutput.readUpdate(state.output, cursor: .initial).cursor
    var received = ""
    for _ in 0..<2500 {
      state = apply(state, output("x"))
      let update = TerminalOutput.readUpdate(state.output, cursor: cursor)
      #expect(update.kind == .append)
      received += update.data
      cursor = update.cursor
    }
    #expect(received == String(repeating: "x", count: 2500))
    #expect(state.output.chunks.count < 1024)
    #expect(state.output.text == received)
  }

  @Test func appendsEveryUnreadCharacterAcrossACompactionBoundary() {
    var state = apply(.empty, .snapshot(.init(snapshot: snapshot(""))))
    var cursor = TerminalOutput.readUpdate(state.output, cursor: .initial).cursor
    let writes = (0..<1200).map { ["x", "é", "界", "🙂"][$0 % 4] }
    for (index, data) in writes.enumerated() {
      state = apply(state, output(data))
      if index == 99 { cursor = TerminalOutput.readUpdate(state.output, cursor: cursor).cursor }
    }
    let update = TerminalOutput.readUpdate(state.output, cursor: cursor)
    #expect(update.kind == .append)
    #expect(update.data == writes[100...].joined())
  }
}
