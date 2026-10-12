import AppKit
import Observation
import T3ClientRuntime
import T3Contracts
import T3Keybindings
import T3Protocol

/// State and server calls of Settings › Keybindings. Rules come from the representative environment (`keybindingsUpdated`
/// keeps them current); an edit is sent to every connected environment of the selection, as in the web page.
@MainActor @Observable
final class KeybindingsController {
  let model: SettingsModel
  var query = ""
  var isAdding = false
  /// The row (or "new") whose shortcut is being recorded.
  private(set) var recordingId: String?
  private(set) var savingIds: Set<String> = []
  @ObservationIgnored private var monitor: Any?

  init(model: SettingsModel) { self.model = model }

  // MARK: Reading

  var targetIds: [EnvironmentId] { model.targets.map(\.environmentId) }
  var canWrite: Bool { !targetIds.isEmpty }
  private var config: ServerConfig? { targetIds.first.flatMap { model.runtime.serverConfigs[$0]?.config } }
  var rules: [KeybindingRule] { config?.keybindings ?? [] }
  var configPath: String? { config?.keybindingsConfigPath }

  // MARK: Writing

  /// Sends the edit to every target. A refusal is reported by environment; returns whether all accepted it.
  @discardableResult
  func upsert(_ input: ServerUpsertKeybindingInput, rowId: String) async -> Bool {
    await write(rowId: rowId, failure: "Keybinding not saved.") { session in _ = try await session.call(Rpc.serverUpsertKeybinding, input) }
  }

  func remove(_ row: KeybindingRow) async {
    let target = removeTarget(row)
    await write(rowId: row.id, failure: "Keybinding not removed.") { session in _ = try await session.call(Rpc.serverRemoveKeybinding, target) }
  }

  /// Puts the built-in key back by replacing the custom rule with the default one.
  func reset(_ row: KeybindingRow) async {
    guard row.canReset, let defaultKey = row.defaultKey else { return }
    await upsert(
      ServerUpsertKeybindingInput(
        key: defaultKey, command: row.command, when: row.defaultWhen.isEmpty ? nil : row.defaultWhen, replace: removeTarget(row)), rowId: row.id)
  }

  func removeTarget(_ row: KeybindingRow) -> ServerRemoveKeybindingInput {
    ServerRemoveKeybindingInput(key: row.key, command: row.command, when: row.when.isEmpty ? nil : row.when)
  }

  private func write(rowId: String, failure: String, _ call: @escaping @Sendable (any EnvironmentSession) async throws -> Void) async -> Bool {
    let ids = targetIds
    guard !ids.isEmpty else {
      model.report("\(failure) Connect an environment first.")
      return false
    }
    savingIds.insert(rowId)
    defer { savingIds.remove(rowId) }
    var failed: [String] = []
    var reason = ""
    for id in ids {
      let label = model.runtime.environments.first { $0.environmentId == id }?.label ?? id.rawValue
      guard let session = await model.runtime.runtime(for: id)?.supervisor.session.value else {
        failed.append(label)
        reason = "It is not connected."
        continue
      }
      do { try await call(session) } catch {
        failed.append(label)
        reason = SourceControlStore.describe(error)
      }
    }
    guard !failed.isEmpty else { return true }
    model.report("\(failure) \(failed.count == ids.count ? "" : "Only failed on \(failed.joined(separator: ", ")). ")\(reason)")
    return false
  }

  // MARK: keybindings.json

  func openFile() async {
    guard let id = targetIds.first, let path = configPath, !path.isEmpty else { return }
    if let editor = config?.availableEditors.first, let session = await model.runtime.runtime(for: id)?.supervisor.session.value,
      (try? await session.call(Rpc.shellOpenInEditor, LaunchEditorInput(cwd: path, editor: editor))) != nil
    {
      return
    }
    let host = model.runtime.connectionEntry(id)?.httpBaseURL.host(percentEncoded: false) ?? ""
    if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), FileManager.default.fileExists(atPath: path) {
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
    } else {
      model.report("Unable to open keybindings file. No editor is available for this environment.")
    }
  }

  // MARK: Recording

  /// Captures the next chord. Escape cancels; a key a shortcut cannot name (a lone modifier) is ignored so recording keeps waiting.
  func startRecording(_ id: String, onKey: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    stopRecording()
    recordingId = id
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      nonisolated(unsafe) let unsafeEvent = event
      MainActor.assumeIsolated {
        guard let self else { return }
        let flags = unsafeEvent.modifierFlags
        if unsafeEvent.keyCode == 53, flags.intersection([.command, .control, .option, .shift]).isEmpty {
          self.stopRecording()
          onCancel()
          return
        }
        let descriptor = KeyDescriptor(
          keyCode: unsafeEvent.keyCode, characters: unsafeEvent.charactersIgnoringModifiers, meta: flags.contains(.command), ctrl: flags.contains(.control),
          shift: flags.contains(.shift), alt: flags.contains(.option))
        guard let input = KeybindingCatalog.recordedInput(descriptor) else { return }
        self.stopRecording()
        onKey(input)
      }
      return nil
    }
  }

  func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recordingId = nil
  }
}
