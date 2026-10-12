import Foundation

/// A macOS key event as the page expects it: DOM `key`/`code`, the Windows virtual key code the server's CDP input needs,
/// and the text a printable key types. Modifier-only events and dead keys (empty characters) map to nil.
public enum PreviewKeys {
  public struct Mapped: Sendable, Equatable {
    public var key: String
    public var code: String
    public var keyCode: Int
    /// Only for printable keys without Ctrl or Meta; Enter is "\r" like Puppeteer's key table.
    public var text: String?
  }

  private struct Named {
    var key: String
    var code: String
    var vk: Int
  }

  /// By `kVK_*`: keys that do not depend on the keyboard layout.
  private static let named: [UInt16: Named] = [
    0x24: Named(key: "Enter", code: "Enter", vk: 13), 0x4C: Named(key: "Enter", code: "NumpadEnter", vk: 13),
    0x30: Named(key: "Tab", code: "Tab", vk: 9), 0x33: Named(key: "Backspace", code: "Backspace", vk: 8),
    0x35: Named(key: "Escape", code: "Escape", vk: 27), 0x75: Named(key: "Delete", code: "Delete", vk: 46),
    0x73: Named(key: "Home", code: "Home", vk: 36), 0x77: Named(key: "End", code: "End", vk: 35),
    0x74: Named(key: "PageUp", code: "PageUp", vk: 33), 0x79: Named(key: "PageDown", code: "PageDown", vk: 34),
    0x7B: Named(key: "ArrowLeft", code: "ArrowLeft", vk: 37), 0x7C: Named(key: "ArrowRight", code: "ArrowRight", vk: 39),
    0x7D: Named(key: "ArrowDown", code: "ArrowDown", vk: 40), 0x7E: Named(key: "ArrowUp", code: "ArrowUp", vk: 38),
    0x7A: Named(key: "F1", code: "F1", vk: 112), 0x78: Named(key: "F2", code: "F2", vk: 113), 0x63: Named(key: "F3", code: "F3", vk: 114),
    0x76: Named(key: "F4", code: "F4", vk: 115), 0x60: Named(key: "F5", code: "F5", vk: 116), 0x61: Named(key: "F6", code: "F6", vk: 117),
    0x62: Named(key: "F7", code: "F7", vk: 118), 0x64: Named(key: "F8", code: "F8", vk: 119), 0x65: Named(key: "F9", code: "F9", vk: 120),
    0x6D: Named(key: "F10", code: "F10", vk: 121), 0x67: Named(key: "F11", code: "F11", vk: 122), 0x6F: Named(key: "F12", code: "F12", vk: 123),
  ]

  /// By `kVK_*`: the physical key's DOM `code` and Windows virtual key (ASCII for letters and digits, OEM codes for punctuation).
  private static let printable: [UInt16: (code: String, vk: Int)] = [
    0x00: ("KeyA", 65), 0x0B: ("KeyB", 66), 0x08: ("KeyC", 67), 0x02: ("KeyD", 68), 0x0E: ("KeyE", 69), 0x03: ("KeyF", 70),
    0x05: ("KeyG", 71), 0x04: ("KeyH", 72), 0x22: ("KeyI", 73), 0x26: ("KeyJ", 74), 0x28: ("KeyK", 75), 0x25: ("KeyL", 76),
    0x2E: ("KeyM", 77), 0x2D: ("KeyN", 78), 0x1F: ("KeyO", 79), 0x23: ("KeyP", 80), 0x0C: ("KeyQ", 81), 0x0F: ("KeyR", 82),
    0x01: ("KeyS", 83), 0x11: ("KeyT", 84), 0x20: ("KeyU", 85), 0x09: ("KeyV", 86), 0x0D: ("KeyW", 87), 0x07: ("KeyX", 88),
    0x10: ("KeyY", 89), 0x06: ("KeyZ", 90),
    0x1D: ("Digit0", 48), 0x12: ("Digit1", 49), 0x13: ("Digit2", 50), 0x14: ("Digit3", 51), 0x15: ("Digit4", 52),
    0x17: ("Digit5", 53), 0x16: ("Digit6", 54), 0x1A: ("Digit7", 55), 0x1C: ("Digit8", 56), 0x19: ("Digit9", 57),
    0x31: ("Space", 32), 0x1B: ("Minus", 189), 0x18: ("Equal", 187), 0x21: ("BracketLeft", 219), 0x1E: ("BracketRight", 221),
    0x2A: ("Backslash", 220), 0x29: ("Semicolon", 186), 0x27: ("Quote", 222), 0x2B: ("Comma", 188), 0x2F: ("Period", 190),
    0x2C: ("Slash", 191), 0x32: ("Backquote", 192),
    0x52: ("Numpad0", 96), 0x53: ("Numpad1", 97), 0x54: ("Numpad2", 98), 0x55: ("Numpad3", 99), 0x56: ("Numpad4", 100),
    0x57: ("Numpad5", 101), 0x58: ("Numpad6", 102), 0x59: ("Numpad7", 103), 0x5B: ("Numpad8", 104), 0x5C: ("Numpad9", 105),
    0x43: ("NumpadMultiply", 106), 0x45: ("NumpadAdd", 107), 0x4E: ("NumpadSubtract", 109), 0x41: ("NumpadDecimal", 110), 0x4B: ("NumpadDivide", 111),
  ]

  /// `characters` is what the key types with the held modifiers; `charactersIgnoringModifiers` is what it types with only Shift.
  public static func map(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?, modifiers: PreviewModifiers) -> Mapped? {
    let shortcut = modifiers.contains(.control) || modifiers.contains(.meta)
    if let named = named[keyCode] {
      return Mapped(key: named.key, code: named.code, keyCode: named.vk, text: shortcut || named.key != "Enter" ? nil : "\r")
    }
    guard let physical = printable[keyCode] else { return nil }
    // Ctrl turns letters into control characters; the page wants the letter.
    let typed = (modifiers.contains(.control) ? charactersIgnoringModifiers : characters) ?? ""
    guard typed.count == 1, let scalar = typed.unicodeScalars.first, scalar.value >= 0x20, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
    return Mapped(key: typed, code: physical.code, keyCode: physical.vk, text: shortcut ? nil : typed)
  }
}
