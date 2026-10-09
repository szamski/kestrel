import AppKit
import Synchronization
import Testing

@testable import T3Terminal

/// Hosts a surface in an offscreen window so Ghostty gets a real layer-backed view and layout.
@MainActor
func makeHostedSurface(width: CGFloat = 800, height: CGFloat = 400, theme: TerminalTheme = .dark) -> (TerminalSurfaceView, NSWindow) {
  let view = TerminalSurfaceView(theme: theme)
  let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
  window.contentView = view
  view.frame = NSRect(x: 0, y: 0, width: width, height: height)
  window.orderBack(nil)
  view.layoutSubtreeIfNeeded()
  return (view, window)
}

/// Ghostty parses on its IO thread; poll the grid until `done` (bounded; the assertion itself never sleeps).
@MainActor
func settle(_ view: TerminalSurfaceView, timeout: Duration = .seconds(5), until done: (String) -> Bool) async -> String {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  var text = view.viewportText()
  while !done(text), clock.now < deadline {
    try? await clock.sleep(for: .milliseconds(10))
    text = view.viewportText()
  }
  return text
}

func rows(_ grid: String) -> [String] {
  grid.split(separator: "\n", omittingEmptySubsequences: false).map { row in
    var line = String(row)
    while line.last == " " { line.removeLast() }
    return line
  }
}

/// Collects what the terminal writes back to the PTY.
final class InputCollector: Sendable {
  private let storage = Mutex("")
  var text: String { storage.withLock { $0 } }
  func append(_ data: String) { storage.withLock { $0 += data } }
}

@MainActor
@Suite(.serialized) struct TerminalSurfaceTests {
  @Test func laysOutAGridAndReportsItsSize() async throws {
    let (view, _) = makeHostedSurface()
    let grid = try #require(view.gridSize)
    #expect(grid.cols > 40 && grid.rows > 10)
  }

  @Test func rendersColorsAndCursorMovesIntoTheGrid() async throws {
    let (view, _) = makeHostedSurface()
    view.feed("\u{1B}[31mred\u{1B}[0m plain\r\nsecond\u{1B}[3Cline\r\n\u{1B}[3;1Hrow3 \u{1B}[2Aup")
    let text = await settle(view) { $0.contains("up") }
    let lines = rows(text)
    #expect(lines[0] == "red pupin")
    #expect(lines[1] == "second   line")
    #expect(lines[2] == "row3")
  }

  @Test func alternateScreenHidesAndRestoresTheMainScreen() async throws {
    let (view, _) = makeHostedSurface()
    view.feed("main screen")
    _ = await settle(view) { $0.contains("main screen") }
    view.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[HTUI frame")
    let alt = await settle(view) { $0.contains("TUI frame") }
    #expect(!alt.contains("main screen"))
    view.feed("\u{1B}[?1049l")
    let main = await settle(view) { $0.contains("main screen") }
    #expect(!main.contains("TUI frame"))
  }

  @Test func replayStartsFromACleanTerminal() async throws {
    let (view, _) = makeHostedSurface()
    view.feed("stale output\r\n")
    _ = await settle(view) { $0.contains("stale") }
    view.replay("fresh history\r\n")
    let text = await settle(view) { $0.contains("fresh history") }
    #expect(!text.contains("stale"))
  }

  @Test func terminalRepliesReachTheInputCallbackButNotDuringReplay() async throws {
    let (view, _) = makeHostedSurface()
    let sent = InputCollector()
    view.onInput = { sent.append($0) }
    // A live device-status query is answered...
    view.feed("\u{1B}[6n")
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !sent.text.contains("R"), clock.now < deadline { try? await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text.hasPrefix("\u{1B}["))
    #expect(sent.text.hasSuffix("R"))
    let before = sent.text
    // ...but the same query inside replayed history must not provoke a reply at the shell.
    view.replay("history with query \u{1B}[6n and \u{1B}[c done\r\n")
    _ = await settle(view) { $0.contains("done") }
    while view.isReplayDraining, clock.now < deadline { try? await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text == before)  // nothing from the replayed queries
    view.feed("\u{1B}[6n")  // proves the callback is attached again after the replay
    let again = clock.now + .seconds(5)
    while sent.text == before, clock.now < again { try? await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text.count > before.count)
    #expect(sent.text.components(separatedBy: "R").count == before.components(separatedBy: "R").count + 1)
  }
}
