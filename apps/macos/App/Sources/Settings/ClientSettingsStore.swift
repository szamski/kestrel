import Foundation
import Observation
import T3Contracts

/// Client settings: preferences of this device, stored as `client-settings.json` in the app data directory and decoded with the
/// generated `ClientSettingsSchema` (missing keys take the contract defaults, like the web's `DEFAULT_CLIENT_SETTINGS`).
/// Everything the app reads live (composer, diff, confirmations, time format) goes through `shared`.
@MainActor @Observable
final class ClientSettingsStore {
  static let shared = ClientSettingsStore(directory: AppModel.dataDirectory)

  private(set) var client: ClientSettingsSchema
  /// Set when the last write failed; the in-memory value still applies for this session.
  private(set) var saveFailed = false
  @ObservationIgnored private let fileURL: URL?

  /// `directory: nil` keeps everything in memory (previews, debug snapshots).
  init(directory: URL?) {
    fileURL = directory?.appending(path: "client-settings.json")
    client = ClientSettingsSchema()
    guard let fileURL else { return }
    if let data = try? Data(contentsOf: fileURL) {
      if let decoded = try? JSONDecoder().decode(ClientSettingsSchema.self, from: data) {
        client = decoded
      } else {
        // Unreadable: keep the file for inspection instead of letting defaults overwrite it.
        let aside = fileURL.deletingLastPathComponent().appending(path: "client-settings.invalid.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
      }
    } else {
      importLegacyDefaults()
      save()
    }
  }

  func update(_ edit: (inout ClientSettingsSchema) -> Void) {
    var next = client
    edit(&next)
    guard next != client else { return }
    client = next
    save()
  }

  private func save() {
    guard let fileURL else { return }
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(client).write(to: fileURL, options: .atomic)
      saveFailed = false
    } catch {
      saveFailed = true
    }
  }

  /// First run of the settings store: carry over the values earlier builds kept in UserDefaults.
  private func importLegacyDefaults() {
    let d = UserDefaults.standard
    func flag(_ key: String) -> Bool? { d.object(forKey: key) as? Bool }
    if let raw = d.string(forKey: "composer.sendShortcut") { client.sendShortcut = .init(rawValue: raw) }
    if let raw = d.string(forKey: "composer.followUpBehavior") { client.followUpBehavior = .init(rawValue: raw) }
    if let value = flag("composer.planModeEnabled") { client.planModeEnabled = value }
    if let value = flag("composer.showSkillsInSlashMenu") { client.showSkillsInSlashMenu = value }
    if let value = flag("composer.richTextEnabled") { client.composerRichTextEnabled = value }
    if let value = flag("composer.collapseOnScroll") { client.composerCollapseOnScroll = value }
    if let value = flag("composer.contextWindowMeterEnabled") { client.contextWindowMeterEnabled = value }
    if let value = flag("confirmThreadArchive") { client.confirmThreadArchive = value }
    if let raw = d.string(forKey: "diff.layout") { client.diffLayout = .init(rawValue: raw) }
    if let value = flag("diff.wordWrap") { client.wordWrap = value }
    if let value = flag("diff.ignoreWhitespace") { client.diffIgnoreWhitespace = value }
    if let value = flag("diff.filesCollapsed") { client.diffFilesCollapsed = value }
  }
}
