import Foundation
import T3Contracts
import Testing

@testable import T3Composer

private func selectionJSON(_ any: Any?) throws -> ModelSelection? {
  guard let any, !(any is NSNull) else { return nil }
  return try JSONDecoder().decode(ModelSelection.self, from: JSONSerialization.data(withJSONObject: any))
}

private func optionsJSON(_ options: [ProviderOptionSelection]?) throws -> Any {
  guard let options else { return NSNull() }
  return try json(options)
}

private func optionsFrom(_ any: Any?) throws -> [ProviderOptionSelection]? {
  guard let any, !(any is NSNull) else { return nil }
  return try JSONDecoder().decode([ProviderOptionSelection].self, from: JSONSerialization.data(withJSONObject: any))
}

@Suite("Model catalog oracle") struct ModelOracleTests {
  @Test func constantsMatchContracts() throws {
    let output = try #require(try Oracle.cases("modelConstants").first?.output as? [String: Any])
    #expect(output["defaultModel"] as? String == ModelConstants.defaultModel)
    #expect(output["antigravity"] as? String == ModelConstants.antigravityDefaultModel)
    #expect(output["byProvider"] as? [String: String] == ModelConstants.defaultModelByProvider)
    #expect(output["display"] as? [String: String] == ModelConstants.providerDisplayNames)
    #expect(output["aliases"] as? [String: [String: String]] == ModelConstants.slugAliasesByProvider)
  }

  @Test func instancesAndOptions() throws {
    let catalog = try OracleCatalog.load()
    try Oracle.check("providerEntries") { input in
      catalog.entries(input.int("settingsIndex")).map { entry in
        ["instanceId": entry.instanceId, "driverKind": entry.driverKind, "displayName": entry.displayName,
          "accentColor": entry.accentColor as Any? ?? NSNull(), "enabled": entry.enabled, "installed": entry.installed,
          "status": entry.status.rawValue, "isDefault": entry.isDefault, "isAvailable": entry.isAvailable, "pickerReady": entry.isPickerReady] as [String: Any]
      }
    }
    try Oracle.check("modelOptions") { input in
      let settingsIndex = input.int("settingsIndex")
      let entry = catalog.entry(settingsIndex, input.string("instanceId"))
      return ModelCatalog.modelOptions(for: entry, settings: catalog.settings[settingsIndex], selectedModel: input["selected"] as? String).map { option in
        ["slug": option.slug, "name": option.name, "isCustom": option.isCustom, "isDefault": option.isDefault, "isLegacy": option.isLegacy,
          "isUnavailable": option.isUnavailable, "shortName": option.shortName as Any? ?? NSNull(), "badge": option.badge as Any? ?? NSNull()] as [String: Any]
      }
    }
    try Oracle.check("resolveInstanceModel") { input in
      ModelCatalog.resolveModel(
        instanceId: input.string("instanceId"), settings: catalog.settings[input.int("settingsIndex")], providers: catalog.providers,
        selectedModel: input["selectedModel"] as? String, preserveUnavailableSelection: input.bool("preserve")) as Any? ?? NSNull()
    }
    try Oracle.check("resolveDriverModel") { input in
      ModelCatalog.resolveAppModel(
        driver: input.string("driver"), settings: catalog.settings[input.int("settingsIndex")], providers: catalog.providers, selectedModel: input["selectedModel"] as? String)
    }
    try Oracle.check("driverDefaults") { input in
      let driver = input.string("driver")
      return ["selectable": ModelCatalog.resolveSelectableDriver(catalog.providers, instanceOrDriver: driver), "defaultModel": ModelCatalog.defaultServerModel(catalog.providers, driver: driver)]
    }
    try Oracle.check("selectableInstance") { input in
      let instanceId = input["instanceId"] as? String
      let entries = ModelCatalog.deriveEntries(catalog.providers)
      let selection = instanceId.map { ModelSelection(instanceId: ProviderInstanceId($0), model: "x", options: nil) }
      return [
        "selectable": ModelCatalog.resolveSelectableEntry(entries, instanceId: instanceId)?.instanceId as Any? ?? NSNull(),
        "defaultModel": instanceId.flatMap { ModelCatalog.defaultInstanceModel(catalog.providers, instanceId: $0) } as Any? ?? NSNull(),
        "defaultSelection": try ModelPicker.resolveDefaultSelection(providers: catalog.providers, selection: selection).map(json) as Any? ?? NSNull(),
      ]
    }
  }

  @Test func providerStateAndTraits() throws {
    let catalog = try OracleCatalog.load()
    try Oracle.check("providerState") { input in
      let entry = catalog.entry(0, input.string("instanceId"))
      let state = ModelOptions.providerState(
        driver: entry.driverKind, model: input.string("model"), models: entry.models, modelOptions: try optionsFrom(input["modelOptions"]),
        promptInjectionUltrathink: ComposerSubmission.isUltrathinkPrompt(input.string("prompt")), planModeEnabled: input.bool("planModeEnabled"))
      return ["promptEffort": state.promptEffort as Any? ?? NSNull(), "modelOptionsForDispatch": try optionsJSON(state.modelOptionsForDispatch), "ultrathink": state.ultrathinkActive]
    }
    try Oracle.check("traits") { input in
      let entry = catalog.entry(0, input.string("instanceId"))
      let prompt = input.string("prompt")
      let state = Traits.state(
        driver: entry.driverKind, models: entry.models, model: input.string("model"), prompt: prompt,
        modelOptions: try optionsFrom(input["modelOptions"]), planModeEnabled: input.bool("planModeEnabled"))
      // The oracle's trigger display reads descriptors resolved without the unavailable-model fallback.
      let caps = ModelOptions.capabilities(models: entry.models, model: input.string("model"), driver: entry.driverKind, planModeEnabled: input.bool("planModeEnabled"))
      let descriptors = ModelOptions.resolvedDescriptors(caps, selections: try optionsFrom(input["modelOptions"]))
      var primary: SelectProviderOptionDescriptor?
      for descriptor in descriptors { if case .select(let value) = descriptor { primary = value; break } }
      let controlled = (primary?.promptInjectedValues?.count ?? 0) > 0 && ComposerSubmission.isUltrathinkPrompt(prompt)
      let display = Traits.triggerDisplay(driver: entry.driverKind, descriptors: descriptors, primaryId: primary?.id, ultrathinkPromptControlled: controlled)
      return ["shouldRender": state.hasAnyControls, "display": ["label": display.label, "showFastModeIcon": display.showFastModeIcon]] as [String: Any]
    }
  }

  @Test func effectiveModelAndPicker() throws {
    let catalog = try OracleCatalog.load()
    try Oracle.check("effectiveModel") { input in
      var drafts: [String: ModelSelection] = [:]
      for (key, value) in (input["draft"] as? [String: Any]) ?? [:] { drafts[key] = try selectionJSON(value) }
      let state = ModelPicker.effectiveState(
        draftSelections: drafts, providers: catalog.providers, selectedDriver: input.string("selectedProvider"),
        selectedInstanceId: input["selectedInstanceId"] as? String, threadSelection: try selectionJSON(input["threadSelection"]),
        projectSelection: try selectionJSON(input["projectSelection"]), settings: catalog.settings[input.int("settingsIndex")])
      var options: Any = NSNull()
      if let map = state.modelOptions { options = try map.mapValues { try json($0) } }
      return ["selectedModel": state.selectedModel, "modelOptions": options]
    }
    try Oracle.check("pickerSearch") { input in
      let model = input["model"] as! [String: Any]
      let searchable = ModelPicker.Searchable(
        driverKind: model.string("driverKind"), providerDisplayName: model.string("providerDisplayName"), name: model.string("name"),
        shortName: model.optionalString("shortName"), subProvider: model.optionalString("subProvider"), isFavorite: model.optionalBool("isFavorite") ?? false)
      return ModelPicker.score(searchable, query: input.string("query")) as Any? ?? NSNull()
    }
    try Oracle.check("pickerKeys") { input in
      if let instanceId = input.optionalString("instanceId") {
        let slug = input.string("slug")
        let key = ModelPicker.modelKey(instanceId: instanceId, slug: slug)
        let parsed = ModelPicker.parseModelKey(key)
        let legacy = ModelPicker.legacySectionKey(instanceId)
        return [
          "key": key, "parsed": parsed.map { ["instanceId": $0.instanceId, "slug": $0.slug] } as Any? ?? NSNull(), "legacy": legacy,
          "parsedLegacy": ModelPicker.parseLegacySectionKey(legacy) as Any? ?? NSNull(),
        ] as [String: Any]
      }
      let key = input.string("key")
      return [
        "parsed": ModelPicker.parseModelKey(key).map { ["instanceId": $0.instanceId, "slug": $0.slug] } as Any? ?? NSNull(),
        "parsedLegacy": ModelPicker.parseLegacySectionKey(key) as Any? ?? NSNull(),
      ] as [String: Any]
    }
  }

  @Test func skillsAndSlashCommands() throws {
    let catalog = try OracleCatalog.load()
    let codex = catalog.providers[0]
    try Oracle.check("skillHelpers") { _ in
      let skills = codex.skills
      return [
        "names": skills.map(ProviderSkills.displayName), "invocable": skills.map(ProviderSkills.isUserInvocable),
        "deduped": ProviderSkills.dedupeByName(skills).map(\.name), "sourceKinds": skills.map { ProviderSkills.sourceKind($0).rawValue },
        "slashMenuOn": ProviderSkills.forSlashMenu(skills, showSkillsInSlashMenu: true).map(\.name),
        "slashMenuOff": ProviderSkills.forSlashMenu(skills, showSkillsInSlashMenu: false).map(\.name),
        "commands": ProviderSkills.slashCommandsForSlashMenu(codex.slashCommands, visibleSkills: ProviderSkills.forSlashMenu(skills, showSkillsInSlashMenu: true)).map(\.name),
      ] as [String: Any]
    }
    try Oracle.check("skillSearch") { input in ProviderSkills.search(codex.skills, query: input.string("query")).map(\.name) }
    var items: [SlashMenuItem] = [
      .builtIn(.model, label: "/model", description: "Switch response model for this thread"),
      .builtIn(.plan, label: "/plan", description: "Switch this thread into plan mode"),
      .builtIn(.default, label: "/default", description: "Switch this thread back to normal build mode"),
    ]
    for command in codex.slashCommands {
      items.append(.provider(driver: "codex", command: command, label: "/\(command.name)", description: command.description ?? command.input?.hint ?? "Run provider command"))
    }
    for skill in ProviderSkills.forSlashMenu(codex.skills, showSkillsInSlashMenu: true) {
      items.append(.skill(driver: "codex", skill: skill, label: "/skill:\(skill.name)", description: skill.shortDescription ?? skill.description ?? (skill.scope.map { "\($0) skill" } ?? "")))
    }
    try Oracle.check("slashSearch") { input in
      SlashCommandSearch.search(SlashCommandSearch.itemsForPromptPosition(items, isAtPromptStart: input.bool("atStart")), query: input.string("query")).map(\.id)
    }
  }
}
