import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Terminal

/// The terminal drawer of every thread: one `TerminalDrawerModel` per thread (so tabs, splits and the
/// attached sessions survive switching threads), whether its drawer is shown, and the drawer height.
/// Mirrors `terminalUiStateStore.ts`: the open flag and height persist; the terminals themselves live on
/// the server and the layout is rebuilt from its metadata after a relaunch.
@MainActor @Observable
final class TerminalDrawers {
  static let shared = TerminalDrawers()

  private(set) var open: Set<String>
  var height: CGFloat { didSet { defaults.set(Double(height), forKey: Self.heightKey) } }
  static let defaultHeight: CGFloat = 280
  static let heightRange: ClosedRange<CGFloat> = 140...720

  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private var models: [String: TerminalDrawerModel] = [:]
  private static let openKey = "terminal.open.v1"
  private static let heightKey = "terminal.height"

  private init() {
    open = Set(defaults.stringArray(forKey: Self.openKey) ?? [])
    let stored = defaults.double(forKey: Self.heightKey)
    height = stored > 0 ? CGFloat(stored) : Self.defaultHeight
  }

  func isOpen(_ key: ScopedThreadKey) -> Bool { open.contains(key.description) }

  /// A terminal needs a directory to start in: the thread's worktree, else its project's workspace.
  func cwd(for key: ScopedThreadKey, app: AppModel) -> String? { app.runtime.threadShell(key)?.shell.worktreePath ?? app.workspaceRoot(of: key) }

  func canOpen(_ key: ScopedThreadKey, app: AppModel) -> Bool { cwd(for: key, app: app) != nil }

  func model(for key: ScopedThreadKey, app: AppModel) -> TerminalDrawerModel {
    if let existing = models[key.description] { return existing }
    let transport = RpcTerminalTransport(EnvironmentTerminalClient(runtime: app.runtime, environmentId: key.environmentId))
    let model = TerminalDrawerModel(threadId: key.threadId.rawValue, transport: transport) { [weak app] terminalId in
      // Resolved when the terminal starts, so a worktree created later is picked up by new terminals.
      // The environment is the web's `projectScriptRuntimeEnv`, which every drawer terminal gets, not just scripts.
      let worktree = app.flatMap { $0.runtime.threadShell(key)?.shell.worktreePath }
      var env: [String: String] = [:]
      if let root = app.flatMap({ $0.workspaceRoot(of: key) }) { env["T3CODE_PROJECT_ROOT"] = root }
      if let worktree { env["T3CODE_WORKTREE_PATH"] = worktree }
      return TerminalTarget(
        threadId: key.threadId.rawValue, terminalId: terminalId, cwd: app.flatMap { Self.shared.cwd(for: key, app: $0) } ?? "",
        worktreePath: worktree, env: env.isEmpty ? nil : env)
    }
    model.onDrawerEmpty = { [weak self] in self?.setOpen(false, key) }
    models[key.description] = model
    return model
  }

  func setOpen(_ shown: Bool, _ key: ScopedThreadKey) {
    if shown { open.insert(key.description) } else { open.remove(key.description) }
    defaults.set(open.sorted(), forKey: Self.openKey)
    // A hidden drawer hands the keyboard back to the thread's composer, as the web does.
    if !shown { LiveComposers.shared.model(for: key.description)?.requestFocus() }
  }

  /// "Run action": shows the drawer and runs `command` in the active terminal, or in a new tab when that one is busy
  /// (`runProjectScript` in ChatView.tsx). False when the thread has no drawer, so the caller can fall back.
  @discardableResult
  func runScript(_ command: String, in key: ScopedThreadKey, app: AppModel) -> Bool {
    guard canOpen(key, app: app) else { return false }
    let model = model(for: key, app: app)
    setOpen(true, key)
    if model.summary(for: model.layout.activeTerminalId)?.hasRunningSubprocess == true { model.newTerminal() } else { model.requestFocus() }
    let session = model.session(for: model.layout.activeTerminalId)
    Task {
      // The terminal must exist before the write, which the drawer's own attach may not have caused yet.
      try? await session.open()
      session.send("\(command)\r")
    }
    return true
  }

  func toggle(_ key: ScopedThreadKey, app: AppModel) {
    if isOpen(key) {
      setOpen(false, key)
    } else {
      setOpen(true, key)
      model(for: key, app: app).requestFocus()
    }
  }

  /// `terminal.split`, `terminal.splitVertical` and `terminal.new` show the drawer first, like the web.
  func edit(_ key: ScopedThreadKey, app: AppModel, _ change: (TerminalDrawerModel) -> Void) {
    if !isOpen(key) { setOpen(true, key) }
    change(model(for: key, app: app))
  }

  /// The commands of the thread on screen (`terminal.toggle/split/splitVertical/new/close`).
  func registerCommands(_ commands: CommandCenter, app: AppModel, key: ScopedThreadKey) {
    let here = { [self] in app.selection == key && canOpen(key, app: app) }
    commands.register(.terminalToggle, isAvailable: here) { [self] in toggle(key, app: app) }
    commands.register(.terminalSplit, isAvailable: here) { [self] in edit(key, app: app) { $0.split(vertical: false) } }
    commands.register(.terminalSplitVertical, isAvailable: here) { [self] in edit(key, app: app) { $0.split(vertical: true) } }
    commands.register(.terminalNew, isAvailable: here) { [self] in edit(key, app: app) { $0.newTerminal() } }
    commands.register(.terminalClose, isAvailable: { [self] in here() && isOpen(key) }) { [self] in
      let model = model(for: key, app: app)
      model.requestClose(model.layout.activeTerminalId)
    }
  }
}

/// The drawer under a thread's chat: a resize handle over the terminal tabs and panes.
struct ThreadTerminalDrawerView: View {
  let app: AppModel
  let key: ScopedThreadKey
  @Bindable var drawers: TerminalDrawers
  @State private var dragStart: CGFloat?

  var body: some View {
    if drawers.isOpen(key), drawers.canOpen(key, app: app) {
      VStack(spacing: 0) {
        handle
        TerminalDrawerView(
          model: drawers.model(for: key, app: app), theme: AppTheme.shared.terminalTheme, font: AppTheme.shared.terminalFont, onOpenLink: openLink)
          .frame(height: drawers.height)
      }
      .background(Palette.canvas)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Terminal")
    }
  }

  private var handle: some View {
    Divider()
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .pointerStyle(.rowResize)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let start = dragStart ?? drawers.height
            dragStart = start
            drawers.height = min(max(start - drag.translation.height, TerminalDrawers.heightRange.lowerBound), TerminalDrawers.heightRange.upperBound)
          }
          .onEnded { _ in dragStart = nil }
      )
      .accessibilityLabel("Resize terminal")
  }

  private func openLink(_ target: TerminalLinkTarget) {
    switch target {
    case .url(let url): NSWorkspace.shared.open(url)
    case .path(let path): app.open(.file(MarkdownFileTarget(path: path)), in: key)
    }
  }
}
