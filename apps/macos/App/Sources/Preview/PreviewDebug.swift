#if DEBUG
import AppKit
import T3ClientRuntime
import T3Preview

/// Driver steps of the browser panel (`-T3Driver pv:<step>[:<arg>]`), all in-process: input reaches the page view through its own
/// event methods with events built here, never through the system.
/// - `pv:open` shows the Preview tab of the selected thread; `pv:status` logs the model; `pv:wait[:seconds]` waits for a streaming page.
/// - `pv:new:<url>` opens a server tab (an empty `pv:new` opens a blank one); `pv:closetab` closes the tab in view.
/// - `pv:control` takes control and waits for it; `pv:release`.
/// - `pv:scroll:<dy>` sends a wheel message; `pv:click:<x>:<y>` (page CSS pixels), `pv:type:<text>`, `pv:key:<mac keyCode>` (a click and typing through `NSEvent`s).
/// - `pv:shot:<name>` captures the window and the page view; `pv:address:<text>` submits the address bar's text.
extension DebugDriver {
  func runPreviewStep(_ arg: String) async {
    guard let key = app.selection else { say("pv: no selected thread"); return }
    let bits = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let name = bits.first ?? "", rest = bits.count > 1 ? bits[1] : ""
    let model = PreviewStore.shared.model(for: key, app: app)
    switch name {
    case "open":
      // A window behind other apps is occluded, and an occluded browser pauses its stream by design.
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
      RightPanelStore.live?.open(.preview, in: key)
      await sleep(1.0)
    case "status": say("pv \(model.debugSummary)")
    case "wait":
      let limit = Double(rest) ?? 60
      var waited = 0.0
      while model.phase != .streaming, waited < limit { await sleep(0.5); waited += 0.5 }
      say("pv wait \(waited)s \(model.debugSummary)")
    case "new": model.openTab(rest.isEmpty ? nil : rest); await sleep(1.0)
    case "closetab": if let tab = model.selectedTab { model.closeTab(tab.tabId) }; await sleep(0.5)
    case "control":
      model.takeControl()
      for _ in 0..<40 where !model.controlsPage { await sleep(0.25) }
      say("pv control=\(model.controlsPage) \(PreviewStreamControl.label(model.control))")
    case "release": model.releaseControl(); await sleep(0.5)
    case "back": model.back(); await sleep(1.0)
    case "forward": model.forward(); await sleep(1.0)
    case "reload": model.reload(); await sleep(1.0)
    case "zoom": model.adjust(zoomStep: Int(rest) ?? 1); await sleep(1.0)
    case "viewport":  // `pv:viewport:fill` or a preset id such as `iphone-12-pro`
      if rest == "fill" { model.setViewport(.fill) } else if let preset = PreviewViewports.presets.first(where: { $0.id == rest }) { model.setViewport(preset.setting) }
      await sleep(1.5)
    case "dark": model.adjust(colorScheme: .dark); await sleep(1.0)
    case "address": model.addressDraft = rest; model.submitAddress(); await sleep(0.5)
    case "click":
      let p = rest.split(separator: ":").compactMap { Double($0) }
      guard p.count == 2 else { return say("pv click: x:y") }
      click(model.surface, page: CGPoint(x: p[0], y: p[1]))
      await sleep(0.5)
    case "type":
      for character in rest {
        press(model.surface, String(character))
        await sleep(0.05)
      }
      await sleep(0.3)
    case "scroll":  // `pv:scroll:<css pixels>`: a wheel message over the middle of the page (the server's input path, not AppKit's)
      let page = model.surface.pageSize
      model.surface(send: .wheel(x: page.width / 2, y: page.height / 2, deltaX: 0, deltaY: Double(rest) ?? 300, modifiers: []))
      await sleep(0.8)
    case "key":
      if let code = UInt16(rest) { press(model.surface, nil, keyCode: code) }
      await sleep(0.3)
    case "shot":
      capture(window, name: rest)
      captureView(model.surface, name: rest + "-page")
    default: say("pv: unknown step \(arg)")
    }
  }

  private func click(_ surface: PreviewSurfaceView, page: CGPoint) {
    guard let window = surface.window else { return say("pv click: no window") }
    let geometry = PreviewGeometry(view: surface.bounds.size, frame: surface.frameSize, page: surface.pageSize)
    guard let viewPoint = geometry.viewPoint(page) else { return say("pv click: no frame yet") }
    let location = surface.convert(viewPoint, to: nil)
    window.makeFirstResponder(surface)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
      if type == .leftMouseDown { surface.mouseDown(with: event) } else { surface.mouseUp(with: event) }
    }
    say("pv click page=\(page) view=\(viewPoint)")
  }

  /// Key codes of the letters and digits `pv:type` can press; anything else is typed as text.
  private static let letterKeyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
    "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
  ]

  private func press(_ surface: PreviewSurfaceView, _ text: String?, keyCode: UInt16? = nil) {
    guard let window = surface.window else { return }
    let code = keyCode ?? text?.first.flatMap { Self.letterKeyCodes[Character($0.lowercased())] }
    guard let code else { return say("pv type: no key for \(text ?? "?")") }
    let characters = text ?? (code == 36 ? "\r" : "")
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
      if type == .keyDown { surface.keyDown(with: event) } else { surface.keyUp(with: event) }
    }
  }
}
#endif
