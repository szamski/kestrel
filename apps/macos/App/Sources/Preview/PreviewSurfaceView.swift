import AppKit
import QuartzCore
import SwiftUI
import T3Preview

/// What the page view needs from whoever owns the stream: whether input goes through, where it goes, and how to
/// report what the view itself saw. `PreviewThreadModel` implements it.
@MainActor
protocol PreviewSurfaceDelegate: AnyObject {
  /// The viewer holds control of the page, so pointer and keyboard input apply.
  var controlsPage: Bool { get }
  func surface(send input: PreviewStreamInput)
  func surfaceResized(points: CGSize, scale: CGFloat)
  func surfaceFocusChanged(_ focused: Bool)
  func surfaceFirstFrame()
}

/// The page, as the newest decoded frame on a layer, aspect-fit. It repaints only when a frame arrives. With control it
/// forwards the mouse, trackpad and keyboard in page coordinates; the frame's letterbox is accounted for.
@MainActor
final class PreviewSurfaceView: NSView {
  weak var delegate: PreviewSurfaceDelegate?

  /// The page's CSS viewport as the server reported it: the coordinate space of input and of the agent's pointer.
  var pageSize: CGSize = .zero { didSet { if pageSize != oldValue { agentPointerPage.map(placeAgentCursor) } } }
  private(set) var frameSize: CGSize = .zero

  private var presented = false
  var hasFrame: Bool { presented }
  private let agentCursor = CAShapeLayer()
  private var agentPointerPage: CGPoint?
  private var agentDimTask: Task<Void, Never>?
  private var resizeTask: Task<Void, Never>?
  private var lastReportedSize: CGSize = .zero

  private var buttonsDown = 0
  private var clickCounts: [PreviewStreamInput.MouseButton: Int] = [:]
  private var pendingMove: (point: CGPoint, buttons: Int, modifiers: PreviewModifiers)?
  private var pendingWheel: (point: CGPoint, dx: Double, dy: Double, modifiers: PreviewModifiers)?
  private var flushScheduled = false
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.contentsGravity = .resizeAspect
    layer?.magnificationFilter = .linear
    layer?.minificationFilter = .trilinear
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
    // The agent's pointer: a small arrow that jumps to where its action lands.
    agentCursor.path = CGPath(
      ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14), transform: nil)
    agentCursor.fillColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
    agentCursor.strokeColor = NSColor.white.cgColor
    agentCursor.lineWidth = 2
    agentCursor.opacity = 0
    layer?.addSublayer(agentCursor)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Browser page")
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  // MARK: Frames

  func present(_ frame: DecodedFrame) {
    frameSize = frame.pixelSize
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contents = frame.image
    CATransaction.commit()
    if !presented {
      presented = true
      delegate?.surfaceFirstFrame()
    }
  }

  /// Back to nothing, for a tab switch or a reconnect that has not painted yet.
  func clear() {
    presented = false
    frameSize = .zero
    layer?.contents = nil
    agentCursor.opacity = 0
  }

  private var geometry: PreviewGeometry { PreviewGeometry(view: bounds.size, frame: frameSize, page: pageSize) }

  // MARK: Size

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    agentPointerPage.map(placeAgentCursor)
    CATransaction.commit()
    // The first size reports at once; later ones settle before the page is resized.
    let size = bounds.size
    guard size.width >= 1, size.height >= 1, size != lastReportedSize else { return }
    resizeTask?.cancel()
    let first = lastReportedSize == .zero
    resizeTask = Task { [weak self] in
      if !first { try? await Task.sleep(for: .milliseconds(150)) }
      guard !Task.isCancelled, let self else { return }
      lastReportedSize = bounds.size
      delegate?.surfaceResized(points: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { resizeTask?.cancel() }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  // MARK: Agent pointer

  /// The agent's action is about to land at `page` (CSS pixels): shows its pointer there, bright while it acts.
  func showAgentPointer(_ pointer: PreviewStreamPointer) {
    guard delegate?.controlsPage != true else { return }
    agentPointerPage = CGPoint(x: pointer.x, y: pointer.y)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    placeAgentCursor(agentPointerPage!)
    agentCursor.opacity = 1
    CATransaction.commit()
    agentDimTask?.cancel()
    agentDimTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      self?.agentCursor.opacity = 0.35
    }
  }

  func hideAgentPointer() {
    agentDimTask?.cancel()
    agentCursor.opacity = 0
  }

  private func placeAgentCursor(_ page: CGPoint) {
    if let point = geometry.viewPoint(page) { agentCursor.position = point } else { agentCursor.opacity = 0 }
  }

  // MARK: Input

  private func modifiers(_ event: NSEvent) -> PreviewModifiers {
    var result: PreviewModifiers = []
    if event.modifierFlags.contains(.option) { result.insert(.alt) }
    if event.modifierFlags.contains(.control) { result.insert(.control) }
    if event.modifierFlags.contains(.command) { result.insert(.meta) }
    if event.modifierFlags.contains(.shift) { result.insert(.shift) }
    return result
  }

  private func page(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
    geometry.pagePoint(convert(event.locationInWindow, from: nil), clamp: clamp)?.point
  }

  private func button(_ event: NSEvent) -> PreviewStreamInput.MouseButton {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged: .left
    case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
    default: .middle
    }
  }

  private func bit(_ button: PreviewStreamInput.MouseButton) -> Int {
    switch button {
    case .left: 1
    case .right: 2
    case .middle: 4
    case .none: 0
    }
  }

  private func pressed(_ event: NSEvent) {
    guard delegate?.controlsPage == true, let point = page(event) else { return }
    window?.makeFirstResponder(self)
    flushPending()
    let button = button(event)
    buttonsDown |= bit(button)
    clickCounts[button] = event.clickCount
    delegate?.surface(send: .mouse(action: .down, x: point.x, y: point.y, button: button, buttons: buttonsDown, clickCount: event.clickCount, modifiers: modifiers(event)))
  }

  private func released(_ event: NSEvent) {
    guard delegate?.controlsPage == true, buttonsDown != 0 else { return }
    flushPending()
    let button = button(event)
    guard buttonsDown & bit(button) != 0 else { return }
    buttonsDown &= ~bit(button)
    // A drag that ended outside the page still releases on it.
    guard let point = page(event, clamp: true) else { return }
    delegate?.surface(send: .mouse(action: .up, x: point.x, y: point.y, button: button, buttons: buttonsDown, clickCount: clickCounts[button] ?? 1, modifiers: modifiers(event)))
  }

  override func mouseDown(with event: NSEvent) { pressed(event) }
  override func rightMouseDown(with event: NSEvent) { pressed(event) }
  override func otherMouseDown(with event: NSEvent) { pressed(event) }
  override func mouseUp(with event: NSEvent) { released(event) }
  override func rightMouseUp(with event: NSEvent) { released(event) }
  override func otherMouseUp(with event: NSEvent) { released(event) }

  private func moved(_ event: NSEvent) {
    guard delegate?.controlsPage == true, let point = page(event, clamp: buttonsDown != 0) else { return }
    pendingMove = (point, buttonsDown, modifiers(event))
    scheduleFlush()
  }

  override func mouseMoved(with event: NSEvent) { moved(event) }
  override func mouseDragged(with event: NSEvent) { moved(event) }
  override func rightMouseDragged(with event: NSEvent) { moved(event) }
  override func otherMouseDragged(with event: NSEvent) { moved(event) }

  override func scrollWheel(with event: NSEvent) {
    guard delegate?.controlsPage == true, let point = page(event) else { return super.scrollWheel(with: event) }
    // A page scrolls the way the content moved, so the DOM delta is the opposite of AppKit's; mouse wheels count lines.
    let unit: Double = event.hasPreciseScrollingDeltas ? 1 : 16
    let scale = geometry.pagePoint(convert(event.locationInWindow, from: nil))?.scale ?? 1
    let dx = Double(-event.scrollingDeltaX) * unit * Double(scale)
    let dy = Double(-event.scrollingDeltaY) * unit * Double(scale)
    pendingWheel = (point, (pendingWheel?.dx ?? 0) + dx, (pendingWheel?.dy ?? 0) + dy, modifiers(event))
    scheduleFlush()
  }

  /// Moves and wheel deltas coalesce to one message per frame's worth of time (60 Hz), never one per event.
  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
      self?.flushScheduled = false
      self?.flushPending()
    }
  }

  private func flushPending() {
    if let move = pendingMove {
      pendingMove = nil
      let button: PreviewStreamInput.MouseButton = move.buttons & 1 != 0 ? .left : move.buttons & 2 != 0 ? .right : move.buttons & 4 != 0 ? .middle : .none
      delegate?.surface(send: .mouse(action: .move, x: move.point.x, y: move.point.y, button: button, buttons: move.buttons, clickCount: 0, modifiers: move.modifiers))
    }
    if let wheel = pendingWheel {
      pendingWheel = nil
      delegate?.surface(send: .wheel(x: wheel.point.x, y: wheel.point.y, deltaX: wheel.dx, deltaY: wheel.dy, modifiers: wheel.modifiers))
    }
  }

  /// Drops what a press or a drag left half done when control is lost.
  func resetInput() {
    pendingMove = nil
    pendingWheel = nil
    buttonsDown = 0
    clickCounts = [:]
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    if delegate?.controlsPage == true { key(.down, event) } else { super.keyDown(with: event) }
  }
  override func keyUp(with event: NSEvent) {
    if delegate?.controlsPage == true { key(.up, event) } else { super.keyUp(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Command shortcuts belong to the app (menus, keybindings) except the clipboard and editing keys, which the page gets.
    guard delegate?.controlsPage == true, window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "v":
      if event.type == .keyDown, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { delegate?.surface(send: .text(text)) }
      return true
    case "c", "x", "a", "z":
      key(event.type == .keyUp ? .up : .down, event)
      return true
    default: return false
    }
  }

  private func key(_ action: PreviewStreamInput.KeyAction, _ event: NSEvent) {
    // Shift+Escape hands the keyboard back to the app.
    if event.keyCode == 0x35, event.modifierFlags.contains(.shift) {
      if action == .down { window?.makeFirstResponder(nil) }
      return
    }
    // Dead keys and input methods compose text; their result arrives as characters, never as a key.
    guard let mapped = PreviewKeys.map(keyCode: event.keyCode, characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifiers: modifiers(event)) else { return }
    delegate?.surface(send: .key(action: action, key: mapped.key, code: mapped.code, keyCode: mapped.keyCode, text: action == .down ? mapped.text : nil, modifiers: modifiers(event)))
  }

  override func becomeFirstResponder() -> Bool {
    delegate?.surfaceFocusChanged(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    flushPending()
    delegate?.surfaceFocusChanged(false)
    return true
  }
}

/// The page view inside SwiftUI. The view is owned by the model so a tab switch inside the panel keeps it; this only mounts it.
struct PreviewSurface: NSViewRepresentable {
  let view: PreviewSurfaceView
  func makeNSView(context: Context) -> PreviewSurfaceView { view }
  func updateNSView(_ nsView: PreviewSurfaceView, context: Context) {}
}
