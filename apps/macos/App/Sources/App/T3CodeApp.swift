import AppKit
import SwiftUI
import T3ClientRuntime

@main
struct T3CodeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var app: AppModel
  @State private var commands: CommandCenter

  init() {
    let model = AppModel()
    AppTheme.shared.start()
    _app = State(initialValue: model)
    _commands = State(initialValue: CommandCenter(app: model))
  }

  var body: some Scene {
    Window("T3 Code", id: "main") {
      MainView()
        .environment(app)
        .environment(commands)
        .themed()
        .overlay {
          if commands.palette.isOpen {
            PaletteView(app: app, commands: commands, startMode: commands.palette.mode) { commands.palette.dismiss() }
          }
        }
        .task {
          delegate.model = app
          SettingsBindings.start(runtime: app.runtime)
          AppTheme.shared.observeEnvironment(runtime: app.runtime)
          #if DEBUG
          AppearanceDebug.runIfRequested(app: app)
          #endif
          commands.start()
          await app.start()
        }
        .onChange(of: app.selection) { _, selection in commands.selectionChanged(selection) }
    }
    .defaultSize(width: 1180, height: 780)
    .windowToolbarStyle(.unified)
    .commands { AppCommands(app: app, commands: commands) }

    Settings { SettingsView(model: SettingsModel(runtime: app.runtime)).themed() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  private var terminating = false

  /// Flushes client state and closes connections before the process goes away. The deadline runs off the main actor
  /// and is armed first: whatever `model.stop()` waits on (a connection, the server's shutdown, a blocked main
  /// actor) quit ends after 6 s at the latest, with our server SIGKILLed (the watchdog would also catch it).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    guard !terminating else { return .terminateLater }
    terminating = true
    DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
      LocalServer.killSpawned()
      _exit(0)
    }
    Task { @MainActor in
      await model.stop()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct AppCommands: Commands {
  let app: AppModel
  let commands: CommandCenter

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      CommandButton(commands: commands, command: .chatNew, title: "New Thread")
      Button("New Thread in\u{2026}") { commands.palette.present(mode: .newThreadIn) }
        .disabled(app.runtime.projectGroups.isEmpty)
      Button("Add Project\u{2026}") { commands.addProject() }
      Button("Add Environment\u{2026}") { app.sheet = .addEnvironment }
    }
    // Pasting into the composer keeps the destination's style.
    CommandGroup(after: .pasteboard) {
      Button("Paste and Match Style") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
    }
    CommandGroup(replacing: .sidebar) {
      CommandButton(commands: commands, command: .sidebarToggle, title: "Toggle Sidebar")
      CommandButton(commands: commands, command: .rightPanelToggle, title: "Toggle Right Panel")
      CommandButton(commands: commands, command: .diffToggle, title: "Toggle Diff")
      Divider()
      CommandButton(commands: commands, command: .commandPaletteToggle, title: "Command Palette")
      CommandButton(commands: commands, command: .appearanceCycle, title: "Cycle Appearance")
    }
    CommandMenu("Thread") {
      CommandButton(commands: commands, command: .threadPrevious, title: "Previous Thread")
      CommandButton(commands: commands, command: .threadNext, title: "Next Thread")
      CommandButton(commands: commands, command: .navigationBack, title: "Back")
      CommandButton(commands: commands, command: .navigationForward, title: "Forward")
      Divider()
      CommandButton(commands: commands, command: .threadSettle, title: "Settle Thread")
      CommandButton(commands: commands, command: .threadPin, title: "Pin Thread")
      CommandButton(commands: commands, command: .threadStop, title: "Stop Turn")
      CommandButton(commands: commands, command: .threadCopyReference, title: "Copy Thread ID")
      Divider()
      CommandButton(commands: commands, command: .modelPickerToggle, title: "Choose Model")
      CommandButton(commands: commands, command: .composerMode, title: "Toggle Plan Mode")
      Divider()
      Button("Archive Thread") { if let thread = app.selectedThread { app.archive(thread) } }
        .keyboardShortcut(.delete, modifiers: [.command])
        .disabled(app.selection == nil)
    }
    CommandMenu("Terminal") {
      CommandButton(commands: commands, command: .terminalToggle, title: "Toggle Terminal")
      CommandButton(commands: commands, command: .terminalNew, title: "New Terminal")
      CommandButton(commands: commands, command: .terminalSplit, title: "Split Terminal")
      CommandButton(commands: commands, command: .terminalSplitVertical, title: "Split Terminal Vertically")
      CommandButton(commands: commands, command: .terminalClose, title: "Close Terminal")
    }
  }
}
