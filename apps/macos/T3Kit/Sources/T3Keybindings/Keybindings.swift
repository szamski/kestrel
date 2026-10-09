import T3Contracts

/// The identifiers that are true right now (`terminalFocus`, `modelPickerOpen`, ...); everything else is false.
public typealias WhenContext = Set<String>

extension KeybindingWhenNode {
  /// `true` and `false` are literals. A node this build cannot read (a newer server) never matches,
  /// so a rule it cannot understand stays inert instead of firing everywhere.
  public func evaluate(_ context: WhenContext) -> Bool {
    switch self {
    case .identifier(let node):
      switch node.name {
      case "true": true
      case "false": false
      default: context.contains(node.name)
      }
    case .not(let node): !node.node.evaluate(context)
    case .and(let node): node.left.evaluate(context) && node.right.evaluate(context)
    case .or(let node): node.left.evaluate(context) || node.right.evaluate(context)
    case .unknown: false
    }
  }
}

/// What the server config delivers: `command`, `shortcut`, `whenAst`. Later rules win, like the web client.
public typealias KeybindingRule = ServerConfigKeybindingsItem

public enum Keybindings {
  /// The command a key press triggers: the last rule whose `when` holds and whose shortcut matches.
  public static func resolve(_ event: KeyDescriptor, in rules: [KeybindingRule], context: WhenContext) -> KeybindingCommand? {
    for rule in rules.reversed() {
      if let when = rule.whenAst, !when.evaluate(context) { continue }
      if event.matches(rule.shortcut) { return rule.command }
    }
    return nil
  }

  /// Two shortcuts collide when this key is equal (`mod` is Command on macOS).
  public static func conflictKey(_ shortcut: KeybindingShortcut) -> String {
    [
      shortcut.key, shortcut.metaKey || shortcut.modKey ? "meta" : "", shortcut.ctrlKey ? "ctrl" : "", shortcut.shiftKey ? "shift" : "",
      shortcut.altKey ? "alt" : "",
    ].joined(separator: "|")
  }

  /// The shortcut that actually triggers `command`: a later rule on the same chord shadows an earlier one,
  /// and rules whose `when` fails do not claim the chord. Nil when `command` is unbound or shadowed.
  public static func effectiveShortcut(for command: KeybindingCommand, in rules: [KeybindingRule], context: WhenContext) -> KeybindingShortcut? {
    var claimed = Set<String>()
    for rule in rules.reversed() {
      if let when = rule.whenAst, !when.evaluate(context) { continue }
      guard claimed.insert(conflictKey(rule.shortcut)).inserted else { continue }
      if rule.command == command { return rule.shortcut }
    }
    return nil
  }

  /// "⇧⌘D": control, option, shift, command, then the key.
  public static func label(_ shortcut: KeybindingShortcut) -> String {
    var text = ""
    if shortcut.ctrlKey { text += "\u{2303}" }
    if shortcut.altKey { text += "\u{2325}" }
    if shortcut.shiftKey { text += "\u{21E7}" }
    if shortcut.metaKey || shortcut.modKey { text += "\u{2318}" }
    return text + keyLabel(shortcut.key)
  }

  public static func keyLabel(_ key: String) -> String {
    switch key {
    case " ": "Space"
    case "escape": "\u{238B}"
    case "enter": "\u{21A9}"
    case "tab": "\u{21E5}"
    case "backspace": "\u{232B}"
    case "delete": "\u{2326}"
    case "arrowup": "\u{2191}"
    case "arrowdown": "\u{2193}"
    case "arrowleft": "\u{2190}"
    case "arrowright": "\u{2192}"
    default: key.count == 1 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
    }
  }
}
