#if DEBUG
import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Diff

/// Debug-only: renders the real right panel with the diff from a recorded patch file, offscreen, to a PNG, and
/// optionally measures scrolling. `-T3DiffSnapshot <patch> -T3OutDir <dir> [-T3DiffBench YES] [-T3DiffDark YES] [-T3DiffLayout split]`.
/// Used when no connected environment has a repository to diff.
@MainActor
enum DiffDebugSnapshot {
  static func runIfRequested(app: AppModel) {
    let defaults = UserDefaults.standard
    guard let patch = defaults.string(forKey: "T3DiffSnapshot"), let out = defaults.string(forKey: "T3OutDir") else { return }
    Task { await run(app: app, patchPath: patch, out: URL(fileURLWithPath: out), bench: defaults.bool(forKey: "T3DiffBench"), dark: defaults.bool(forKey: "T3DiffDark")) }
  }

  private static func run(app: AppModel, patchPath: String, out: URL, bench: Bool, dark: Bool) async {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let log = out.appending(path: "diff-snapshot.log")
    var lines: [String] = []
    func say(_ text: String) { lines.append(text); try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8) }
    guard let patch = try? String(contentsOfFile: patchPath, encoding: .utf8) else { return say("cannot read \(patchPath)") }

    let suite = UserDefaults(suiteName: "codes.t3.diff-snapshot")!
    suite.removePersistentDomain(forName: "codes.t3.diff-snapshot")
    let model = DiffPanelModel(fetch: { _ in DiffFetchResult(patch: patch, truncated: false) }, defaults: suite, settings: ClientSettingsStore(directory: nil))
    model.filesCollapsedByDefault = false
    if let layout = UserDefaults.standard.string(forKey: "T3DiffLayout").flatMap(DiffLayoutMode.init(rawValue:)) { model.layout = layout }
    let store = RightPanelStore(defaults: suite)
    let key = ScopedThreadKey(environmentId: EnvironmentId(rawValue: "snapshot"), threadId: ThreadId(rawValue: "snapshot"))
    store.open(.diff, in: key)

    let size = NSSize(width: 640, height: 820)
    let host = NSHostingView(rootView: RightPanelView(app: app, key: key, turns: [], store: store, diff: model).environment(app).background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    window.orderFrontRegardless()

    let started = Date()
    for _ in 0..<300 where model.phase != .ready || model.files.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    say("loaded \(model.files.count) files, \(model.rows.count) rows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    try? await Task.sleep(for: .milliseconds(1500))  // syntax highlighting arrives asynchronously
    save(host, to: out.appending(path: "diff-panel\(dark ? "-dark" : "").png"), say: say)

    if bench, let table = findTable(in: host), let scroll = table.enclosingScrollView {
      for (layout, wrap) in [(DiffLayoutMode.stacked, true), (.stacked, false), (.split, true)] {
        model.layout = layout
        model.wordWrap = wrap
        try? await Task.sleep(for: .milliseconds(1200))
        let clip = scroll.contentView
        let total = table.frame.height - clip.bounds.height
        var y: CGFloat = 0, frames = 0, worst = 0.0
        let begin = Date()
        while y < total, frames < 600 {
          let t0 = Date()
          clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
          scroll.reflectScrolledClipView(clip)
          window.displayIfNeeded()
          worst = max(worst, Date().timeIntervalSince(t0))
          y += 64
          frames += 1
        }
        let elapsed = Date().timeIntervalSince(begin)
        say("bench \(layout.rawValue) wrap=\(wrap): rows=\(model.rows.count) height=\(Int(table.frame.height)) frames=\(frames) avg=\(String(format: "%.2f", elapsed / Double(max(frames, 1)) * 1000)) ms worst=\(String(format: "%.2f", worst * 1000)) ms")
      }
    }
    NSApp.terminate(nil)
  }

  private static func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for sub in view.subviews { if let found = findTable(in: sub) { return found } }
    return nil
  }

  private static func save(_ view: NSView, to url: URL, say: (String) -> Void) {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return say("no bitmap") }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: url)
      say("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
  }
}
#endif
