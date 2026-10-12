import Foundation
import Testing
import T3Contracts

@testable import T3Preview

private func object(_ text: String) -> [String: Any] {
  (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

@Suite("Preview stream codec")
struct PreviewStreamCodecTests {
  @Test("client messages carry the TypeScript shapes")
  func inputShapes() throws {
    #expect(PreviewStreamInput.takeControl.encoded() == #"{"type":"takeControl"}"#)
    #expect(PreviewStream.ack == #"{"type":"ack"}"#)

    let mouse = object(PreviewStreamInput.mouse(action: .down, x: 10.5, y: 20, button: .left, buttons: 1, clickCount: 2, modifiers: [.shift, .meta]).encoded())
    #expect(mouse["type"] as? String == "mouse")
    #expect(mouse["action"] as? String == "down")
    #expect(mouse["x"] as? Double == 10.5)
    #expect(mouse["button"] as? String == "left")
    #expect(mouse["buttons"] as? Int == 1)
    #expect(mouse["clickCount"] as? Int == 2)
    #expect(mouse["modifiers"] as? Int == 12)  // Meta 4 + Shift 8

    let key = object(PreviewStreamInput.key(action: .down, key: "Enter", code: "Enter", keyCode: 13, text: "\r", modifiers: []).encoded())
    #expect(key["keyCode"] as? Int == 13)
    #expect(key["text"] as? String == "\r")
    let shortcut = object(PreviewStreamInput.key(action: .up, key: "c", code: "KeyC", keyCode: 67, text: nil, modifiers: .meta).encoded())
    #expect(shortcut["text"] == nil)

    let wheel = object(PreviewStreamInput.wheel(x: 1, y: 2, deltaX: 0, deltaY: -40, modifiers: []).encoded())
    #expect(wheel["deltaY"] as? Double == -40)

    #expect(object(PreviewStreamInput.resize(width: 800, height: 600).encoded())["width"] as? Int == 800)
    #expect(object(PreviewStreamInput.history(delta: -1).encoded())["delta"] as? Int == -1)
    #expect(object(PreviewStreamInput.reload().encoded())["ignoreCache"] == nil)
    #expect(object(PreviewStreamInput.reload(ignoreCache: true).encoded())["ignoreCache"] as? Bool == true)
    #expect(object(PreviewStreamInput.dialog(accept: true, promptText: "hi").encoded())["promptText"] as? String == "hi")
    #expect(object(PreviewStreamInput.dialog(accept: false).encoded())["promptText"] == nil)

    let fill = object(PreviewStreamInput.viewport(.fill).encoded())
    #expect((fill["setting"] as? [String: Any])?["_tag"] as? String == "fill")
    let preset = object(PreviewStreamInput.viewport(PreviewViewports.presets[0].setting).encoded())
    let setting = preset["setting"] as? [String: Any]
    #expect(setting?["_tag"] as? String == "preset")
    #expect(setting?["presetId"] as? String == "iphone-se")
    #expect(setting?["width"] as? Int == 375)

    #expect(PreviewStreamInput.takeControl.needsControl == false)
    #expect(PreviewStreamInput.releaseControl.needsControl)
  }

  @Test("server messages decode, and unknown or malformed ones are dropped")
  func messages() {
    #expect(PreviewStreamMessage.decode(#"{"type":"viewport","width":1280,"height":800}"#) == .viewport(width: 1280, height: 800))
    #expect(
      PreviewStreamMessage.decode(#"{"type":"control","canOperate":true,"controller":"another-viewer","generation":3,"dialog":null}"#)
        == .control(PreviewStreamControl(canOperate: true, controller: .anotherViewer, generation: 3)))
    let withDialog = PreviewStreamMessage.decode(
      #"{"type":"control","canOperate":true,"controller":"you","generation":4,"dialog":{"type":"prompt","message":"Name?","defaultValue":"x"}}"#)
    #expect(withDialog == .control(PreviewStreamControl(canOperate: true, controller: .you, generation: 4, dialog: .init(type: "prompt", message: "Name?", defaultValue: "x"))))
    #expect(PreviewStreamMessage.decode(#"{"type":"probe","x":1,"y":2,"editable":true}"#) == .probe(x: 1, y: 2, editable: true))
    #expect(
      PreviewStreamMessage.decode(#"{"type":"pointer","phase":"click","x":5,"y":6,"sequence":9}"#)
        == .pointer(PreviewStreamPointer(phase: .click, x: 5, y: 6, sequence: 9)))
    #expect(
      PreviewStreamMessage.decode(#"{"type":"download","id":"d1","fileName":"a.pdf","sizeBytes":1024}"#)
        == .download(PreviewStreamDownloadOffer(id: "d1", fileName: "a.pdf", sizeBytes: 1024)))
    #expect(
      PreviewStreamMessage.decode(#"{"type":"fileChooser","id":"c1","multiple":false,"accept":"image/*"}"#)
        == .fileChooser(PreviewStreamFileChooser(id: "c1", multiple: false, accept: "image/*")))
    #expect(PreviewStreamMessage.decode(#"{"type":"fileChooserClosed","id":"c1"}"#) == .fileChooserClosed(id: "c1"))
    #expect(PreviewStreamMessage.decode(#"{"type":"popup","tabId":"tab_2"}"#) == .popup(tabId: "tab_2"))
    #expect(PreviewStreamMessage.decode(#"{"type":"clipboard","text":"copied"}"#) == .clipboard("copied"))
    // A boolean is not a number, and a number is not a boolean.
    #expect(PreviewStreamMessage.decode(#"{"type":"viewport","width":true,"height":1}"#) == nil)
    #expect(PreviewStreamMessage.decode(#"{"type":"probe","x":1,"y":2,"editable":1}"#) == nil)
    #expect(PreviewStreamMessage.decode(#"{"type":"control","canOperate":true,"controller":"nobody","generation":1,"dialog":null}"#) == nil)
    #expect(PreviewStreamMessage.decode(#"{"type":"something-new"}"#) == nil)
    #expect(PreviewStreamMessage.decode("not json") == nil)
  }

  @Test("the socket URL carries the viewer's size and the ticket, percent-encoded")
  func urls() {
    let base = URL(string: "https://box.example:3773")!
    let socket = PreviewStream.socketURL(httpBase: base, threadId: "t 1", tabId: "tab_1", maxWidth: 1600, maxHeight: 0, ticket: "a+b/c=")
    #expect(socket.scheme == "wss")
    #expect(socket.path == "/api/preview-stream/ws")
    let query = socket.query(percentEncoded: true) ?? ""
    #expect(query == "threadId=t%201&tabId=tab_1&maxWidth=1600&maxHeight=1&wsTicket=a%2Bb%2Fc%3D")
    #expect(PreviewStream.socketURL(httpBase: URL(string: "http://localhost:1")!, threadId: "t", tabId: "x", maxWidth: 1, maxHeight: 1, interactive: false, ticket: nil).absoluteString
      == "ws://localhost:1/api/preview-stream/ws?threadId=t&tabId=x&maxWidth=1&maxHeight=1&interactive=false")
    #expect(PreviewStream.downloadURL(httpBase: base, threadId: "t", tabId: "x", id: "d", ticket: "k").absoluteString == "https://box.example:3773/api/preview-stream/download?threadId=t&tabId=x&id=d&wsTicket=k")
    #expect(PreviewStream.uploadURL(httpBase: base, threadId: "t", tabId: "x", chooser: "c", ticket: nil).absoluteString == "https://box.example:3773/api/preview-stream/upload?threadId=t&tabId=x&chooser=c")
  }

  @Test("host setup decodes from the close reason")
  func hostSetup() {
    #expect(PreviewStreamHostSetup.decode(reason: #"{"need":"libraries","command":"sudo npx t3 browser setup"}"#) == PreviewStreamHostSetup(need: .libraries, command: "sudo npx t3 browser setup"))
    #expect(PreviewStreamHostSetup.decode(reason: "tab closed") == nil)
    #expect(PreviewStreamHostSetup.decode(reason: nil) == nil)
  }

  @Test("control labels")
  func labels() {
    #expect(PreviewStreamControl.label(nil) == "Connecting\u{2026}")
    #expect(PreviewStreamControl.label(PreviewStreamControl(canOperate: false, controller: .you, generation: 1)) == "Read-only")
    #expect(PreviewStreamControl.label(PreviewStreamControl(canOperate: true, controller: .agent, generation: 1)) == "Agent has control")
  }
}

@Suite("Preview geometry and keys")
struct PreviewGeometryTests {
  @Test("a frame is letterboxed and points map back to page CSS pixels")
  func mapping() throws {
    // A 800x400 page streamed as 1600x800 into a 400x400 view: 400x200, centred vertically.
    let geometry = PreviewGeometry(view: CGSize(width: 400, height: 400), frame: CGSize(width: 1600, height: 800), page: CGSize(width: 800, height: 400))
    #expect(geometry.fitted == CGRect(x: 0, y: 100, width: 400, height: 200))
    let center = try #require(geometry.pagePoint(CGPoint(x: 200, y: 200)))
    #expect(center.point == CGPoint(x: 400, y: 200))
    #expect(center.scale == 2)
    #expect(geometry.pagePoint(CGPoint(x: 200, y: 50)) == nil)  // in the letterbox
    #expect(try #require(geometry.pagePoint(CGPoint(x: 200, y: 50), clamp: true)).point == CGPoint(x: 400, y: 0))
    #expect(geometry.viewPoint(CGPoint(x: 400, y: 200)) == CGPoint(x: 200, y: 200))
    #expect(PreviewGeometry(view: .zero, frame: .zero, page: .zero).pagePoint(.zero) == nil)
  }

  @Test("the requested frame cap is capped at 2x and only ever grows")
  func cap() {
    #expect(PreviewFrameCap.request(view: CGSize(width: 500, height: 300), backingScale: 3) == (1000, 600))
    #expect(PreviewFrameCap.outgrown(cap: nil, wanted: (1, 1)))
    #expect(!PreviewFrameCap.outgrown(cap: (1000, 600), wanted: (900, 600)))
    #expect(PreviewFrameCap.outgrown(cap: (1000, 600), wanted: (1001, 600)))
  }

  @Test("macOS key events map to what the page expects")
  func keys() {
    let enter = PreviewKeys.map(keyCode: 0x24, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: [])
    #expect(enter == PreviewKeys.Mapped(key: "Enter", code: "Enter", keyCode: 13, text: "\r"))
    let letter = PreviewKeys.map(keyCode: 0x00, characters: "A", charactersIgnoringModifiers: "A", modifiers: .shift)
    #expect(letter == PreviewKeys.Mapped(key: "A", code: "KeyA", keyCode: 65, text: "A"))
    // Cmd+C is a shortcut: no text. Ctrl+A arrives as a control character; the page wants the letter.
    #expect(PreviewKeys.map(keyCode: 0x08, characters: "c", charactersIgnoringModifiers: "c", modifiers: .meta)?.text == nil)
    #expect(PreviewKeys.map(keyCode: 0x00, characters: "\u{01}", charactersIgnoringModifiers: "a", modifiers: .control)?.key == "a")
    #expect(PreviewKeys.map(keyCode: 0x7B, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", modifiers: [])?.key == "ArrowLeft")
    #expect(PreviewKeys.map(keyCode: 0x33, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", modifiers: [])?.keyCode == 8)
    // Diacritics typed with Option keep their character; a dead key has none.
    #expect(PreviewKeys.map(keyCode: 0x00, characters: "\u{0105}", charactersIgnoringModifiers: "a", modifiers: .alt)?.text == "\u{0105}")
    #expect(PreviewKeys.map(keyCode: 0x0E, characters: "", charactersIgnoringModifiers: "e", modifiers: .alt) == nil)
    #expect(PreviewKeys.map(keyCode: 0x38, characters: "", charactersIgnoringModifiers: "", modifiers: .shift) == nil)
  }
}

@Suite("Preview addresses")
struct PreviewAddressTests {
  @Test("typed text becomes an address or a search")
  func resolve() throws {
    #expect(try PreviewAddress.resolve("localhost:5173") == "http://localhost:5173/")
    #expect(try PreviewAddress.resolve("example.com/a?b=1") == "https://example.com/a?b=1")
    #expect(try PreviewAddress.resolve("http://127.0.0.1:8000") == "http://127.0.0.1:8000/")
    #expect(try PreviewAddress.resolve("swift concurrency") == "https://duckduckgo.com/?q=swift%20concurrency")
    #expect(try PreviewAddress.resolve("devbox:8080") == "https://devbox:8080/")
    #expect(throws: PreviewAddress.Failure.self) { try PreviewAddress.resolve("mailto:a@b.c") }
    #expect(throws: PreviewAddress.Failure.self) { try PreviewAddress.resolve("  ") }
  }
}

@Suite("Preview tabs")
struct PreviewTabsTests {
  private func snapshot(_ tab: String, _ url: String, runtime: PreviewRuntime? = .server) -> PreviewSessionSnapshot {
    PreviewSessionSnapshot(
      threadId: "th", tabId: tab, navStatus: .success(PreviewNavStatusSuccess(url: url, title: "")), canGoBack: false, canGoForward: false,
      runtime: runtime, updatedAt: "2026-01-01T00:00:00.000Z")
  }
  private func opened(_ tab: String, revision: Int, epoch: String = "e1") -> PreviewEvent {
    .opened(PreviewEventOpened(threadId: "th", tabId: tab, createdAt: "2026-01-01T00:00:00.000Z", serverEpoch: epoch, revision: revision, snapshot: snapshot(tab, "http://x/\(tab)")))
  }
  private func closed(_ tab: String, revision: Int) -> PreviewEvent {
    .closed(PreviewEventClosed(threadId: "th", tabId: tab, createdAt: "2026-01-01T00:00:00.000Z", serverEpoch: "e1", revision: revision))
  }

  @Test("a list is authoritative for its revision and later events apply on top")
  func listThenEvents() {
    var state = PreviewTabsState()
    state.apply(list: PreviewListResult(sessions: [snapshot("a", "http://x/a"), snapshot("d", "http://x/d", runtime: .desktop)], serverEpoch: "e1", revision: 5))
    #expect(state.serverTabs.map(\.tabId) == ["a"])
    #expect(state.apply(event: opened("b", revision: 5)) == .ignored)  // not newer than the list
    #expect(state.apply(event: opened("b", revision: 6)) == .applied)
    #expect(state.apply(event: closed("a", revision: 7)) == .applied)
    #expect(state.serverTabs.map(\.tabId) == ["b"])
    #expect(state.apply(event: closed("b", revision: 7)) == .ignored)
    // A stale list (older revision) does not roll the state back.
    state.apply(list: PreviewListResult(sessions: [snapshot("a", "http://x/a")], serverEpoch: "e1", revision: 4))
    #expect(state.serverTabs.map(\.tabId) == ["b"])
  }

  @Test("events that arrive before the list are replayed on it; a restarted server needs a fresh list")
  func replayAndEpoch() {
    var state = PreviewTabsState()
    #expect(state.apply(event: opened("late", revision: 9)) == .applied)
    #expect(state.sessions.isEmpty)
    state.apply(list: PreviewListResult(sessions: [snapshot("a", "http://x/a")], serverEpoch: "e1", revision: 8))
    #expect(state.sessions.map(\.tabId) == ["a", "late"])
    #expect(state.apply(event: opened("x", revision: 1, epoch: "e2")) == .needsRefresh)
    state.apply(list: PreviewListResult(sessions: [], serverEpoch: "e2", revision: 1))
    #expect(state.sessions.isEmpty)
  }

  @Test("a failed load keeps the tab's place and shows the failure")
  func failed() {
    var state = PreviewTabsState()
    state.apply(list: PreviewListResult(sessions: [snapshot("a", "http://x/a")], serverEpoch: "e1", revision: 1))
    state.apply(event: .failed(PreviewEventFailed(threadId: "th", tabId: "a", createdAt: "2026-02-01T00:00:00.000Z", serverEpoch: "e1", revision: 2, url: "http://x/a", title: "", code: -102, description: "refused")))
    #expect(state.sessions[0].failure?.description == "refused")
    #expect(state.sessions[0].displayTitle == "x")
  }

  @Test("zoom steps along Chrome's ladder")
  func zoom() {
    #expect(PreviewViewports.zoom(from: 1, step: 1) == 1.1)
    #expect(PreviewViewports.zoom(from: 0.25, step: -1) == 0.25)
    #expect(PreviewViewports.zoom(from: 5, step: 1) == 5)
    #expect(PreviewViewports.rotated(.fill) == nil)
    if case .preset(let rotated)? = PreviewViewports.rotated(PreviewViewports.presets[0].setting) { #expect(rotated.width == 667 && rotated.height == 375) } else { Issue.record("not a preset") }
  }
}
