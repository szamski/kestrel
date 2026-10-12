import Testing
import T3Contracts

@testable import T3Keybindings

private func rule(_ key: String, _ command: String, when: String? = nil) -> KeybindingRule {
  KeybindingRule(command: KeybindingCommand(rawValue: command), shortcut: KeybindingParser.shortcut(key)!, whenAst: when.flatMap(KeybindingParser.when))
}

private func press(_ key: String, code: String? = nil, meta: Bool = false, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) -> KeyDescriptor {
  KeyDescriptor(key: key, code: code, meta: meta, ctrl: ctrl, shift: shift, alt: alt)
}

@Suite struct KeybindingRecorderTests {
  @Test func commandBecomesMod() {
    #expect(KeybindingCatalog.recordedInput(press("k", code: "KeyK", meta: true, shift: true)) == "mod+shift+k")
    #expect(KeybindingCatalog.recordedInput(press("l", ctrl: true, alt: true)) == "ctrl+alt+l")
  }

  @Test func symbolsAndDigitsUseThePhysicalKey() {
    // Shift+1 types "!" but the shortcut is `1`, as in the web client.
    #expect(KeybindingCatalog.recordedInput(press("!", code: "Digit1", meta: true, shift: true)) == "mod+shift+1")
    #expect(KeybindingCatalog.recordedInput(press("[", code: "BracketLeft", meta: true)) == "mod+[")
  }

  @Test func namedKeys() {
    #expect(KeybindingCatalog.recordedInput(press(" ", meta: true)) == "mod+space")
    #expect(KeybindingCatalog.recordedInput(press("escape")) == "esc")
    #expect(KeybindingCatalog.recordedInput(press("arrowup", alt: true)) == "alt+arrowup")
    #expect(KeybindingCatalog.recordedInput(KeyDescriptor(keyCode: 96, characters: "\u{F708}")) == "f5")
  }

  @Test func keysAShortcutCannotNameAreIgnored() {
    for key in ["shift", "Meta", "control", "alt", "option", "dead", ""] { #expect(KeybindingCatalog.recordedInput(press(key, meta: true)) == nil, "\(key)") }
  }

  @Test func recordedInputParsesBack() {
    let input = KeybindingCatalog.recordedInput(press("d", code: "KeyD", meta: true, ctrl: true, shift: true, alt: true))!
    #expect(KeybindingParser.shortcut(input).map(KeybindingCatalog.input) == "mod+ctrl+alt+shift+d")
  }
}

@Suite struct KeybindingRowTests {
  @Test func defaultsParseAndLabelsRead() {
    #expect(KeybindingCatalog.defaults.count == 81)
    #expect(KeybindingCatalog.staticCommands.allSatisfy { if case .unknown = $0 { false } else { true } })
    #expect(KeybindingCatalog.label(KeybindingCommand(rawValue: "rightPanel.toggleMaximized")) == "Right Panel: Toggle Maximized")
    #expect(KeybindingCatalog.label(KeybindingCommand(rawValue: "script.run-tests.run")) == "Run Script: Run Tests")
    #expect(KeybindingCatalog.label(KeybindingCommand(rawValue: "usage.period.week")) == "Usage: Period: 7 days")
    #expect(KeybindingCatalog.label(KeybindingCommand(rawValue: "thread.steerQueuedMessage")) == "Queue: Send First Queued Message as Steer")
  }

  @Test func defaultsMergeWithCustomRules() {
    // A custom rule replaces every default of its command and keeps the others.
    let merged = KeybindingCatalog.merged(with: [rule("mod+shift+b", "sidebar.toggle")])
    #expect(merged.filter { $0.command == .sidebarToggle }.map { KeybindingCatalog.input($0.shortcut) } == ["mod+shift+b"])
    #expect(merged.contains { $0.command == .terminalToggle })
    #expect(KeybindingCatalog.merged(with: []).count == KeybindingCatalog.defaults.count)
  }

  @Test func sourceDefaultKeyAndReset() {
    let rows = KeybindingCatalog.rows([rule("mod+shift+b", "sidebar.toggle"), rule("mod+9", "script.test.run")])
    let custom = rows.first { $0.command == .sidebarToggle }!
    #expect(custom.source == .custom && custom.defaultKey == "mod+b" && custom.canReset && custom.canRemove)
    let project = rows.first { $0.command.rawValue == "script.test.run" }!
    #expect(project.source == .project && project.canRemove && !project.canReset)
    let builtIn = rows.first { $0.command == .terminalToggle }!
    #expect(builtIn.source == .default && !builtIn.canRemove && !builtIn.canReset)
  }

  @Test func unassignedCommandsAreListed() {
    let rows = KeybindingCatalog.rows([])
    let stop = rows.first { $0.command == .threadStop }!
    #expect(stop.isUnassigned && stop.key.isEmpty && !stop.canRemove)
    #expect(KeybindingCatalog.rows([], query: "cycle host").map(\.command) == [.composerCycleHost])
  }

  @Test func conflictsFollowKeyAndCondition() {
    // mod+d is bound to terminal.split (terminalFocus) and diff.toggle (!terminalFocus): different conditions, no conflict.
    let defaultsRows = KeybindingCatalog.rows([])
    #expect(defaultsRows.first { $0.command == .diffToggle }!.conflicts.isEmpty)
    // mod+n: terminal.new (terminalFocus) vs chat.new (!terminalFocus) do not collide either.
    #expect(defaultsRows.first { $0.command == .chatNew && $0.key == "mod+n" }!.conflicts.isEmpty)
    // Unconditional rules on mod+j collide with each other and with the default terminal.toggle.
    let rows = KeybindingCatalog.rows([rule("mod+j", "sidebar.toggle"), rule("mod+j", "chat.new")])
    #expect(rows.first { $0.command == .sidebarToggle }!.conflicts == ["Chat: New", "Terminal: Toggle"])
    #expect(KeybindingCatalog.conflictLabels(rows, id: "new", key: "mod+j", when: "") == ["Chat: New", "Sidebar: Toggle", "Terminal: Toggle"])
    #expect(KeybindingCatalog.conflictLabels(rows, id: "new", key: "", when: "").isEmpty)
  }

  @Test func groupsFollowThePrefix() {
    let groups = KeybindingCatalog.groups(KeybindingCatalog.rows([rule("mod+9", "script.test.run")]))
    #expect(groups.map(\.id) == ["navigation", "threads", "composer", "terminal", "preview", "appearance", "scripts", "other"])
    let other = Set(groups.first { $0.id == "other" }!.rows.compactMap { $0.command.rawValue.split(separator: ".").first.map(String.init) })
    #expect(other == ["navigation", "threadPanel", "usage", "view"])
  }
}

@Suite struct WhenDraftTests {
  @Test func emptyValidAndInvalid() {
    #expect(KeybindingCatalog.whenDraft("  ") == .empty)
    #expect(KeybindingCatalog.whenDraft("a &&") == .invalid)
  }

  @Test func negatedGroupsRoundTrip() {
    guard case .valid(_, let expression, let unknown) = KeybindingCatalog.whenDraft("!(terminalFocus||previewFocus) && composerFocus") else {
      Issue.record("expected a valid expression")
      return
    }
    #expect(expression == "!(terminalFocus || previewFocus) && composerFocus")
    #expect(unknown.isEmpty)
    #expect(KeybindingParser.when(expression) == KeybindingParser.when("!(terminalFocus||previewFocus) && composerFocus"))
  }

  @Test func unknownVariablesAreReported() {
    guard case .valid(_, _, let unknown) = KeybindingCatalog.whenDraft("terminalFocus && nonsense") else {
      Issue.record("expected a valid expression")
      return
    }
    #expect(unknown == ["nonsense"])
  }
}
