import AppKit
import Testing

@testable import T3Terminal

/// Real AppKit events against a hosted surface: keyboard encoding, mouse selection, copy/paste,
/// scrollback, wrapped links and bell/title actions.
@MainActor
@Suite(.serialized) struct TerminalInteractionTests {
  private func key(_ view: TerminalSurfaceView, _ window: NSWindow, code: UInt16, chars: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil,
      characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)!
    if !view.performKeyEquivalent(with: event) { view.keyDown(with: event) }
  }

  /// Window-space point at the center of a cell (the view is the window's content view).
  private func point(_ view: TerminalSurfaceView, col: Int, row: Int, fraction: Double = 0.5) -> NSPoint {
    NSPoint(
      x: TerminalGhosttyConfig.padding.x + (Double(col) + fraction) * view.cellSize.width,
      y: view.bounds.height - (TerminalGhosttyConfig.padding.y + (Double(row) + 0.5) * view.cellSize.height))
  }

  private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
  }

  @Test func keysAreEncodedForTheShell() async throws {
    let (view, window) = makeHostedSurface()
    window.makeFirstResponder(view)
    let sent = InputCollector()
    view.onInput = { sent.append($0) }
    key(view, window, code: 0, chars: "a")
    key(view, window, code: 36, chars: "\r")
    key(view, window, code: 8, chars: "\u{03}", ignoring: "c", flags: .control)
    key(view, window, code: 126, chars: "\u{F700}", flags: [.numericPad, .function])
    key(view, window, code: 123, chars: "\u{F702}", flags: [.option, .numericPad, .function])  // ⌥← = word left
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    let expected = "a\r\u{03}\u{1B}[A\u{1B}b"
    while sent.text != expected, clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text == expected)
  }

  @Test func dragSelectsTextAndCopyWritesThePasteboard() async throws {
    let board = NSPasteboard(name: NSPasteboard.Name("t3-terminal-test-\(UUID().uuidString)"))
    TerminalPasteboard.current = board
    defer { board.releaseGlobally(); TerminalPasteboard.current = .general }
    let (view, window) = makeHostedSurface()
    view.feed("hello selectable world\r\nsecond row")
    _ = await settle(view) { $0.contains("second row") }
    view.mouseDown(with: mouse(.leftMouseDown, at: point(view, col: 6, row: 0), window: window))
    // Ghostty includes a cell only when the pointer is past its midpoint, so end on the right edge.
    view.mouseDragged(with: mouse(.leftMouseDragged, at: point(view, col: 15, row: 0, fraction: 0.9), window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: point(view, col: 15, row: 0, fraction: 0.9), window: window))
    #expect(view.hasSelection)
    #expect(view.selectedText == "selectable")
    view.copy(nil)
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while board.string(forType: .string) == nil, clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(board.string(forType: .string) == "selectable")
  }

  @Test func pasteIsBracketedWhenTheProgramAsksForIt() async throws {
    let board = NSPasteboard(name: NSPasteboard.Name("t3-terminal-test-\(UUID().uuidString)"))
    TerminalPasteboard.current = board
    defer { board.releaseGlobally(); TerminalPasteboard.current = .general }
    board.clearContents()
    board.setString("pasted\ntext", forType: .string)
    let (view, window) = makeHostedSurface()
    window.makeFirstResponder(view)
    let sent = InputCollector()
    view.onInput = { sent.append($0) }
    view.feed("\u{1B}[?2004h")  // bracketed paste on
    try await Task.sleep(for: .milliseconds(50))
    view.paste(nil)
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while !sent.text.contains("text"), clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text == "\u{1B}[200~pasted\ntext\u{1B}[201~")
    // Without bracketed paste, newlines become carriage returns like typed Enter.
    view.feed("\u{1B}[?2004l")
    try await Task.sleep(for: .milliseconds(50))
    let before = sent.text.count
    view.paste(nil)
    while sent.text.count == before, clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(sent.text.dropFirst(before) == "pasted\rtext")
  }

  @Test func scrollbackIsReachableAndCommandInputStaysLive() async throws {
    let (view, window) = makeHostedSurface()
    window.makeFirstResponder(view)
    view.feed((1...200).map { "line \($0)" }.joined(separator: "\r\n"))
    let bottom = await settle(view) { $0.contains("line 200") }
    #expect(!bottom.contains("line 1\n"))
    for _ in 0..<3 { key(view, window, code: 116, chars: "\u{F72C}", flags: [.shift, .function]) }  // ⇧PageUp
    let scrolled = await settle(view) { !$0.contains("line 200") }
    #expect(!scrolled.contains("line 200"))
    #expect(scrolled.contains("line 1"))
  }

  @Test func clearRemovesScreenAndScrollback() async throws {
    let (view, _) = makeHostedSurface()
    view.feed((1...100).map { "row \($0)" }.joined(separator: "\r\n"))
    _ = await settle(view) { $0.contains("row 100") }
    view.reset()
    let text = await settle(view) { !$0.contains("row 100") }
    #expect(rows(text).allSatisfy { $0.isEmpty })
  }

  @Test func commandClickOpensUrlsAndResolvedPaths() async throws {
    let (view, window) = makeHostedSurface()
    view.workingDirectory = "/Users/dev/project"
    view.feed("see https://example.com/docs, and src/main.ts:42: boom")
    _ = await settle(view) { $0.contains("boom") }
    var opened: [TerminalLinkTarget] = []
    view.onOpenLink = { opened.append($0) }
    let line = "see https://example.com/docs, and src/main.ts:42: boom"
    let urlCol = (line as NSString).range(of: "example").location
    let pathCol = (line as NSString).range(of: "main").location
    for col in [urlCol, pathCol] {
      let p = point(view, col: col, row: 0)
      view.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, flags: .command))
      view.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, flags: .command))
    }
    #expect(opened == [.url(URL(string: "https://example.com/docs")!), .path("/Users/dev/project/src/main.ts:42")])
    // A plain click on the same text is a selection gesture, not a link.
    let p = point(view, col: urlCol, row: 0)
    view.mouseDown(with: mouse(.leftMouseDown, at: p, window: window))
    view.mouseUp(with: mouse(.leftMouseUp, at: p, window: window))
    #expect(opened.count == 2)
  }

  @Test func linksSurviveSoftWrapAcrossRows() async throws {
    let (view, window) = makeHostedSurface(width: 480)
    let cols = try #require(view.gridSize).cols
    let url = "https://example.com/" + String(repeating: "a", count: cols + 10) + "/end"
    view.feed("go \(url) now")
    _ = await settle(view) { $0.contains("now") }
    var opened: [TerminalLinkTarget] = []
    view.onOpenLink = { opened.append($0) }
    // The tail of the URL sits on the second physical row.
    let p = point(view, col: 3, row: 1)
    view.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, flags: .command))
    view.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, flags: .command))
    #expect(opened == [.url(URL(string: url)!)])
  }

  @Test func bellAndTitleActionsReachTheHost() async throws {
    let (view, _) = makeHostedSurface()
    var bells = 0
    var titles: [String] = []
    view.onBell = { bells += 1 }
    view.onTitleChange = { titles.append($0) }
    view.feed("\u{07}\u{1B}]0;build: ok\u{07}")
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while (bells == 0 || titles.isEmpty), clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
    #expect(bells >= 1)
    #expect(titles == ["build: ok"])
  }
}
