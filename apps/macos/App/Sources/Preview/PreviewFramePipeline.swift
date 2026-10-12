import AppKit
import ImageIO
import Synchronization

/// A decoded page frame. `CGImage` is immutable, so handing it between threads is safe.
struct DecodedFrame: @unchecked Sendable {
  let image: CGImage
  var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// Decodes the stream's JPEG frames off the main thread and presents only the newest one: while a frame decodes, the
/// latest waiting JPEG replaces older waiting ones, and the main thread is woken once per presented frame, never per
/// received one. A frame that fails to decode is skipped; the next one replaces it. No timers and no display link: an
/// idle page costs nothing.
final class PreviewFramePipeline: Sendable {
  private struct State {
    var waiting: Data?
    var decoding = false
    var ready: DecodedFrame?
    var presentScheduled = false
    var stopped = false
  }

  private let state = Mutex(State())
  private let present: @MainActor @Sendable (DecodedFrame) -> Void

  init(present: @escaping @MainActor @Sendable (DecodedFrame) -> Void) { self.present = present }

  /// One complete JPEG from the socket; callable from any thread.
  func submit(_ jpeg: Data) {
    let start = state.withLock { state -> Bool in
      guard !state.stopped else { return false }
      state.waiting = jpeg
      guard !state.decoding else { return false }
      state.decoding = true
      return true
    }
    if start { Task.detached(priority: .userInitiated) { [self] in drain() } }
  }

  func stop() { state.withLock { $0.stopped = true; $0.waiting = nil; $0.ready = nil } }

  private func drain() {
    while true {
      let next = state.withLock { state -> Data? in
        guard let data = state.waiting, !state.stopped else { state.decoding = false; return nil }
        state.waiting = nil
        return data
      }
      guard let data = next else { return }
      guard let frame = Self.decode(data) else { continue }
      let schedule = state.withLock { state -> Bool in
        guard !state.stopped else { return false }
        state.ready = frame
        guard !state.presentScheduled else { return false }
        state.presentScheduled = true
        return true
      }
      if schedule {
        DispatchQueue.main.async { [self] in
          let frame = state.withLock { state -> DecodedFrame? in
            state.presentScheduled = false
            defer { state.ready = nil }
            return state.stopped ? nil : state.ready
          }
          if let frame { MainActor.assumeIsolated { present(frame) } }
        }
      }
    }
  }

  /// Forces the decode here (`ShouldCacheImmediately`) so the main thread only hands the bitmap to the layer.
  static func decode(_ jpeg: Data) -> DecodedFrame? {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    return DecodedFrame(image: image)
  }
}
