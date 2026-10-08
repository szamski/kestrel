import Foundation

/// Saved environments (id, label, base URLs, enabled flag) as a JSON file under an injectable
/// app-support directory. Bearer credentials never live here: they are only in the Keychain.
public struct EnvironmentCatalogFile: Sendable {
  public let url: URL
  private struct Document: Codable {
    var version = 1
    var environments: [EnvironmentConnectionEntry]
  }

  public init(directory: URL) { url = directory.appendingPathComponent("environments.json") }

  public func load() -> [EnvironmentConnectionEntry] {
    guard let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data) else { return [] }
    return document.environments
  }

  public func save(_ entries: [EnvironmentConnectionEntry]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Document(environments: entries)).write(to: url, options: .atomic)
  }
}
