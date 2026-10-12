import AppKit
import T3ClientRuntime
import T3Composer
import T3Contracts

/// The commands that work on the app's own state today. Commands without a handler here
/// (preview.*, rightPanel.*, diff.toggle, usage.*, theme.*, ...) stay unavailable until
/// the panel that owns them calls `CommandCenter.register`; `modelPicker.jump.N` and
/// `modelPicker.previousProvider/nextProvider` stay unavailable on purpose: the open picker
/// handles ⌘1-9 and the arrow keys itself, and an unavailable command is not consumed.
extension CommandCenter {
  func registerBuiltIns() {
    register(.chatNew, isAvailable: { [self] in app.currentGroup != nil }) { [self] in
      if let group = app.currentGroup { app.startNewThread(in: group) }
    }
    // ponytail: drafts have no worktree mode yet, so a local thread is the same draft as a new one.
    register(.chatNewLocal, isAvailable: { [self] in app.currentGroup != nil }) { [self] in
      if let group = app.currentGroup { app.startNewThread(in: group) }
    }
    register(.sidebarToggle) { NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) }
    register(.commandPaletteToggle) { [self] in palette.toggle() }
    register(.appearanceCycle) { Appearance.cycle() }
    register(.navigationBack, isAvailable: { [self] in history.canGoBack }) { [self] in goBack() }
    register(.navigationForward, isAvailable: { [self] in history.canGoForward }) { [self] in goForward() }

    // Threads, in the order the sidebar shows them.
    register(.threadPrevious, isAvailable: { [self] in !visibleThreads.isEmpty }) { [self] in step(-1) }
    register(.threadNext, isAvailable: { [self] in !visibleThreads.isEmpty }) { [self] in step(1) }
    let jumps: [KeybindingCommand] = [
      .threadJump1, .threadJump2, .threadJump3, .threadJump4, .threadJump5, .threadJump6, .threadJump7, .threadJump8, .threadJump9,
    ]
    for (index, command) in jumps.enumerated() {
      register(command, isAvailable: { [self] in index < visibleThreads.count }) { [self] in
        if index < visibleThreads.count { app.selection = visibleThreads[index] }
      }
    }

    register(.threadSettle, isAvailable: { [self] in selectedRow != nil && supports(\.threadSettlement) }) { [self] in
      guard let key = app.selection, let row = selectedRow else { return }
      let settled = row.section == .settled || row.thread.shell.settledOverride == .settled
      app.run { [runtime = app.runtime] in settled ? try await runtime.unsettleThread(key) : try await runtime.settleThread(key) }
    }
    register(.threadPin, isAvailable: { [self] in (selectedRow?.section == .pinned || selectedRow?.section == .active) && supports(\.threadPinning) }) { [self] in
      guard let key = app.selection, let row = selectedRow else { return }
      let pinned = row.section == .pinned
      app.setPinned(!pinned, key)
    }
    register(.threadStop, isAvailable: { [self] in selectedRow?.status == .working }) { [self] in
      guard let key = app.selection else { return }
      app.run { [runtime = app.runtime] in try await runtime.interruptTurn(key) }
    }
    // The web copies the linked pull request when there is one; native copies the thread id.
    register(.threadCopyReference, isAvailable: { [self] in app.selection != nil }) { [self] in
      guard let key = app.selection else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(key.threadId.rawValue, forType: .string)
    }

    // Composer of the thread or draft on screen.
    register(.modelPickerToggle, isAvailable: { [self] in activeComposer != nil }) { [self] in
      activeComposer?.isModelPickerOpen.toggle()
    }
    register(
      .threadSteerQueuedMessage,
      isAvailable: { [self] in activeComposer.map { $0.serverQueue?.items.isEmpty == false || !$0.queuedMessages.isEmpty } == true }
    ) { [self] in
      activeComposer?.steerNextQueued()
    }
    register(.composerMode, isAvailable: { [self] in activeComposer?.planModeUiEnabled == true }) { [self] in
      activeComposer?.toggleInteractionMode()
    }
    registerPullRequestCommands()
    registerPreviewCommands()
  }

  // MARK: Helpers

  private var selectedRow: SidebarRow? {
    guard let key = app.selection else { return nil }
    return app.runtime.sidebar.rows.first { $0.thread.key == key }
  }

  private var visibleThreads: [ScopedThreadKey] { app.runtime.sidebar.rows.map(\.thread.key) }

  /// Previous / next thread in the sidebar, wrapping; from no selection, next is the first and previous the last.
  private func step(_ delta: Int) {
    let threads = visibleThreads
    guard !threads.isEmpty else { return }
    let current = app.selection.flatMap { threads.firstIndex(of: $0) }
    let next = current.map { ($0 + delta + threads.count) % threads.count } ?? (delta > 0 ? 0 : threads.count - 1)
    app.selection = threads[next]
  }

  /// Whether the open thread's server supports a feature (an environment without a config yet counts as capable).
  private func supports(_ capability: KeyPath<ExecutionEnvironmentCapabilities, Bool?>) -> Bool {
    guard let key = app.selection, let config = app.runtime.serverConfigs[key.environmentId] else { return true }
    return config.config.environment.capabilities[keyPath: capability] == true
  }
}
