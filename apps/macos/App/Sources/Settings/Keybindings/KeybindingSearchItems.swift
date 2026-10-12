import T3Contracts
import T3Keybindings

extension SettingsRegistry {
  /// One search result per built-in command, by label; the default keys are searchable ("mod+b" finds Sidebar: Toggle).
  /// They scroll to the command's first row and rank after every other match.
  static var keybindingItems: [SettingsSearchItem] {
    KeybindingCatalog.staticCommands.sorted { KeybindingCatalog.label($0).localizedCompare(KeybindingCatalog.label($1)) == .orderedAscending }.map { command in
      let keys = KeybindingCatalog.defaults.filter { $0.command == command }.map { KeybindingCatalog.input($0.shortcut) }
      return SettingsSearchItem(
        id: KeybindingCatalog.anchor(command), title: KeybindingCatalog.label(command), page: .keybindings, terms: ([command.rawValue] + keys).joined(separator: " "))
    }
  }
}
