import Foundation

/// Terminal-style prompt recall (`components/chat/composerPromptHistory.ts`). ArrowUp on an empty
/// composer walks back through the thread's sent prompts, ArrowDown walks forward and empties the
/// composer past the newest entry. History is text only and derived from the thread's user
/// messages on every keypress, so there is no store to persist.
public struct ComposerPromptHistoryMessage: Sendable, Hashable {
  public var id: String
  public var role: String
  public var text: String

  public init(id: String, role: String, text: String) {
    self.id = id
    self.role = role
    self.text = text
  }
}

public struct ComposerPromptHistoryEntry: Sendable, Hashable {
  public var id: String
  public var prompt: String
}

/// Active recall. `entryId` is resolved against the current entries on every step; `recalled` is
/// the text put in the composer, and once the composer no longer matches it browsing is over.
public struct ComposerPromptHistoryPosition: Sendable, Hashable {
  public var entryId: String
  public var recalled: String
}

public struct ComposerPromptHistoryStep: Sendable, Hashable {
  public var position: ComposerPromptHistoryPosition?
  public var prompt: String
}

public enum ComposerPromptHistory {
  private static let ultrathinkPrefix = "Ultrathink:\n"
  private static let reviewCommentBlock = JSRegex("<review_comment\\b[^>]*>[\\s\\S]*?</review_comment>")
  private static let trailingLegacyContext = JSRegex(
    "\\n*<(terminal_context|element_context|preview_annotation)>\\n([\\s\\S]*?)\\n</\\1>[\(JS.spaceClass)]*\\z")
  private static let blankPreviewAnnotation = JSRegex("(?m)^<preview_annotation>[\(JS.spaceClass)]*$")
  private static let previewAnnotationField = JSRegex("(?m)^(?:Id|Page|Comment|Targets): ")
  private static let blockHeader = JSRegex("(?m)^- (.+):$")
  private static let terminalHeader = JSRegex("^(.+?) lines? ([0-9]+(?:-[0-9]+)?)\\z")

  /// Drop only the review comments appended at send time, which sit at the end.
  private static func stripTrailingReviewComments(_ prompt: String) -> String {
    var cut = prompt.jsLength
    for match in reviewCommentBlock.matches(in: prompt).reversed() {
      let blockEnd = match.range.upperBound
      if !prompt.jsSlice(blockEnd, cut).jsTrim().isEmpty { break }
      cut = match.range.lowerBound
    }
    return cut == prompt.jsLength ? prompt : prompt.jsSlice(0, cut).jsTrimEnd()
  }

  private static func escapeRegExp(_ value: String) -> String { NSRegularExpression.escapedPattern(for: value) }

  /// Inline terminal chips are sent as `@terminal-1:12-13` labels with their content in the
  /// trailing block; once the block is stripped the label points at nothing, so remove it too.
  private static func stripInlineTerminalLabels(_ prompt: String, headers: [String]) -> String {
    var result = prompt
    for header in headers {
      guard let match = terminalHeader.firstMatch(in: header), let name = match.group(1), let range = match.group(2) else { continue }
      let label = "@\(name.jsTrim().lowercased().jsCollapsingWhitespaceWith("-")):\(range)"
      // Whole label only: `@terminal-1:4` must not match inside `@terminal-1:40`.
      let pattern = JSRegex("(?<![A-Za-z0-9_@.-])\(escapeRegExp(label))(?![0-9-])")
      guard let found = pattern.firstMatch(in: result) else { continue }
      var start = found.range.lowerBound
      var end = start + label.jsLength
      if result.jsUnit(at: end) == 0x20 {
        end += 1
      } else if result.jsUnit(at: start - 1) == 0x20 {
        start -= 1
      }
      result = result.jsSlice(0, start) + result.jsSlice(end)
    }
    return result
  }

  /// Reduce a sent message to the text the user typed.
  public static func recallablePrompt(_ messageText: String) -> String {
    var prompt = messageText.jsTrim()
    if prompt.hasPrefix(ultrathinkPrefix) { prompt = prompt.jsSlice(ultrathinkPrefix.jsLength) }
    while !prompt.isEmpty {
      let withoutReviewComments = stripTrailingReviewComments(prompt)
      if withoutReviewComments != prompt {
        prompt = withoutReviewComments
        continue
      }
      if let legacy = trailingLegacyContext.firstMatch(in: prompt) {
        let kind = legacy.group(1) ?? ""
        let body = legacy.group(2) ?? ""
        if kind == "preview_annotation", blankPreviewAnnotation.test(body), !previewAnnotationField.test(body) { break }
        let headers = blockHeader.matches(in: body).compactMap { $0.group(1) }
        if kind != "preview_annotation" && headers.isEmpty { break }
        prompt = prompt.jsSlice(0, legacy.range.lowerBound).jsTrimEnd()
        if kind == "terminal_context" { prompt = stripInlineTerminalLabels(prompt, headers: headers) }
        continue
      }
      break
    }
    // Recall is text-only: never create dangling chips without their backing records.
    for reference in ComposerContextReferences.collect(prompt).reversed() {
      var start = reference.start
      var end = reference.end
      if prompt.jsUnit(at: end) == 0x20 {
        end += 1
      } else if prompt.jsUnit(at: start - 1) == 0x20 {
        start -= 1
      }
      prompt = prompt.jsSlice(0, start) + prompt.jsSlice(end)
    }
    // App-composed sends are not text the user typed, so they are not history.
    let trimmed = prompt.jsTrim()
    if trimmed == ComposerSubmission.attachmentOnlyBootstrapPrompt || trimmed.hasPrefix(ComposerSubmission.planImplementationPromptPrefix) {
      return ""
    }
    return trimmed
  }

  /// Oldest first. Consecutive identical prompts collapse into the newest one.
  public static func entries(from messages: [ComposerPromptHistoryMessage]) -> [ComposerPromptHistoryEntry] {
    var entries: [ComposerPromptHistoryEntry] = []
    for message in messages where message.role == "user" {
      let prompt = recallablePrompt(message.text)
      if prompt.isEmpty { continue }
      if let previous = entries.last, previous.prompt == prompt {
        entries[entries.count - 1] = ComposerPromptHistoryEntry(id: message.id, prompt: prompt)
        continue
      }
      entries.append(ComposerPromptHistoryEntry(id: message.id, prompt: prompt))
    }
    return entries
  }

  /// Prefer the id; a consecutive-duplicate collapse can retire the recalled id while the same
  /// text lives on under a newer one.
  private static func findActive(_ entries: [ComposerPromptHistoryEntry], _ position: ComposerPromptHistoryPosition) -> Int {
    if let byId = entries.firstIndex(where: { $0.id == position.entryId }) { return byId }
    return entries.lastIndex { $0.prompt == position.recalled } ?? -1
  }

  public enum Direction: String, Sendable { case backward, forward }

  /// Nil when the key should fall through to normal caret movement.
  public static func step(
    direction: Direction, entries: [ComposerPromptHistoryEntry], position: ComposerPromptHistoryPosition?, currentPrompt: String
  ) -> ComposerPromptHistoryStep? {
    let activeIndex = position.flatMap { $0.recalled == currentPrompt ? findActive(entries, $0) : -1 } ?? -1
    if direction == .backward {
      if activeIndex < 0 && !currentPrompt.isEmpty { return nil }
      let index = activeIndex < 0 ? entries.count - 1 : activeIndex - 1
      guard entries.indices.contains(index) else { return nil }
      let entry = entries[index]
      return ComposerPromptHistoryStep(position: ComposerPromptHistoryPosition(entryId: entry.id, recalled: entry.prompt), prompt: entry.prompt)
    }
    if activeIndex < 0 { return nil }
    guard entries.indices.contains(activeIndex + 1) else { return ComposerPromptHistoryStep(position: nil, prompt: "") }
    let entry = entries[activeIndex + 1]
    return ComposerPromptHistoryStep(position: ComposerPromptHistoryPosition(entryId: entry.id, recalled: entry.prompt), prompt: entry.prompt)
  }
}

extension String {
  /// `replace(/\s+/g, replacement)`
  func jsCollapsingWhitespaceWith(_ replacement: String) -> String {
    var out = ""
    var inRun = false
    var buffer: [UInt16] = []
    func flush() {
      if !buffer.isEmpty { out += String(decoding: buffer, as: UTF16.self) }
      buffer = []
    }
    for unit in utf16 {
      if JS.isSpace(unit) {
        if !inRun {
          flush()
          out += replacement
        }
        inRun = true
      } else {
        buffer.append(unit)
        inRun = false
      }
    }
    flush()
    return out
  }
}
