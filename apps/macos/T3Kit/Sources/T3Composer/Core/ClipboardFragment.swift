import Foundation
import T3Contracts

/// Structured clipboard payload for context copied between drafts and messages
/// (`packages/contracts/src/composerContextClipboard.ts`). It carries the records behind the copied
/// links plus where they came from, never bytes or URLs.
public struct ComposerContextClipboardFragment: Sendable, Hashable, Codable {
  public struct Source: Sendable, Hashable, Codable {
    public var environmentId: String
    public var threadId: String?
    public var messageId: String?

    public init(environmentId: String, threadId: String? = nil, messageId: String? = nil) {
      self.environmentId = environmentId
      self.threadId = threadId
      self.messageId = messageId
    }
  }

  public var version = 1
  public var source: Source
  public var records: [ComposerContextRecord]

  public init(source: Source, records: [ComposerContextRecord]) {
    self.source = source
    self.records = records
  }
}

public enum ComposerContextClipboard {
  /// The Chromium custom-format name the web composer registers; kept for parity and for desktop.
  public static let webMime = "web application/x-t3-context-fragment+json"
  /// What the native composer writes on the pasteboard next to plain text and HTML.
  public static let pasteboardType = "application/x-t3-context-fragment+json"
  static let maxFragmentChars = 16_000_000
  static let maxRecords = 200
  private static let htmlWrapperSlack = 4096

  /// `JSON.stringify(fragment)`, or nil when it is too large for the clipboard.
  public static func encode(_ fragment: ComposerContextClipboardFragment) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(fragment), let text = String(data: data, encoding: .utf8) else { return nil }
    return text.jsLength <= maxFragmentChars ? text : nil
  }

  /// HTML is the portable flavor shared by browsers and native system clipboards.
  public static func encodeHTML(text: String, fragment: String, html: String? = nil) -> String {
    let attribute = URICodec.encodeComponent(fragment)
    if let html { return "<div data-t3-context-fragment=\"\(attribute)\">\(html)</div>" }
    let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return "<pre data-t3-context-fragment=\"\(attribute)\">\(escaped)</pre>"
  }

  private static let htmlAttribute = JSRegex("data-t3-context-fragment=[\"']([^\"']+)[\"']")

  public static func decodeHTML(_ html: String?) -> ComposerContextClipboardFragment? {
    guard let html, !html.isEmpty, html.jsLength <= maxFragmentChars * 9 + htmlWrapperSlack else { return nil }
    guard let match = htmlAttribute.firstMatch(in: html), let encoded = match.group(1),
      let raw = URICodec.decodeComponent(encoded)
    else { return nil }
    return decode(raw)
  }

  /// Clipboard data is untrusted: anything that is not a valid version-1 fragment is ignored.
  public static func decode(_ raw: String?) -> ComposerContextClipboardFragment? {
    guard let raw, !raw.isEmpty, raw.jsLength <= maxFragmentChars, let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (object["version"] as? NSNumber)?.intValue == 1,
      let sourceObject = object["source"] as? [String: Any],
      let environmentId = trimmedId(sourceObject["environmentId"]),
      let records = object["records"] as? [Any], records.count <= maxRecords
    else { return nil }
    var source = ComposerContextClipboardFragment.Source(environmentId: environmentId)
    if let thread = sourceObject["threadId"] {
      guard let id = trimmedId(thread) else { return nil }
      source.threadId = id
    }
    if let message = sourceObject["messageId"] {
      guard let id = trimmedId(message) else { return nil }
      source.messageId = id
    }
    // Forward-compatible: an undecodable record is dropped instead of failing the whole fragment.
    guard let context = try? JSONDecoder().decode(
      OrchestrationMessageContext.self,
      from: JSONSerialization.data(withJSONObject: ["version": 1, "records": records]))
    else { return nil }
    // `.unknown` is what the generated decoder keeps for an object that matches no record shape;
    // the TypeScript schema drops those.
    return ComposerContextClipboardFragment(
      source: source,
      records: context.records.filter { if case .unknown = $0 { false } else { true } })
  }

  private static func trimmedId(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.jsTrim()
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Only records whose links are in the pasted text get imported; a fragment may carry more (it
  /// was built for a larger copy) and must not start transfers for those.
  public static func readPasted(text pastedText: String, fragment rawFragment: String?, html: String?) -> ComposerContextClipboardFragment? {
    guard let decoded = decode(rawFragment) ?? decodeHTML(html) else { return nil }
    var pastedIds = Set(ComposerContextReferences.collect(pastedText).map(\.contextId))
    for record in decoded.records {
      if case .previewAnnotation(let annotation) = record, pastedIds.contains(annotation.contextId.rawValue),
        let screenshot = annotation.screenshotContextId
      {
        pastedIds.insert(screenshot.rawValue)
      }
    }
    var result = decoded
    result.records = decoded.records.filter { pastedIds.contains($0.contextIdentifier) }
    return result
  }

  /// Rewrites pasted links to the ids the importer assigned (`importPastedComposerText`).
  public static func rewriteIds(in pastedText: String, with rewritten: [String: String]) -> String {
    guard !rewritten.isEmpty else { return pastedText }
    return ComposerContextReferences.replace(pastedText) { occurrence in
      guard let next = rewritten[occurrence.contextId] else { return occurrence.source }
      return ComposerContextReferences.format(
        ComposerContextReference(
          kind: occurrence.kind == "element" ? "preview-annotation" : occurrence.kind, contextId: next,
          label: occurrence.label))
    }
  }
}

extension ComposerContextRecord {
  /// The record's payload identity, whichever kind it is.
  public var contextIdentifier: String {
    switch self {
    case .image(let value): value.contextId.rawValue
    case .file(let value): value.contextId.rawValue
    case .terminal(let value): value.contextId.rawValue
    case .element(let value): value.contextId.rawValue
    case .previewAnnotation(let value): value.contextId.rawValue
    case .reviewComment(let value): value.contextId.rawValue
    case .mention(let value): value.contextId.rawValue
    case .skill(let value): value.contextId.rawValue
    case .other(let value): value.contextId.rawValue
    case .unknown(let value): value["contextId"]?.stringValue ?? ""
    }
  }

  public var contextKind: String {
    switch self {
    case .image: "image"
    case .file: "file"
    case .terminal: "terminal"
    case .element: "element"
    case .previewAnnotation: "preview-annotation"
    case .reviewComment: "review-comment"
    case .mention: "mention"
    case .skill: "skill"
    case .other(let value): value.kind
    case .unknown(let value): value["kind"]?.stringValue ?? ""
    }
  }

  public var contextLabel: String {
    switch self {
    case .image(let value): value.label
    case .file(let value): value.label
    case .terminal(let value): value.label
    case .element(let value): value.label
    case .previewAnnotation(let value): value.label
    case .reviewComment(let value): value.label
    case .mention(let value): value.label
    case .skill(let value): value.label
    case .other(let value): value.label
    case .unknown(let value): value["label"]?.stringValue ?? ""
    }
  }
}
