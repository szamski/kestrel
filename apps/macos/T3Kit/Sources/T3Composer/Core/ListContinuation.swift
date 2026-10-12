import Foundation

/// Port of `apps/web/src/composer-list-continuation.ts`: Enter on a list item continues it (or
/// exits an empty one) and Tab indents it. Plain Markdown markers only, applied as store edits so
/// both composer modes serialize identically.
public struct ComposerListEdit: Sendable, Hashable {
  /// Offsets into the Markdown string.
  public var start: Int
  public var end: Int
  public var replacement: String
}

public enum ComposerListContinuation {
  private enum Marker {
    case ordered(indent: String, numberText: String, delimiter: String, space: String)
    case task(indent: String, space: String)
    case bullet(indent: String, bullet: String, space: String)
  }

  private static let s = JS.spaceClass
  private static let ordered = JSRegex("^([0-9]+)([.)])((?:[ \\t]+)|[\(s)]*\\z)")
  private static let task = JSRegex("^-[\(s)]\\[[ xX]\\]((?:[ \\t]+)|[\(s)]*\\z)")
  private static let bullet = JSRegex("^([-*+])((?:[ \\t]+)|[\(s)]*\\z)")

  private static func parseMarker(_ line: String) -> (marker: Marker, markerEnd: Int)? {
    let units = Array(line.utf16)
    var indentLength = 0
    while indentLength < units.count, units[indentLength] == 0x20 || units[indentLength] == 0x09 { indentLength += 1 }
    let indent = String(decoding: units[0..<indentLength], as: UTF16.self)
    let rest = String(decoding: units[indentLength...], as: UTF16.self)
    if let match = ordered.firstMatch(in: rest) {
      return (.ordered(indent: indent, numberText: match.group(1) ?? "", delimiter: match.group(2) == ")" ? ")" : ".", space: match.group(3) ?? ""), indentLength + match.range.upperBound)
    }
    if let match = task.firstMatch(in: rest) {
      return (.task(indent: indent, space: match.group(1) ?? ""), indentLength + match.range.upperBound)
    }
    if let match = bullet.firstMatch(in: rest) {
      return (.bullet(indent: indent, bullet: match.group(1) ?? "-", space: match.group(2) ?? ""), indentLength + match.range.upperBound)
    }
    return nil
  }

  /// `nextOrderedMarkerText`: `9.` -> `10.`, `09)` -> `10)`; a number beyond the safe integers stays.
  /// The rich editor's native split counts the same way.
  static func nextOrderedMarker(_ marker: String) -> String {
    let numberText = String(marker.dropLast())
    let delimiter = marker.suffix(1)
    var next = numberText
    if let number = UInt64(numberText), number <= 9_007_199_254_740_991 {
      let text = String(number + 1)
      next = String(repeating: "0", count: max(0, numberText.count - text.count)) + text
    }
    return next + delimiter
  }

  private static func nextMarkerText(_ marker: Marker) -> String {
    switch marker {
    case .ordered(let indent, let numberText, let delimiter, _):
      return "\(indent)\(nextOrderedMarker(numberText + delimiter)) "
    case .task(let indent, _): return "\(indent)- [ ] "
    case .bullet(let indent, let bullet, _): return "\(indent)\(bullet) "
    }
  }

  /// True when splitting at the caret would cut an inline chip in two.
  private static func isInsideInlineToken(_ value: String, _ cursor: Int) -> Bool {
    var offset = 0
    for segment in ComposerPromptSegments.split(value) {
      let end = offset + segment.sourceLength
      if segment.isInlineToken && cursor > offset && cursor < end { return true }
      offset = end
    }
    return false
  }

  private static func currentLine(_ value: String, _ cursor: Int) -> (start: Int, end: Int, text: String) {
    let start = value.jsLastIndex(of: 0x0A, from: max(0, cursor - 1)) + 1
    let endIndex = value.jsIndex(of: 0x0A, from: cursor)
    let end = endIndex == -1 ? value.jsLength : endIndex
    return (start, end, value.jsSlice(start, end))
  }

  /// Enter on a list item line: continue the list, or exit it when the item is empty. Nil for
  /// non-list lines, carets inside the marker and carets inside an inline chip.
  public static func forEnter(_ value: String, _ cursor: Int) -> ComposerListEdit? {
    guard cursor >= 0, cursor <= value.jsLength else { return nil }
    let line = currentLine(value, cursor)
    guard let parsed = parseMarker(line.text) else { return nil }
    let markerEnd = line.start + parsed.markerEnd
    if cursor < markerEnd || isInsideInlineToken(value, cursor) { return nil }
    if value.jsSlice(markerEnd, line.end).jsTrim().isEmpty {
      // Empty item: Enter exits the list by removing the marker.
      return ComposerListEdit(start: line.start, end: max(cursor, markerEnd), replacement: "")
    }
    return ComposerListEdit(start: cursor, end: cursor, replacement: "\n" + nextMarkerText(parsed.marker))
  }

  /// Tab on a list item line: indent by two spaces. Ranged selections, non-list lines and carets
  /// inside an inline chip fall through.
  public static func indentForTab(_ value: String, start: Int, end: Int) -> ComposerListEdit? {
    guard start == end, start >= 0, start <= value.jsLength else { return nil }
    let line = currentLine(value, start)
    guard parseMarker(line.text) != nil, !isInsideInlineToken(value, start) else { return nil }
    return ComposerListEdit(start: line.start, end: line.start, replacement: "  ")
  }
}
