import SwiftUI
import T3Contracts

/// A menu item whose title, key equivalent and enabled state come from the command center.
struct CommandButton: View {
  let commands: CommandCenter
  let command: KeybindingCommand
  let title: String

  var body: some View {
    let button = Button(title) { commands.perform(command) }.disabled(!commands.isAvailable(command))
    if let shortcut = commands.menuShortcut(command) {
      button.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    } else {
      button
    }
  }
}
