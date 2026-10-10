#if DEBUG
import AppKit
import SwiftUI
import T3Theme

/// Verification only: `-T3AppearanceShots <dir> -T3AppearanceThread <row>` selects a thread, captures the main window, opens
/// Settings on the page named by `-T3SettingsPage`, captures that window, and quits. Never ships (`#if DEBUG`).
@MainActor
enum AppearanceDebug {
  static func runIfRequested(app: AppModel) {
    guard let dir = UserDefaults.standard.string(forKey: "T3AppearanceShots") else { return }
    let out = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    Task {
      var log = ""
      func say(_ text: String) { log += text + "\n"; try? Data(log.utf8).write(to: out.appending(path: "appearance-debug.log")) }
      for _ in 0..<300 where app.runtime.sidebar.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
      try? await Task.sleep(for: .seconds(1))
      let rows = app.runtime.sidebar.rows
      say("rows=\(rows.count) theme=\(AppTheme.shared.resolved.themeId ?? "standard") appearance=\(AppTheme.shared.resolved.appearance)")
      if let index = UserDefaults.standard.object(forKey: "T3AppearanceThread") as? Int, index < rows.count {
        app.selection = rows[index].thread.key
        for _ in 0..<100 where app.detail?.thread == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2.5))
      }
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first { $0.isVisible && $0.frame.width > 700 }?.makeKeyAndOrderFront(nil)  // an inactive window paints a gray selection
      try? await Task.sleep(for: .milliseconds(600))
      if let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "Appearance" && $0.contentView != nil && $0.frame.width > 700 }) {
        capture(main, to: out.appending(path: "main.png"), say)
      }
      // A live switch: the surfaces that were already on screen must repaint without being rebuilt.
      if let next = UserDefaults.standard.string(forKey: "T3AppearanceSwitchTo"), let main = NSApp.windows.first(where: { $0.isVisible && $0.title != "Appearance" && $0.frame.width > 700 }) {
        AppTheme.shared.use(next == "standard" ? nil : next)
        if let mode = UserDefaults.standard.string(forKey: "T3AppearanceSwitchMode").flatMap(ThemeMode.init) { AppTheme.shared.setMode(mode) }
        try? await Task.sleep(for: .seconds(2.5))
        capture(main, to: out.appending(path: "main-switched.png"), say)
      }
      say("showSettingsWindow: \(NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil))")
      try? await Task.sleep(for: .seconds(2))
      if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Appearance" }), let menu = NSApp.mainMenu, let appMenu = menu.items.first?.submenu {
        say("menu: \(appMenu.items.map(\.title))")
        if let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) { appMenu.performActionForItem(at: index) }
        try? await Task.sleep(for: .seconds(2))
      }
      if let settings = NSApp.windows.first(where: { $0.isVisible && $0.title == "Appearance" }) {
        settings.setContentSize(NSSize(width: 980, height: 1100))
        try? await Task.sleep(for: .seconds(1.2))
        capture(settings, to: out.appending(path: "appearance.png"), say)
        if let scroll = Self.largestScrollView(in: settings.contentView) {
          scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)))
          try? await Task.sleep(for: .seconds(1))
          capture(settings, to: out.appending(path: "appearance-bottom.png"), say)
        }
      } else {
        say("no settings window: \(NSApp.windows.map { "\($0.title)|\($0.isVisible)" })")
      }
      say("done")
      NSApp.terminate(nil)  // the normal quit path, so the local server is stopped too
    }
  }

  private static func largestScrollView(in view: NSView?) -> NSScrollView? {
    guard let view else { return nil }
    var best: NSScrollView?
    func walk(_ v: NSView) {
      if let scroll = v as? NSScrollView, scroll.frame.width > 400, (best?.frame.height ?? 0) < scroll.frame.height { best = scroll }
      v.subviews.forEach(walk)
    }
    walk(view)
    return best
  }

  private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

  private static func capture(_ window: NSWindow, to url: URL, _ say: (String) -> Void) {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return say("capture unavailable") }
    let fn = unsafeBitCast(symbol, to: CaptureFn.self)
    let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
    guard let image = fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue() else {
      return say("capture failed \(url.lastPathComponent)")
    }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    say("wrote \(url.lastPathComponent) \(image.width)x\(image.height)")
  }
}
#endif
