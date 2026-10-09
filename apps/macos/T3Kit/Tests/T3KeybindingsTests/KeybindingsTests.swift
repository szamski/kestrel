import Testing
import T3Contracts

@testable import T3Keybindings

private func rule(_ key: String, _ command: KeybindingCommand, when: String? = nil) -> KeybindingRule {
  KeybindingRule(command: command, shortcut: KeybindingParser.shortcut(key)!, whenAst: when.map { KeybindingParser.when($0)! })
}

private func press(_ key: String, code: String? = nil, meta: Bool = false, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) -> KeyDescriptor {
  KeyDescriptor(key: key, code: code, meta: meta, ctrl: ctrl, shift: shift, alt: alt)
}

@Suite struct ShortcutParserTests {
  @Test func parsesModifiersAndKey() {
    let s = KeybindingParser.shortcut("mod+shift+arrowup")
    #expect(s == KeybindingShortcut(key: "arrowup", metaKey: false, ctrlKey: false, shiftKey: true, altKey: false, modKey: true))
    #expect(KeybindingParser.shortcut("cmd+alt+B")?.metaKey == true)
    #expect(KeybindingParser.shortcut("Option+Esc")?.key == "escape")
    #expect(KeybindingParser.shortcut("mod+space")?.key == " ")
  }

  @Test func plusKeyAndInvalidInput() {
    #expect(KeybindingParser.shortcut("mod++")?.key == "+")
    #expect(KeybindingParser.shortcut("mod+")?.key == "+")
    #expect(KeybindingParser.shortcut("mod+a+b") == nil)
    #expect(KeybindingParser.shortcut("mod+shift") == nil)
    #expect(KeybindingParser.shortcut("mod++b") == nil)
    #expect(KeybindingParser.shortcut("") == nil)
  }
}

@Suite struct WhenExpressionTests {
  private func eval(_ expression: String, _ context: WhenContext) -> Bool? { KeybindingParser.when(expression)?.evaluate(context) }

  @Test func precedenceAndGrouping() {
    #expect(eval("!terminalFocus", []) == true)
    #expect(eval("!terminalFocus && !editableFocus", ["editableFocus"]) == false)
    // && binds tighter than ||.
    #expect(eval("a || b && c", ["a"]) == true)
    #expect(eval("(a || b) && c", ["a"]) == false)
    #expect(eval("modelPickerOpen && isDesktop", ["modelPickerOpen", "isDesktop"]) == true)
    #expect(eval("!!a", ["a"]) == true)
  }

  @Test func literalsAndUnknownIdentifiers() {
    #expect(eval("true", []) == true)
    #expect(eval("false", ["false"]) == false)
    #expect(eval("never.seen-id", []) == false)
  }

  @Test func rejectsMalformedExpressions() {
    for bad in ["", "&&", "a &&", "(a", "a)", "a b", "a & b", "!", "a $ b"] { #expect(KeybindingParser.when(bad) == nil, "\(bad)") }
    #expect(KeybindingParser.when(String(repeating: "(", count: 70) + "a" + String(repeating: ")", count: 70)) == nil)
    #expect(KeybindingParser.when(String(repeating: "(", count: 10) + "a" + String(repeating: ")", count: 10)) != nil)
  }

  @Test func unknownNodeNeverMatches() {
    #expect(KeybindingWhenNode.unknown(.null).evaluate(["x"]) == false)
  }
}

@Suite struct MatchingTests {
  @Test func modIsCommandOnMac() {
    let rules = [rule("mod+k", .commandPaletteToggle, when: "!terminalFocus")]
    #expect(Keybindings.resolve(press("k", meta: true), in: rules, context: []) == .commandPaletteToggle)
    #expect(Keybindings.resolve(press("k", ctrl: true), in: rules, context: []) == nil)
    #expect(Keybindings.resolve(press("k", meta: true, shift: true), in: rules, context: []) == nil)
    #expect(Keybindings.resolve(press("k", meta: true), in: rules, context: ["terminalFocus"]) == nil)
  }

  @Test func laterFocusedRuleOverridesGlobalRule() {
    let rules = [rule("mod+d", .diffToggle, when: "!terminalFocus"), rule("mod+d", .terminalSplit, when: "terminalFocus")]
    #expect(Keybindings.resolve(press("d", meta: true), in: rules, context: ["terminalFocus"]) == .terminalSplit)
    #expect(Keybindings.resolve(press("d", meta: true), in: rules, context: []) == .diffToggle)
  }

  @Test func laterGlobalRuleWinsWhenBothMatch() {
    let rules = [rule("mod+d", .terminalSplit, when: "terminalFocus"), rule("mod+d", .diffToggle)]
    #expect(Keybindings.resolve(press("d", meta: true), in: rules, context: ["terminalFocus"]) == .diffToggle)
  }

  @Test func bracketShortcutsMatchByPhysicalKey() {
    let rules = [rule("mod+shift+[", .threadPrevious), rule("mod+shift+]", .threadNext)]
    #expect(Keybindings.resolve(press("{", code: "BracketLeft", meta: true, shift: true), in: rules, context: []) == .threadPrevious)
    #expect(Keybindings.resolve(press("}", code: "BracketRight", meta: true, shift: true), in: rules, context: []) == .threadNext)
  }

  @Test func punctuationPositionDoesNotShadowLatinLayoutKey() {
    let rules = [rule("mod+m", .diffToggle), rule("mod+;", .sidebarToggle)]
    #expect(Keybindings.resolve(press("m", code: "Semicolon", meta: true), in: rules, context: []) == .diffToggle)
    #expect(Keybindings.resolve(press("\"", code: "Digit2", meta: true, shift: true), in: [rule("mod+shift+'", .diffToggle)], context: []) == nil)
  }

  @Test func optionAndNonLatinLettersMatchByPhysicalKey() {
    #expect(Keybindings.resolve(press("\u{222B}", code: "KeyB", meta: true, alt: true), in: [rule("mod+alt+b", .rightPanelToggle)], context: []) == .rightPanelToggle)
    let d = [rule("mod+d", .diffToggle)]
    #expect(Keybindings.resolve(press("\u{432}", code: "KeyD", meta: true), in: d, context: []) == .diffToggle)
    // A remapped layout types "a" on the physical D key: only the key that types "d" triggers.
    #expect(Keybindings.resolve(press("a", code: "KeyD", meta: true), in: d, context: []) == nil)
    #expect(Keybindings.resolve(press("d", code: "KeyL", meta: true), in: d, context: []) == .diffToggle)
  }

  @Test func descriptorFromKeyCode() {
    // ⇧⌘[ arrives as "{" on key code 33; ↑ and Return are named keys whatever characters they carry.
    let bracket = KeyDescriptor(keyCode: 33, characters: "{", meta: true, shift: true)
    #expect(bracket.matches(KeybindingParser.shortcut("mod+shift+[")!))
    #expect(KeyDescriptor(keyCode: 126, characters: "\u{F700}", meta: true, shift: true).matches(KeybindingParser.shortcut("mod+shift+arrowup")!))
    #expect(KeyDescriptor(keyCode: 36, characters: "\r", meta: true, shift: true).matches(KeybindingParser.shortcut("mod+shift+enter")!))
  }
}

@Suite struct LabelAndConflictTests {
  @Test func labelsUseMacGlyphs() {
    #expect(Keybindings.label(KeybindingParser.shortcut("mod+shift+d")!) == "\u{21E7}\u{2318}D")
    #expect(Keybindings.label(KeybindingParser.shortcut("ctrl+alt+shift+cmd+1")!) == "\u{2303}\u{2325}\u{21E7}\u{2318}1")
    #expect(Keybindings.label(KeybindingParser.shortcut("mod++")!) == "\u{2318}+")
    #expect(Keybindings.label(KeybindingParser.shortcut("mod+shift+arrowdown")!) == "\u{21E7}\u{2318}\u{2193}")
  }

  @Test func shadowedCommandHasNoEffectiveShortcut() {
    let rules = [rule("mod+shift+1", .threadJump1), rule("mod+shift+1", .threadJump7)]
    #expect(Keybindings.effectiveShortcut(for: .threadJump1, in: rules, context: []) == nil)
    #expect(Keybindings.effectiveShortcut(for: .threadJump7, in: rules, context: []).map(Keybindings.label) == "\u{21E7}\u{2318}1")
  }

  @Test func effectiveShortcutRespectsWhenContext() {
    let rules = [rule("mod+d", .diffToggle), rule("mod+d", .terminalSplit, when: "terminalFocus")]
    #expect(Keybindings.effectiveShortcut(for: .diffToggle, in: rules, context: []) != nil)
    #expect(Keybindings.effectiveShortcut(for: .diffToggle, in: rules, context: ["terminalFocus"]) == nil)
    #expect(Keybindings.effectiveShortcut(for: .terminalSplit, in: rules, context: ["terminalFocus"]) != nil)
  }

  @Test func modAndMetaCollide() {
    #expect(Keybindings.conflictKey(KeybindingParser.shortcut("mod+k")!) == Keybindings.conflictKey(KeybindingParser.shortcut("cmd+k")!))
  }
}

@Suite struct NavigationHistoryTests {
  @Test func backForwardAndTruncation() {
    var history = NavigationHistory<Int>()
    [1, 2, 3].forEach { history.record($0) }
    history.record(3)  // the entry on screen again: no-op
    #expect(history.entries == [1, 2, 3])
    #expect(history.back() == 2)
    #expect(history.back() == 1)
    #expect(history.back() == nil)
    #expect(history.forward() == 2)
    history.record(9)  // a new place drops the forward entries
    #expect(history.entries == [1, 2, 9])
    #expect(!history.canGoForward)
  }

  @Test func skipsInvalidEntries() {
    var history = NavigationHistory<Int>()
    [1, 2, 3].forEach { history.record($0) }
    #expect(history.back(where: { $0 != 2 }) == 1)
    #expect(history.forward(where: { $0 != 2 }) == 3)
  }
}
