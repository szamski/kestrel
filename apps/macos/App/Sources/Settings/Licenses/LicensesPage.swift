import SwiftUI

/// One notice of `third-party-licenses.json`, the same manifest format the web build emits
/// (`packages/shared/src/thirdPartyLicenses.ts`). `apps/macos/scripts/generate-licenses.ts` writes the bundled copy.
struct LicenseEntry: Codable, Identifiable, Hashable, Sendable {
  var bundles: [String]
  var kind: String
  var license: String
  var name: String
  var noticeText: String
  var sourceUrl: String?
  var version: String?

  var id: String { "\(kind)|\(name)|\(version ?? "")" }

  private static let bundleLabels = [
    "android": "Android", "assets": "Assets", "desktop": "Desktop", "device-tools": "Device tools", "ios": "iOS", "macos": "macOS app", "mobile": "Mobile",
    "server": "Server", "web": "Web",
  ]

  var bundleLabel: String { bundles.map { Self.bundleLabels[$0] ?? $0 }.joined(separator: ", ") }

  /// Every word must appear in the name, version, license or app component (`filterThirdPartyLicenseEntries`).
  static func filter(_ entries: [LicenseEntry], _ query: String) -> [LicenseEntry] {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !terms.isEmpty else { return entries }
    return entries.filter { entry in
      let haystack = ([entry.name, entry.version, entry.license].compactMap { $0 } + entry.bundles).joined(separator: " ").lowercased()
      return terms.allSatisfy { haystack.contains($0) }
    }
  }
}

private struct LicenseManifest: Decodable {
  var schemaVersion: Int
  var entries: [LicenseEntry]

  static func load() throws -> [LicenseEntry] {
    guard let url = Bundle.main.url(forResource: "third-party-licenses", withExtension: "json") else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The license manifest is missing from this build."])
    }
    let manifest = try JSONDecoder().decode(LicenseManifest.self, from: Data(contentsOf: url))
    guard manifest.schemaVersion == 1 else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The open-source license manifest has an unsupported format."])
    }
    return manifest.entries
  }
}

/// Settings › Open-source licenses: notices for dependencies, assets and bundled tools. A device page: no server involved.
struct LicensesPage: View {
  private enum Phase { case loading, ready([LicenseEntry]), failed(String) }

  @State private var phase = Phase.loading
  @State private var query = ""
  @State private var open: String?

  var body: some View {
    VStack(spacing: 0) {
      switch phase {
      case .loading:
        ProgressView("Loading open-source notices…").frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Open-source notices are unavailable", systemImage: "doc.text")
        } description: {
          Text(message)
        } actions: {
          Button("Try again") { Task { await load() } }
        }
      case .ready(let entries):
        let shown = LicenseEntry.filter(entries, query)
        header(shown: shown.count, total: entries.count)
        Divider()
        if shown.isEmpty {
          ContentUnavailableView("No licenses match that search.", systemImage: "magnifyingglass").frame(maxHeight: .infinity)
        } else {
          List(shown) { entry in row(entry) }.listStyle(.inset)
        }
      }
    }
    .task { await load() }
  }

  private func header(shown: Int, total: Int) -> some View {
    HStack {
      Text("Third-party notices").font(.headline)
      Text(shown == total ? "\(total) notices" : "\(shown) of \(total)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
      Spacer()
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search licenses", text: $query).textFieldStyle(.plain).frame(width: 190).accessibilityLabel("Search open-source licenses")
        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Clear search") }
      }
      .padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
  }

  private func row(_ entry: LicenseEntry) -> some View {
    let expanded = open == entry.id
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          open = expanded ? nil : entry.id
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.secondary).rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
            Text(entry.name).fontWeight(.medium).lineLimit(1)
            if let version = entry.version { Text(version).font(.caption).monospaced().foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            Text("\(entry.license) \u{00B7} \(entry.bundleLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("\(entry.name) notice").accessibilityValue(expanded ? "expanded" : "collapsed")
        if let source = entry.sourceUrl.flatMap(URL.init(string:)), source.scheme == "https" || source.scheme == "http" {
          Link(destination: source) { Image(systemName: "arrow.up.right.square") }.help("Project source").accessibilityLabel("View project source for \(entry.name)")
        }
      }
      if expanded {
        Text(entry.noticeText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
          .frame(maxWidth: 640, alignment: .leading).padding(.leading, 20).padding(.bottom, 6)
      }
    }
    .padding(.vertical, 2)
  }

  private func load() async {
    phase = .loading
    do {
      phase = .ready(try await Task.detached { try LicenseManifest.load() }.value)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}
