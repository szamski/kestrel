import CoreGraphics
import Foundation

/// Where the page's frame sits inside a viewer and how points map between the two. The frame is letterboxed
/// (aspect fit) inside the view; pointer input and the agent cursor use the page's CSS viewport as coordinate space.
public struct PreviewGeometry: Sendable, Equatable {
  /// The viewer's size in points.
  public var view: CGSize
  /// The latest frame's size in pixels; only its aspect matters.
  public var frame: CGSize
  /// The page's CSS viewport, as the server last reported it.
  public var page: CGSize

  public init(view: CGSize, frame: CGSize, page: CGSize) {
    self.view = view
    self.frame = frame
    self.page = page
  }

  /// The aspect-fit rectangle of the frame in the view (top-left origin); nil until sizes are known.
  public var fitted: CGRect? {
    guard view.width > 0, view.height > 0, frame.width > 0, frame.height > 0 else { return nil }
    let scale = min(view.width / frame.width, view.height / frame.height)
    let size = CGSize(width: frame.width * scale, height: frame.height * scale)
    return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width, height: size.height)
  }

  /// The page point under a view point (top-left origin). Outside the frame it is nil, or clamped onto it with `clamp` (a drag
  /// that left the page keeps tracking). `scale` is page CSS pixels per view point.
  public func pagePoint(_ point: CGPoint, clamp: Bool = false) -> (point: CGPoint, scale: CGFloat)? {
    guard let fit = fitted, page.width > 0, page.height > 0 else { return nil }
    let scale = page.width / fit.width
    let x = (point.x - fit.minX) * scale
    let y = (point.y - fit.minY) * (page.height / fit.height)
    let inside = x >= 0 && y >= 0 && x <= page.width && y <= page.height
    guard inside || clamp else { return nil }
    return (CGPoint(x: min(max(x, 0), page.width), y: min(max(y, 0), page.height)), scale)
  }

  /// The view point of a page point (the agent cursor).
  public func viewPoint(_ point: CGPoint) -> CGPoint? {
    guard let fit = fitted, page.width > 0, page.height > 0 else { return nil }
    return CGPoint(x: fit.minX + point.x * fit.width / page.width, y: fit.minY + point.y * fit.height / page.height)
  }
}

/// The frame size a viewer asks the server for: its backing store in device pixels, at most `maxScale`x (a Retina
/// frame past 2x costs bandwidth without a visible gain). Grows only, so a window drag does not reconnect per step.
public enum PreviewFrameCap {
  public static func request(view: CGSize, backingScale: CGFloat, maxScale: CGFloat = 2) -> (width: Int, height: Int) {
    let scale = min(max(backingScale, 1), maxScale)
    return (max(1, Int((view.width * scale).rounded())), max(1, Int((view.height * scale).rounded())))
  }

  /// Whether a socket opened for `cap` is too small for `wanted`.
  public static func outgrown(cap: (width: Int, height: Int)?, wanted: (width: Int, height: Int)) -> Bool {
    guard let cap else { return true }
    return wanted.width > cap.width || wanted.height > cap.height
  }
}
