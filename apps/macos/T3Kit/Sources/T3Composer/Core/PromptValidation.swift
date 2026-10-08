import Foundation

/// Prompt length validation (`components/chat/composerSubmission.ts`).
public enum ComposerSubmission {
  public static let maxInputChars = 120_000

  private static func grouped(_ value: Int) -> String {
    let digits = String(value)
    var out = ""
    for (index, character) in digits.enumerated() {
      if index > 0 && (digits.count - index) % 3 == 0 { out += "," }
      out.append(character)
    }
    return out
  }

  public static func promptLengthValidationMessage(_ prompt: String) -> String? {
    let normalized = prompt.jsTrim()
    let inputLength = max(normalized.jsLength, AssistantCitations.expandForProvider(normalized).jsLength)
    let excess = inputLength - maxInputChars
    if excess <= 0 { return nil }
    return "Prompt is \(grouped(excess)) \(excess == 1 ? "character" : "characters") over the \(grouped(maxInputChars))-character limit. Shorten or split it before sending."
  }

  public enum Target: Sendable { case providerTurn, pendingUserInput }

  public static func validationMessage(prompt: String, providerInput: String? = nil, target: Target) -> String? {
    target == .providerTurn ? promptLengthValidationMessage(providerInput ?? prompt) : nil
  }

  /// Text sent in place of an empty prompt when a message is attachments only.
  public static let attachmentOnlyBootstrapPrompt =
    "[User attached one or more files without additional text. Respond using the conversation context and the attached files.]"
  public static let planImplementationPromptPrefix = "PLEASE IMPLEMENT THIS PLAN:\n"

  /// `applyClaudePromptEffortPrefix`: Claude reads "ultrathink" from the prompt text.
  public static func applyClaudePromptEffortPrefix(_ text: String, effort: String?) -> String {
    let trimmed = text.jsTrim()
    if trimmed.isEmpty { return trimmed }
    // Prefixing a slash command turns it into plain prose, so Claude never runs it.
    if effort != "ultrathink" || startsWithSlashCommand(trimmed) { return trimmed }
    if trimmed.hasPrefix("Ultrathink:") { return trimmed }
    return "Ultrathink:\n\(trimmed)"
  }

  /// `/^\/[^\s/]+(?:\s|$)/u`
  private static func startsWithSlashCommand(_ text: String) -> Bool {
    let units = Array(text.utf16)
    guard units.first == 0x2F else { return false }
    var index = 1
    while index < units.count, !JS.isSpace(units[index]), units[index] != 0x2F { index += 1 }
    return index > 1 && (index == units.count || JS.isSpace(units[index]))
  }

  /// `isClaudeUltrathinkPrompt`: `/\bultrathink\b/i`
  public static func isUltrathinkPrompt(_ text: String) -> Bool {
    let lowered = Array(text.lowercased().utf16)
    let needle = Array("ultrathink".utf16)
    func isWord(_ unit: UInt16) -> Bool {
      (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }
    var index = 0
    while index + needle.count <= lowered.count {
      if Array(lowered[index..<(index + needle.count)]) == needle,
        index == 0 || !isWord(lowered[index - 1]),
        index + needle.count == lowered.count || !isWord(lowered[index + needle.count])
      {
        return true
      }
      index += 1
    }
    return false
  }
}
