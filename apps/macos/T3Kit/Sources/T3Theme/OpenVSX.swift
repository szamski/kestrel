import CryptoKit
import Foundation

public enum OpenVsxSort: String, Sendable, CaseIterable, Identifiable {
  case downloadCount, rating, timestamp, relevance
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .downloadCount: "Most downloaded"
    case .rating: "Best rated"
    case .timestamp: "Newest"
    case .relevance: "Most relevant"
    }
  }
}

public struct OpenVsxExtension: Sendable, Hashable, Identifiable {
  public var id: String
  public var collectionId: String
  public var name: String
  public var publisher: String
  public var description: String
  public var downloadCount: Int
  public var iconURL: URL?
  public var sourceURL: URL?
  public var manifestURL: URL
  public var sha256URL: URL
  public var vsixURL: URL
  public var version: String
  public var license: String
}

/// Search and install of community themes from Open VSX, with the web importer's trust rules: https open-vsx.org URLs only,
/// an allowlist of permissive licenses, size caps, a SHA-256 check of the package, and the package manifest matching the
/// advertised extension. A port of `apps/web/src/openVsxThemes.ts`.
public struct OpenVsxClient: Sendable {
  /// One request, with the body capped at `limit` bytes (HEAD ignores it).
  public typealias Fetch = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

  static let searchURL = "https://open-vsx.org/api/-/search"
  static let maxVsixBytes = 20 * 1024 * 1024
  static let maxSearchBytes = 512 * 1024
  static let maxDetailBytes = 256 * 1024
  static let maxManifestBytes = 256 * 1024
  static let maxThemeBytes = 256 * 1024
  static let maxThemesPerExtension = 40
  static let maxIncludeDepth = 8
  static let maxColorValueLength = 128
  static let maxResolvedThemeFiles = maxThemesPerExtension * maxIncludeDepth
  static let requestTimeout: TimeInterval = 10
  static let supportedLicenses: Set<String> = ["0BSD", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "CC0-1.0", "ISC", "MIT", "MPL-2.0", "Unlicense"]
  static let usedWorkbenchColors: Set<String> = [
    "activityBar.background", "activityBarBadge.background", "badge.background", "button.background", "button.foreground", "contrastBorder",
    "descriptionForeground", "disabledForeground", "dropdown.background", "dropdown.border", "editor.background", "editor.foreground",
    "editor.selectionBackground", "editorCursor.foreground", "editorError.foreground", "editorGroup.border", "editorPane.background",
    "editorWarning.foreground", "editorWidget.background", "errorForeground", "focusBorder", "foreground", "input.border",
    "input.placeholderForeground", "list.activeSelectionBackground", "list.hoverBackground", "list.inactiveSelectionBackground",
    "menu.background", "panel.background", "panel.border", "progressBar.background", "quickInput.background", "scrollbarSlider.background",
    "sideBar.background", "sideBar.border", "sideBar.foreground", "terminal.background", "terminal.foreground",
    "terminal.selectionBackground", "terminalCursor.foreground", "textCodeBlock.background", "textLink.foreground",
  ]

  public var fetch: Fetch

  public init(fetch: @escaping Fetch = Self.liveFetch) { self.fetch = fetch }

  /// Streams the body and stops as soon as it passes `limit`.
  public static let liveFetch: Fetch = { request, limit in
    var request = request
    request.timeoutInterval = requestTimeout  // ponytail: idle timeout per request, not a total deadline
    let (stream, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw ThemeError("Open VSX returned an unreadable response.") }
    if http.expectedContentLength > Int64(limit), request.httpMethod != "HEAD" { throw ThemeError("Open VSX returned an unexpectedly large response.") }
    var data = Data()
    if request.httpMethod != "HEAD" {
      for try await byte in stream {
        data.append(byte)
        if data.count > limit { throw ThemeError("Open VSX returned an unexpectedly large response.") }
      }
    }
    return (data, http)
  }

  // MARK: Identity

  static func shortHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func themeId(extensionId: String, source: String) -> String { "ovx-theme-\(shortHash("\(extensionId):\(source)"))" }

  static func collectionId(_ extensionId: String) -> String {
    let normalized = "open-vsx:\(extensionId.lowercased())"
    return normalized.range(of: #"^[a-z0-9][a-z0-9.:-]{0,127}$"#, options: .regularExpression) != nil ? normalized : "open-vsx:\(shortHash(extensionId))"
  }

  static func trustedURL(_ value: Any?) -> URL? {
    guard let text = value as? String, let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "open-vsx.org" else { return nil }
    return url
  }

  static func publicSourceURL(_ value: Any?) -> URL? {
    let raw = (value as? String) ?? (value as? [String: Any])?["url"] as? String
    guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
    return url
  }

  static func contributions(_ manifest: [String: Any]) -> [[String: Any]] {
    ((manifest["contributes"] as? [String: Any])?["themes"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
  }

  static func licenseMatches(_ manifest: [String: Any], _ license: String) -> Bool {
    (manifest["license"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == license.lowercased()
  }

  /// `extensionFromDetail`: nil for an unsupported license, an error for a malformed response.
  static func extensionFromDetail(_ value: Any) throws -> OpenVsxExtension? {
    guard let detail = value as? [String: Any], let files = detail["files"] as? [String: Any] else {
      throw ThemeError("Open VSX returned malformed theme details.")
    }
    func text(_ key: String) -> String { (detail[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let namespace = text("namespace"), name = text("name"), version = text("version"), license = text("license")
    let displayName = text("displayName").isEmpty ? name : text("displayName")
    guard !namespace.isEmpty, !name.isEmpty, !version.isEmpty, let manifestURL = trustedURL(files["manifest"]),
      let sha256URL = trustedURL(files["sha256"]), let vsixURL = trustedURL(files["download"])
    else { throw ThemeError("Open VSX returned malformed theme details.") }
    guard supportedLicenses.contains(license) else { return nil }
    let id = "\(namespace).\(name)"
    let downloads = (detail["downloadCount"] as? NSNumber)?.intValue ?? 0
    return OpenVsxExtension(
      id: id, collectionId: collectionId(id), name: displayName, publisher: namespace, description: detail["description"] as? String ?? "",
      downloadCount: downloads, iconURL: trustedURL(files["icon"]),
      sourceURL: publicSourceURL(detail["repository"]) ?? publicSourceURL(detail["homepage"]) ?? publicSourceURL(detail["url"]),
      manifestURL: manifestURL, sha256URL: sha256URL, vsixURL: vsixURL, version: version, license: license)
  }

  private func get(_ url: URL, limit: Int, tooLarge: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    do { return try await fetch(request, limit) } catch let error as ThemeError where error.message == "Open VSX returned an unexpectedly large response." {
      throw ThemeError(tooLarge)
    }
  }

  // MARK: Search

  public func search(_ query: String, sortBy: OpenVsxSort = .downloadCount) async throws -> [OpenVsxExtension] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    var components = URLComponents(string: Self.searchURL)!
    // A few extras: results without a supported license are omitted.
    components.queryItems = [
      .init(name: "query", value: text), .init(name: "category", value: "Themes"), .init(name: "sortBy", value: sortBy.rawValue),
      .init(name: "sortOrder", value: "desc"), .init(name: "size", value: "16"),
    ]
    let (data, response) = try await get(components.url!, limit: Self.maxSearchBytes, tooLarge: "Open VSX returned an unexpectedly large response.")
    guard (200..<300).contains(response.statusCode) else { throw ThemeError("Open VSX search is unavailable right now.") }
    guard let value = try? JSONSerialization.jsonObject(with: data) else { throw ThemeError("Open VSX returned an unreadable response.") }
    guard let object = value as? [String: Any], let found = object["extensions"] as? [Any] else {
      throw ThemeError("Open VSX returned an unreadable search response.")
    }
    let identities = found.compactMap { candidate -> (String, String)? in
      guard let item = candidate as? [String: Any], let namespace = item["namespace"] as? String, let name = item["name"] as? String,
        !namespace.isEmpty, !name.isEmpty
      else { return nil }
      return (namespace, name)
    }
    let results = await withTaskGroup(of: (Int, Result<OpenVsxExtension?, Error>).self) { group in
      for (index, identity) in identities.prefix(16).enumerated() {
        group.addTask { (index, await Result { try await detail(namespace: identity.0, name: identity.1) }) }
      }
      var collected: [(Int, Result<OpenVsxExtension?, Error>)] = []
      for await item in group { collected.append(item) }
      return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }
    try Task.checkCancellation()
    let completed = results.compactMap { try? $0.get() }
    if !identities.isEmpty, completed.isEmpty { throw ThemeError("Open VSX theme details are unavailable right now.") }
    return Array(completed.compactMap { $0 }.prefix(8))
  }

  private func detail(namespace: String, name: String) async throws -> OpenVsxExtension? {
    let encode = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? s }
    guard let url = URL(string: "https://open-vsx.org/api/\(encode(namespace))/\(encode(name))") else { throw ThemeError("Open VSX theme details are unavailable.") }
    let (data, response) = try await get(url, limit: Self.maxDetailBytes, tooLarge: "Open VSX returned an unexpectedly large detail response.")
    guard (200..<300).contains(response.statusCode) else { throw ThemeError("Open VSX theme details are unavailable.") }
    do {
      guard let value = try? JSONSerialization.jsonObject(with: data), let found = try Self.extensionFromDetail(value) else { return nil }
      async let manifestResult = get(found.manifestURL, limit: Self.maxManifestBytes, tooLarge: "Open VSX returned an unexpectedly large manifest.")
      async let packageResult = get(found.vsixURL, limit: 0, tooLarge: "", method: "HEAD")
      let (manifestData, manifestResponse) = try await manifestResult
      let (_, packageResponse) = try await packageResult
      guard (200..<300).contains(manifestResponse.statusCode) else { throw ThemeError("manifest unavailable") }
      guard (200..<300).contains(packageResponse.statusCode) else { return nil }
      if let length = packageResponse.value(forHTTPHeaderField: "content-length").flatMap(Int.init), length > Self.maxVsixBytes { return nil }
      let manifest = try JSONC.parseObject(String(decoding: manifestData, as: UTF8.self), description: "Extension manifest")
      return !Self.contributions(manifest).isEmpty && Self.licenseMatches(manifest, found.license) ? found : nil
    } catch {
      throw ThemeError("Open VSX returned unreadable theme details.")
    }
  }

  // MARK: Install

  /// Downloads the package and converts its color themes. Everything is checked before any theme is returned.
  public func install(_ ext: OpenVsxExtension) async throws -> [ThemeDefinition] {
    let (manifestData, manifestResponse) = try await get(ext.manifestURL, limit: Self.maxManifestBytes, tooLarge: "That Open VSX extension manifest is too large.")
    guard (200..<300).contains(manifestResponse.statusCode) else { throw ThemeError("That Open VSX extension has no readable manifest.") }
    let manifest = try JSONC.parseObject(String(decoding: manifestData, as: UTF8.self), description: "Extension manifest")
    let advertised = Self.contributions(manifest)
    if advertised.isEmpty { throw ThemeError("That extension does not contain color themes.") }
    if advertised.count > Self.maxThemesPerExtension { throw ThemeError("That extension contains too many color themes to import safely.") }

    let (packageData, packageResponse) = try await get(ext.vsixURL, limit: Self.maxVsixBytes, tooLarge: "That theme extension is too large to import safely.")
    guard (200..<300).contains(packageResponse.statusCode) else { throw ThemeError("That Open VSX theme could not be downloaded.") }
    try Task.checkCancellation()
    let (checksumData, checksumResponse) = try await get(ext.sha256URL, limit: 256, tooLarge: "That Open VSX checksum response is invalid.")
    guard (200..<300).contains(checksumResponse.statusCode) else { throw ThemeError("That Open VSX theme has no readable checksum.") }
    let expected = String(decoding: checksumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard expected.range(of: #"^[a-f\d]{64}$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
      throw ThemeError("That Open VSX theme has an invalid checksum.")
    }
    guard Self.sha256Hex(packageData) == expected.lowercased() else { throw ThemeError("That Open VSX theme failed its integrity check.") }
    return try Self.convert(package: packageData, extension: ext)
  }

  /// Everything after the integrity check: open the package, verify it is the advertised extension, convert its themes.
  static func convert(package packageData: Data, extension ext: OpenVsxExtension) throws -> [ThemeDefinition] {
    let zip: ZipArchive
    do { zip = try ZipArchive(data: packageData) } catch let error as ThemeError where error.message.hasPrefix("That extension package") { throw error } catch {
      throw ThemeError("That Open VSX extension package could not be opened.")
    }
    let packaged = try JSONC.parseObject(
      String(decoding: try zip.read("extension/package.json", description: "Extension manifest", maxBytes: maxManifestBytes), as: UTF8.self),
      description: "Extension manifest")
    guard let publisher = packaged["publisher"] as? String, publisher.lowercased() == ext.publisher.lowercased(), let name = packaged["name"] as? String,
      "\(publisher).\(name)".lowercased() == ext.id.lowercased(), packaged["version"] as? String == ext.version
    else { throw ThemeError("That extension package does not match the selected Open VSX theme.") }
    guard licenseMatches(packaged, ext.license) else { throw ThemeError("That extension package does not match its advertised license.") }
    let declared = contributions(packaged)
    if declared.isEmpty { throw ThemeError("That extension does not contain color themes.") }
    if declared.count > maxThemesPerExtension { throw ThemeError("That extension contains too many color themes to import safely.") }

    var parsed: [(theme: ThemeDefinition, sourceName: String?, sourcePath: String)] = []
    var failures = 0
    var cache: [String: [String: Any]] = [:]
    var budget = 0
    for contribution in declared {
      guard let rawPath = contribution["path"] as? String else { failures += 1; continue }
      do {
        let path = try ZipArchive.normalizePackagePath(rawPath)
        var object = try loadThemeObject(zip, path: path, cache: &cache, budget: &budget, ancestors: [])
        let label = (contribution["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        object["displayName"] = (label?.isEmpty == false) ? label! : ext.name
        switch contribution["uiTheme"] as? String {
        case "vs": object["type"] = "light"
        case "vs-dark": object["type"] = "dark"
        case "hc-black"?, "hc-light"?: object["type"] = contribution["uiTheme"]
        default: break
        }
        guard VSCodeThemeImport.isVSCodeTheme(object) else { throw ThemeError("not a VS Code color theme") }
        parsed.append((try VSCodeThemeImport.parse(object), path.split(separator: "/").last.map(String.init), path))
      } catch {
        failures += 1
      }
    }
    if failures > 0 { throw ThemeError("One or more color themes in that extension could not be imported safely.") }
    if parsed.isEmpty { throw ThemeError("That extension has no compatible color themes.") }

    let extensionId = ext.id.lowercased()
    var pathCounts: [String: Int] = [:]
    for item in parsed { pathCounts[item.sourcePath, default: 0] += 1 }
    var occurrences: [String: Int] = [:]
    let identities = parsed.map { item -> String in
      if pathCounts[item.sourcePath] == 1 { return item.sourcePath }
      let occurrence = occurrences[item.sourcePath, default: 0]
      occurrences[item.sourcePath] = occurrence + 1
      return occurrence == 0 ? item.sourcePath : "\(item.sourcePath)\0\(occurrence)"
    }
    var resolved = VSCodeThemeImport.resolveLabelCollisions(parsed.map { ($0.theme, $0.sourceName) })
    for index in resolved.indices { resolved[index].id = themeId(extensionId: extensionId, source: identities[index]) }
    let paired = VSCodeThemeImport.pair(resolved) { light, dark in themeId(extensionId: extensionId, source: [light.id, dark.id].sorted().joined(separator: ":")) }
    let themes = VSCodeThemeImport.resolveLabelCollisions(paired.map { ($0, nil) })
    let collection = ThemeDefinition.Collection(id: ext.collectionId, label: String(ext.name.prefix(48)))
    return themes.map { theme in
      var themed = theme
      themed.collection = collection
      return themed
    }
  }

  /// Keeps only the workbench colors the converter reads, and resolves `include` chains (bounded depth, no cycles).
  static func loadThemeObject(
    _ zip: ZipArchive, path: String, cache: inout [String: [String: Any]], budget: inout Int, ancestors: Set<String>
  ) throws -> [String: Any] {
    if ancestors.count >= maxIncludeDepth { throw ThemeError("Theme includes are nested too deeply.") }
    if ancestors.contains(path) { throw ThemeError("Theme includes contain a cycle.") }
    if let cached = cache[path] { return cached }
    budget += 1
    if budget > maxResolvedThemeFiles { throw ThemeError("That extension references too many theme files.") }
    let source = String(decoding: try zip.read(path, description: path, maxBytes: maxThemeBytes), as: UTF8.self)
    let raw = try JSONC.parseObject(source, description: path)
    var colors: [String: Any] = [:]
    for (key, color) in raw["colors"] as? [String: Any] ?? [:] {
      if usedWorkbenchColors.contains(key), let text = color as? String, text.count <= maxColorValueLength { colors[key] = text }
    }
    var value: [String: Any] = ["colors": colors]
    if let include = raw["include"] as? String { value["include"] = include }
    guard let include = value["include"] as? String else {
      cache[path] = value
      return value
    }
    let includePath = try ZipArchive.normalizePackagePath(include, relativeTo: path)
    let base = try loadThemeObject(zip, path: includePath, cache: &cache, budget: &budget, ancestors: ancestors.union([path]))
    var resolved = base
    for (key, item) in value { resolved[key] = item }
    resolved["colors"] = (base["colors"] as? [String: Any] ?? [:]).merging(value["colors"] as? [String: Any] ?? [:]) { _, new in new }
    cache[path] = resolved
    return resolved
  }
}

extension Result where Failure == Error {
  init(_ body: () async throws -> Success) async {
    do { self = .success(try await body()) } catch { self = .failure(error) }
  }
}
