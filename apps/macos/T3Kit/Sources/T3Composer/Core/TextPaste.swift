import Foundation

/// Port of `packages/client-runtime/src/textPaste.ts`: large clipboard text becomes a file
/// attachment so an agent can inspect it selectively.
public enum TextPaste {
  public static let attachmentThresholdBytes = 32 * 1024

  public enum Disposition: String, Sendable { case attachment, inline }

  /// The threshold is byte-based: character counts understate the context cost of some Unicode.
  public static func disposition(
    text: String, canAttach: Bool, bypassAutoAttachment: Bool = false, wouldExceedInputLimit: Bool = false
  ) -> Disposition {
    if bypassAutoAttachment || !canAttach || text.isEmpty { return .inline }
    return wouldExceedInputLimit || text.jsLength >= attachmentThresholdBytes
      || text.utf8.count >= attachmentThresholdBytes ? .attachment : .inline
  }

  /// Stable, human-readable names when a draft contains several folded pastes.
  public static func nextFileName(existing: [String]) -> String {
    let names = Set(existing.map { $0.lowercased() })
    if !names.contains("pasted-text.txt") { return "pasted-text.txt" }
    var sequence = 2
    while names.contains("pasted-text-\(sequence).txt") { sequence += 1 }
    return "pasted-text-\(sequence).txt"
  }

  public static func replaceSelection(value: String, start: Int, end: Int, text: String) -> (value: String, cursor: Int) {
    let length = value.jsLength
    let from = max(0, min(length, start))
    let to = max(from, min(length, end))
    return (value.jsSlice(0, from) + text + value.jsSlice(to), from + text.jsLength)
  }

  public static func wouldExceedLimit(valueLength: Int, start: Int, end: Int, textLength: Int, maxLength: Int) -> Bool {
    let from = max(0, min(valueLength, start))
    let to = max(from, min(valueLength, end))
    return valueLength - (to - from) + textLength > maxLength
  }
}

public enum AttachmentNames {
  /// Keeps both the recognizable beginning and the extension/end of a long attachment name.
  public static func middleTruncated(_ name: String, maxCharacters: Int = 36) -> String {
    let characters = Array(name.unicodeScalars)
    if characters.count <= maxCharacters { return name }
    if maxCharacters <= 0 { return "" }
    if maxCharacters == 1 { return "…" }
    let available = maxCharacters - 1
    let suffixLength = min(available - 1, available >= 18 ? 14 : Int((Double(available) / 2).rounded(.up)))
    let prefixLength = available - suffixLength
    let suffix = suffixLength == 0 ? "" : String(String.UnicodeScalarView(characters.suffix(suffixLength)))
    return String(String.UnicodeScalarView(characters.prefix(prefixLength))) + "…" + suffix
  }
}
