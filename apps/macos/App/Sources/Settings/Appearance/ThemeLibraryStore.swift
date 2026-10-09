import Foundation
import T3Theme

/// Custom themes on disk: one theme file v1 (`<id>.json`, the format the web exports and imports) per theme in
/// `<app data>/themes`. Writes are atomic so a reader never sees a partial file.
struct ThemeLibraryStore {
  let directory: URL?

  init(directory: URL?) { self.directory = directory }

  private func fileURL(_ id: String) -> URL? { directory?.appending(path: "\(id).json") }

  /// Every readable theme, and a note for each file that was not. Files are read leniently, so a theme written by another
  /// build keeps the colors this one understands.
  func load() -> (themes: [ThemeDefinition], issues: [String]) {
    guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
    var themes: [ThemeDefinition] = []
    var issues: [String] = []
    for name in names.sorted() where name.hasSuffix(".json") {
      do {
        let data = try Data(contentsOf: directory.appending(path: name))
        let theme = try ThemeFile.parse(data: data, lenient: true)
        if themes.contains(where: { $0.id == theme.id }) { throw ThemeError("duplicate theme id \"\(theme.id)\"") }
        themes.append(theme)
      } catch {
        issues.append("\(name): \(error.localizedDescription)")
      }
    }
    return (themes, issues)
  }

  func write(_ theme: ThemeDefinition) throws {
    guard let url = fileURL(theme.id), let directory else { throw ThemeError("Themes cannot be saved in this session.") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(try ThemeFile.serialize(theme).utf8).write(to: url, options: .atomic)
  }

  func remove(_ ids: [String]) throws {
    for id in ids {
      guard let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) else { continue }
      try FileManager.default.removeItem(at: url)
    }
  }
}
