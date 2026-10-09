import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Keybindings
import T3Terminal

/// Server-owned keybindings applied to the app. One path dispatches everything:
/// - `handlers` maps a `KeybindingCommand` to what it does here and whether it can run right now.
///   Other panels register theirs (`register`), e.g. the right panel for `rightPanel.toggle` / `diff.toggle`;
///   a command without a handler is unavailable.
/// - A local key monitor resolves each key press against the active environment's rules and the focus
///   context (`when`), then runs the command. Unavailable commands are not consumed, so the key keeps its
///   native meaning (⌘W closes the window while `rightPanel.close` has no handler).
/// - The menu bar shows the same bindings (`menuShortcut`); a menu item with a key equivalent only fires
///   when the monitor let the key through, which for an available command means a failed `when`.
///   ponytail: the menu path ignores `when`, so a chord claimed by the terminal could still reach its
///   menu item; the terminal view has to consume such keys itself.
@MainActor @Observable
final class CommandCenter {
  struct Handler {
    var isAvailable: () -> Bool
    var perform: () -> Void
  }

  let app: AppModel
  let palette = PaletteController()
  /// Threads the user has opened, for `navigation.back` / `navigation.forward`.
  private(set) var history = NavigationHistory<ScopedThreadKey>()
  private(set) var handlers: [KeybindingCommand: Handler] = [:]
  @ObservationIgnored private var contextProviders: [String: () -> Bool] = [:]
  @ObservationIgnored private var monitor: Any?

  init(app: AppModel) {
    self.app = app
    registerBuiltIns()
  }

  /// Installs the key monitor and applies the saved appearance. Idempotent.
  func start() {
    guard monitor == nil else { return }
    Appearance.applyStored()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // Local monitors run on the main thread; NSEvent is not Sendable, so it is handed over unchecked.
      nonisolated(unsafe) let unsafeEvent = event
      let consumed = MainActor.assumeIsolated { self?.handle(unsafeEvent) ?? false }
      return consumed ? nil : event
    }
  }

  // MARK: Registry

  func register(_ command: KeybindingCommand, isAvailable: @escaping () -> Bool = { true }, perform: @escaping () -> Void) {
    handlers[command] = Handler(isAvailable: isAvailable, perform: perform)
  }

  /// Adds a `when` identifier fed by another panel (`previewFocus`).
  func provideContext(_ id: String, _ value: @escaping () -> Bool) { contextProviders[id] = value }

  func isAvailable(_ command: KeybindingCommand) -> Bool { handlers[command]?.isAvailable() == true }

  @discardableResult
  func perform(_ command: KeybindingCommand) -> Bool {
    guard let handler = handlers[command], handler.isAvailable() else { return false }
    handler.perform()
    return true
  }

  // MARK: Bindings

  /// Rules of the environment in view (open thread, draft, else the first with a config).
  var rules: [KeybindingRule] {
    let preferred = app.selection?.environmentId ?? app.draft?.key.environmentId
    let order = ([preferred].compactMap { $0 }) + app.runtime.environments.map(\.environmentId)
    for id in order { if let config = app.runtime.serverConfigs[id] { return config.config.keybindings } }
    return []
  }

  /// The `when` identifiers that hold for key presses in `window`.
  func context(in window: NSWindow?) -> WhenContext {
    var context: WhenContext = ["isDesktop"]
    var responder = window?.firstResponder
    if responder is NSText || responder is NSTextField { context.insert("editableFocus") }
    if responder is ComposerTextView { context.insert("composerFocus") }
    while let current = responder {
      if current is TerminalSurfaceView { context.insert("terminalFocus") }
      responder = (current as? NSView)?.superview
    }
    if activeComposer?.isModelPickerOpen == true { context.insert("modelPickerOpen") }
    for (id, value) in contextProviders where value() { context.insert(id) }
    return context
  }

  /// Label of the shortcut that triggers `command` right now ("⇧⌘P"), for the palette.
  func shortcutLabel(_ command: KeybindingCommand) -> String? {
    Keybindings.effectiveShortcut(for: command, in: rules, context: context(in: NSApp.keyWindow)).map(Keybindings.label)
  }

  /// Key equivalent for a menu item: the binding that holds with nothing focused.
  func menuShortcut(_ command: KeybindingCommand) -> (key: KeyEquivalent, modifiers: EventModifiers)? {
    guard let shortcut = Keybindings.effectiveShortcut(for: command, in: rules, context: ["isDesktop"]),
      let key = Self.keyEquivalent(shortcut.key)
    else { return nil }
    var modifiers: EventModifiers = []
    if shortcut.metaKey || shortcut.modKey { modifiers.insert(.command) }
    if shortcut.ctrlKey { modifiers.insert(.control) }
    if shortcut.altKey { modifiers.insert(.option) }
    if shortcut.shiftKey { modifiers.insert(.shift) }
    return (key, modifiers)
  }

  private static func keyEquivalent(_ key: String) -> KeyEquivalent? {
    switch key {
    case "enter": .return
    case "escape": .escape
    case "tab": .tab
    case "backspace": .delete
    case "delete": .deleteForward
    case "arrowup": .upArrow
    case "arrowdown": .downArrow
    case "arrowleft": .leftArrow
    case "arrowright": .rightArrow
    default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }
  }

  // MARK: Key monitor

  /// Returns true when the key press was a binding the app ran (or deliberately swallowed).
  private func handle(_ event: NSEvent) -> Bool {
    guard let window = event.window, !(window is NSPanel), window.sheetParent == nil, window.attachedSheet == nil,
      window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") != true
    else { return false }
    // An input method composing text owns the key.
    if (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }

    let flags = event.modifierFlags
    let key = KeyDescriptor(
      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, meta: flags.contains(.command), ctrl: flags.contains(.control),
      shift: flags.contains(.shift), alt: flags.contains(.option))
    let context = context(in: window)
    // ⌘B is the composer's bold: the rich-text editor keeps it, like the web client.
    if context.contains("composerFocus"), key.meta, !key.ctrl, !key.shift, !key.alt, key.key == "b" { return false }
    guard let command = Keybindings.resolve(key, in: rules, context: context) else { return false }

    if palette.isOpen {
      // Only the palette's own shortcut acts while it is open; other bindings are swallowed rather than
      // reaching their menu items behind it.
      if command == .commandPaletteToggle, !event.isARepeat { palette.dismiss() }
      return true
    }
    guard let handler = handlers[command], handler.isAvailable() else { return false }
    if event.isARepeat, command != .threadPrevious, command != .threadNext { return true }
    handler.perform()
    return true
  }

  // MARK: Shared state for handlers

  /// The thread or draft whose composer is on screen.
  var activeKey: ScopedThreadKey? { app.selection ?? app.draft?.key }
  var activeComposer: ComposerModel? { activeKey.flatMap { LiveComposers.shared.model(for: $0.description) } }

  func selectionChanged(_ key: ScopedThreadKey?) {
    if let key { history.record(key) }
  }

  func goBack() {
    if let key = history.back(where: { app.runtime.threadShell($0) != nil }) { app.selection = key }
  }

  func goForward() {
    if let key = history.forward(where: { app.runtime.threadShell($0) != nil }) { app.selection = key }
  }
}

/// Light, dark or follow the system; `appearance.cycle` steps through them.
enum Appearance {
  private static let key = "appearance.mode"
  private static let order = ["system", "light", "dark"]

  static func applyStored() { apply(UserDefaults.standard.string(forKey: key) ?? "system") }

  static func cycle() {
    let current = UserDefaults.standard.string(forKey: key) ?? "system"
    let next = order[((order.firstIndex(of: current) ?? 0) + 1) % order.count]
    UserDefaults.standard.set(next, forKey: key)
    apply(next)
  }

  private static func apply(_ mode: String) {
    NSApp.appearance = switch mode {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
  }
}
