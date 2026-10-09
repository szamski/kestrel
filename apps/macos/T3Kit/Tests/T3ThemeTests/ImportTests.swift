import Compression
import Foundation
import Testing

@testable import T3Theme

/// A tiny ZIP writer for tests: stored or raw-deflate entries, no CRC (the reader does not check it).
private func makeZip(_ files: [(name: String, data: Data, deflate: Bool)], comment: Data = Data()) -> Data {
  var out = Data(), central = Data()
  /// Little-endian fields, `(value, byteCount)`.
  func put(_ target: inout Data, _ fields: [(Int, Int)]) {
    for (value, count) in fields { for i in 0..<count { target.append(UInt8((value >> (8 * i)) & 0xff)) } }
  }
  for file in files {
    var packed = file.data
    if file.deflate {
      var buffer = [UInt8](repeating: 0, count: file.data.count + 1024)
      let n = file.data.withUnsafeBytes { src in
        compression_encode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, file.data.count, nil, COMPRESSION_ZLIB)
      }
      packed = Data(buffer[..<n])
    }
    let name = Data(file.name.utf8)
    let method = file.deflate ? 8 : 0
    let offset = out.count
    put(&out, [(0x0403_4b50, 4), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4), (packed.count, 4), (file.data.count, 4), (name.count, 2), (0, 2)])
    out.append(name)
    out.append(packed)
    put(&central, [(0x0201_4b50, 4), (20, 2), (20, 2), (0, 2), (method, 2), (0, 4), (0, 4), (packed.count, 4), (file.data.count, 4)])
    put(&central, [(name.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4)])
    central.append(name)
  }
  let directoryOffset = out.count
  out.append(central)
  put(&out, [(0x0605_4b50, 4), (0, 2), (0, 2), (files.count, 2), (files.count, 2), (central.count, 4), (directoryOffset, 4), (comment.count, 2)])
  out.append(comment)
  return out
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

nonisolated(unsafe) private let darkTheme: [String: Any] = [
  "type": "dark",
  "colors": ["editor.background": "#1e1e2e", "editor.foreground": "#cdd6f4", "focusBorder": "#89b4fa", "unused.key": "#ff0000"],
]

nonisolated(unsafe) private let manifest: [String: Any] = [
  "publisher": "acme", "name": "cool", "version": "1.2.3", "license": "MIT",
  "contributes": ["themes": [
    ["label": "Cool Dark", "uiTheme": "vs-dark", "path": "./themes/dark.json"],
    ["label": "Cool Light", "uiTheme": "vs", "path": "./themes/light.json"],
  ]],
]

private let sample = OpenVsxExtension(
  id: "acme.cool", collectionId: "open-vsx:acme.cool", name: "Cool", publisher: "acme", description: "", downloadCount: 1, iconURL: nil, sourceURL: nil,
  manifestURL: URL(string: "https://open-vsx.org/m")!, sha256URL: URL(string: "https://open-vsx.org/s")!, vsixURL: URL(string: "https://open-vsx.org/v")!,
  version: "1.2.3", license: "MIT")

@Suite struct ZipTests {
  @Test func readsStoredAndDeflatedEntriesAndSurvivesArchiveComments() throws {
    let text = Data(String(repeating: "hello theme ", count: 50).utf8)
    // The comment contains EOCD-like bytes; the reader must still find the real directory.
    let zip = makeZip([("a.txt", text, false), ("dir/b.txt", text, true)], comment: Data([0x50, 0x4b, 0x05, 0x06]))
    let archive = try ZipArchive(data: zip)
    #expect(try archive.read("a.txt", description: "a", maxBytes: 10_000) == text)
    #expect(try archive.read("dir/b.txt", description: "b", maxBytes: 10_000) == text)
    #expect(throws: ThemeError("b is too large.")) { try archive.read("dir/b.txt", description: "b", maxBytes: 10) }
    #expect(throws: ThemeError("c is missing from the extension package.")) { try archive.read("c", description: "c", maxBytes: 10) }
  }

  @Test func refusesZipBombsAndUnsafePaths() throws {
    let zeros = Data(repeating: 0, count: 200_000)
    #expect(throws: ThemeError("That extension package has an unsafe compression ratio.")) { try ZipArchive(data: makeZip([("bomb", zeros, true)])) }
    #expect(throws: ThemeError("Theme path escapes the extension package.")) { try ZipArchive(data: makeZip([("../evil", Data("x".utf8), false)])) }
    #expect(throws: ThemeError("That extension package has no ZIP directory.")) { try ZipArchive(data: Data("not a zip at all, really not......".utf8)) }
    #expect(try ZipArchive.normalizePackagePath("./themes/a.json") == "extension/themes/a.json")
    #expect(try ZipArchive.normalizePackagePath("../b.json", relativeTo: "extension/themes/a.json") == "extension/b.json")
    #expect(throws: ThemeError("Theme path is not a safe relative package path.")) { try ZipArchive.normalizePackagePath("/etc/passwd") }
  }
}

@Suite struct OpenVsxImportTests {
  private func package(extra: [(String, Data, Bool)] = [], manifest manifestObject: [String: Any] = manifest) -> Data {
    makeZip(
      [("extension/package.json", json(manifestObject), true), ("extension/themes/dark.json", json(darkTheme), true),
       ("extension/themes/light.json", json(["type": "light", "colors": ["editor.background": "#eff1f5", "editor.foreground": "#4c4f69", "focusBorder": "#1e66f5"]]), false)]
        + extra.map { ($0.0, $0.1, $0.2) })
  }

  @Test func convertsAPackageIntoOnePairedCollection() throws {
    let themes = try OpenVsxClient.convert(package: package(), extension: sample)
    // "Cool Dark" and "Cool Light" differ only by the appearance word: one dual-mode theme.
    #expect(themes.count == 1)
    let theme = themes[0]
    #expect(theme.label == "Cool" && theme.modes == [.light, .dark])
    #expect(theme.collection == .init(id: "open-vsx:acme.cool", label: "Cool"))
    #expect(theme.id.hasPrefix("ovx-theme-") && theme.id.count == "ovx-theme-".count + 12)
    #expect(theme.colors(for: .dark)?[.canvas] == ThemeColorMath.canonical("#1e1e2e"))
  }

  @Test func includeChainsMergeAndCyclesFail() throws {
    var chained = manifest
    chained["contributes"] = ["themes": [["label": "Child", "uiTheme": "vs-dark", "path": "./themes/child.json"]]]
    let child = json(["include": "./dark.json", "colors": ["focusBorder": "#f38ba8"]])
    let themes = try OpenVsxClient.convert(package: package(extra: [("extension/themes/child.json", child, false)], manifest: chained), extension: sample)
    #expect(themes.count == 1 && themes[0].colors[.canvas] == ThemeColorMath.canonical("#1e1e2e"))  // from the included base
    #expect(themes[0].colors[.accent] != ThemePalette.vivid(.dark, background: "#1e1e2e", accent: "#89b4fa")[.accent])  // child's focusBorder wins

    let cycle = package(
      extra: [("extension/themes/a.json", json(["include": "./b.json"]), false), ("extension/themes/b.json", json(["include": "./a.json"]), false)],
      manifest: ["publisher": "acme", "name": "cool", "version": "1.2.3", "license": "MIT", "contributes": ["themes": [["label": "A", "path": "./themes/a.json"]]]])
    #expect(throws: ThemeError("One or more color themes in that extension could not be imported safely.")) { try OpenVsxClient.convert(package: cycle, extension: sample) }
  }

  @Test func refusesAPackageThatIsNotTheAdvertisedExtension() throws {
    var other = manifest
    other["version"] = "9.9.9"
    #expect(throws: ThemeError("That extension package does not match the selected Open VSX theme.")) { try OpenVsxClient.convert(package: package(manifest: other), extension: sample) }
    var license = manifest
    license["license"] = "GPL-3.0"
    #expect(throws: ThemeError("That extension package does not match its advertised license.")) { try OpenVsxClient.convert(package: package(manifest: license), extension: sample) }
  }

  @Test func detailsAreTrustCheckedAndLicenseFiltered() throws {
    func detail(license: String, download: String = "https://open-vsx.org/v") -> [String: Any] {
      ["namespace": "acme", "name": "cool", "version": "1", "license": license, "displayName": "Cool", "downloadCount": 12,
       "files": ["manifest": "https://open-vsx.org/m", "sha256": "https://open-vsx.org/s", "download": download]]
    }
    #expect(try OpenVsxClient.extensionFromDetail(detail(license: "MIT"))?.id == "acme.cool")
    #expect(try OpenVsxClient.extensionFromDetail(detail(license: "GPL-3.0")) == nil)
    #expect(throws: ThemeError("Open VSX returned malformed theme details.")) { try OpenVsxClient.extensionFromDetail(detail(license: "MIT", download: "https://evil.example/v")) }
  }

  @Test func searchAndInstallTalkToOpenVsxThroughOneInjectedFetch() async throws {
    let vsix = package()
    let digest = OpenVsxClient.sha256Hex(vsix)
    let detailJSON = json([
      "namespace": "acme", "name": "cool", "version": "1.2.3", "license": "MIT", "displayName": "Cool",
      "files": ["manifest": "https://open-vsx.org/m", "sha256": "https://open-vsx.org/s", "download": "https://open-vsx.org/v"],
    ])
    let manifestJSON = json(manifest)
    let client = OpenVsxClient { request, _ in
      let url = request.url!.absoluteString
      let body: Data
      switch url {
      case _ where url.hasPrefix("https://open-vsx.org/api/-/search"): body = json(["extensions": [["namespace": "acme", "name": "cool"]]])
      case "https://open-vsx.org/api/acme/cool": body = detailJSON
      case "https://open-vsx.org/m": body = manifestJSON
      case "https://open-vsx.org/s": body = Data((digest + "  cool.vsix\n").utf8)
      case "https://open-vsx.org/v": body = request.httpMethod == "HEAD" ? Data() : vsix
      default: Issue.record("unexpected request \(url)"); body = Data()
      }
      return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
    let found = try await client.search("cool")
    #expect(found.map(\.id) == ["acme.cool"])
    let installed = try await client.install(found[0])
    #expect(installed.count == 1)
  }
}
