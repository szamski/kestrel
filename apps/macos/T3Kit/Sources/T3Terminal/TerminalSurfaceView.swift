import AppKit
import GhosttyKit
import Synchronization

/// A link activated with ⌘-click. Path links are already resolved against the terminal's cwd and
/// keep their `:line:column` suffix.
public enum TerminalLinkTarget: Sendable, Hashable {
  case url(URL)
  case path(String)
}

/// The pasteboard terminal copy, paste and OSC 52 use. Tests substitute a private one.
enum TerminalPasteboard {
  nonisolated(unsafe) static var current = NSPasteboard.general
}

private enum GhosttyProcess {
  /// libghostty must be initialized once per process before any config or app exists.
  static let initialized: Bool = ghostty_init(0, nil) == GHOSTTY_SUCCESS
}

/// What Ghostty's C callbacks reach. Ghostty calls from its IO and renderer threads, so everything
/// here is either lock-protected or only touched on the main thread (`view`).
private final class SurfaceHostBox: @unchecked Sendable {
  struct Handle: @unchecked Sendable { var raw: UnsafeMutableRawPointer? }
  let input = Mutex<(@Sendable (String) -> Void)?>(nil)
  let app = Mutex(Handle())
  let surface = Mutex(Handle())
  struct ReplayState { var remaining = 0; var active = false }
  /// Replies still expected from a replay before the real input callback may come back (see `replay`).
  let replay = Mutex(ReplayState())
  weak var view: TerminalSurfaceView?

  /// Ghostty wakes the host when its app mailbox has work; actions (cursor shape, bell, ...) run in `tick`.
  func scheduleTick() {
    DispatchQueue.main.async { [self] in
      guard let app = app.withLock({ $0.raw }) else { return }
      ghostty_app_tick(app)
    }
  }

  static func from(_ userdata: UnsafeMutableRawPointer?) -> SurfaceHostBox? {
    userdata.map { Unmanaged<SurfaceHostBox>.fromOpaque($0).takeUnretainedValue() }
  }
}

/// The layer-hosting view Ghostty draws into (it replaces the view's layer with its own
/// IOSurface-backed layer). Kept apart from the event-handling view so no subview ever lives in a
/// hosted layer tree.
private final class GhosttyHostView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isFlipped: Bool { true }
}

/// A native terminal: Ghostty's Metal renderer and VT engine in custom-I/O mode. Remote PTY output
/// goes in through `feed`/`replay`; keystrokes, pastes and terminal replies come out through
/// `onInput`. Bind a `TerminalSession` with `bind(to:)` to wire all of that to the server.
@MainActor
public final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
  // MARK: Public configuration and callbacks

  public var theme: TerminalTheme { didSet { if theme != oldValue { updateConfig() } } }
  public var font: TerminalFont { didSet { if font != oldValue { updateConfig() } } }
  /// Base for resolving relative path links.
  public var workingDirectory = ""
  /// Bytes the terminal wants to send to the PTY. Called on Ghostty's IO thread.
  public var onInput: (@Sendable (String) -> Void)? { didSet { let handler = onInput; box.input.withLock { $0 = handler } } }
  /// The character grid changed (first layout, window resize, font change).
  public var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
  /// ⌘-click on a link. Without a handler URLs open in the default browser and paths are ignored.
  public var onOpenLink: ((TerminalLinkTarget) -> Void)?
  /// BEL. Silent by default; hook a sound or dock bounce here if wanted.
  public var onBell: (() -> Void)?
  public var onTitleChange: ((String) -> Void)?
  /// Offered in the context menu when a selection exists.
  public var onAddSelectionToChat: ((String) -> Void)?

  public private(set) var gridSize: (cols: Int, rows: Int)?

  // MARK: State

  private let host = GhosttyHostView()
  private let box = SurfaceHostBox()
  private var app: ghostty_app_t?
  private var surface: ghostty_surface_t?
  private var creationFailed = false
  private(set) var cellSize = CGSize(width: 8, height: 16)
  private var cursor = NSCursor.iBeam
  private var trackingArea: NSTrackingArea?
  private var markedText = NSMutableAttributedString()
  private var keyTextAccumulator: [String]?
  private var pending: [Pending] = []
  private var boundSession: TerminalSession?
  private var outputCursor = TerminalOutputCursor.initial
  private var reportedStatus = TerminalLifecycleStatus.closed
  private var reportedError: String?
  private var windowObservers: [any NSObjectProtocol] = []

  private enum Pending { case feed(Data), replay(Data) }

  // ESC c: full reset, scrollback included. Replaying history starts from a clean terminal.
  private static let fullReset = Data([0x1B, 0x63])

  public init(theme: TerminalTheme = .dark, font: TerminalFont = TerminalFont()) {
    self.theme = theme
    self.font = font
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    box.view = self
    addSubview(host)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("Terminal")
  }

  public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  isolated deinit { destroySurface() }

  // MARK: Output

  /// Appends PTY output. Terminal replies it provokes (cursor position reports, ...) go to `onInput`.
  public func feed(_ text: String) { feed(Data(text.utf8)) }

  public func feed(_ data: Data) {
    guard !data.isEmpty else { return }
    guard surface != nil else { pending.append(.feed(data)); return }
    submit(data)
  }

  /// Resets the terminal and writes `history` without letting its terminal queries reach the PTY.
  /// Replies to old device queries would otherwise land at the shell prompt as junk input.
  ///
  /// Ghostty answers queries asynchronously: a reply is queued behind the bytes already waiting on
  /// its IO thread, so detaching the input callback around the feed is not enough (the replies
  /// arrive after it is back). Instead a sink drops everything while the history is processed, and
  /// the real callback returns only after the replies to a trailing `CSI 5 n` (and to any `CSI 5 n`
  /// inside the history) have drained, because replies come back in query order.
  public func reset() { replay("") }

  public func replay(_ history: String) {
    guard surface != nil else { pending = [.replay(Data(history.utf8))]; return }
    replay(Data(history.utf8))
  }

  private static let statusQuery = "\u{1B}[5n"

  private func replay(_ data: Data) {
    guard let surface else { return }
    let queries = String(decoding: data, as: UTF8.self).components(separatedBy: Self.statusQuery).count  // history's own + ours
    box.replay.withLock { $0.remaining += queries; $0.active = true }
    ghostty_surface_set_write_callback(surface, GhosttyCallbacks.replaySink, Unmanaged.passUnretained(box).toOpaque())
    submit(Self.fullReset)
    submit(data)
    submit(Data(Self.statusQuery.utf8))
    // Never leave input dead if a reply goes missing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      MainActor.assumeIsolated { self?.finishReplay(force: true) }
    }
  }

  /// True while the input callback is withheld; keystrokes in this window (tens of ms) are dropped.
  var isReplayDraining: Bool { box.replay.withLock { $0.active } }

  fileprivate func finishReplay(force: Bool = false) {
    guard let surface else { return }
    let drained = box.replay.withLock { state -> Bool in
      guard state.active, state.remaining <= 0 || force else { return false }
      state = SurfaceHostBox.ReplayState()
      return true
    }
    if drained { attachWriter(surface) }
  }

  private func submit(_ data: Data) {
    guard let surface else { return }
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      ghostty_surface_feed_data(surface, base, raw.count)
    }
  }

  private func attachWriter(_ surface: ghostty_surface_t) {
    ghostty_surface_set_write_callback(surface, GhosttyCallbacks.write, Unmanaged.passUnretained(box).toOpaque())
  }

  // MARK: Text access

  /// The visible grid as text, rows joined by newline.
  public func viewportText() -> String {
    guard let gridSize else { return "" }
    return readText(from: (0, 0), to: (gridSize.cols - 1, gridSize.rows - 1)) ?? ""
  }

  public var hasSelection: Bool { surface.map { ghostty_surface_has_selection($0) } ?? false }

  public var selectedText: String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.string(from: text)
  }

  private static func string(from text: ghostty_text_s) -> String {
    guard let pointer = text.text else { return "" }
    return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
  }

  /// Text of a viewport range (inclusive, zero-based cells), untrimmed; soft-wrapped rows join
  /// without a newline.
  func readText(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) -> String? {
    guard let surface else { return nil }
    func point(_ p: (x: Int, y: Int)) -> ghostty_point_s {
      ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(max(p.x, 0)), y: UInt32(max(p.y, 0)))
    }
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, ghostty_selection_s(top_left: point(start), bottom_right: point(end), rectangle: false), &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    return Self.string(from: text)
  }

  @objc public func copy(_ sender: Any?) {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, "copy_to_clipboard", 17)
  }

  @objc public func paste(_ sender: Any?) {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, "paste_from_clipboard", 20)
  }

  public override func selectAll(_ sender: Any?) {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, "select_all", 10)
  }

  public func scrollToBottom() {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, "scroll_to_bottom", 16)
  }

  // MARK: Session binding

  /// Renders `session` and routes input and size back to it. The owner calls `session.start()`.
  public func bind(to session: TerminalSession) {
    unbind()
    boundSession = session
    workingDirectory = session.target.cwd
    onInput = session.inputHandler
    onResize = { [weak session] cols, rows in session?.resize(cols: cols, rows: rows) }
    session.onOutputChanged = { [weak self] in self?.drainSession() }
    outputCursor = .initial
    reportedStatus = .closed
    reportedError = nil
    if let gridSize { session.resize(cols: gridSize.cols, rows: gridSize.rows) }
    drainSession()
  }

  public func unbind() {
    boundSession?.onOutputChanged = nil
    boundSession = nil
    onInput = nil
    onResize = nil
  }

  private func drainSession() {
    guard let session = boundSession else { return }
    let update = session.readOutput(since: outputCursor)
    outputCursor = update.cursor
    switch update.kind {
    case .reset: replay(update.data)
    case .append: feed(update.data)
    case .none: break
    }
    // Status lines are local to this renderer, like the web drawer's `[terminal] ...` messages.
    let buffer = session.buffer
    if buffer.error != reportedError {
      reportedError = buffer.error
      if let error = buffer.error { feed("\r\n[terminal] \(error)\r\n") }
    }
    if buffer.status != reportedStatus {
      reportedStatus = buffer.status
      if buffer.status == .exited { feed("\r\n[terminal] Process exited\r\n") }
      if buffer.status == .closed && buffer.version > 0 { feed("\r\n[terminal] Terminal closed\r\n") }
    }
  }

  // MARK: Surface lifecycle

  private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  private func makeConfig() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    if let url = TerminalGhosttyConfig.write(theme: theme, font: font) {
      url.path.withCString { ghostty_config_load_file(config, $0) }
    }
    ghostty_config_finalize(config)
    return config
  }

  private func createSurfaceIfNeeded() {
    guard surface == nil, !creationFailed, bounds.width > 0, bounds.height > 0 else { return }
    guard GhosttyProcess.initialized, let config = makeConfig() else { creationFailed = true; return }
    defer { ghostty_config_free(config) }

    let userdata = Unmanaged.passUnretained(box).toOpaque()
    var runtime = ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: false,
      wakeup_cb: GhosttyCallbacks.wakeup,
      action_cb: GhosttyCallbacks.action,
      read_clipboard_cb: GhosttyCallbacks.readClipboard,
      confirm_read_clipboard_cb: GhosttyCallbacks.confirmReadClipboard,
      write_clipboard_cb: GhosttyCallbacks.writeClipboard,
      close_surface_cb: GhosttyCallbacks.closeSurface)

    guard let createdApp = ghostty_app_new(&runtime, config) else { creationFailed = true; return }
    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(host).toOpaque()
    surfaceConfig.userdata = userdata
    surfaceConfig.scale_factor = Double(backingScale)
    surfaceConfig.font_size = Float(font.size)
    surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    surfaceConfig.use_custom_io = true
    host.frame = bounds
    guard let createdSurface = ghostty_surface_new(createdApp, &surfaceConfig) else {
      ghostty_app_free(createdApp)
      creationFailed = true
      return
    }
    app = createdApp
    surface = createdSurface
    box.app.withLock { $0 = .init(raw: createdApp) }
    box.surface.withLock { $0 = .init(raw: createdSurface) }
    attachWriter(createdSurface)
    let scheme = theme.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    ghostty_app_set_color_scheme(createdApp, scheme)
    ghostty_surface_set_color_scheme(createdSurface, scheme)
    syncSize()
    updateVisibility()
    updateFocus()
    for operation in pending {
      switch operation {
      case .feed(let data): submit(data)
      case .replay(let data): replay(data)
      }
    }
    pending = []
  }

  private func destroySurface() {
    box.app.withLock { $0 = .init(raw: nil) }
    box.surface.withLock { $0 = .init(raw: nil) }
    if let surface {
      ghostty_surface_set_write_callback(surface, nil, nil)
      ghostty_surface_free(surface)
    }
    if let app { ghostty_app_free(app) }
    surface = nil
    app = nil
  }

  private func updateConfig() {
    guard let surface, let app, let config = makeConfig() else { return }
    defer { ghostty_config_free(config) }
    ghostty_app_update_config(app, config)
    ghostty_surface_update_config(surface, config)
    let scheme = theme.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    ghostty_app_set_color_scheme(app, scheme)
    ghostty_surface_set_color_scheme(surface, scheme)
    syncSize()
  }

  // MARK: Layout

  public override func layout() {
    super.layout()
    host.frame = bounds
    createSurfaceIfNeeded()
    syncSize()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    syncSize()
  }

  private func syncSize() {
    guard let surface else { return }
    let scale = Double(backingScale)
    ghostty_surface_set_content_scale(surface, scale, scale)
    let pixels = convertToBacking(bounds.size)
    ghostty_surface_set_size(surface, UInt32(max(pixels.width.rounded(.down), 1)), UInt32(max(pixels.height.rounded(.down), 1)))
    let size = ghostty_surface_size(surface)
    cellSize = CGSize(width: Double(size.cell_width_px) / scale, height: Double(size.cell_height_px) / scale)
    let grid = (cols: max(Int(size.columns), 1), rows: max(Int(size.rows), 1))
    if gridSize?.cols != grid.cols || gridSize?.rows != grid.rows {
      gridSize = grid
      onResize?(grid.cols, grid.rows)
    }
  }

  // MARK: Window, focus, visibility

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    windowObservers.forEach(NotificationCenter.default.removeObserver)
    windowObservers = []
    if let window {
      let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification]
      windowObservers = names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateFocus(); self?.updateVisibility() }
        }
      }
    }
    syncSize()
    updateVisibility()
    updateFocus()
  }

  private func updateVisibility() {
    guard let surface else { return }
    let visible = window.map { $0.occlusionState.contains(.visible) || !$0.isVisible } ?? true
    // ponytail: an unshown (offscreen) window counts as visible so hosted tests and snapshots still render.
    ghostty_surface_set_occlusion(surface, visible)
    if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 { ghostty_surface_set_display_id(surface, id) }
  }

  private func updateFocus() {
    guard let surface else { return }
    let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
    ghostty_surface_set_focus(surface, focused)
    if let app { ghostty_app_set_focus(app, NSApp.isActive) }
  }

  public override var acceptsFirstResponder: Bool { true }
  public override func becomeFirstResponder() -> Bool { updateFocusSoon(); return true }
  public override func resignFirstResponder() -> Bool { updateFocusSoon(); return true }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // firstResponder changes after these return; read it on the next turn.
  private func updateFocusSoon() { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateFocus() } } }

  // MARK: Ghostty callbacks

  fileprivate func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
    switch shape {
    case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
    case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
    case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
    case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursor = .operationNotAllowed
    default: cursor = .arrow
    }
    window?.invalidateCursorRects(for: self)
  }

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: linkUnderMouse ? .pointingHand : cursor)
  }

  // MARK: Mouse

  private var linkUnderMouse = false

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  private func mods(_ event: NSEvent) -> ghostty_input_mods_e { Self.ghosttyMods(event.modifierFlags) }

  private func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    // Ghostty's origin is top-left, in points.
    ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(event))
    updateLinkHover(event)
  }

  public override func mouseEntered(with event: NSEvent) { sendMousePosition(event) }

  public override func mouseExited(with event: NSEvent) {
    guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
    setLinkUnderMouse(false)
  }

  public override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
  public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
  public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
  public override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let surface else { return }
    sendMousePosition(event)
    if Self.isLinkActivation(event.modifierFlags), let target = linkTarget(at: event) {
      open(target)
      return
    }
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
  }

  public override func mouseUp(with event: NSEvent) {
    guard let surface else { return }
    sendMousePosition(event)
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    onSelectionMayHaveChanged()
  }

  public override func rightMouseDown(with event: NSEvent) {
    guard let surface else { return super.rightMouseDown(with: event) }
    sendMousePosition(event)
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event)) { return }
    super.rightMouseDown(with: event)
  }

  public override func rightMouseUp(with event: NSEvent) {
    guard let surface else { return super.rightMouseUp(with: event) }
    if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event)) { return }
    super.rightMouseUp(with: event)
  }

  public override func otherMouseDown(with event: NSEvent) {
    guard let surface else { return }
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
  }

  public override func otherMouseUp(with event: NSEvent) {
    guard let surface else { return }
    _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
  }

  public override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precise = event.hasPreciseScrollingDeltas
    // Trackpads report points; Ghostty wants them doubled to feel like the native Ghostty app.
    if precise { x *= 2; y *= 2 }
    let momentum: Int32 = switch event.momentumPhase {
    case .began: 1
    case .stationary: 2
    case .changed: 3
    case .ended: 4
    case .cancelled: 5
    case .mayBegin: 6
    default: 0
    }
    ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
  }

  public override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let hasSelection = hasSelection
    menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").isEnabled = hasSelection
    menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
    if onAddSelectionToChat != nil {
      let item = menu.addItem(withTitle: "Add to Chat", action: #selector(addSelectionToChat(_:)), keyEquivalent: "")
      item.isEnabled = hasSelection
    }
    menu.items.forEach { $0.target = self }
    return menu
  }

  @objc private func addSelectionToChat(_ sender: Any?) {
    if let text = selectedText, !text.isEmpty { onAddSelectionToChat?(text) }
  }

  private func onSelectionMayHaveChanged() {}

  // MARK: Links

  private static func isLinkActivation(_ flags: NSEvent.ModifierFlags) -> Bool {
    TerminalLinks.isActivation(command: flags.contains(.command), control: flags.contains(.control))
  }

  private struct ViewportRow: TerminalBufferLine {
    let text: String
    let isWrapped: Bool
    func translateToString(trimRight: Bool) -> String {
      guard trimRight else { return text }
      var trimmed = Substring(text)
      while trimmed.last == " " { trimmed.removeLast() }
      return String(trimmed)
    }
  }

  private func viewportRow(_ index: Int) -> ViewportRow? {
    guard let gridSize, index >= 0, index < gridSize.rows, let text = readText(from: (0, index), to: (gridSize.cols - 1, index)) else { return nil }
    // Ghostty joins soft-wrapped rows without a newline, so a missing newline between two rows marks the wrap.
    let wrapped = index > 0 && (readText(from: (0, index - 1), to: (gridSize.cols - 1, index)).map { !$0.contains("\n") } ?? false)
    return ViewportRow(text: text.hasSuffix("\n") ? String(text.dropLast()) : text, isWrapped: wrapped)
  }

  /// The grid cell under a mouse event, or nil outside the grid.
  private func cell(at event: NSEvent) -> (col: Int, row: Int)? {
    guard let gridSize, cellSize.width > 0, cellSize.height > 0 else { return nil }
    let point = convert(event.locationInWindow, from: nil)
    let col = Int(((point.x - TerminalGhosttyConfig.padding.x) / cellSize.width).rounded(.down))
    let row = Int(((bounds.height - point.y - TerminalGhosttyConfig.padding.y) / cellSize.height).rounded(.down))
    guard col >= 0, row >= 0, col < gridSize.cols, row < gridSize.rows else { return nil }
    return (col, row)
  }

  private func linkTarget(at event: NSEvent) -> TerminalLinkTarget? {
    guard let cell = cell(at: event) else { return nil }
    return linkTarget(column: cell.col, row: cell.row)
  }

  /// Link under a viewport cell, found with the shared terminal-links rules on the logical
  /// (unwrapped) line the cell belongs to.
  func linkTarget(column: Int, row: Int) -> TerminalLinkTarget? {
    guard let line = TerminalLinks.collectWrappedLine(bufferLineNumber: row + 1, line: { viewportRow($0) }),
      let segment = line.segments.first(where: { $0.bufferLineNumber == row + 1 }),
      // Text of this row up to and including the cell tells where the cell sits in UTF-16 units,
      // which stays right with wide characters before it.
      let prefix = readText(from: (0, row), to: (column, row)), !prefix.isEmpty
    else { return nil }
    let offset = segment.startIndex + (prefix as NSString).length - 1
    guard let match = TerminalLinks.link(in: line.text, atUTF16Offset: offset) else { return nil }
    switch match.kind {
    case .url: return URL(string: match.text).map(TerminalLinkTarget.url)
    case .path: return .path(TerminalLinks.resolvePathTarget(match.text, cwd: workingDirectory))
    }
  }

  private func open(_ target: TerminalLinkTarget) {
    if let onOpenLink { return onOpenLink(target) }
    if case .url(let url) = target { NSWorkspace.shared.open(url) }
  }

  private func updateLinkHover(_ event: NSEvent) {
    guard Self.isLinkActivation(event.modifierFlags) else { return setLinkUnderMouse(false) }
    setLinkUnderMouse(linkTarget(at: event) != nil)
  }

  private func setLinkUnderMouse(_ value: Bool) {
    guard value != linkUnderMouse else { return }
    linkUnderMouse = value
    window?.invalidateCursorRects(for: self)
  }

  // MARK: Keyboard

  public override func keyDown(with event: NSEvent) {
    guard let surface else { return interpretKeyEvents([event]) }
    let translationMods = Self.eventModifierFlags(ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags)))
    // Hidden bits in the flags matter for dead keys, so only the four real modifiers are replaced.
    var flags = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translationMods.contains(flag) { flags.insert(flag) } else { flags.remove(flag) }
    }
    // The original event must be reused when nothing changed: Korean input depends on object identity.
    let translationEvent: NSEvent =
      flags == event.modifierFlags
      ? event
      : (NSEvent.keyEvent(
        with: event.type, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp,
        windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: flags) ?? "",
        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }
    let markedBefore = markedText.length > 0
    interpretKeyEvents([translationEvent])
    syncPreedit(clearIfNeeded: markedBefore)
    // Composing (or just finished composing) keys edit the preedit, not the terminal.
    let composing = markedText.length > 0 || markedBefore

    if let texts = keyTextAccumulator, !texts.isEmpty {
      for text in texts {
        if Self.isComposingControl(text, composing: composing) { continue }
        if markedBefore { sendCommittedText(text) } else { sendKey(action, event: event, translation: translationEvent, text: text) }
      }
      return
    }
    if Self.isComposingControl(event.characters, composing: composing) { return }
    sendKey(action, event: event, translation: translationEvent, text: Self.ghosttyCharacters(of: translationEvent), composing: composing)
  }

  public override func keyUp(with event: NSEvent) {
    sendKey(GHOSTTY_ACTION_RELEASE, event: event)
  }

  public override func flagsChanged(with event: NSEvent) {
    updateLinkHover(event)
    let modifier: UInt32
    switch event.keyCode {
    case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }
    if hasMarkedText() { return }
    let current = Self.ghosttyMods(event.modifierFlags)
    var action = GHOSTTY_ACTION_RELEASE
    if current.rawValue & modifier != 0 {
      // A modifier still set after its key went up means the opposite side is held: that is a release.
      let rawFlags = event.modifierFlags.rawValue
      let sidePressed: Bool = switch event.keyCode {
      case 0x3C: rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E: rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D: rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36: rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0
      default: true
      }
      if sidePressed { action = GHOSTTY_ACTION_PRESS }
    }
    sendKey(action, event: event)
  }

  /// AppKit offers key equivalents to the view before the menu. Only terminal bindings (copy, paste,
  /// select all, ...) are taken; ⌘T/⌘W and the rest stay with the app.
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
    var key = Self.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
    let isBinding = (event.characters ?? "").withCString { pointer -> Bool in
      key.text = pointer
      var flags = ghostty_binding_flags_e(0)
      return ghostty_surface_key_is_binding(surface, key, &flags)
    }
    if isBinding {
      keyDown(with: event)
      return true
    }
    // Ctrl+Return and Ctrl+/ never reach keyDown otherwise (AppKit turns them into menu equivalents / a beep).
    let control = event.modifierFlags.contains(.control) && event.modifierFlags.isDisjoint(with: [.command, .option])
    if control, event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "/" {
      keyDown(with: event)
      return true
    }
    return false
  }

  public override func doCommand(by selector: Selector) {
    // Swallow AppKit's text commands (moveLeft:, deleteBackward:, ...) so they do not beep; keys are encoded in keyDown.
  }

  private func sendKey(_ action: ghostty_input_action_e, event: NSEvent, translation: NSEvent? = nil, text: String? = nil, composing: Bool = false) {
    guard let surface else { return }
    var key = Self.keyEvent(event, action: action, translationMods: translation?.modifierFlags)
    key.composing = composing
    // Control characters are encoded by Ghostty itself so the physical key stays visible to protocols such as Kitty's.
    if let text, !text.isEmpty, let first = text.utf8.first, first >= 0x20 {
      text.withCString { pointer in
        key.text = pointer
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      _ = ghostty_surface_key(surface, key)
    }
  }

  private func sendCommittedText(_ text: String) {
    guard let surface else { return }
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.mods = GHOSTTY_MODS_NONE
    key.consumed_mods = GHOSTTY_MODS_NONE
    text.withCString { pointer in
      key.text = pointer
      _ = ghostty_surface_key(surface, key)
    }
  }

  private static func keyEvent(_ event: NSEvent, action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(event.keyCode)
    key.mods = ghosttyMods(event.modifierFlags)
    // Control and command never contribute to text translation; everything else is assumed to have.
    key.consumed_mods = ghosttyMods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
    if event.type == .keyDown || event.type == .keyUp, let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
      key.unshifted_codepoint = scalar.value
    }
    return key
  }

  private static func ghosttyCharacters(of event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      // Control characters are encoded by Ghostty from the key + modifiers, not from the text.
      if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
      // Function keys live in the private-use area; Ghostty must not see those code points.
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
    }
    return characters
  }

  private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
    guard composing, let scalars = text?.unicodeScalars, scalars.count == 1, let scalar = scalars.first else { return false }
    return scalar.value < 0x20
  }

  static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
  }

  static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  // MARK: NSTextInputClient (IME, dead keys, dictation)

  public func hasMarkedText() -> Bool { markedText.length > 0 }

  public func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }

  public func selectedRange() -> NSRange {
    guard let surface else { return NSRange(location: NSNotFound, length: 0) }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: NSNotFound, length: 0) }
    defer { ghostty_surface_free_text(surface, &text) }
    return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
  }

  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
    case let value as String: markedText = NSMutableAttributedString(string: value)
    default: return
    }
    // Outside a keyDown (e.g. a keyboard layout switch mid-composition) the preedit updates right away.
    if keyTextAccumulator == nil { syncPreedit() }
  }

  public func unmarkText() {
    guard markedText.length > 0 else { return }
    markedText.mutableString.setString("")
    syncPreedit()
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    guard range.length > 0, let text = selectedText else { return nil }
    return NSAttributedString(string: text)
  }

  public func characterIndex(for point: NSPoint) -> Int { 0 }

  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else { return .zero }
    var x = 0.0, y = 0.0, width = Double(cellSize.width), height = Double(cellSize.height)
    // Ghostty reports where the IME candidate window belongs (the cursor cell), top-left origin.
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let rect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, cellSize.height))
    guard let window else { return convert(rect, to: nil) }
    return window.convertToScreen(convert(rect, to: nil))
  }

  public func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil else { return }
    let text: String
    switch string {
    case let value as NSAttributedString: text = value.string
    case let value as String: text = value
    default: return
    }
    unmarkText()
    // Inside a keyDown the committed text joins the key event; otherwise (dictation, services) it is typed.
    if keyTextAccumulator != nil { keyTextAccumulator?.append(text) } else if !text.isEmpty { sendCommittedText(text) }
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedText.length > 0 {
      let string = markedText.string
      string.withCString { ghostty_surface_preedit(surface, $0, UInt(string.utf8.count)) }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  // MARK: Accessibility

  public override func accessibilityValue() -> Any? { viewportText() }
  public override func accessibilitySelectedText() -> String? { selectedText }
}

/// Ghostty's C callbacks. Declared outside the main-actor view on purpose: closures formed inside
/// a main-actor method inherit its isolation and would trap when Ghostty calls from its IO thread.
private enum GhosttyCallbacks {
  static let write: ghostty_surface_write_fn = { userdata, data, len in
    guard let box = SurfaceHostBox.from(userdata), let data, len > 0, let handler = box.input.withLock({ $0 }) else { return }
    // The session transport carries text; a stray non-UTF-8 byte (legacy mouse reports) degrades to U+FFFD.
    handler(String(decoding: UnsafeBufferPointer(start: data, count: len), as: UTF8.self))
  }

  /// Input callback while a replay drains: drops everything, counts replies to `CSI 5 n` (`CSI 0 n`).
  static let replaySink: ghostty_surface_write_fn = { userdata, data, len in
    guard let box = SurfaceHostBox.from(userdata), let data, len > 0 else { return }
    let text = String(decoding: UnsafeBufferPointer(start: data, count: len), as: UTF8.self)
    let replies = text.components(separatedBy: "\u{1B}[0n").count - 1
    guard replies > 0 else { return }
    let done = box.replay.withLock { state -> Bool in
      state.remaining -= replies
      return state.remaining <= 0
    }
    if done { onMain(box) { $0.finishReplay() } }
  }

  static let wakeup: ghostty_runtime_wakeup_cb = { userdata in SurfaceHostBox.from(userdata)?.scheduleTick() }

  static let closeSurface: ghostty_runtime_close_surface_cb = { _, _ in }

  static let confirmReadClipboard: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }

  static let action: ghostty_runtime_action_cb = { _, target, action in
    guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
      let box = SurfaceHostBox.from(ghostty_surface_userdata(surface))
    else { return false }
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      let shape = action.action.mouse_shape
      onMain(box) { $0.setCursorShape(shape) }
      return true
    case GHOSTTY_ACTION_RING_BELL:
      onMain(box) { $0.onBell?() }
      return true
    case GHOSTTY_ACTION_SET_TITLE:
      guard let cString = action.action.set_title.title else { return true }
      let title = String(cString: cString)
      onMain(box) { $0.onTitleChange?(title) }
      return true
    default:
      // Tabs, splits, window and notification actions belong to the app, not to a PTY mirror.
      return false
    }
  }

  private static func onMain(_ box: SurfaceHostBox, _ body: @escaping @MainActor (TerminalSurfaceView) -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { if let view = box.view { body(view) } }
    }
  }

  static let readClipboard: ghostty_runtime_read_clipboard_cb = { userdata, _, state, mimes, count, _ in
    guard let box = SurfaceHostBox.from(userdata), let surface = box.surface.withLock({ $0.raw }), Thread.isMainThread else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    // Only plain text is served, and only to the request that asked for it (paste).
    guard let text = TerminalPasteboard.current.string(forType: .string), let mimes else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    var bytes = Array(text.utf8)
    let requested = (0..<count).compactMap { mimes[$0] }.filter { String(cString: $0).hasPrefix("text/plain") }
    guard !requested.isEmpty else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
    bytes.withUnsafeMutableBufferPointer { buffer in
      let base = UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self)
      var contents = requested.map { ghostty_clipboard_content_s(mime: $0, data: base, len: buffer.count) }
      contents.withUnsafeMutableBufferPointer { contents in
        var complete = ghostty_clipboard_complete_s(contents: contents.baseAddress, contents_len: contents.count, available: nil, available_len: 0, confirmed: true, remember: false)
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
      }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  static let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, content, count, _ in
    guard let content, count > 0 else { return }
    for index in 0..<count {
      let item = content[index]
      guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
      let text = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: item.len), as: UTF8.self)
      DispatchQueue.main.async {
        TerminalPasteboard.current.clearContents()
        TerminalPasteboard.current.setString(text, forType: .string)
      }
      return
    }
  }
}
