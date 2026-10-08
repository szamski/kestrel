import Foundation

/// Typed links ride through `NSAttributedString.Key.link` as URLs so AppKit gives us cursor,
/// hover tooltips, the link context menu and VoiceOver's link rotor for free. Web links are
/// real URLs; everything else is a private `t3md://link` URL carrying the payload.
enum MarkdownLinkCoding {
  /// Internal actions that are not `MarkdownLink`s.
  enum Action: Equatable {
    /// The summary row of a `<details>`; `open` is the state it is drawn in.
    case toggleDetails(key: UInt64, open: Bool)
    case link(MarkdownLink)
  }

  static func url(for link: MarkdownLink) -> URL {
    var c = URLComponents()
    c.scheme = "t3md"
    c.host = "link"
    func q(_ items: [(String, String?)]) -> URL {
      c.queryItems = items.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
      return c.url!
    }
    switch link {
    case .web(let url): return url
    case .file(let t):
      return q([
        ("kind", "file"), ("path", t.path), ("line", t.line.map(String.init)), ("column", t.column.map(String.init)),
        ("endLine", t.endLine.map(String.init)),
      ])
    case .anchor(let a): return q([("kind", "anchor"), ("name", a)])
    case .context(let kind, let id): return q([("kind", "context"), ("ckind", kind), ("id", id)])
    case .citation(let c):
      return q([
        ("kind", "citation"), ("env", c.environmentId), ("thread", c.threadId), ("message", c.messageId),
        ("text", c.text), ("comment", c.comment), ("start", String(c.start)), ("end", String(c.end)),
        ("prefix", c.prefix), ("suffix", c.suffix),
      ])
    case .artifactTemplate(let t):
      return q([
        ("kind", "artifact"), ("akind", t.kind.rawValue), ("name", t.displayName), ("gallery", t.galleryKind?.rawValue),
        ("dir", t.skillDirectory), ("skill", t.skillName),
      ])
    case .image(let i):
      let (type, value): (String, String?) =
        switch i.source {
        case .direct(let v): ("direct", v)
        case .workspaceFile(let v): ("file", v)
        case .blocked: ("blocked", nil)
        }
      return q([
        ("kind", "image"), ("stype", type), ("src", value), ("dest", i.destination), ("alt", i.alt), ("title", i.title),
        ("w", i.width.map(String.init)), ("h", i.height.map(String.init)),
      ])
    }
  }

  static func toggleURL(key: UInt64, open: Bool) -> URL {
    var c = URLComponents()
    c.scheme = "t3md"
    c.host = "toggle"
    c.queryItems = [URLQueryItem(name: "key", value: String(key)), URLQueryItem(name: "open", value: open ? "1" : "0")]
    return c.url!
  }

  static func decode(_ any: Any) -> Action? {
    guard let url = (any as? URL) ?? (any as? String).flatMap(URL.init(string:)) else { return nil }
    guard url.scheme == "t3md" else {
      return MarkdownLink.webURL(url.absoluteString).map { .link(.web($0)) }
    }
    let items = Dictionary(
      (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { a, _ in a })
    if url.host == "toggle" {
      guard let key = items["key"].flatMap(UInt64.init) else { return nil }
      return .toggleDetails(key: key, open: items["open"] == "1")
    }
    func int(_ k: String) -> Int? { items[k].flatMap(Int.init) }
    switch items["kind"] {
    case "file":
      guard let path = items["path"] else { return nil }
      return .link(.file(MarkdownFileTarget(path: path, line: int("line"), column: int("column"), endLine: int("endLine"))))
    case "anchor": return items["name"].map { .link(.anchor($0)) }
    case "context":
      guard let k = items["ckind"], let id = items["id"] else { return nil }
      return .link(.context(kind: k, id: id))
    case "citation":
      guard let env = items["env"], let thread = items["thread"], let msg = items["message"], let text = items["text"],
        let start = int("start"), let end = int("end")
      else { return nil }
      return .link(
        .citation(
          MarkdownCitation(
            environmentId: env, threadId: thread, messageId: msg, text: text, comment: items["comment"], start: start,
            end: end, prefix: items["prefix"] ?? "", suffix: items["suffix"] ?? "")))
    case "artifact":
      var attrs = [
        "artifact_kind": items["akind"] ?? "", "display_name": items["name"] ?? "",
        "skill_directory": items["dir"] ?? "", "skill_name": items["skill"] ?? "",
      ]
      if let g = items["gallery"] { attrs["gallery_kind"] = g }
      return MarkdownArtifactTemplate(attributes: attrs).map { .link(.artifactTemplate($0)) }
    case "image":
      let source: MarkdownImageSource =
        switch items["stype"] {
        case "direct": .direct(items["src"] ?? "")
        case "file": .workspaceFile(items["src"] ?? "")
        default: .blocked
        }
      return .link(
        .image(
          MarkdownImage(
            source: source, destination: items["dest"] ?? "", alt: items["alt"] ?? "", title: items["title"],
            width: int("w"), height: int("h"))))
    default: return nil
    }
  }

  /// Tooltip text: what the link points at.
  static func tooltip(for link: MarkdownLink) -> String? {
    switch link {
    case .web(let u): u.absoluteString
    case .file(let t): t.pathWithPosition
    case .anchor(let a): "#" + a
    case .citation(let c): c.text
    case .context(_, let id): id
    case .artifactTemplate(let t): t.usePrompt
    case .image(let i): i.alt.isEmpty ? nil : i.alt
    }
  }
}
