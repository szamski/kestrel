import T3Contracts

/// A key press without AppKit: what `NSEvent` reports, in the shape the web matcher expects.
/// `key` is the layout's output (`NSEvent.charactersIgnoringModifiers`, lowercased, or a name such as
/// `enter` / `arrowup`); `code` is the physical key (`KeyB`, `BracketLeft`, ...) by ANSI position.
public struct KeyDescriptor: Sendable, Equatable {
  public var key: String
  public var code: String?
  public var meta: Bool
  public var ctrl: Bool
  public var shift: Bool
  public var alt: Bool

  public init(key: String, code: String? = nil, meta: Bool = false, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) {
    self.key = key.lowercased() == "esc" ? "escape" : key.lowercased()
    self.code = code
    self.meta = meta
    self.ctrl = ctrl
    self.shift = shift
    self.alt = alt
  }

  /// From `NSEvent.keyCode` and `charactersIgnoringModifiers`.
  public init(keyCode: UInt16, characters: String?, meta: Bool = false, ctrl: Bool = false, shift: Bool = false, alt: Bool = false) {
    self.init(
      key: Self.namedKeys[keyCode] ?? characters ?? "", code: Self.codes[keyCode], meta: meta, ctrl: ctrl, shift: shift, alt: alt)
  }

  /// Port of `matchesShortcut`: `mod` is Command, modifiers must match exactly, and the key may match
  /// by layout output or, for symbols, digits and non-Latin layouts, by physical position.
  public func matches(_ shortcut: KeybindingShortcut) -> Bool {
    guard meta == (shortcut.metaKey || shortcut.modKey), ctrl == shortcut.ctrlKey, shift == shortcut.shiftKey, alt == shortcut.altKey
    else { return false }
    return candidateKeys.contains(shortcut.key)
  }

  private static func isLatinLetter(_ s: String) -> Bool { s.count == 1 && s.unicodeScalars.first.map { $0.value >= 97 && $0.value <= 122 } == true }

  /// The key a recorded shortcut stores (`shortcutKeyFromEvent`): a Latin letter as typed, otherwise the physical
  /// symbol or digit so Shift+1 records `1`, not `!`.
  public var shortcutKey: String { Self.isLatinLetter(key) ? key : (code.flatMap { Self.symbolCodes[$0] } ?? key) }

  private var candidateKeys: Set<String> {
    var keys: Set<String> = [key]
    // The physical letter is a fallback only when the layout does not type a Latin letter itself;
    // otherwise a remapped key would trigger two different letters at once.
    if let code, code.hasPrefix("Key"), code.count == 4, !Self.isLatinLetter(key) { keys.insert(code.suffix(1).lowercased()) }
    keys.insert(Self.isLatinLetter(key) ? key : (code.flatMap { Self.symbolCodes[$0] } ?? key))
    return keys
  }

  // MARK: Tables (ANSI key codes; `EVENT_CODE_SHORTCUT_KEYS` in apps/web/src/keybindings.ts)

  private static let symbolCodes: [String: String] = [
    "Backquote": "`", "Backslash": "\\", "BracketLeft": "[", "BracketRight": "]", "Comma": ",", "Equal": "=", "Minus": "-",
    "Period": ".", "Quote": "'", "Semicolon": ";", "Slash": "/",
    "Digit0": "0", "Digit1": "1", "Digit2": "2", "Digit3": "3", "Digit4": "4", "Digit5": "5", "Digit6": "6", "Digit7": "7",
    "Digit8": "8", "Digit9": "9",
  ]

  private static let namedKeys: [UInt16: String] = [
    36: "enter", 76: "enter", 48: "tab", 49: " ", 51: "backspace", 53: "escape", 117: "delete",
    115: "home", 119: "end", 116: "pageup", 121: "pagedown", 123: "arrowleft", 124: "arrowright", 125: "arrowdown", 126: "arrowup",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
  ]

  private static let codes: [UInt16: String] = [
    0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF", 5: "KeyG", 4: "KeyH", 34: "KeyI", 38: "KeyJ", 40: "KeyK",
    37: "KeyL", 46: "KeyM", 45: "KeyN", 31: "KeyO", 35: "KeyP", 12: "KeyQ", 15: "KeyR", 1: "KeyS", 17: "KeyT", 32: "KeyU",
    9: "KeyV", 13: "KeyW", 7: "KeyX", 16: "KeyY", 6: "KeyZ",
    29: "Digit0", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 23: "Digit5", 22: "Digit6", 26: "Digit7", 28: "Digit8",
    25: "Digit9",
    50: "Backquote", 42: "Backslash", 33: "BracketLeft", 30: "BracketRight", 43: "Comma", 24: "Equal", 27: "Minus", 47: "Period",
    39: "Quote", 41: "Semicolon", 44: "Slash",
  ]
}
