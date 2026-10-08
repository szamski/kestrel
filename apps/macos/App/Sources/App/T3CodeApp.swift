import AppKit
import SwiftUI
import T3ClientRuntime

@main
struct T3CodeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var app = AppModel()

  var body: some Scene {
    Window("T3 Code", id: "main") {
      MainView()
        .environment(app)
        .task {
          delegate.model = app
          await app.start()
        }
    }
    .defaultSize(width: 1180, height: 780)
    .windowToolbarStyle(.unified)
    .commands { AppCommands(app: app) }

    Settings { SettingsView().environment(app) }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// Flushes client state and closes connections before the process goes away.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task { @MainActor in
      await model.stop()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

struct AppCommands: Commands {
  let app: AppModel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Thread") { if let group = app.currentGroup { app.startNewThread(in: group) } }
        .keyboardShortcut("n")
        .disabled(app.currentGroup == nil)
      Button("Add Environment\u{2026}") { app.sheet = .addEnvironment }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }
    // Pasting into the composer keeps the destination's style.
    CommandGroup(after: .pasteboard) {
      Button("Paste and Match Style") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
    }
    CommandGroup(after: .sidebar) {
      Button("Archive Thread") { if let thread = app.selectedThread { app.archive(thread) } }
        .keyboardShortcut(.delete, modifiers: [.command])
        .disabled(app.selection == nil)
    }
  }
}

struct SettingsView: View {
  @AppStorage("confirmThreadArchive") private var confirmArchive = false

  var body: some View {
    Form {
      Toggle("Confirm before archiving a thread", isOn: $confirmArchive)
      Text("More settings arrive with later stages.").font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 440, height: 160)
  }
}
