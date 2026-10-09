import AppKit
import SwiftUI
import T3Theme
import UniformTypeIdentifiers

/// "Add a theme": search community themes on Open VSX, or import theme files (T3 Code JSON, VS Code color themes, several at
/// once) from disk, from `~/.vscode/extensions`, or pasted.
struct AddThemeSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var sort = OpenVsxSort.downloadCount
  @State private var results: [OpenVsxExtension]?
  @State private var searching = false
  @State private var installing: String?
  @State private var searchError: String?
  @State private var pendingUpdate: OpenVsxExtension?
  @State private var pasted = ""
  @State private var importError: String?
  @State private var conflicts: [ThemeDefinition]?
  @State private var conflictName: String?
  @State private var dropTargeted = false

  private let client = OpenVsxClient()
  private static let suggestions = ["Dracula", "Catppuccin", "Nord", "Tokyo Night"]

  private struct SearchKey: Hashable {
    var query: String
    var sort: OpenVsxSort
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Add a theme").font(.headline)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(20).padding(.bottom, -8)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          search
          Divider()
          importFiles
        }.padding(20)
      }
    }
    .frame(width: 580, height: 680)
    .confirmationDialog(
      "A theme with this name is already installed", isPresented: Binding(get: { conflicts != nil }, set: { if !$0 { conflicts = nil } }), titleVisibility: .visible
    ) {
      Button("Update the installed theme") { resolveConflicts(update: true) }
      Button("Keep both") { resolveConflicts(update: false) }
      Button("Cancel", role: .cancel) { conflicts = nil }
    } message: {
      Text(conflicts.map { $0.map(\.label).joined(separator: ", ") } ?? "")
    }
    .confirmationDialog(
      "Update \(pendingUpdate?.name ?? "theme")?", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }), titleVisibility: .visible
    ) {
      if let ext = pendingUpdate { Button("Replace installed version") { install(ext, allowUpdate: true) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This replaces the themes you installed from this extension with the latest version.")
    }
  }

  // MARK: Open VSX

  private var search: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Search community themes").font(.subheadline.weight(.semibold))
      Text("Find open-source themes from Open VSX.").font(.callout).foregroundStyle(.secondary)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search themes\u{2026}", text: $query).textFieldStyle(.plain).onSubmit { Task { await runSearch() } }
        if searching { ProgressView().controlSize(.small) }
      }
      .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
      HStack(spacing: 6) {
        Text("Popular").font(.caption).foregroundStyle(.secondary)
        ForEach(Self.suggestions, id: \.self) { suggestion in
          Button(suggestion) { query = suggestion }.buttonStyle(.borderless).font(.caption).disabled(installing != nil)
        }
        Spacer()
        if let results, !results.isEmpty {
          Picker("Sort", selection: $sort) { ForEach(OpenVsxSort.allCases) { Text($0.label).tag($0) } }.labelsHidden().fixedSize().disabled(installing != nil)
        }
      }
      if let searchError { Text(searchError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      if let results {
        if results.isEmpty { Text("No supported themes found. Only permissively licensed themes are listed.").font(.callout).foregroundStyle(.secondary) }
        ForEach(results) { ext in resultRow(ext) }
      }
    }
    .task(id: SearchKey(query: query.trimmingCharacters(in: .whitespaces), sort: sort)) {
      guard installing == nil else { return }
      guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        results = nil
        searchError = nil
        searching = false
        return
      }
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await runSearch()
    }
  }

  private func resultRow(_ ext: OpenVsxExtension) -> some View {
    let installed = AppTheme.shared.installedCollection(ext.collectionId)
    return HStack(alignment: .top, spacing: 10) {
      AsyncImage(url: ext.iconURL) { image in image.resizable().scaledToFill() } placeholder: {
        Image(systemName: "paintpalette").foregroundStyle(.secondary)
      }
      .frame(width: 40, height: 40).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 2) {
        Text(ext.name).font(.callout.weight(.medium)).lineLimit(1)
        Text("\(ext.publisher) \u{00B7} \(ext.downloadCount.formatted(.number.notation(.compactName))) downloads \u{00B7} \(ext.license)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if !ext.description.isEmpty { Text(ext.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
      }
      Spacer(minLength: 8)
      if let source = ext.sourceURL { Link(destination: source) { Image(systemName: "arrow.up.right.square") }.help("Open the source") }
      if installing == ext.id {
        ProgressView().controlSize(.small)
      } else {
        Button(installed.isEmpty ? "Install" : "Update") { install(ext, allowUpdate: false) }.disabled(installing != nil)
      }
    }
    .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
  }

  private func runSearch() async {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    searching = true
    searchError = nil
    defer { searching = false }
    do {
      let found = try await client.search(text, sortBy: sort)
      guard !Task.isCancelled else { return }
      results = found
    } catch is CancellationError {
    } catch let error as URLError where error.code == .cancelled {
    } catch {
      results = nil
      searchError = error.localizedDescription
    }
  }

  private func install(_ ext: OpenVsxExtension, allowUpdate: Bool) {
    let installed = AppTheme.shared.installedCollection(ext.collectionId)
    if !installed.isEmpty, !allowUpdate {
      pendingUpdate = ext
      return
    }
    installing = ext.id
    searchError = nil
    Task {
      defer { installing = nil }
      do {
        let themes = try await client.install(ext)
        try AppTheme.shared.replaceCollection(ext.collectionId, with: themes)
        if let first = themes.first { AppTheme.shared.use(first.id) }
        dismiss()
      } catch {
        searchError = error.localizedDescription
      }
    }
  }

  // MARK: Files

  private var importFiles: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Import a file").font(.subheadline.weight(.semibold))
      Text("T3 Code theme files and VS Code color themes (.json). Pick several to import a whole family; light and dark variants pair up.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Image(systemName: "doc.badge.plus").font(.title2).foregroundStyle(.secondary)
        VStack(alignment: .leading) {
          Text("Drop theme files here").font(.callout.weight(.medium))
          Text("or choose them; the picker opens in your VS Code extensions").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Choose files\u{2026}") { chooseFiles() }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 10).strokeBorder(dropTargeted ? Color.accentColor : .primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5])))
      .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
        Task {
          var urls: [URL] = []
          for provider in providers {
            if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier), let data = item as? Data,
              let url = URL(dataRepresentation: data, relativeTo: nil)
            { urls.append(url) }
          }
          importFiles(urls)
        }
        return true
      }
      Text("Or paste the JSON").font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $pasted).font(.system(size: 11, design: .monospaced)).frame(height: 110)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
      HStack {
        if let importError { Text(importError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        Spacer()
        Button("Add theme") { importPasted() }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.json, UTType(filenameExtension: "jsonc")].compactMap { $0 }
    let extensions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vscode/extensions", directoryHint: .isDirectory)
    if FileManager.default.fileExists(atPath: extensions.path) { panel.directoryURL = extensions }
    guard panel.runModal() == .OK else { return }
    importFiles(panel.urls)
  }

  /// One file reads like the paste box; several import as a batch (variants pair, colliding names are told apart).
  private func importFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    importError = nil
    var parsed: [(theme: ThemeDefinition, sourceName: String?)] = []
    var failures: [String] = []
    for url in urls {
      do { parsed.append((try Self.readTheme(at: url), url.lastPathComponent)) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    let themes = urls.count > 1 ? VSCodeThemeImport.pair(VSCodeThemeImport.resolveLabelCollisions(parsed)) : parsed.map(\.theme)
    finish(themes, preferredName: urls.count == 1 ? VSCodeThemeImport.humanizeName(urls[0].deletingPathExtension().lastPathComponent) : nil, failures: failures)
  }

  private func importPasted() {
    importError = nil
    let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= ThemeFile.maxBytes else { importError = "That is too large to be a theme file (limit 256 KB)."; return }
    do {
      let object = try JSONC.parseObject(text, description: "That text")
      finish([try Self.theme(from: object)], preferredName: nil, failures: [])
    } catch {
      importError = error.localizedDescription
    }
  }

  private static func theme(from object: [String: Any]) throws -> ThemeDefinition {
    VSCodeThemeImport.isVSCodeTheme(object) ? try VSCodeThemeImport.parse(object) : try ThemeFile.parse(object)
  }

  /// Reads one theme file, following a VS Code `include` chain beside it (bounded depth).
  private static func readTheme(at url: URL) throws -> ThemeDefinition {
    var object = try loadObject(url, depth: 0)
    if let type = object["type"] as? String, VSCodeThemeImport.isVSCodeTheme(object) { object["type"] = type }
    return try theme(from: object)
  }

  private static func loadObject(_ url: URL, depth: Int) throws -> [String: Any] {
    guard depth < 8 else { throw ThemeError("Theme includes are nested too deeply.") }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= ThemeFile.maxBytes else { throw ThemeError("Theme files are only a few KB; this one was not read (limit 256 KB).") }
    var object = try JSONC.parseObject(String(decoding: try Data(contentsOf: url), as: UTF8.self), description: "That file")
    if let include = object["include"] as? String {
      let base = try loadObject(url.deletingLastPathComponent().appending(path: include), depth: depth + 1)
      var colors = base["colors"] as? [String: Any] ?? [:]
      for (key, value) in object["colors"] as? [String: Any] ?? [:] { colors[key] = value }
      object = base.merging(object) { _, own in own }
      object["colors"] = colors
    }
    return object
  }

  // MARK: Installing

  private func finish(_ themes: [ThemeDefinition], preferredName: String?, failures: [String]) {
    var clashes: [ThemeDefinition] = []
    var added: [ThemeDefinition] = []
    var problems = failures
    for theme in themes {
      if AppTheme.shared.customThemes.contains(where: { $0.id == theme.id }) {
        clashes.append(theme)
      } else {
        do { added.append(try AppTheme.shared.install(theme)) } catch { problems.append("\(theme.label): \(error.localizedDescription)") }
      }
    }
    if let first = added.first { AppTheme.shared.use(first.id) }
    conflictName = preferredName
    if !clashes.isEmpty {
      conflicts = clashes
      importError = problems.isEmpty ? nil : problems.joined(separator: " \u{2014} ")
    } else if problems.isEmpty {
      dismiss()
    } else {
      importError = problems.joined(separator: " \u{2014} ")
      if !added.isEmpty { pasted = "" }
    }
  }

  private func resolveConflicts(update: Bool) {
    guard let clashes = conflicts else { return }
    conflicts = nil
    var problems: [String] = []
    for theme in clashes {
      do {
        if update {
          var next = theme
          next.collection = AppTheme.shared.definition(theme.id)?.collection
          try AppTheme.shared.update(next)
        } else {
          let copy = try versionedCopy(theme)
          try AppTheme.shared.install(copy)
          AppTheme.shared.use(copy.id)
        }
      } catch {
        problems.append("\(theme.label): \(error.localizedDescription)")
      }
    }
    if problems.isEmpty { dismiss() } else { importError = problems.joined(separator: " \u{2014} ") }
  }

  /// The file's own name when it differs (Dracula Soft), else the next free "Name (1)".
  private func versionedCopy(_ theme: ThemeDefinition) throws -> ThemeDefinition {
    func make(_ name: String) throws -> ThemeDefinition {
      try ThemeFile.make(name: String(name.prefix(48)), appearance: theme.appearance, colors: theme.colors, variants: theme.variants, managed: theme.managed)
    }
    if let preferred = conflictName, preferred.lowercased() != theme.label.lowercased(),
      let candidate = try? make(preferred), !AppTheme.shared.customThemes.contains(where: { $0.id == candidate.id })
    { return candidate }
    for copy in 1..<100 {
      let suffix = " (\(copy))"
      let candidate = try make(String(theme.label.prefix(48 - suffix.count)) + suffix)
      if !AppTheme.shared.customThemes.contains(where: { $0.id == candidate.id }) { return candidate }
    }
    throw ThemeError("Too many copies of \"\(theme.label)\".")
  }
}
