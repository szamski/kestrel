import Foundation

/// Port of `apps/web/src/composer-editor-mentions.ts`: the prompt split into prose and inline
/// chips. Every chip is one character in the editor ("collapsed") and its `source` in Markdown.
public enum ComposerPromptSegment: Sendable, Hashable {
  case text(String)
  case mention(path: String, source: String)
  case skill(name: String, source: String)
  case citation(AssistantCitation, source: String)
  case contextReference(kind: String, contextId: String, label: String, source: String)

  public var isInlineToken: Bool {
    if case .text = self { return false }
    return true
  }

  /// Length in the Markdown string.
  public var sourceLength: Int {
    switch self {
    case .text(let text): text.jsLength
    case .mention(_, let source), .skill(_, let source), .citation(_, let source), .contextReference(_, _, _, let source):
      source.jsLength
    }
  }

  /// Length in the collapsed coordinate space: a chip counts one.
  public var collapsedLength: Int {
    if case .text(let text) = self { return text.jsLength }
    return 1
  }

  public var source: String {
    switch self {
    case .text(let text): text
    case .mention(_, let source), .skill(_, let source), .citation(_, let source), .contextReference(_, _, _, let source):
      source
    }
  }
}

public struct ComposerPromptToken: Sendable, Hashable {
  public enum Payload: Sendable, Hashable {
    case mention(path: String)
    case skill(name: String)
    case citation(AssistantCitation)
    case contextReference(kind: String, contextId: String, label: String)
  }
  public var payload: Payload
  public var source: String
  public var start: Int
  public var end: Int
}

public enum ComposerPromptSegments {
  /// Inline tokens plus citations and context references; an unfinished `@` mention can otherwise
  /// consume the start of a link label, so tokens overlapping a link are dropped.
  public static func collectTokens(_ text: String) -> [ComposerPromptToken] {
    let tokens = ComposerInlineTokens.collect(text)
    let citations = AssistantCitations.collect(text)
    let references = ComposerContextReferences.collect(text)
    func plain(_ token: ComposerInlineToken) -> ComposerPromptToken {
      ComposerPromptToken(
        payload: token.kind == .mention ? .mention(path: token.value) : .skill(name: token.value),
        source: token.source, start: token.start, end: token.end)
    }
    if citations.isEmpty && references.isEmpty { return tokens.map(plain) }
    var links: [ComposerPromptToken] = citations.map {
      ComposerPromptToken(payload: .citation($0.citation), source: $0.source, start: $0.start, end: $0.end)
    }
    links += references.map {
      ComposerPromptToken(
        payload: .contextReference(kind: $0.kind, contextId: $0.contextId, label: $0.label),
        source: $0.source, start: $0.start, end: $0.end)
    }
    let kept = tokens.filter { token in !links.contains { token.start < $0.end && token.end > $0.start } }.map(plain)
    return (kept + links).enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
  }

  private static func pushText(_ segments: inout [ComposerPromptSegment], _ text: String) {
    guard !text.isEmpty else { return }
    if case .text(let last)? = segments.last {
      segments[segments.count - 1] = .text(last + text)
    } else {
      segments.append(.text(text))
    }
  }

  public static func split(_ prompt: String) -> [ComposerPromptSegment] {
    var segments: [ComposerPromptSegment] = []
    guard !prompt.isEmpty else { return segments }
    var cursor = 0
    for token in collectTokens(prompt) {
      if token.start < cursor { continue }
      if token.start > cursor { pushText(&segments, prompt.jsSlice(cursor, token.start)) }
      switch token.payload {
      case .citation(let citation): segments.append(.citation(citation, source: token.source))
      case .contextReference(let kind, let contextId, let label):
        segments.append(.contextReference(kind: kind, contextId: contextId, label: label, source: token.source))
      case .mention(let path): segments.append(.mention(path: path, source: token.source))
      case .skill(let name): segments.append(.skill(name: name, source: token.source))
      }
      cursor = token.end
    }
    if cursor < prompt.jsLength { pushText(&segments, prompt.jsSlice(cursor)) }
    return segments
  }

  /// True when a selection starts or ends on the whitespace beside a mention.
  public static func selectionTouchesMentionBoundary(_ prompt: String, start: Int, end: Int) -> Bool {
    guard !prompt.isEmpty, start < end else { return false }
    for token in collectTokens(prompt) {
      guard case .mention = token.payload else { continue }
      let before = token.start - 1
      let after = token.end
      if before >= 0, let unit = prompt.jsUnit(at: before), JS.isSpace(unit), start <= before, before < end { return true }
      if after < prompt.jsLength, let unit = prompt.jsUnit(at: after), JS.isSpace(unit), start <= after, after < end { return true }
    }
    return false
  }
}
