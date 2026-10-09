import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The dialog behind `filePicker.toggle` (go to file) and `projectSearch.toggle` (search contents).
struct FileDialogView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore
  let kind: FileDialogRequest.Kind

  var body: some View {
    Group {
      switch kind {
      case .goToFile: FilePickerView(app: app, key: key, store: store)
      case .searchContents: ContentSearchView(app: app, key: key, store: store)
      }
    }
    .frame(width: 640, height: 460)
  }
}

/// Fuzzy file finder over `projects.searchEntries`; the server ranks, this only marks the matching letters.
struct FilePickerView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore
  @State private var query = ""
  @State private var results: [ProjectEntry] = []
  @State private var selection = 0
  @State private var message: String?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        TextField("Go to file", text: $query)
          .textFieldStyle(.plain).font(.title3).focused($focused)
          .onSubmit(openSelected)
          .onKeyPress(.downArrow) { move(1); return .handled }
          .onKeyPress(.upArrow) { move(-1); return .handled }
          .accessibilityLabel("Go to file")
      }
      .padding(14)
      Divider()
      if results.isEmpty {
        Text(message ?? (query.isEmpty ? "Type to search workspace files." : "No matching files."))
          .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(results.enumerated()), id: \.offset) { index, entry in
                row(entry, selected: index == selection).id(index)
                  .onTapGesture { selection = index; openSelected() }
              }
            }
            .padding(6)
          }
          .onChange(of: selection) { _, index in proxy.scrollTo(index) }
        }
      }
    }
    .background(.regularMaterial)
    .onAppear { focused = true }
    .task(id: query) { await search() }
  }

  private func row(_ entry: ProjectEntry, selected: Bool) -> some View {
    let name = FileLogic.basename(entry.path)
    return HStack(spacing: 8) {
      Image(systemName: FileLogic.symbol(for: entry.path)).foregroundStyle(Palette.muted).frame(width: 16)
      Text(Self.marked(name, query: query)).lineLimit(1)
      Text(Self.marked(FileLogic.directory(entry.path), query: "")).font(.callout).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .contentShape(Rectangle())
    .accessibilityLabel(entry.path)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// `text` with the letters of `query` (a subsequence) emphasised.
  static func marked(_ text: String, query: String) -> AttributedString {
    let marked = Set(FileLogic.matchIndices(of: text, query: query.trimmingCharacters(in: CharacterSet(charactersIn: "@./"))))
    var result = AttributedString()
    for (index, character) in text.enumerated() {
      var piece = AttributedString(String(character))
      if marked.contains(index) { piece.font = .body.bold(); piece.foregroundColor = .accentColor }
      result += piece
    }
    return result
  }

  private func search() async {
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled, let service = await app.fileService(for: key) else { return }
    do throws(FileService.Failure) {
      results = try await service.searchEntries(query.trimmingCharacters(in: .whitespaces), limit: 200, kind: .file).filter { $0.kind == .file }
      message = nil
    } catch {
      results = []
      message = error.localizedDescription
    }
    selection = 0
  }

  private func move(_ delta: Int) {
    guard !results.isEmpty else { return }
    selection = min(max(selection + delta, 0), results.count - 1)
  }

  private func openSelected() {
    guard results.indices.contains(selection) else { return }
    store.fileDialog = nil
    store.openFile(results[selection].path, in: key)
  }
}

/// Project-wide text search (`projects.searchContents`): results grouped by file with line previews.
struct ContentSearchView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore
  @State private var query = ""
  @State private var caseSensitive = false
  @State private var wholeWord = false
  @State private var useRegex = false
  @State private var matches: [ProjectContentMatch] = []
  @State private var truncated = false
  @State private var notice: String?
  @State private var searching = false
  @State private var selection = 0
  @FocusState private var focused: Bool

  private struct Settings: Hashable { var query: String; var caseSensitive: Bool; var wholeWord: Bool; var useRegex: Bool }

  /// Matches ordered by file (first appearance), the order rows show and the arrow keys walk.
  private var ordered: [ProjectContentMatch] {
    var order: [String] = []
    var groups: [String: [ProjectContentMatch]] = [:]
    for match in matches {
      if groups[match.path] == nil { order.append(match.path) }
      groups[match.path, default: []].append(match)
    }
    return order.flatMap { groups[$0] ?? [] }
  }

  var body: some View {
    let rows = ordered
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        TextField("Search in project", text: $query)
          .textFieldStyle(.plain).font(.title3).focused($focused)
          .onSubmit { open(rows) }
          .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
          .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
          .accessibilityLabel("Search in project")
        toggle("Aa", "Match case", $caseSensitive)
        toggle("W", "Whole word", $wholeWord)
        toggle(".*", "Regular expression", $useRegex)
      }
      .padding(14)
      Divider()
      results(rows)
      Divider()
      Text(summary(rows)).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
    }
    .background(.regularMaterial)
    .onAppear { focused = true }
    .task(id: Settings(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)) { await search() }
  }

  private func toggle(_ label: String, _ help: String, _ value: Binding<Bool>) -> some View {
    Toggle(isOn: value) { Text(label).font(.system(.callout, design: .monospaced)) }
      .toggleStyle(.button).buttonStyle(.borderless).help(help).accessibilityLabel(help)
  }

  @ViewBuilder private func results(_ rows: [ProjectContentMatch]) -> some View {
    if rows.isEmpty {
      Text(notice ?? (query.isEmpty ? "Type to search file contents." : searching ? "Searching\u{2026}" : "No results."))
        .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, match in
              if index == 0 || rows[index - 1].path != match.path { fileHeader(match.path) }
              line(match, selected: index == selection).id(index).onTapGesture { selection = index; open(rows) }
            }
          }
          .padding(6)
        }
        .onChange(of: selection) { _, index in proxy.scrollTo(index) }
      }
    }
  }

  private func fileHeader(_ path: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: FileLogic.symbol(for: path)).foregroundStyle(Palette.muted)
      Text(FileLogic.basename(path)).font(.callout.weight(.semibold))
      Text(FileLogic.directory(path)).font(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
    }
    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
  }

  private func line(_ match: ProjectContentMatch, selected: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(String(match.lineNumber)).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 40, alignment: .trailing)
      Text(Self.preview(match)).font(.system(.callout, design: .monospaced)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .contentShape(Rectangle())
    .accessibilityLabel("\(FileLogic.basename(match.path)) line \(match.lineNumber): \(match.lineContent)")
  }

  /// The line without its indentation, cut so the first match is in view, with the matches marked.
  static func preview(_ match: ProjectContentMatch) -> AttributedString {
    let units = Array(match.lineContent.utf16)
    var cut = 0
    while cut < units.count, units[cut] == 0x20 || units[cut] == 0x09 { cut += 1 }
    var prefix = ""
    if let first = match.matchRanges.first?.start, first - cut > 40 {
      cut = first - 30
      prefix = "\u{2026}"
    }
    var text = AttributedString(prefix + String(decoding: units[min(cut, units.count)...], as: UTF16.self))
    let shift = prefix.utf16.count - cut
    let length = (prefix + String(decoding: units[min(cut, units.count)...], as: UTF16.self)).utf16.count
    for range in match.matchRanges {
      let start = range.start + shift, count = range.end - range.start
      guard start >= prefix.utf16.count, count > 0, start + count <= length, let found = Range(NSRange(location: start, length: count), in: text) else { continue }
      text[found].font = .system(.callout, design: .monospaced).bold()
      text[found].backgroundColor = .yellow.opacity(0.35)
    }
    return text
  }

  private func summary(_ rows: [ProjectContentMatch]) -> String {
    if let notice, !rows.isEmpty { return notice }
    guard !rows.isEmpty else { return "" }
    let files = Set(rows.map(\.path)).count
    let count = "\(rows.count.formatted())\(truncated ? "+" : "")"
    return "\(count) \(rows.count == 1 ? "result" : "results") in \(files.formatted()) \(files == 1 ? "file" : "files")"
  }

  private func search() async {
    let text = query
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
      matches = []
      notice = nil
      return
    }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled, let service = await app.fileService(for: key) else { return }
    searching = true
    defer { searching = false }
    do throws(FileService.Failure) {
      let result = try await service.searchContents(text, caseSensitive: caseSensitive, wholeWord: wholeWord, useRegex: useRegex)
      guard !Task.isCancelled else { return }
      matches = result.matches
      truncated = result.truncated
      notice = result.regexFallbackError.map { "Invalid regular expression, searched as text: \($0)" }
    } catch {
      guard !Task.isCancelled else { return }
      matches = []
      notice = error.localizedDescription
    }
    selection = 0
  }

  private func move(_ delta: Int, count: Int) {
    guard count > 0 else { return }
    selection = min(max(selection + delta, 0), count - 1)
  }

  private func open(_ rows: [ProjectContentMatch]) {
    guard rows.indices.contains(selection) else { return }
    let match = rows[selection]
    store.fileDialog = nil
    store.openFile(match.path, line: match.lineNumber, in: key)
  }
}
