import Foundation
import T3Contracts
import Testing

@testable import T3Composer

/// The synthetic provider catalog and settings the oracle runs the TypeScript against.
struct OracleCatalog {
  let providers: [ProviderSnapshot]
  let settings: [ComposerModelSettings]

  static func load() throws -> OracleCatalog {
    let item = try #require(try Oracle.cases("catalog").first)
    let output = try #require(item.output as? [String: Any])
    let providersData = try JSONSerialization.data(withJSONObject: output["providers"] as Any)
    let providers = try JSONDecoder().decode([ProviderSnapshot].self, from: providersData)
    func customModels(_ value: Any?) -> [CustomModelDefinition]? {
      guard let array = value as? [Any] else { return nil }
      var seen = Set<String>()
      var result: [CustomModelDefinition] = []
      for raw in array {
        let slug: String?
        var name: String?
        if let text = raw as? String { slug = text } else if let object = raw as? [String: Any] {
          slug = object["slug"] as? String
          name = object["name"] as? String
        } else { continue }
        guard let trimmed = slug?.jsTrim(), !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
        result.append(CustomModelDefinition(slug: trimmed, name: name?.jsTrim().isEmpty == false ? name!.jsTrim() : nil))
      }
      return result
    }
    let settings = (output["settings"] as! [[String: Any]]).map { raw -> ComposerModelSettings in
      var settings = ComposerModelSettings(planModeEnabled: (raw["planModeEnabled"] as? Bool) ?? false)
      for (id, any) in (raw["providerInstances"] as? [String: Any]) ?? [:] {
        let instance = any as! [String: Any]
        settings.instanceEnabled[id] = (instance["enabled"] as? Bool) ?? true
        if let custom = customModels((instance["config"] as? [String: Any])?["customModels"]) { settings.instanceCustomModels[id] = custom }
      }
      for (id, any) in (raw["providerModelPreferences"] as? [String: Any]) ?? [:] {
        let preference = any as! [String: Any]
        settings.hiddenModels[id] = preference["hiddenModels"] as? [String] ?? []
        settings.modelOrder[id] = preference["modelOrder"] as? [String] ?? []
      }
      return settings
    }
    return OracleCatalog(providers: providers, settings: settings)
  }

  func entries(_ settingsIndex: Int) -> [ProviderInstanceEntry] {
    ModelCatalog.sortEntries(ModelCatalog.applySettings(ModelCatalog.deriveEntries(providers), settings[settingsIndex]))
  }

  func entry(_ settingsIndex: Int, _ id: String) -> ProviderInstanceEntry { entries(settingsIndex).first { $0.instanceId == id }! }
}


extension OracleCatalog {
  /// A composer catalog with the oracle providers; instances are enabled via the second settings set.
  func composerCatalog(planMode: Bool = false, followUp: FollowUpBehavior = .queue, sendShortcut: SendShortcut = .enter) -> ComposerCatalog {
    var models = settings[1]
    models.planModeEnabled = planMode
    return ComposerCatalog(
      providers: providers,
      settings: ComposerSettings(sendShortcut: sendShortcut, followUpBehavior: followUp, richTextEnabled: true, models: models),
      capabilities: ComposerCapabilities(attachments: .init(attachmentUploadsCapabilityKnown: true, supportsAttachmentUploads: true, maxFileAttachmentBytes: 50 * 1024 * 1024), inlineMessageContext: true),
      defaultModelSelection: ModelSelection(instanceId: "codex", model: "gpt-6-astra", options: nil))
  }
}
