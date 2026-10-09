import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

struct ThreadContextMenu: View {
  @Environment(AppModel.self) private var app
  let row: SidebarRow

  var body: some View {
    let thread = row.thread
    let key = thread.key
    let runtime = app.runtime
    let shell = thread.shell
    let settled = shell.settledOverride == .settled
    let pinned = row.section == .pinned
    let snoozed = row.section == .snoozed

    Button(settled ? "Un-settle thread" : "Settle thread") {
      app.run { settled ? try await runtime.unsettleThread(key) : try await runtime.settleThread(key) }
    }
    if row.section == .pinned || row.section == .active {
      Button(pinned ? "Unpin" : "Pin") {
        app.setPinned(!pinned, key)
      }
    }
    if pinned {
      Button("Move up") { app.run { try await runtime.movePinnedThread(key, up: true) } }
      Button("Move down") { app.run { try await runtime.movePinnedThread(key, up: false) } }
    }
    Divider()
    if snoozed {
      Button("Wake") { app.run { try await runtime.unsnoozeThread(key) } }
    } else {
      Menu("Snooze") {
        ForEach(runtime.snoozePresets()) { preset in
          Button("\(preset.label)  \(preset.whenLabel)") { app.run { try await runtime.snoozeThread(key, preset: preset) } }
        }
        Divider()
        Button("Custom\u{2026}") { app.sheet = .snooze(key) }
      }
      .disabled(!row.canSnooze)
    }
    Menu("Auto-settle") {
      let disabled = shell.autoSettleDisabledAt.flatMap { $0 } != nil
      Toggle("Enabled", isOn: Binding(get: { !disabled }, set: { _ in app.run { try await runtime.setAutoSettle(key, enabled: true) } }))
      Toggle("Disabled", isOn: Binding(get: { disabled }, set: { _ in app.run { try await runtime.setAutoSettle(key, enabled: false) } }))
    }
    Divider()
    Button("Rename\u{2026}") { app.sheet = .rename(key) }
    Button(row.isUnread ? "Mark as read" : "Mark as unread") {
      Task { if row.isUnread { await runtime.markThreadRead(key) } else { await runtime.markThreadUnread(key) } }
    }
    Menu("Copy") {
      Button("Thread ID") { Self.copy(shell.id.rawValue) }
      if let path = shell.worktreePath ?? app.workspaceRoot(of: key) { Button("Path") { Self.copy(path) } }
      if let branch = shell.branch, !branch.isEmpty { Button("Branch") { Self.copy(branch) } }
    }
    Divider()
    Button("Archive") { app.archive(thread) }
    Button("Delete\u{2026}", role: .destructive) { app.delete(thread) }
  }

  private static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
