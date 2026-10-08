import Foundation

public enum ComposerTriggerKind: String, Sendable, Hashable, Codable {
  case path
  case pullRequest = "pull-request"
  case slashCommand = "slash-command"
  /// Only produced by `ComposerLogic.detectSharedTrigger` (the `/model <query>` form).
  case slashModel = "slash-model"
  case skill
}

public enum ComposerSlashCommand: String, Sendable, Hashable, Codable {
  case model, plan, `default`
}

public enum ComposerSubmissionIntent: String, Sendable, Hashable, Codable {
  case foreground, background, alternate
}

public enum SendShortcut: String, Sendable, Hashable, Codable, CaseIterable {
  case enter
  case modEnterMultiline = "mod-enter-multiline"
  case modEnter = "mod-enter"
}

public struct ComposerTrigger: Sendable, Hashable {
  public var kind: ComposerTriggerKind
  public var query: String
  public var rangeStart: Int
  public var rangeEnd: Int

  public init(kind: ComposerTriggerKind, query: String, rangeStart: Int, rangeEnd: Int) {
    self.kind = kind
    self.query = query
    self.rangeStart = rangeStart
    self.rangeEnd = rangeEnd
  }
}

/// Port of `apps/web/src/composer-logic.ts` (cursor coordinate systems, trigger detection,
/// Enter intent) and `packages/shared/src/composerTrigger.ts`.
///
/// Two cursor spaces meet here: the *expanded* cursor indexes the Markdown string, the *collapsed*
/// cursor treats every inline chip as one character (what the editor and the draft store use).
public enum ComposerLogic {
  public static func formatAssistantCitation(_ citation: AssistantCitation, comment: String = "") -> String {
    AssistantCitations.formatForComposer(citation, comment: comment)
  }

  public static func submissionIntentForEnter(
    isMobileViewport: Bool,
    shiftKey: Bool,
    modifierKey: Bool,
    isDraftThread: Bool,
    isRunning: Bool = false,
    sendShortcut: SendShortcut? = nil,
    prompt: String = ""
  ) -> ComposerSubmissionIntent? {
    let hasLineBreak = prompt.utf16.contains { $0 == 0x0A || $0 == 0x0D }
    let requiresModifier = sendShortcut == .modEnter || (sendShortcut == .modEnterMultiline && hasLineBreak)
    if isMobileViewport || (requiresModifier && !modifierKey) { return nil }
    if shiftKey && !(requiresModifier && modifierKey && isRunning) { return nil }
    if isRunning && modifierKey && (!requiresModifier || shiftKey) { return .alternate }
    return modifierKey && isDraftThread ? .background : .foreground
  }

  static func clampCursor(_ text: String, _ cursor: Int) -> Int {
    max(0, min(text.jsLength, cursor))
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
  }

  private static func tokenStart(units: [UInt16], cursor: Int) -> Int {
    var index = cursor - 1
    while index >= 0, !isWhitespace(units[index]) { index -= 1 }
    return index + 1
  }

  // MARK: Cursor coordinate systems

  public static func expandCollapsedCursor(_ text: String, _ cursorInput: Int) -> Int {
    let collapsed = clampCursor(text, cursorInput)
    let segments = ComposerPromptSegments.split(text)
    if segments.isEmpty { return collapsed }
    var remaining = collapsed
    var expanded = 0
    for segment in segments {
      if segment.isInlineToken {
        let length = segment.sourceLength
        if remaining <= 1 { return expanded + (remaining == 0 ? 0 : length) }
        remaining -= 1
        expanded += length
        continue
      }
      let length = segment.sourceLength
      if remaining <= length { return expanded + remaining }
      remaining -= length
      expanded += length
    }
    return expanded
  }

  public static func clampCollapsedCursor(_ text: String, _ cursorInput: Int) -> Int {
    clampCollapsedCursor(segments: ComposerPromptSegments.split(text), cursorInput)
  }

  static func clampCollapsedCursor(segments: [ComposerPromptSegment], _ cursorInput: Int) -> Int {
    let length = segments.reduce(0) { $0 + $1.collapsedLength }
    return max(0, min(length, cursorInput))
  }

  public static func collapseExpandedCursor(_ text: String, _ cursorInput: Int) -> Int {
    let expanded = clampCursor(text, cursorInput)
    let segments = ComposerPromptSegments.split(text)
    if segments.isEmpty { return expanded }
    var remaining = expanded
    var collapsed = 0
    for segment in segments {
      if segment.isInlineToken {
        let length = segment.sourceLength
        if remaining == 0 { return collapsed }
        if remaining <= length { return collapsed + 1 }
        remaining -= length
        collapsed += 1
        continue
      }
      let length = segment.sourceLength
      if remaining <= length { return collapsed + remaining }
      remaining -= length
      collapsed += length
    }
    return collapsed
  }

  public enum Direction: String, Sendable { case left, right }

  public static func isCollapsedCursorAdjacentToInlineToken(_ text: String, _ cursorInput: Int, _ direction: Direction) -> Bool {
    let segments = ComposerPromptSegments.split(text)
    guard segments.contains(where: \.isInlineToken) else { return false }
    let cursor = clampCollapsedCursor(segments: segments, cursorInput)
    var offset = 0
    for segment in segments {
      if segment.isInlineToken {
        if direction == .left && cursor == offset + 1 { return true }
        if direction == .right && cursor == offset { return true }
      }
      offset += segment.collapsedLength
    }
    return false
  }

  // MARK: Triggers

  private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .decimalNumber, .letterNumber, .otherNumber:
      true
    default: false
    }
  }

  /// `/^#([\p{L}\p{N}][\p{L}\p{N}_-]*)?$/u`; returns the query, or nil when the token is not one.
  static func pullRequestQuery(_ token: String) -> String? {
    guard token.hasPrefix("#") else { return nil }
    let rest = Array(token.unicodeScalars.dropFirst())
    if rest.isEmpty { return "" }
    guard isLetterOrNumber(rest[0]) else { return nil }
    for scalar in rest.dropFirst() where !(isLetterOrNumber(scalar) || scalar == "_" || scalar == "-") { return nil }
    return String(String.UnicodeScalarView(rest))
  }

  /// Detect an active trigger (`@path`, `$skill`, `#pull-request`, `/command`) at the cursor.
  public static func detectTrigger(_ text: String, _ cursorInput: Int) -> ComposerTrigger? {
    detect(text, cursorInput, shared: false)
  }

  /// `packages/shared/src/composerTrigger.ts`: the variant that also understands `/model <query>`.
  public static func detectSharedTrigger(_ text: String, _ cursorInput: Int) -> ComposerTrigger? {
    detect(text, cursorInput, shared: true)
  }

  private static func detect(_ text: String, _ cursorInput: Int, shared: Bool) -> ComposerTrigger? {
    let units = Array(text.utf16)
    let cursor = max(0, min(units.count, cursorInput))
    var found = -1
    var index = min(max(0, cursor - 1), units.count - 1)
    while index >= 0 {
      if units[index] == 0x0A {
        found = index
        break
      }
      index -= 1
    }
    let lineStart = found + 1
    let prefix = Array(units[min(lineStart, cursor)..<cursor])
    if prefix.first == 0x2F {
      if !prefix.dropFirst().contains(where: JS.isSpace) {
        let query = String(decoding: prefix.dropFirst(), as: UTF16.self)
        if shared && query.lowercased() == "model" {
          return ComposerTrigger(kind: .slashModel, query: "", rangeStart: lineStart, rangeEnd: cursor)
        }
        return ComposerTrigger(kind: .slashCommand, query: query, rangeStart: lineStart, rangeEnd: cursor)
      }
      // /^\/model(?:\s+(.*))?$/: `\s+` takes the whole whitespace run and `.` stops at \r, U+2028/9.
      let line = String(decoding: prefix, as: UTF16.self)
      if shared, line.hasPrefix("/model") {
        let rest = line.jsSlice(6)
        if let first = rest.utf16.first, JS.isSpace(first) {
          let body = rest.jsTrimStart()
          if !body.utf16.contains(where: { $0 == 0x0D || $0 == 0x2028 || $0 == 0x2029 }) {
            return ComposerTrigger(kind: .slashModel, query: body.jsTrim(), rangeStart: lineStart, rangeEnd: cursor)
          }
        }
      }
    }
    let start = tokenStart(units: units, cursor: cursor)
    let token = String(decoding: units[start..<cursor], as: UTF16.self)
    if let query = pullRequestQuery(token) {
      return ComposerTrigger(kind: .pullRequest, query: query, rangeStart: start, rangeEnd: cursor)
    }
    if let first = token.unicodeScalars.first, first.properties.generalCategory == .currencySymbol {
      return ComposerTrigger(
        kind: .skill, query: token.jsSlice(String(first).jsLength), rangeStart: start, rangeEnd: cursor)
    }
    guard token.hasPrefix("@") else { return nil }
    return ComposerTrigger(kind: .path, query: token.jsSlice(1), rangeStart: start, rangeEnd: cursor)
  }

  /// Caret and trigger after replacing composer text and continuing at the end.
  public static func stateAtPromptEnd(_ text: String) -> (cursor: Int, trigger: ComposerTrigger?) {
    let cursor = collapseExpandedCursor(text, text.jsLength)
    return (cursor, detectTrigger(text, expandCollapsedCursor(text, cursor)))
  }

  /// `/plan` or `/default` alone in the composer.
  public static func parseStandaloneSlashCommand(_ text: String) -> ComposerSlashCommand? {
    switch text.jsTrim().lowercased() {
    case "/plan": .plan
    case "/default": .default
    default: nil
    }
  }

  public static func replaceTextRange(_ text: String, rangeStart: Int, rangeEnd: Int, replacement: String) -> (text: String, cursor: Int) {
    let length = text.jsLength
    let start = max(0, min(length, rangeStart))
    let end = max(start, min(length, rangeEnd))
    return (text.jsSlice(0, start) + replacement + text.jsSlice(end), start + replacement.jsLength)
  }
}
