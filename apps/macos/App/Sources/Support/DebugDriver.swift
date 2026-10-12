#if DEBUG
import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Debug-only automation for verification runs (screen recording may be denied, so the app
/// captures its own windows). Enabled by `-T3Driver <step,step,...>` and `-T3OutDir <dir>`; steps are
/// documented where they are handled. Never ships: the whole file is `#if DEBUG`.
@MainActor
final class DebugDriver {
  private let app: AppModel
  private let out: URL
  private var log: FileHandle?

  static func startIfRequested(_ app: AppModel) {
    let defaults = UserDefaults.standard
    guard let steps = defaults.string(forKey: "T3Driver"), let dir = defaults.string(forKey: "T3OutDir") else { return }
    let driver = DebugDriver(app: app, out: URL(fileURLWithPath: dir))
    Task { await driver.run(steps.split(separator: ",").map(String.init)) }
  }

  init(app: AppModel, out: URL) {
    self.app = app
    self.out = out
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: out.appending(path: "driver.log").path, contents: nil)
    log = try? FileHandle(forWritingTo: out.appending(path: "driver.log"))
  }

  private func say(_ text: String) { log?.write(Data((text + "\n").utf8)) }

  private var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.title.isEmpty == false || $0.isMainWindow } ?? NSApp.windows.first { $0.isVisible } }

  private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

  func run(_ steps: [String], quick: Bool = false) async {
    if !quick {
      // Wait for the sidebar to have rows.
      for _ in 0..<200 where app.runtime.sidebar.isEmpty { await sleep(0.1) }
      await sleep(1.0)
      say("rows=\(app.runtime.sidebar.rows.count) windows=\(NSApp.windows.map { "\($0.windowNumber):\(type(of: $0))" })")
    }
    for step in steps {
      let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
      let arg = parts.count > 1 ? parts[1] : ""
      say("step \(step)")
      switch parts[0] {
      case "dump": dump()
      case "select": await select(arg)
      case "loadall": await loadAll()
      case "wait": await sleep(Double(arg) ?? 1)
      case "light": NSApp.appearance = NSAppearance(named: .aqua); await sleep(0.6)
      case "dark": NSApp.appearance = NSAppearance(named: .darkAqua); await sleep(0.6)
      case "shot": capture(window, name: arg)
      case "shotv": captureViews(window, name: arg)
      case "shotsheet": captureViews(window?.attachedSheet, name: arg)
      case "shotsb":
        let table = findSidebarTable(in: window?.contentView)
        say("sidebar table \(String(describing: table.map { type(of: $0) })) rows=\(table?.numberOfRows ?? -1) frame=\(String(describing: table?.frame))")
        captureView(table?.enclosingScrollView ?? table, name: arg)
      case "sheet": await sheet(arg)
      case "menu": await contextMenu(arg)
      case "top": scrollTimeline(top: true); await sleep(0.8)
      case "bottom": scrollTimeline(top: false); await sleep(0.8)
      case "groups": say(app.runtime.projectGroups.map { "\($0.label) [\($0.representative.project.workspaceRoot)]" }.joined(separator: " | "))
      case "bench": await bench(arg)
      case "survey": let r = arg.split(separator: "-").compactMap { Int($0) }; await survey(r.count == 2 ? r[0]..<r[1] : 0..<(r.first ?? 12))
      case "newthread":  // `newthread:<project label>`: opens the draft composer of that project
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let group = app.runtime.projectGroups.first(where: { $0.label == arg }) { app.startNewThread(in: group) } else { say("no project \(arg)") }
        await sleep(1.0)
      case "providers":  // per environment: the provider snapshots the composer catalog is built from
        for (id, projection) in app.runtime.serverConfigs {
          let label = app.environmentLabel(id)
          say("providers \(label) source=\(projection.source) cwd=\(projection.config.cwd) count=\(projection.config.providers.count)")
          for p in projection.config.providers {
            say("  \(p.instanceId.rawValue) driver=\(p.driver.rawValue) enabled=\(p.enabled) installed=\(p.installed) status=\(p.status.rawValue) availability=\(String(describing: p.availability)) auth=\(p.auth.status.rawValue) models=\(p.models.count)")
          }
        }
      case "envs": for e in app.runtime.environments { say("env \(e.label) enabled=\(e.enabled) phase=\(e.connection.phase) stage=\(String(describing: e.connection.stage)) failure=\(String(describing: e.connection.lastFailure))") }
      case "panel":  // `panel:files`, `panel:diff`, `panel:file:<path>[:line]`, `panel:goto`, `panel:search`
        if let key = app.selection, let store = RightPanelStore.live {
          let bits = arg.split(separator: ":").map(String.init)
          switch bits.first {
          case "files": store.openFiles(in: key)
          case "diff": store.open(.diff, in: key)
          case "worktree": store.open(.diff, in: key); store.selectScope(.workingTree, in: key)
          case "file": store.openFile(bits[1], line: bits.count > 2 ? Int(bits[2]) : nil, in: key)
          case "goto": store.goToFile(in: key)
          case "search": store.searchContents(in: key)
          default: say("unknown panel \(arg)")
          }
        } else { say("panel: no selected thread") }
        await sleep(1.0)
      case "mkthread":  // `mkthread:<project label>`: a titled thread in that project, with any known thread's model, selected
        let model = app.runtime.sidebar.rows.first?.thread.shell.modelSelection
        if let group = app.runtime.projectGroups.first(where: { $0.label == arg }), let model {
          do {
            let project = group.representative
            let id = try await app.runtime.createThread(environmentId: project.environmentId, projectId: project.projectId, title: "[files] scratch", modelSelection: model)
            app.selection = ScopedThreadKey(environmentId: project.environmentId, threadId: id)
            for _ in 0..<100 where app.detail?.thread == nil { await sleep(0.1) }
          } catch { say("mkthread failed: \(AppModel.describe(error))") }
        } else { say("mkthread: no project or model for \(arg)") }
      case "mkproject":  // `mkproject:<title>:<path>`: adds that directory as a project of the first connected environment
        let bits = arg.split(separator: ":", maxSplits: 1).map(String.init)
        if bits.count == 2, let entry = app.runtime.environments.first(where: { $0.connection.phase == .connected }), let env = await app.runtime.runtime(for: entry.environmentId) {
          let meta = CommandMeta.fresh()
          do {
            _ = try await env.dispatch(.projectCreate(V1.ProjectCreateCommand(commandId: meta.commandId, projectId: ProjectId(rawValue: UUID().uuidString.lowercased()), title: bits[0], workspaceRoot: bits[1], createdAt: meta.createdAt)))
            await sleep(1.5)
          } catch { say("mkproject failed: \(error)") }
        } else { say("mkproject: no connected environment or bad arg") }
      case "proto": await protocolStatus()
      case "send": await sendMessage(arg)
      case "scratch": await scratch()
      case "scratchops": await scratchOps()
      case "scratchclean": await scratchClean()
      case "unread": await markUnread(Int(arg) ?? 2)
      case "sbrender": renderSidebar(name: arg)
      case "fr": say("firstResponder=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") key=\(window?.isKeyWindow ?? false) active=\(NSApp.isActive)")
      case "rename":
        if let key = app.selection { do { try await app.runtime.renameThread(key, title: arg) } catch { say("rename failed: \(AppModel.describe(error))") } }
      case "deletethread":
        // Removes the selected thread only when its title matches (cleanup of threads this driver created).
        if let key = app.selection, app.runtime.threadShell(key)?.shell.title == arg {
          app.selection = nil
          do { try await app.runtime.deleteThread(key); say("deleted \(arg)") } catch { say("delete failed: \(AppModel.describe(error))") }
        } else { say("deletethread: selection does not match \(arg)") }
      case "watch": await watch()
      case "typein": await typeIn(arg)
      case "key": await key(arg)
      case "clickat": await clickAt(arg)
      case "clickscreen": await clickScreen(arg)
      case "paste": paste(arg)
      case "send": say("action \(arg): \(NSApp.sendAction(Selector(arg), to: nil, from: nil))")
      case "archivedcheck": await archivedCheck()  // creates, archives, lists, unarchives and deletes scratch threads; leaves two archived for a screenshot
      case "archivedclean": await archivedClean()
      case "settings":  // opens the Settings window (on the page of `-T3SettingsPage`); `shotsettings:<name>` captures it
        NSApp.activate(ignoringOtherApps: true)
        say("showSettingsWindow: \(NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil))")
        await sleep(2)
        // SwiftUI answers `showSettingsWindow:` only from a key window; the app menu's own "Settings…" item always works.
        if !NSApp.windows.contains(where: { SettingsPage.allCases.map(\.title).contains($0.title) }),
          let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") })
        {
          menu.performActionForItem(at: index)
          await sleep(2)
        }
      case "shotsettings":
        let pages = SettingsPage.allCases.map(\.title)
        if let settings = NSApp.windows.first(where: { $0.isVisible && pages.contains($0.title) }) {
          settings.setContentSize(NSSize(width: 980, height: 760))
          await sleep(1.5)
          capture(settings, name: arg)
        } else { say("no settings window; windows=\(NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")|vis=\($0.isVisible)|\(type(of: $0))" })") }
      case "quit": RunLoop.main.perform { NSApp.terminate(nil) }; await sleep(30)
      default: say("unknown step")
      }
    }
  }

  // MARK: composer input (in-process events: this machine does not grant the tools Accessibility, so HID events are dropped)

  /// Polls `<out>/cmds.txt` and runs each new line as a step; `echo step >> cmds.txt` drives a live run.
  private func watch() async {
    let file = out.appending(path: "cmds.txt")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    var done = 0
    while true {
      let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
      while done < lines.count {
        let line = lines[done]
        done += 1
        if line == "stopwatch" { return }
        await run([line], quick: true)
        say("ok \(line)")
      }
      await sleep(0.25)
    }
  }

  private func post(_ event: NSEvent?) { if let event { NSApp.sendEvent(event) } }

  /// Types text through keyDown events to the first responder (a real keyboard path into the editor).
  private func typeIn(_ text: String) async {
    for ch in text {
      let s = String(ch)
      for down in [true, false] {
        post(NSEvent.keyEvent(
          with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: (window?.attachedSheet ?? window)?.windowNumber ?? 0, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0))
      }
      await sleep(0.02)
    }
  }

  /// `key:<keyCode>:<mods c s o k>:<char>`, e.g. `key:36:c` is ⌘↩, `key:1:c:s` is ⌘S, `key:53` is Esc.
  private func key(_ arg: String) async {
    let parts = arg.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let code = UInt16(parts[0]) else { return }
    var flags: NSEvent.ModifierFlags = []
    for m in parts.count > 1 ? parts[1] : "" { switch m { case "c": flags.insert(.command); case "s": flags.insert(.shift); case "o": flags.insert(.option); case "k": flags.insert(.control); default: break } }
    let ch = parts.count > 2 ? parts[2] : (code == 36 ? "\r" : code == 53 ? "\u{1b}" : code == 126 ? String(UnicodeScalar(NSUpArrowFunctionKey)!) : code == 125 ? String(UnicodeScalar(NSDownArrowFunctionKey)!) : code == 48 ? "\t" : "")
    for down in [true, false] {
      post(NSEvent.keyEvent(
        with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code))
    }
    await sleep(0.15)
  }

  /// Per environment: the negotiated orchestration protocol, shell size and sync status.
  private func protocolStatus() async {
    for e in app.runtime.environments {
      let version = await app.runtime.orchestrationProtocol(e.environmentId).map { "v\($0.rawValue)" } ?? "none"
      let shell = app.runtime.shells[e.environmentId]
      say("proto \(e.label) \(version) phase=\(e.connection.phase) shell=\(String(describing: shell?.status)) threads=\(shell?.snapshot?.threads.count ?? -1) v2=\(shell?.v2 != nil) seq=\(shell?.snapshot?.snapshotSequence ?? -1)")
    }
    if let detail = app.detail {
      let p = detail.projection
      say("detail \(detail.key) status=\(detail.state.status) v2=\(p != nil) messages=\(detail.thread?.messages.count ?? -1) runs=\(p?.runs.count ?? -1) items=\(p?.turnItems.count ?? -1) visible=\(p?.visibleTurnItems.count ?? -1) older=\(detail.hasOlderTurns) queued=\(detail.queue.queued.count)")
    }
  }

  /// `send:<text>`: sends a message to the selected thread, then follows the turn for up to a minute (what streamed, how it ended).
  private func sendMessage(_ text: String) async {
    guard let key = app.selection, let detail = app.detail else { say("send: no selected thread"); return }
    do {
      _ = try await app.runtime.sendMessage(key, text: text)
      say("send: accepted")
    } catch { say("send failed: \(AppModel.describe(error))"); return }
    var lastLength = -1
    for _ in 0..<120 {
      await sleep(0.5)
      let messages = detail.thread?.messages ?? []
      let assistant = messages.last { $0.role == .assistant }
      let length = assistant?.text.count ?? 0
      if length != lastLength {
        lastLength = length
        say("stream: messages=\(messages.count) assistant=\(length) streaming=\(assistant?.streaming ?? false) runs=\((detail.projection?.runs.map { $0.status.rawValue }) ?? [])")
      }
      if let run = detail.projection?.runs.last, ["completed", "failed", "interrupted", "cancelled"].contains(run.status.rawValue), messages.count >= 2 { break }
    }
    say("turn end: \((detail.thread?.messages.last).map { "\($0.role.rawValue): \($0.text.prefix(120))" } ?? "none")")
  }

  /// `clickat:<x>:<y>` in window points from the top-left of the content area (a 2x `shot` pixel / 2).
  private func clickAt(_ arg: String) async {
    let p = arg.split(separator: ":").compactMap { Double($0) }
    guard p.count >= 2, let window, let content = window.contentView else { return }
    let point = NSPoint(x: p[0], y: content.frame.height - p[1])
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      post(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      await sleep(0.08)
    }
    say("click hit: \(content.hitTest(point).map { String(describing: type(of: $0)) } ?? "nil")")
    await sleep(0.3)
  }

  /// `clickscreen:<x>:<y>` in screen points from the top-left of the main display (what `CGWindowList` reports). Reaches popovers and menus, which are windows of their own.
  private func clickScreen(_ arg: String) async {
    let p = arg.split(separator: ":").compactMap { Double($0) }
    guard p.count >= 2, let height = NSScreen.screens.first?.frame.height else { return }
    let screenPoint = NSPoint(x: p[0], y: height - p[1])
    guard let target = NSApp.windows.filter({ $0.isVisible && $0.frame.contains(screenPoint) }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
      say("clickscreen: no window at \(arg)")
      return
    }
    let point = target.convertPoint(fromScreen: screenPoint)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      post(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      await sleep(0.08)
    }
    say("clickscreen hit window \(type(of: target)) \(target.windowNumber)")
    await sleep(0.3)
  }

  /// `paste:<image or file path>`: puts it on the pasteboard and pastes into the first responder.
  private func paste(_ path: String) {
    let board = NSPasteboard.general
    board.clearContents()
    let url = URL(fileURLWithPath: path)
    if let image = NSImage(contentsOf: url), url.pathExtension.lowercased() != "pdf" { board.writeObjects([image]) } else { board.writeObjects([url as NSURL]) }
    say("paste sent: \(NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))")
  }

  // MARK: steps

  private func findScrollViews(in view: NSView?, into out: inout [NSScrollView]) {
    guard let view else { return }
    if let scroll = view as? NSScrollView { out.append(scroll) }
    for sub in view.subviews { findScrollViews(in: sub, into: &out) }
  }

  private func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }

  /// Scrolls the timeline at a fixed speed, one synchronous layout+display pass per "frame", and logs the
  /// main-thread cost per frame. The display is asleep in automated runs, so this measures main-thread work
  /// (layout, SwiftUI, text, backing-store drawing), not GPU compositing or vsync pacing.
  private func bench(_ label: String) async {
    guard let window else { return }
    var scrolls: [NSScrollView] = []
    findScrollViews(in: window.contentView, into: &scrolls)
    scrolls = scrolls.filter { !($0.documentView is NSOutlineView) }
    guard let scroll = scrolls.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }), let doc = scroll.documentView else { say("bench: no scroll view"); return }
    let clip = scroll.contentView
    let total = doc.bounds.height, viewport = clip.bounds.height
    say("bench \(label): doc=\(Int(total))pt viewport=\(Int(viewport))pt scrollView=\(type(of: scroll)) doc=\(type(of: doc))")
    let step: CGFloat = 32
    func pass(_ name: String, from: CGFloat, to: CGFloat) {
      var times: [Double] = []
      var y = from
      let direction: CGFloat = to > from ? 1 : -1
      while direction > 0 ? y < to : y > to {
        let t0 = CFAbsoluteTimeGetCurrent()
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(mode: .default, before: Date())
        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        y += step * direction
      }
      let sorted = times.sorted()
      let over8 = times.filter { $0 > 8.33 }.count, over16 = times.filter { $0 > 16.67 }.count
      say(String(format: "bench %@ %@: frames=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.1fms >8.3ms=%d (%.1f%%) >16.7ms=%d", label, name, times.count, percentile(sorted, 0.5), percentile(sorted, 0.95), percentile(sorted, 0.99), sorted.last ?? 0, over8, Double(over8) * 100 / Double(max(times.count, 1)), over16))
    }
    let bottom = max(0, doc.bounds.height - clip.bounds.height)
    pass("cold-up", from: bottom, to: 0)
    pass("cold-down", from: 0, to: max(0, doc.bounds.height - clip.bounds.height))
    pass("warm-up", from: max(0, doc.bounds.height - clip.bounds.height), to: 0)
    pass("warm-down", from: 0, to: max(0, doc.bounds.height - clip.bounds.height))
    if let controller = TimelineController.current { say("bench \(label) measure: \(controller.debugStats)") }
  }

  /// Read-only: opens the first n threads, loads all history and logs their size.
  private func survey(_ range: Range<Int>) async {
    let all = app.runtime.sidebar.rows
    for index in range where index < all.count {
      let row = all[index]
      app.selection = row.thread.key
      for _ in 0..<100 where app.detail?.thread == nil { await sleep(0.1) }
      await loadAll()
      let thread = app.detail?.thread
      say("survey \(index) \(row.thread.shell.id.rawValue.prefix(8)) messages=\(thread?.messages.count ?? 0) activities=\(thread?.activities.count ?? 0) checkpoints=\(thread?.checkpoints.count ?? 0) \"\(row.thread.shell.title.prefix(30))\"")
    }
    app.selection = nil
  }

  private var scratchKeys: [String: ScopedThreadKey] = [:]

  private var scratchGroup: ProjectGroup? { app.runtime.projectGroups.first { $0.representative.project.workspaceRoot == "/private/tmp/t3-scratch" } }

  private func scratchRow(_ key: ScopedThreadKey) -> SidebarRow? { app.runtime.sidebar.rows.first { $0.thread.key == key } }

  private func check(_ label: String, _ key: ScopedThreadKey, _ expected: ThreadListLayout.Section) async {
    for _ in 0..<40 where scratchRow(key)?.section != expected { await sleep(0.1) }
    say("\(label): section=\(String(describing: scratchRow(key)?.section)) expected=\(expected)")
  }

  /// Creates threads in the T3 Scratch project only and puts them in four sections.
  private func scratch() async {
    guard let group = scratchGroup else { say("no scratch project"); return }
    for name in ["pinned", "snoozed", "settled", "active"] {
      if let key = await app.newThread(in: group, title: "[stageC] \(name)") { scratchKeys[name] = key } else { say("create \(name) failed: \(app.errorMessage ?? "")") }
    }
    let runtime = app.runtime
    do {
      if let key = scratchKeys["pinned"] { try await runtime.pinThread(key); await check("pin", key, .pinned) }
      if let key = scratchKeys["snoozed"], let preset = runtime.snoozePresets().first { try await runtime.snoozeThread(key, preset: preset); await check("snooze", key, .snoozed) }
      if let key = scratchKeys["settled"] { try await runtime.settleThread(key); await check("settle", key, .settled) }
      if let key = scratchKeys["active"] { await check("active", key, .active) }
    } catch { say("scratch error: \(AppModel.describe(error))") }
    app.selection = nil
  }

  /// Exercises the remaining commands on the threads created above.
  private func scratchOps() async {
    let runtime = app.runtime
    do {
      if let key = scratchKeys["active"] {
        try await runtime.renameThread(key, title: "[stageC] renamed")
        for _ in 0..<40 where scratchRow(key)?.thread.shell.title != "[stageC] renamed" { await sleep(0.1) }
        say("rename: title=\(scratchRow(key)?.thread.shell.title ?? "?")")
        try await runtime.setAutoSettle(key, enabled: false)
        for _ in 0..<40 where scratchRow(key)?.thread.shell.autoSettleDisabledAt.flatMap({ $0 }) == nil { await sleep(0.1) }
        say("autosettle off: \(scratchRow(key)?.thread.shell.autoSettleDisabledAt.flatMap { $0 } != nil)")
        await runtime.markThreadUnread(key)
        try await runtime.settleThread(key); await check("settle", key, .settled)
        try await runtime.unsettleThread(key); await check("unsettle", key, .active)
      }
      if let key = scratchKeys["snoozed"] { try await runtime.unsnoozeThread(key); await check("unsnooze", key, .active) }
      if let key = scratchKeys["pinned"] {
        try await runtime.movePinnedThread(key, up: true)
        try await runtime.unpinThread(key); await check("unpin", key, .active)
      }
      if let key = scratchKeys["settled"] {
        try await runtime.archiveThread(key)
        for _ in 0..<40 where scratchRow(key) != nil { await sleep(0.1) }
        say("archive: removed from sidebar=\(scratchRow(key) == nil)")
      }
    } catch { say("ops error: \(AppModel.describe(error))") }
  }

  /// Settings › Archived against the scratch project only: `[archived-check]` threads are created here and removed again.
  private func archivedCheck() async {
    guard let group = scratchGroup, let model = app.runtime.sidebar.rows.first?.thread.shell.modelSelection else { say("archivedcheck: no scratch project or model"); return }
    let project = group.representative
    let runtime = app.runtime
    for _ in 0..<300 where runtime.environments.first(where: { $0.environmentId == project.environmentId })?.connection.phase != .connected { await sleep(0.1) }
    func listed(_ key: ScopedThreadKey) async -> Bool {
      for _ in 0..<40 {
        if let projects = try? await runtime.archivedProjects(environmentId: key.environmentId), projects.contains(where: { $0.threads.contains { $0.key == key } }) { return true }
        await sleep(0.1)
      }
      return false
    }
    func gone(_ key: ScopedThreadKey) async -> Bool {
      for _ in 0..<40 {
        if let projects = try? await runtime.archivedProjects(environmentId: key.environmentId), !projects.contains(where: { $0.threads.contains { $0.key == key } }) { return true }
        await sleep(0.1)
      }
      return false
    }
    do {
      var keys: [ScopedThreadKey] = []
      for name in ["A", "B", "C"] {
        let id = try await runtime.createThread(environmentId: project.environmentId, projectId: project.projectId, title: "[archived-check] \(name)", modelSelection: model)
        let key = ScopedThreadKey(environmentId: project.environmentId, threadId: id)
        keys.append(key)
        try await runtime.archiveThread(key)
      }
      say("archived listed: \(await listed(keys[0])) \(await listed(keys[1])) \(await listed(keys[2]))")
      try await runtime.unarchiveThread(keys[0])
      say("unarchive removes from archive: \(await gone(keys[0]))")
      try await runtime.archiveThread(keys[0])
      say("re-archived listed: \(await listed(keys[0]))")
      try await runtime.deleteThread(keys[2])
      say("delete removes from archive: \(await gone(keys[2]))")
    } catch { say("archivedcheck error: \(AppModel.describe(error))") }
  }

  private func archivedClean() async {
    let runtime = app.runtime
    guard let group = scratchGroup else { return }
    for _ in 0..<300 where runtime.environments.first(where: { $0.environmentId == group.representative.environmentId })?.connection.phase != .connected { await sleep(0.1) }
    guard let projects = try? await runtime.archivedProjects(environmentId: group.representative.environmentId) else { return }
    for thread in projects.filter({ $0.projectId == group.representative.projectId }).flatMap(\.threads) where thread.title.hasPrefix("[archived-check]") {
      do { try await runtime.deleteThread(thread.key); say("deleted \(thread.title)") } catch { say("delete \(thread.title) failed: \(AppModel.describe(error))") }
    }
  }

  private func scratchClean() async {
    let runtime = app.runtime
    for (name, key) in scratchKeys {
      do { try await runtime.deleteThread(key); say("deleted \(name)") } catch { say("delete \(name) failed: \(AppModel.describe(error))") }
    }
    scratchKeys = [:]
  }

  /// Local-only: marks the n-th ready thread with a completed turn unread (client-state.json, no server command).
  private func markUnread(_ count: Int) async {
    var done = 0
    for row in app.runtime.sidebar.rows where row.status == .ready && row.thread.shell.latestTurn?.completedAt != nil && done < count {
      await app.runtime.markThreadUnread(row.thread.key)
      done += 1
    }
    await sleep(0.5)
  }

  /// Offscreen render of the sidebar's row views (the live List is not drawable without a display).
  private func renderSidebar(name: String) {
    for dark in [false, true] {
      let view = SidebarSnapshotView(app: app, dark: dark)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      {
        try? png.write(to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
        say("rendered sidebar \(dark ? "dark" : "light")")
      }
    }
  }

  private func dump() {
    for row in app.runtime.sidebar.rows {
      let s = row.thread.shell
      say("\(row.section) \(row.status) unread=\(row.isUnread) woke=\(row.isWoke) \(row.thread.key) \"\(s.title.prefix(48))\"")
    }
  }

  /// `select:<n>` selects the nth sidebar row, `select:<thread id prefix>` a thread by id.
  private func select(_ arg: String) async {
    let rows = app.runtime.sidebar.rows
    let row = Int(arg).flatMap { $0 < rows.count ? rows[$0] : nil } ?? rows.first { $0.thread.shell.id.rawValue.hasPrefix(arg) }
    guard let row else { say("no such row"); return }
    app.selection = row.thread.key
    for _ in 0..<100 where app.detail?.thread == nil { await sleep(0.1) }
    await sleep(1.0)
  }

  private func loadAll() async {
    guard let detail = app.detail else { return }
    var guardCount = 0
    while detail.hasOlderTurns, guardCount < 100 {
      let before = detail.history, visible = detail.projection?.visibleTurnItems.count ?? 0
      await detail.loadOlderTurns()
      guardCount += 1
      await sleep(0.3)
      let after = detail.history
      say("page \(guardCount) cursor=\(before.historyCursor?.suffix(12) ?? "nil") -> \(after.historyCursor?.suffix(12) ?? "nil") more=\(after.hasMoreHistory) loading=\(before.loading)/\(after.loading) status=\(detail.state.status) error=\(after.error ?? "-") visible \(visible) -> \(detail.projection?.visibleTurnItems.count ?? 0)")
      // A page that neither advanced the cursor nor added rows will not do so on retry.
      if after.historyCursor == before.historyCursor { break }
      await sleep(0.2)
    }
    say("loaded all: pages=\(guardCount) older=\(detail.hasOlderTurns) rows=\(detail.projection?.visibleTurnItems.count ?? 0) messages=\(detail.thread?.messages.count ?? 0) activities=\(detail.thread?.activities.count ?? 0)")
    await sleep(2)
  }

  private func sheet(_ arg: String) async {
    switch arg {
    case "add": app.sheet = .addEnvironment
    case "snooze": if let key = app.selection ?? app.runtime.sidebar.rows.first?.thread.key { app.sheet = .snooze(key) }
    case "rename": if let key = app.selection { app.sheet = .rename(key) }
    default: app.sheet = nil
    }
    await sleep(1.0)
    if arg != "close", let sheet = window?.attachedSheet { captureViews(sheet, name: "sheet-\(arg)"); say("sheet size \(sheet.frame.size)") } else { say("no attached sheet") }
    app.sheet = nil
    await sleep(0.5)
  }

  /// Right-clicks a sidebar row (`menu:<row index>`), captures the menu window, then dismisses it.
  private func contextMenu(_ arg: String) async {
    guard let window, let table = findSidebarTable(in: window.contentView) else { say("no sidebar table"); return }
    let index = Int(arg) ?? 0
    var row = 0, found = -1
    for r in 0..<table.numberOfRows {
      let view = table.view(atColumn: 0, row: r, makeIfNecessary: true)
      if view != nil, !(view is NSTableRowView) || true {
        // Skip section headers (group rows) when counting thread rows.
        if !(table.delegate?.tableView?(table, isGroupRow: r) ?? false) {
          if row == index { found = r; break }
          row += 1
        }
      }
    }
    guard found >= 0 else { say("row not found"); return }
    let rect = table.convert(table.rect(ofRow: found), to: nil)
    let point = NSPoint(x: rect.midX, y: rect.midY)
    let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
      let cg = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
      say("cg windows: " + cg.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }.map { "\($0[kCGWindowNumber as String] ?? 0)@\($0[kCGWindowLayer as String] ?? 0) \(($0[kCGWindowBounds as String] as? [String: Any])?["Width"] ?? 0)x\(($0[kCGWindowBounds as String] as? [String: Any])?["Height"] ?? 0)" }.joined(separator: ", "))
      say("ns windows: \(NSApp.windows.map { String(describing: type(of: $0)) })")
      for entry in cg where (entry[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier && (entry[kCGWindowLayer as String] as? Int) == 101 {
        captureNumber(entry[kCGWindowNumber as String] as? UInt32 ?? 0, name: "context-menu-\(entry[kCGWindowNumber as String] ?? 0)")
      }
      let menus = NSApp.windows.filter { String(describing: type(of: $0)).contains("Menu") || String(describing: type(of: $0)).contains("Popup") }
      say("menu windows: \(menus.map { String(describing: type(of: $0)) })")
      if let menuWindow = menus.first {
        captureViews(menuWindow, name: "context-menu")
        say("menu content: \(String(describing: menuWindow.contentView.map { type(of: $0) })) frame=\(menuWindow.frame)")
      }
      let esc = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
      NSApp.postEvent(esc, atStart: true)
    }
    window.sendEvent(event)
    await sleep(0.5)
  }

  private func findSidebarTable(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let table = view as? NSTableView, type(of: table) != NSTableView.self { return table }
    for sub in view.subviews { if let found = findSidebarTable(in: sub) { return found } }
    return nil
  }

  private func findTimelineTable(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let table = view as? NSTableView, type(of: table) == NSTableView.self { return table }
    for sub in view.subviews { if let found = findTimelineTable(in: sub) { return found } }
    return nil
  }

  private func scrollTimeline(top: Bool) {
    guard let table = findTimelineTable(in: window?.contentView), let scroll = table.enclosingScrollView else { return }
    let y = top ? 0 : max(0, table.bounds.height - scroll.contentView.bounds.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  // MARK: capture

  func captureView(_ view: NSView?, name: String) {
    guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: out.appending(path: "\(name).png"))
      say("wrote view \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
  }

  /// Fallback: the window's own view tree drawn into a bitmap (no compositor, so materials look flat).
  func captureViews(_ window: NSWindow?, name: String) {
    guard let view = window?.contentView?.superview ?? window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: out.appending(path: "\(name).png"))
      say("wrote views \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
  }

  private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

  func captureNumber(_ number: UInt32, name: String) {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
    let fn = unsafeBitCast(symbol, to: CaptureFn.self)
    let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
    guard let image = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, number, options)?.takeRetainedValue() else { say("capture failed \(name)"); return }
    if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
      try? png.write(to: out.appending(path: "\(name).png"))
      say("wrote \(name).png \(image.width)x\(image.height)")
    }
  }

  /// Own-process window capture (no Screen Recording permission needed for our own windows).
  func capture(_ window: NSWindow?, name: String) {
    guard let window, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { say("capture unavailable"); return }
    let fn = unsafeBitCast(symbol, to: CaptureFn.self)
    let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
    guard let image = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue() else {
      say("capture failed \(name)")
      return
    }
    let rep = NSBitmapImageRep(cgImage: image)
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: out.appending(path: "\(name).png"))
      say("wrote \(name).png \(image.width)x\(image.height)")
    }
  }
}

/// The sidebar's sections built from the same row views as the List, for offscreen rendering.
struct SidebarSnapshotView: View {
  let app: AppModel
  let dark: Bool

  var body: some View {
    let model = app.runtime.sidebar
    let now = Date.now
    VStack(alignment: .leading, spacing: 2) {
      block("Pinned", model.pinned, now)
      block("Active", model.active, now)
      block("Snoozed (\(model.layout.snoozedCount))", model.snoozed, now)
      block("Settled (\(model.layout.settledCount))", Array(model.settled.prefix(5)), now)
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(dark ? Color(white: 0.13) : Color(white: 0.93))
    .environment(app)
    .environment(\.colorScheme, dark ? .dark : .light)
  }

  @ViewBuilder private func block(_ title: String, _ rows: [SidebarRow], _ now: Date) -> some View {
    if !rows.isEmpty {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 4)
      ForEach(rows) { ThreadRowView(row: $0, now: now).padding(.horizontal, 6) }
    }
  }
}
#endif
