import Foundation

/// Port of `packages/shared/src/composerContextReferences.ts` and
/// `apps/web/src/lib/composerContextReferences.ts`.
///
/// Canonical inline reference: `[label](t3-context://v1/<kind>/<contextId>)`, or the image form
/// `![label](...)`. The link carries position and identity only; the payload lives in the
/// message's context records.
public struct ComposerContextReference: Sendable, Hashable {
  public var kind: String
  public var contextId: String
  public var label: String

  public init(kind: String, contextId: String, label: String) {
    self.kind = kind
    self.contextId = contextId
    self.label = label
  }
}

public struct ComposerContextReferenceOccurrence: Sendable, Hashable {
  public var kind: String
  public var contextId: String
  public var label: String
  /// Whether the occurrence used the `![...]` image form.
  public var image: Bool
  public var source: String
  public var start: Int
  public var end: Int
}

public enum ComposerContextReferences {
  public static let labelMaxChars = 200
  static let hrefPrefix = "t3-context://v1/"
  private static let maxLinkLabelLength = 512
  private static let link = JSRegex(
    "(!?)\\[([^\\]\\n]{0,\(maxLinkLabelLength)})\\]\\((t3-context://v1/[^\\)\(JS.spaceClass)]{1,200})\\)"
  )

  public static func formatHref(kind: String, contextId: String) -> String {
    "\(hrefPrefix)\(kind)/\(contextId)"
  }

  private static func isLower(_ unit: UInt16) -> Bool { unit >= 0x61 && unit <= 0x7A }
  private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

  static func isValidKind(_ kind: String) -> Bool {
    let units = Array(kind.utf16)
    guard (1...40).contains(units.count), isLower(units[0]) else { return false }
    return units.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0 == 0x2D }
  }

  /// `[a-z0-9_-]{1,128}`, case-insensitive.
  static func isValidContextId(_ id: String) -> Bool {
    let units = Array(id.utf16)
    guard (1...128).contains(units.count) else { return false }
    return units.allSatisfy { isLower($0) || ($0 >= 0x41 && $0 <= 0x5A) || isDigit($0) || $0 == 0x5F || $0 == 0x2D }
  }

  public static func parseHref(_ href: String) -> (kind: String, contextId: String)? {
    guard href.hasPrefix(hrefPrefix) else { return nil }
    let rest = String(href.dropFirst(hrefPrefix.count))
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, isValidKind(parts[0]), isValidContextId(parts[1]) else { return nil }
    return (parts[0], parts[1])
  }

  /// Labels must survive a Markdown link: no brackets or line breaks, bounded, never empty.
  public static func sanitizeLabel(_ label: String, kind: String) -> String {
    let replaced = String(
      decoding: label.utf16.map { unit in
        switch unit {
        case 0x5B, 0x5D, 0x5C, 0x0D, 0x0A: UInt16(0x20)
        default: unit
        }
      }, as: UTF16.self)
    let cleaned = replaced.jsCollapsingWhitespace().jsTrim().jsSlice(0, labelMaxChars)
    return cleaned.isEmpty ? kind : cleaned
  }

  public static func format(_ reference: ComposerContextReference) -> String {
    let label = sanitizeLabel(reference.label, kind: reference.kind)
    let href = formatHref(kind: reference.kind, contextId: reference.contextId)
    return "\(reference.kind == "image" ? "!" : "")[\(label)](\(href))"
  }

  public static func collect(_ text: String) -> [ComposerContextReferenceOccurrence] {
    // No link can match without the protocol prefix; skip the scan on plain prose.
    guard text.contains("](t3-context:") else { return [] }
    var occurrences: [ComposerContextReferenceOccurrence] = []
    for match in link.matches(in: text) {
      guard let href = match.group(3), let parsed = parseHref(href) else { continue }
      occurrences.append(
        ComposerContextReferenceOccurrence(
          kind: parsed.kind,
          contextId: parsed.contextId,
          label: sanitizeLabel(match.group(2) ?? "", kind: parsed.kind),
          image: match.group(1) == "!",
          source: match.text,
          start: match.range.lowerBound,
          end: match.range.upperBound))
    }
    return occurrences
  }

  public static func replace(
    _ text: String, _ transform: (ComposerContextReferenceOccurrence) -> String
  ) -> String {
    var result = ""
    var cursor = 0
    for occurrence in collect(text) {
      result += text.jsSlice(cursor, occurrence.start) + transform(occurrence)
      cursor = occurrence.end
    }
    return result + text.jsSlice(cursor)
  }

  // MARK: - Prompt-string operations (apps/web/src/lib/composerContextReferences.ts)

  /// Two independent FNV-1a passes (forward, and reversed with another basis): 64 bits of digest.
  private static func fnv1a64(_ value: String) -> String {
    let units = Array(value.utf16)
    var forward: UInt32 = 0x811c_9dc5
    var reverse: UInt32 = 0x9dc5_811c
    for index in 0..<units.count {
      forward ^= UInt32(units[index])
      forward = forward &* 0x0100_0193
      reverse ^= UInt32(units[units.count - 1 - index])
      reverse = reverse &* 0x0100_0193
    }
    func hex8(_ value: UInt32) -> String {
      let text = String(value, radix: 16)
      return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }
    return hex8(forward) + hex8(reverse)
  }

  /// Producers mint ids in their own grammars; fold anything outside `[a-z0-9_-]` into a slug plus
  /// a hash of the original, deterministically.
  public static func toContextId(_ producerId: String) -> String {
    if isValidContextId(producerId) { return producerId }
    var slug: [UInt16] = []
    var inRun = false
    for unit in producerId.utf16 {
      let ok = isLower(unit) || (unit >= 0x41 && unit <= 0x5A) || isDigit(unit) || unit == 0x5F || unit == 0x2D
      if ok {
        slug.append(unit)
        inRun = false
      } else if !inRun {
        slug.append(0x2D)
        inRun = true
      }
    }
    while slug.first == 0x2D { slug.removeFirst() }
    while slug.last == 0x2D { slug.removeLast() }
    let cut = String(decoding: slug.prefix(48), as: UTF16.self)
    return "\(cut.isEmpty ? "ctx" : cut)-\(fnv1a64(producerId))"
  }

  public static func toKindScopedContextId(kind: String, producerId: String) -> String {
    toContextId("\(kind)_\(producerId)")
  }

  public static func producerId(kind: String, contextId: String) -> String {
    let prefix = "\(kind)_"
    return contextId.hasPrefix(prefix) ? String(contextId.dropFirst(prefix.count)) : contextId
  }

  public static func formatInline(_ reference: ComposerContextReference) -> String { format(reference) }

  /// Payload ids referenced by the prompt, once each in first-occurrence order.
  public static func collectInlineContextIds(_ prompt: String) -> [String] {
    var seen = Set<String>()
    return collect(prompt).compactMap { seen.insert($0.contextId).inserted ? $0.contextId : nil }
  }

  /// Prose without any context link.
  public static func stripInlineReferences(_ prompt: String) -> String {
    replace(prompt) { _ in "" }
  }

  private static func isBoundaryWhitespace(_ unit: UInt16?) -> Bool {
    guard let unit else { return true }
    return unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D
  }

  public struct Replacement: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var text: String
  }

  /// Replaces a selected range with chips, keeping word boundaries and the trailing caret space.
  public static func inlineReplacement(
    prompt: String, start: Int, end: Int, references: [ComposerContextReference]
  ) -> Replacement {
    let length = prompt.jsLength
    let from = max(0, min(length, start))
    let to = max(from, min(length, end))
    let needsLeadingSpace = !isBoundaryWhitespace(prompt.jsUnit(at: from - 1))
    return Replacement(
      start: from,
      end: prompt.jsUnit(at: to) == 0x20 ? to + 1 : to,
      text: "\(needsLeadingSpace ? " " : "")\(references.map(formatInline).joined(separator: " ")) ")
  }

  /// Inserts a link at the cursor, padding with spaces only where words would otherwise join.
  public static func insert(prompt: String, cursor: Int, reference: ComposerContextReference) -> (prompt: String, cursor: Int) {
    let edit = inlineReplacement(prompt: prompt, start: cursor, end: cursor, references: [reference])
    return (prompt.jsSlice(0, edit.start) + edit.text + prompt.jsSlice(edit.end), edit.start + edit.text.jsLength)
  }

  public static func append(prompt: String, reference: ComposerContextReference) -> String {
    insert(prompt: prompt, cursor: prompt.jsLength, reference: reference).prompt
  }

  /// Removes every reference to `contextId` plus one neighbouring space each so words don't join.
  public static func remove(prompt: String, contextId: String) -> (prompt: String, cursor: Int) {
    let occurrences = collect(prompt).filter { $0.contextId == contextId }
    if occurrences.isEmpty { return (prompt, prompt.jsLength) }
    var result = prompt
    var cursor = prompt.jsLength
    for occurrence in occurrences.reversed() {
      var start = occurrence.start
      var end = occurrence.end
      if result.jsUnit(at: end) == 0x20 {
        end += 1
      } else if result.jsUnit(at: start - 1) == 0x20 {
        start -= 1
      }
      result = result.jsSlice(0, start) + result.jsSlice(end)
      cursor = start
    }
    if cursor >= result.jsLength {
      result = result.jsTrimEnd()
      cursor = result.jsLength
    }
    return (result, cursor)
  }

  /// Appends links for records the prompt does not reference yet, in the order given.
  public static func ensure(prompt: String, references: [ComposerContextReference]) -> String {
    var referenced = Set(collectInlineContextIds(prompt))
    var result = prompt
    for reference in references where !referenced.contains(reference.contextId) {
      referenced.insert(reference.contextId)
      result = append(prompt: result, reference: reference)
    }
    return result
  }
}
