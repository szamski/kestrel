import T3Contracts

/// Port of `parseKeybindingShortcut` and `parseKeybindingWhenExpression` (packages/shared/src/keybindings.ts).
/// The server sends rules already compiled, so the app does not parse at runtime; the parser serves
/// tests and any editor of `keybindings.json` that previews a rule.
public enum KeybindingParser {
  public static let maxWhenDepth = 64

  public static func shortcut(_ value: String) -> KeybindingShortcut? {
    guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var tokens = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    var trailingEmpty = 0
    while tokens.last == "" {
      trailingEmpty += 1
      tokens.removeLast()
    }
    // "mod++" and "mod+" both mean the plus key.
    if trailingEmpty > 0 { tokens.append("+") }
    if tokens.isEmpty || tokens.contains("") { return nil }

    var key: String?
    var meta = false, ctrl = false, shift = false, alt = false, mod = false
    for token in tokens {
      switch token {
      case "cmd", "meta": meta = true
      case "ctrl", "control": ctrl = true
      case "shift": shift = true
      case "alt", "option": alt = true
      case "mod": mod = true
      default:
        if key != nil { return nil }
        key = token == "space" ? " " : token == "esc" ? "escape" : token
      }
    }
    guard let key else { return nil }
    return KeybindingShortcut(key: key, metaKey: meta, ctrlKey: ctrl, shiftKey: shift, altKey: alt, modKey: mod)
  }

  // MARK: When expressions

  private enum Token: Equatable {
    case identifier(String), not, and, or, lparen, rparen
  }

  private static func tokenize(_ expression: String) -> [Token]? {
    var tokens: [Token] = []
    let chars = Array(expression)
    var index = 0
    func isIdentifierStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
    func isIdentifierPart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-") }
    while index < chars.count {
      let c = chars[index]
      if c.isWhitespace {
        index += 1
      } else if c == "&", index + 1 < chars.count, chars[index + 1] == "&" {
        tokens.append(.and)
        index += 2
      } else if c == "|", index + 1 < chars.count, chars[index + 1] == "|" {
        tokens.append(.or)
        index += 2
      } else if c == "!" {
        tokens.append(.not)
        index += 1
      } else if c == "(" {
        tokens.append(.lparen)
        index += 1
      } else if c == ")" {
        tokens.append(.rparen)
        index += 1
      } else if isIdentifierStart(c) {
        var end = index + 1
        while end < chars.count, isIdentifierPart(chars[end]) { end += 1 }
        tokens.append(.identifier(String(chars[index..<end])))
        index = end
      } else {
        return nil
      }
    }
    return tokens
  }

  /// Precedence: `!` over `&&` over `||`; parentheses group. Nesting beyond `maxWhenDepth` is rejected.
  public static func when(_ expression: String) -> KeybindingWhenNode? {
    guard let tokens = tokenize(expression), !tokens.isEmpty else { return nil }
    var index = 0

    func primary(_ depth: Int) -> KeybindingWhenNode? {
      if depth > maxWhenDepth || index >= tokens.count { return nil }
      switch tokens[index] {
      case .identifier(let name):
        index += 1
        return .identifier(KeybindingWhenNodeIdentifier(name: name))
      case .lparen:
        index += 1
        guard let inner = or(depth + 1), index < tokens.count, tokens[index] == .rparen else { return nil }
        index += 1
        return inner
      default:
        return nil
      }
    }
    func unary(_ depth: Int) -> KeybindingWhenNode? {
      var nots = 0
      while index < tokens.count, tokens[index] == .not {
        index += 1
        nots += 1
        if nots > maxWhenDepth { return nil }
      }
      guard var node = primary(depth) else { return nil }
      for _ in 0..<nots { node = .not(KeybindingWhenNodeNot(node: node)) }
      return node
    }
    func and(_ depth: Int) -> KeybindingWhenNode? {
      guard var left = unary(depth) else { return nil }
      while index < tokens.count, tokens[index] == .and {
        index += 1
        guard let right = unary(depth) else { return nil }
        left = .and(KeybindingWhenNodeAnd(left: left, right: right))
      }
      return left
    }
    func or(_ depth: Int) -> KeybindingWhenNode? {
      guard var left = and(depth) else { return nil }
      while index < tokens.count, tokens[index] == .or {
        index += 1
        guard let right = and(depth) else { return nil }
        left = .or(KeybindingWhenNodeOr(left: left, right: right))
      }
      return left
    }

    guard let ast = or(0), index == tokens.count else { return nil }
    return ast
  }
}
