import Foundation
import T3Contracts

// Port of packages/client-runtime/src/work-log/toolPresentation.ts: the optional surface, icon
// and source a provider attaches to a tool activity. Anything out of bounds is dropped so a
// hostile or newer payload cannot reach the UI.

struct ExtractedToolActivityPresentation {
  var toolSurface: ToolActivitySurface?
  var toolIcon: ToolActivityIcon?
  var toolSource: ToolActivitySource?
}

private func trimmedString(_ value: JSONValue?, maxLength: Int) -> String? {
  guard let trimmed = value.stringOrNil?.jsTrimmed, !trimmed.isEmpty, trimmed.utf16Length <= maxLength else { return nil }
  return trimmed
}

/// `new URL(raw).href` for the schemes accepted here: lowercase scheme and host, no default
/// port, an explicit `/` path. `data:` URLs are kept as written.
private func normalizedHref(_ raw: String, allowData: Bool) -> String? {
  guard let colon = raw.firstIndex(of: ":") else { return nil }
  let scheme = raw[..<colon].lowercased()
  if scheme == "data" { return allowData ? raw : nil }
  guard scheme == "http" || scheme == "https", var components = URLComponents(string: raw), let host = components.host,
    !host.isEmpty
  else { return nil }
  components.scheme = scheme
  components.host = host.lowercased()
  if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) { components.port = nil }
  if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
  return components.string
}

private func imageUrl(_ value: JSONValue?) -> String? {
  trimmedString(value, maxLength: 4096).flatMap { normalizedHref($0, allowData: true) }
}

private func pageUrl(_ value: JSONValue?) -> String? {
  trimmedString(value, maxLength: 4096).flatMap { normalizedHref($0, allowData: false) }
}

private func nativeAppReference(_ value: JSONValue?) -> ToolActivityNativeApp? {
  let app = value.strictRecord
  if app?["_tag"]?.stringOrNil == "app-id", let appId = trimmedString(app?["appId"], maxLength: 512),
    appId.matches("^[A-Za-z0-9._-]+$")
  {
    return .appId(appId)
  }
  if app?["_tag"]?.stringOrNil == "display-name", let displayName = trimmedString(app?["displayName"], maxLength: 160) {
    return .displayName(displayName)
  }
  return nil
}

private func activityIcon(_ value: JSONValue?) -> ToolActivityIcon? {
  guard let icon = value.strictRecord else { return nil }
  switch icon["_tag"]?.stringOrNil {
  case "website":
    if let page = pageUrl(icon["pageUrl"]) {
      return .website(pageUrl: page, faviconUrl: imageUrl(icon["faviconUrl"]), faviconUrlDark: imageUrl(icon["faviconUrlDark"]))
    }
  case "native-app":
    if let app = nativeAppReference(icon["app"]) { return .nativeApp(app) }
  case "themed-logo":
    if let logo = imageUrl(icon["logoUrl"]) { return .themedLogo(logoUrl: logo, logoUrlDark: imageUrl(icon["logoUrlDark"])) }
  default: break
  }
  return nil
}

private func activitySource(_ value: JSONValue?) -> ToolActivitySource? {
  let source = value.strictRecord
  guard let key = trimmedString(source?["key"], maxLength: 512), let name = trimmedString(source?["name"], maxLength: 160),
    let kindRaw = source?["kind"]?.stringOrNil, let kind = ToolActivitySource.Kind(rawValue: kindRaw)
  else { return nil }
  return ToolActivitySource(key: key, name: name, kind: kind, icon: activityIcon(source?["icon"]))
}

func extractToolActivityPresentation(_ payload: JSONValue?) -> ExtractedToolActivityPresentation {
  let record = payload.strictRecord
  var result = ExtractedToolActivityPresentation()
  if let surface = record?["toolSurface"]?.stringOrNil { result.toolSurface = ToolActivitySurface(rawValue: surface) }
  result.toolIcon = activityIcon(record?["toolIcon"])
  result.toolSource = activitySource(record?["toolSource"])
  return result
}
