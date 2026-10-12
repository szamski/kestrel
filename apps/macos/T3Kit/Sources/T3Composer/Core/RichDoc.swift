import Foundation

/// The inline chips of the rich composer document.
public enum RichAtom: Sendable, Hashable {
  case mention(path: String, source: String)
  case skill(name: String, label: String, description: String?)
  case citation(AssistantCitation, source: String)
  case contextReference(kind: String, contextId: String, label: String, source: String)

  /// The Markdown a chip serializes to.
  public var source: String {
    switch self {
    case .mention(_, let source), .citation(_, let source), .contextReference(_, _, _, let source): source
    case .skill(let name, _, _): name.isEmpty ? "" : "$\(name)"
    }
  }

  public var nodeName: String {
    switch self {
    case .mention: "composer-mention"
    case .skill: "composer-skill"
    case .citation: "composer-citation"
    case .contextReference: "composer-context-reference"
    }
  }
}

public enum RichInline: Sendable, Hashable {
  case text(String, marks: [RichTextMark])
  case atom(RichAtom, marks: [RichTextMark])

  var marks: [RichTextMark] {
    switch self {
    case .text(_, let marks), .atom(_, let marks): marks
    }
  }
}

/// One item of a bullet, ordered or task list. `prefix` keeps the exact source marker and spacing so a
/// list round-trips byte-identically; nested lists are `children`, in order (a parent can hold lists of
/// different kinds).
public struct RichListItem: Sendable, Hashable {
  public enum Prefix: Sendable, Hashable {
    case task(checked: Bool, indent: String, markerSpace: String, contentSpace: String)
    /// A bullet (`-`, `*`, `+`) or ordered (`3.`, `3)`) marker; `space` is what followed it.
    case marker(indent: String, marker: String, space: String)

    public var indent: String {
      switch self {
      case .task(_, let indent, _, _), .marker(let indent, _, _): indent
      }
    }
  }

  public var prefix: Prefix
  public var content: [RichInline]
  public var children: [RichList]

  public init(prefix: Prefix, content: [RichInline] = [], children: [RichList] = []) {
    self.prefix = prefix
    self.content = content
    self.children = children
  }
}

public struct RichList: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case bullet
    /// `start` is the first marker's number (`parseInt(marker) || 1`).
    case ordered(start: Double)
    case task
  }

  public var kind: Kind
  public var items: [RichListItem]

  public init(kind: Kind, items: [RichListItem]) {
    self.kind = kind
    self.items = items
  }
}

public enum RichBlock: Sendable, Hashable {
  case paragraph([RichInline])
  case heading(level: Int, space: String, content: [RichInline])
  /// One paragraph per source line, all behind the same `>` prefix.
  case quote(prefix: String, lines: [[RichInline]])
  /// A fence keeps its exact delimiters: `fence` is the opening run, `close` the closing newline and fence
  /// (empty when never closed). The code is literal text, chips included as their source.
  case codeBlock(fence: String, language: String, close: String, text: String)
  case rule(source: String)
  case list(RichList)
}

public struct SkillMeta: Sendable, Hashable {
  public var label: String
  public var description: String?

  public init(label: String, description: String? = nil) {
    self.label = label
    self.description = description
  }
}

/// One serialized piece of the document in all coordinate spaces (see `RichDocMap`).
public struct RichRun: Sendable, Hashable {
  public enum Kind: String, Sendable { case text, token, `break`, prefix }
  public var kind: Kind
  /// Flat editor offset (chips count 1, markers excluded).
  public var flatStart: Int
  public var docLen: Int
  /// Collapsed cursor length (markers literal, chips count 1).
  public var collapsedLen: Int
  /// Markdown length (chips expand to their source).
  public var mdLen: Int
  public var openLen: Int
  public var closeLen: Int
  public var mdStart: Int
  public var collapsedStart: Int
  /// For chips: the editor node kind (`composer-mention`, `composer-skill`, ...).
  public var nodeName: String?
}

/// Serialized document: canonical Markdown plus the run table that converts cursor offsets between
/// the three coordinate spaces.
///
/// - flat ("editor"): chips count 1, style markers excluded, paragraph boundaries count 1
/// - collapsed: style markers literal, chips count 1; what the draft store and mention detection use
/// - markdown: markers literal, chips expand to their source
public struct RichDocMap: Sendable, Hashable {
  public var value: String
  public var runs: [RichRun]
  public var docLength: Int
  public var contextIds: [String]

  private func lastRunEnd(collapsed: Bool) -> Int {
    guard let last = runs.last else { return 0 }
    return collapsed ? last.collapsedStart + last.collapsedLen : last.mdStart + last.mdLen
  }

  /// The end of a run belongs to the next run, which is how the end of `**bold**` lands after its
  /// markers. A fence is the exception: its close is a line of its own, so the end of the code stays
  /// inside the block rather than jumping past the closing fence.
  private func owns(_ run: RichRun, _ flatOffset: Int) -> Bool {
    let end = run.flatStart + run.docLen
    return flatOffset < end || (flatOffset == end && run.nodeName == "codeBlock")
  }

  public func flatToCollapsed(_ flatOffset: Int) -> Int {
    let bounded = max(0, min(flatOffset, docLength))
    for run in runs where owns(run, bounded) {
      if run.kind == .text || run.kind == .token {
        // A chip's source in a fence spans its characters but one position.
        let within = min(bounded - run.flatStart, run.collapsedLen - run.openLen - run.closeLen)
        return run.collapsedStart + run.openLen + within
      }
      return run.collapsedStart + (bounded - run.flatStart)
    }
    return lastRunEnd(collapsed: true)
  }

  public func flatToMarkdown(_ flatOffset: Int) -> Int {
    let bounded = max(0, min(flatOffset, docLength))
    for run in runs where owns(run, bounded) {
      if run.kind == .text || run.kind == .token { return run.mdStart + run.openLen + (bounded - run.flatStart) }
      return run.mdStart + (bounded - run.flatStart)
    }
    return lastRunEnd(collapsed: false)
  }

  public func collapsedToFlat(_ collapsedOffset: Int) -> Int {
    for run in runs where collapsedOffset < run.collapsedStart + run.collapsedLen {
      // Block prefixes and style markers are shown, never edited: every offset inside them clamps to
      // the adjacent document position.
      if run.kind == .prefix { return run.flatStart }
      if run.kind == .text || run.kind == .token {
        let within = collapsedOffset - run.collapsedStart
        let contentLength = run.collapsedLen - run.openLen - run.closeLen
        if within <= run.openLen { return run.flatStart }
        if within >= run.openLen + contentLength { return run.flatStart + run.docLen }
        return run.flatStart + (within - run.openLen)
      }
      return run.flatStart + (collapsedOffset - run.collapsedStart)
    }
    return docLength
  }
}
