#if DEBUG
import AppKit
import Foundation

extension DiagnosticsController {
  /// `-T3DiagnosticsShot <png path> [-T3DiagnosticsScroll <row id>,...]` (one capture per id, id appended to the file name): once live data has arrived, grows the Settings window to
  /// the screen, scrolls to the row and writes one capture of the window (the app captures itself; no system events).
  func debugShot() async {
    guard let path = UserDefaults.standard.string(forKey: "T3DiagnosticsShot") else { return }
    for _ in 0..<150 where telemetry == nil || trace.value == nil || history.value == nil { try? await Task.sleep(for: .milliseconds(200)) }
    try? await Task.sleep(for: .seconds(4))  // a few samples, so the tree and charts hold real values
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Diagnostics" }) else { return }
    let height = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    window.setContentSize(NSSize(width: 1040, height: height - 60))
    typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
    let capture = unsafeBitCast(symbol, to: CaptureFn.self)
    let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
    let ids = (UserDefaults.standard.string(forKey: "T3DiagnosticsScroll") ?? "").split(separator: ",").map(String.init)
    for id in ids.isEmpty ? [""] : ids {
      if !id.isEmpty { model.scrollTo(id) }
      try? await Task.sleep(for: .seconds(1.5))
      guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?.takeRetainedValue() else { return }
      let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension(id.isEmpty ? "png" : "\(id).png")
      try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
  }
}
#endif
