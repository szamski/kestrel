import Foundation
import T3Contracts

public enum KeybindingSource: String, Sendable { case `default` = "Default", custom = "Custom", project = "Project" }

/// One line of the keybindings page: a rule, or (`rule == nil`) a built-in command nothing is bound to.
public struct KeybindingRow: Sendable, Identifiable, Equatable {
  public let id: String
  public let command: KeybindingCommand
  /// The server's spelling (`mod+shift+d`); empty for an unassigned command.
  public let key: String
  /// The `when` expression; empty means always.
  public let when: String
  public let source: KeybindingSource
  public let defaultKey: String?
  public let defaultWhen: String
  public let rule: KeybindingRule?
  public var conflicts: [String]

  public var isUnassigned: Bool { rule == nil }
  public var canReset: Bool { source == .custom && defaultKey != nil }
  public var canRemove: Bool { rule != nil && source != .default }
}

public struct KeybindingGroup: Sendable, Identifiable, Equatable {
  public let id: String
  public let title: String
  public let rows: [KeybindingRow]
}

/// Port of `KeybindingsSettings.logic.ts` and the defaults of `packages/shared/src/keybindings.ts`: what the settings
/// page lists, how it labels, groups and checks a binding, and how a key press becomes a shortcut string.
public enum KeybindingCatalog {
  // MARK: Defaults

  private typealias Entry = (key: String, command: String, when: String?)

  private static let defaultTable: [Entry] = baseTable + threadJumps + pickerJumps + usageTable
  private static let threadJumps: [Entry] = (1...9).map { Entry("mod+\($0)", "thread.jump.\($0)", "isDesktop") }
  private static let pickerJumps: [Entry] = (1...9).map { Entry("mod+\($0)", "modelPicker.jump.\($0)", "modelPickerOpen && isDesktop") }
  private static let usageTable: [Entry] = [
    ("c", "usage.cost", "usagePageOpen"),
    ("t", "usage.tokens", "usagePageOpen"),
    ("l", "usage.limits", "usagePageOpen"),
    ("mod+shift+1", "usage.period.day", "usagePageOpen"),
    ("mod+shift+2", "usage.period.week", "usagePageOpen"),
    ("mod+shift+3", "usage.period.month", "usagePageOpen"),
    ("mod+shift+4", "usage.period.quarter", "usagePageOpen"),
  ]

  private static let baseTable: [Entry] =
    [
      ("mod+b", "sidebar.toggle", nil),
      ("mod+[", "navigation.back", "!terminalFocus"),
      ("mod+]", "navigation.forward", "!terminalFocus"),
      ("mod+j", "terminal.toggle", nil),
      ("mod+alt+b", "rightPanel.toggle", nil),
      ("mod+t", "rightPanel.new", "rightPanelOpen && !terminalFocus"),
      ("mod+d", "terminal.split", "terminalFocus"),
      ("mod+shift+d", "terminal.splitVertical", "terminalFocus"),
      ("mod+n", "terminal.new", "terminalFocus"),
      ("mod+w", "terminal.close", "terminalFocus"),
      ("mod+w", "rightPanel.close", "!terminalFocus"),
      ("mod+shift+t", "view.reopenClosed", nil),
      ("mod+d", "diff.toggle", "!terminalFocus"),
      ("mod+shift+j", "preview.toggle", nil),
      ("mod+r", "preview.refresh", "previewFocus"),
      ("mod+l", "preview.focusUrl", "previewFocus"),
      ("mod+=", "preview.zoomIn", "previewFocus"),
      ("mod++", "preview.zoomIn", "previewFocus"),
      ("mod+-", "preview.zoomOut", "previewFocus"),
      ("mod+0", "preview.resetZoom", "previewFocus"),
      ("mod+k", "commandPalette.toggle", "!terminalFocus"),
      ("mod+p", "filePicker.toggle", "!terminalFocus"),
      ("mod+shift+f", "projectSearch.toggle", "!terminalFocus"),
      ("mod+u", "usage.open", "!terminalFocus"),
      ("mod+alt+a", "theme.select", "!terminalFocus"),
      ("mod+alt+shift+a", "appearance.cycle", "!terminalFocus"),
      ("mod+alt+shift+t", "themeEditor.toggle", nil),
      ("mod+s", "composer.stash", "!terminalFocus"),
      ("mod+shift+enter", "thread.steerQueuedMessage", "!terminalFocus"),
      ("alt+arrowup", "thread.editQueuedMessage", "composerFocus"),
      ("mod+enter", "composer.sendAlternate", "composerFocus && turnRunning"),
      ("mod+enter", "composer.sendBackground", "composerFocus && draftThreadRoute"),
      ("mod+alt+enter", "composer.sendBackground", "composerFocus && draftThreadRoute"),
      ("mod+alt+enter", "composer.sendAndNewThread", "composerFocus && !draftThreadRoute"),
      ("mod+n", "chat.new", "!terminalFocus"),
      ("mod+shift+o", "chat.new", "!terminalFocus"),
      ("mod+shift+n", "chat.newLocal", "!terminalFocus"),
      ("mod+alt+n", "chat.newWithoutProject", "!terminalFocus"),
      ("mod+f", "chat.find", "!terminalFocus && !previewFocus"),
      ("mod+shift+m", "modelPicker.toggle", "!terminalFocus"),
      ("mod+shift+h", "composer.host", "!terminalFocus"),
      ("mod+shift+e", "composer.effort", "!terminalFocus"),
      ("mod+shift+a", "composer.mode", "!terminalFocus"),
      ("mod+shift+x", "composer.workspace", "!terminalFocus"),
      ("mod+shift+g", "composer.branch", "!terminalFocus"),
      ("mod+shift+l", "composer.previousWorktree", "!terminalFocus"),
      ("mod+shift+k", "pullRequest.copyNumber", "!terminalFocus"),
      ("mod+shift+arrowup", "modelPicker.previousProvider", "modelPickerOpen"),
      ("mod+shift+arrowdown", "modelPicker.nextProvider", "modelPickerOpen"),
      ("mod+o", "editor.openFavorite", nil),
      ("mod+shift+[", "thread.previous", nil),
      ("mod+shift+]", "thread.next", nil),
      ("mod+shift+c", "thread.copyReference", "!terminalFocus"),
      ("mod+shift+s", "thread.settle", "!terminalFocus"),
      ("mod+shift+p", "thread.pin", "!terminalFocus"),
      ("mod+z", "thread.undo", "!terminalFocus && !editableFocus"),
    ]

  /// `DEFAULT_RESOLVED_KEYBINDINGS`.
  public static let defaults: [KeybindingRule] = defaultTable.compactMap { entry in
    guard let shortcut = KeybindingParser.shortcut(entry.key) else { return nil }
    return KeybindingRule(command: KeybindingCommand(rawValue: entry.command), shortcut: shortcut, whenAst: entry.when.flatMap(KeybindingParser.when))
  }

  /// `STATIC_KEYBINDING_COMMANDS`: the commands every server knows. Project scripts add `script.<id>.run` on top.
  public static let staticCommands: [KeybindingCommand] = baseCommands + pickerJumpCommands + threadCommands + threadJumpCommands
  private static let pickerJumpCommands: [KeybindingCommand] = (1...9).map { KeybindingCommand(rawValue: "modelPicker.jump.\($0)") }
  private static let threadJumpCommands: [KeybindingCommand] = (1...9).map { KeybindingCommand(rawValue: "thread.jump.\($0)") }
  private static let threadCommands: [KeybindingCommand] =
    ["thread.stop", "thread.steerQueuedMessage", "thread.editQueuedMessage", "thread.previous", "thread.next", "thread.copyReference", "thread.settle", "thread.pin", "thread.undo"]
    .map { KeybindingCommand(rawValue: $0) }
  private static let baseCommands: [KeybindingCommand] =
    [
      "sidebar.toggle", "navigation.back", "navigation.forward", "terminal.toggle", "terminal.split", "terminal.splitVertical", "terminal.new",
      "terminal.close", "rightPanel.toggle", "rightPanel.new", "threadPanel.toggle", "rightPanel.toggleMaximized", "rightPanel.close",
      "view.reopenClosed", "pullRequest.copyNumber", "diff.toggle", "preview.toggle", "preview.refresh", "preview.focusUrl", "preview.zoomIn",
      "preview.zoomOut", "preview.resetZoom", "commandPalette.toggle", "filePicker.toggle", "projectSearch.toggle", "usage.open", "theme.select",
      "appearance.cycle", "themeEditor.toggle", "composer.stash", "composer.sendAlternate", "composer.sendBackground", "composer.sendAndNewThread",
      "composer.host", "composer.cycleHost", "composer.effort", "composer.mode", "composer.workspace", "composer.previousWorktree", "composer.branch",
      "chat.new", "chat.newLocal", "chat.newWithoutProject", "chat.find", "editor.openFavorite", "usage.cost", "usage.tokens", "usage.limits",
      "usage.period.day", "usage.period.week", "usage.period.month", "usage.period.quarter", "modelPicker.toggle", "modelPicker.previousProvider",
      "modelPicker.nextProvider",
    ].map { KeybindingCommand(rawValue: $0) }

  /// `mergeWithDefaultKeybindings`: defaults for commands the server's rules do not mention, then the rules.
  public static func merged(with rules: [KeybindingRule]) -> [KeybindingRule] {
    guard !rules.isEmpty else { return defaults }
    let overridden = Set(rules.map(\.command))
    let merged = defaults.filter { !overridden.contains($0.command) } + rules
    return merged.count <= 256 ? merged : Array(merged.suffix(256))
  }

  // MARK: Spelling

  /// `shortcutToKeybindingInput`: the server's `mod+shift+d` spelling of a compiled shortcut.
  public static func input(_ shortcut: KeybindingShortcut) -> String {
    var parts: [String] = []
    if shortcut.modKey { parts.append("mod") }
    if shortcut.metaKey { parts.append("meta") }
    if shortcut.ctrlKey { parts.append("ctrl") }
    if shortcut.altKey { parts.append("alt") }
    if shortcut.shiftKey { parts.append("shift") }
    parts.append(shortcut.key == " " ? "space" : shortcut.key == "escape" ? "esc" : shortcut.key)
    return parts.joined(separator: "+")
  }

  /// `whenAstToExpression`: groups are parenthesised, `!` binds to a variable or a group.
  public static func expression(_ node: KeybindingWhenNode?) -> String {
    guard let node else { return "" }
    switch node {
    case .identifier(let n): return n.name
    case .not(let n): return "!\(wrapped(n.node))"
    case .and(let n): return "\(wrapped(n.left)) && \(wrapped(n.right))"
    case .or(let n): return "\(wrapped(n.left)) || \(wrapped(n.right))"
    case .unknown: return "unsupported"
    }
  }

  private static func wrapped(_ node: KeybindingWhenNode) -> String {
    switch node {
    case .identifier, .not, .unknown: expression(node)
    default: "(\(expression(node)))"
    }
  }

  // MARK: Labels

  private static let usageLabels: [String: String] = [
    "usage.cost": "Usage: Cost", "usage.tokens": "Usage: Tokens", "usage.limits": "Usage: Limits",
    "usage.period.day": "Usage: Period: Past 24h", "usage.period.week": "Usage: Period: 7 days",
    "usage.period.month": "Usage: Period: 30 days", "usage.period.quarter": "Usage: Period: 90 days",
  ]
  private static let usageOrder = ["usage.open", "usage.cost", "usage.tokens", "usage.limits", "usage.period.day", "usage.period.week", "usage.period.month", "usage.period.quarter"]

  public static func label(_ command: KeybindingCommand) -> String {
    let raw = command.rawValue
    switch raw {
    case "composer.sendAlternate": return "Composer: Opposite Queue or Steer Action"
    case "composer.sendBackground": return "Composer: Start in Background"
    case "composer.sendAndNewThread": return "Composer: Send and Start New Thread"
    case "thread.steerQueuedMessage": return "Queue: Send First Queued Message as Steer"
    case "thread.editQueuedMessage": return "Queue: Edit Last Queued Message"
    case "thread.copyReference": return "Pull Request: Copy Link or Thread ID"
    case "view.reopenClosed": return "Reopen Closed Tab"
    default: break
    }
    if let usage = usageLabels[raw] { return usage }
    if raw.hasPrefix("script."), raw.hasSuffix(".run") { return "Run Script: \(titleCase(String(raw.dropFirst(7).dropLast(4))))" }
    return raw.split(separator: ".", omittingEmptySubsequences: false).map { titleCase(String($0)) }.joined(separator: ": ")
  }

  private static func titleCase(_ segment: String) -> String {
    let spaced = segment.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
    return spaced.components(separatedBy: CharacterSet(charactersIn: "-_").union(.whitespacesAndNewlines)).filter { !$0.isEmpty }
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }

  /// Orders by `key`, except the Usage commands, which sort as one block in page order (`compareCommands`).
  private static func ordered(_ left: KeybindingCommand, _ right: KeybindingCommand, key: (KeybindingCommand) -> String) -> Bool {
    let leftRank = usageOrder.firstIndex(of: left.rawValue), rightRank = usageOrder.firstIndex(of: right.rawValue)
    if let leftRank, let rightRank { return leftRank < rightRank }
    let first = KeybindingCommand(rawValue: usageOrder[0])
    return key(leftRank == nil ? left : first).localizedCompare(key(rightRank == nil ? right : first)) == .orderedAscending
  }

  // MARK: Rows

  private static let groupTable: [(id: String, title: String, prefixes: [String])] = [
    ("navigation", "Navigation", ["sidebar", "rightPanel", "commandPalette", "filePicker", "projectSearch", "editor"]),
    ("threads", "Threads", ["thread", "chat", "pullRequest"]),
    ("composer", "Composer", ["composer", "modelPicker"]),
    ("terminal", "Terminal", ["terminal"]),
    ("preview", "Preview & diff", ["preview", "diff"]),
    ("appearance", "Appearance", ["theme", "appearance", "themeEditor"]),
    ("scripts", "Project scripts", ["script"]),
    ("other", "Other", []),
  ]

  private static func source(of rule: KeybindingRule) -> KeybindingSource {
    if rule.command.rawValue.hasPrefix("script.") { return .project }
    let key = input(rule.shortcut), when = expression(rule.whenAst)
    return defaults.contains { $0.command == rule.command && input($0.shortcut) == key && expression($0.whenAst) == when } ? .default : .custom
  }

  private static func defaultRule(for rule: KeybindingRule) -> KeybindingRule? {
    let key = input(rule.shortcut), when = expression(rule.whenAst)
    let same = defaults.filter { $0.command == rule.command }
    return same.first { input($0.shortcut) == key && expression($0.whenAst) == when } ?? same.first { expression($0.whenAst) == when } ?? same.first
  }

  /// Two rows collide on the same key when their conditions can hold together (`conflictsWithWhen`).
  public static func conflictLabels(_ rows: [KeybindingRow], id: String, key: String, when: String) -> [String] {
    guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    let labels = rows.filter { $0.id != id && !$0.isUnassigned && $0.key == key && ($0.when.isEmpty || when.isEmpty || $0.when == when) }.map { label($0.command) }
    return Array(Set(labels)).sorted()
  }

  /// Every binding the page lists, conflicts marked, in display order, then the built-in commands nothing is bound to.
  /// `query` filters over command id, label, key, condition and source.
  public static func rows(_ rules: [KeybindingRule], query: String = "") -> [KeybindingRow] {
    var rows = merged(with: rules).enumerated().map { index, rule -> KeybindingRow in
      let key = input(rule.shortcut), when = expression(rule.whenAst), fallback = defaultRule(for: rule)
      return KeybindingRow(
        id: "\(rule.command.rawValue)\u{0}\(key)\u{0}\(when)\u{0}\(index)", command: rule.command, key: key, when: when, source: source(of: rule),
        defaultKey: fallback.map { input($0.shortcut) }, defaultWhen: expression(fallback?.whenAst), rule: rule, conflicts: [])
    }
    for index in rows.indices { rows[index].conflicts = conflictLabels(rows, id: rows[index].id, key: rows[index].key, when: rows[index].when) }
    rows.sort { $0.command == $1.command ? $0.key.localizedCompare($1.key) == .orderedAscending : ordered($0.command, $1.command, key: \.rawValue) }
    let bound = Set(rows.map(\.command))
    let unassigned = staticCommands.filter { !bound.contains($0) }.map {
      KeybindingRow(id: "\($0.rawValue)\u{0}unassigned", command: $0, key: "", when: "", source: .default, defaultKey: nil, defaultWhen: "", rule: nil, conflicts: [])
    }
    rows += unassigned.sorted { ordered($0.command, $1.command, key: \.rawValue) }
    return filter(rows, query: query)
  }

  /// Rows whose command id, label, key, condition or source contain `query`.
  public static func filter(_ rows: [KeybindingRow], query: String) -> [KeybindingRow] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return rows }
    return rows.filter {
      [$0.command.rawValue, label($0.command), $0.key, $0.when, $0.source.rawValue].contains { $0.lowercased().contains(needle) }
    }
  }

  /// The page's sections in display order; empty ones are dropped.
  public static func groups(_ rows: [KeybindingRow]) -> [KeybindingGroup] {
    func group(_ command: KeybindingCommand) -> String {
      let prefix = command.rawValue.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
      return groupTable.first { $0.prefixes.contains(prefix) }?.id ?? "other"
    }
    return groupTable.compactMap { entry in
      let members = rows.filter { group($0.command) == entry.id }
      return members.isEmpty ? nil : KeybindingGroup(id: entry.id, title: entry.title, rows: members)
    }
  }

  /// Built-in commands plus the ones the rules add (`script.<id>.run`), by label.
  public static func commandOptions(_ rules: [KeybindingRule]) -> [KeybindingCommand] {
    var seen = Set<KeybindingCommand>()
    return (staticCommands + merged(with: rules).map(\.command)).filter { seen.insert($0).inserted }.sorted { ordered($0, $1, key: label) }
  }

  /// The id the settings search scrolls to for `command`.
  public static func anchor(_ command: KeybindingCommand) -> String { "keybinding-\(command.rawValue)" }

  // MARK: When

  private static let coreVariables = ["terminalFocus", "terminalOpen", "isWeb", "isDesktop", "true", "false"]

  /// The variables the app knows: the core ones and every identifier a default condition uses.
  public static let whenVariables: [String] = {
    var names = Set(coreVariables)
    func collect(_ node: KeybindingWhenNode?) {
      switch node {
      case .identifier(let n): names.insert(n.name)
      case .not(let n): collect(n.node)
      case .and(let n): collect(n.left); collect(n.right)
      case .or(let n): collect(n.left); collect(n.right)
      case .unknown, nil: break
      }
    }
    defaults.forEach { collect($0.whenAst) }
    return names.sorted {
      let l = coreVariables.firstIndex(of: $0), r = coreVariables.firstIndex(of: $1)
      if l != nil || r != nil { return (l ?? .max) < (r ?? .max) }
      return $0 < $1
    }
  }()

  public enum WhenDraft: Equatable, Sendable {
    case empty
    case valid(KeybindingWhenNode, expression: String, unknownVariables: [String])
    case invalid
  }

  /// Validates a `when` expression typed by the user. `expression` is its normalised spelling, what is sent to the server.
  public static func whenDraft(_ text: String) -> WhenDraft {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .empty }
    guard let node = KeybindingParser.when(trimmed) else { return .invalid }
    var unknown = Set<String>()
    func collect(_ node: KeybindingWhenNode) {
      switch node {
      case .identifier(let n): if !whenVariables.contains(n.name) { unknown.insert(n.name) }
      case .not(let n): collect(n.node)
      case .and(let n): collect(n.left); collect(n.right)
      case .or(let n): collect(n.left); collect(n.right)
      case .unknown: break
      }
    }
    collect(node)
    return .valid(node, expression: expression(node), unknownVariables: unknown.sorted())
  }

  // MARK: Recording

  /// `keybindingFromKeyboardEvent` for macOS: Command is `mod`. Nil for a key a shortcut cannot name (a modifier on its own,
  /// a dead key), so recording keeps waiting.
  public static func recordedInput(_ event: KeyDescriptor) -> String? {
    let key = event.shortcutKey
    let token: String
    switch key {
    case "meta", "control", "ctrl", "shift", "alt", "option": return nil
    case " ": token = "space"
    case "escape": token = "esc"
    case "enter", "tab", "backspace", "delete", "home", "end", "pageup", "pagedown", "arrowup", "arrowdown", "arrowleft", "arrowright": token = key
    default:
      let isFunctionKey = key.range(of: #"^f\d{1,2}$"#, options: .regularExpression) != nil
      guard key.count == 1 || isFunctionKey else { return nil }
      token = key
    }
    var parts: [String] = []
    if event.meta { parts.append("mod") }
    if event.ctrl { parts.append("ctrl") }
    if event.alt { parts.append("alt") }
    if event.shift { parts.append("shift") }
    return (parts + [token]).joined(separator: "+")
  }
}
