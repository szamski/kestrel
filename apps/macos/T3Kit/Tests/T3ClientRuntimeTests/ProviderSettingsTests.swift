import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Instance rows, patches, model ordering and custom-model drafts: the rules behind Settings › Providers.
@Suite struct ProviderSettingsTests {
  func model(_ slug: String, custom: Bool = false) -> ProviderModelItem { ProviderModelItem(slug: slug, name: slug, isCustom: custom) }

  @Test func defaultSlotsComeFromTheLegacyBlobAndCursorWaitsForTheServer() {
    var settings = ServerSettings()
    settings.providerInstances["codex_work"] = ServerSettingsProviderInstancesValue(driver: "codex", displayName: "Work")
    let rows = ProviderInstances.rows(settings: settings, liveInstanceIds: ["codex"])
    #expect(rows.map(\.instanceId) == ["codex", "codex_work", "claudeAgent", "grok", "opencode", "antigravity"])
    #expect(rows.filter(\.isDefault).count == 5 && rows.allSatisfy { !$0.isDirty })
    #expect(ProviderInstances.isEnabled(rows[0].instance) && !ProviderInstances.isEnabled(rows[3].instance), "Codex is on by default, Grok is off")
    #expect(ProviderInstances.rows(settings: settings, liveInstanceIds: ["cursor"]).map(\.instanceId).contains("cursor"))
  }

  @Test func editingADefaultSlotMovesItIntoTheInstanceMap() throws {
    let settings = ServerSettings()
    let row = try #require(ProviderInstances.rows(settings: settings, liveInstanceIds: []).first)
    var next = row.instance
    next.enabled = false
    let patch = ProviderInstances.updatePatch(settings: settings, row: row, next: next)
    #expect(patch.providerInstances?["codex"]?.enabled == false)
    let applied = try #require(SettingsPlanner.applying(patch, to: settings))
    let again = try #require(ProviderInstances.rows(settings: applied, liveInstanceIds: []).first)
    #expect(!ProviderInstances.isEnabled(again.instance) && again.isDirty)
    let reset = try #require(ProviderInstances.resetDefaultPatch(settings: applied, driver: "codex"))
    #expect(reset.providerInstances?["codex"] == nil)
  }

  @Test func deletingAnInstanceDropsItOptimisticallyAndUsageSourcesMergePerEntry() throws {
    var settings = ServerSettings()
    settings.providerInstances["codex_work"] = ServerSettingsProviderInstancesValue(driver: "codex", displayName: "Work", accentColor: "#112233")
    let removed = try #require(SettingsPlanner.applying(ProviderInstances.deletePatch(settings: settings, instanceId: "codex_work"), to: settings))
    #expect(removed.providerInstances["codex_work"] == nil)

    let add = ProviderUsageSources.addPatch(label: " ", url: "https://Hub.example.ts.net:8318/x", managementKey: " key ")
    let withHub = try #require(SettingsPlanner.applying(add, to: settings))
    #expect(Array(withHub.usageLimitSources.keys) == ["cliproxy-hub.example.ts.net-8318"])
    #expect(withHub.usageLimitSources.values.first?.label == nil && withHub.usageLimitSources.values.first?.managementKey == "key")
    let without = try #require(SettingsPlanner.applying(ProviderUsageSources.removePatch(id: "cliproxy-hub.example.ts.net-8318"), to: withHub))
    #expect(without.usageLimitSources.isEmpty)
  }

  @Test func fieldsDropEmptyValuesAndStoreASelectsDefaultAsAnOmittedKey() throws {
    let codex = try #require(ProviderCatalog.driver("codex")).fields[0]
    var config = ProviderConfig.applying(.text("/opt/codex"), to: codex, in: nil)
    #expect(ProviderConfig.string(config, "binaryPath") == "/opt/codex")
    config = ProviderConfig.applying(.text("  "), to: codex, in: config)
    #expect(config == nil)

    let method = try #require(ProviderCatalog.driver("antigravity")).fields[0]
    #expect(ProviderConfig.selection(nil, method) == "oauth-personal")
    let business = ProviderConfig.applyingSelection("oauth-business", to: method, in: nil)
    #expect(ProviderConfig.selection(business, method) == "oauth-business")
    #expect(ProviderConfig.applyingSelection("oauth-personal", to: method, in: business) == nil)

    let compact = try #require(ProviderCatalog.driver("claudeAgent")).fields.first { $0.key == "autoCompactWindow" }
    #expect(compact?.error(for: "") == nil && compact?.error(for: "300000") == nil && compact?.error(for: "1000000") == nil)
    #expect(compact?.error(for: "99999") != nil && compact?.error(for: "abc") != nil)
  }

  @Test func modelsListFavoritesThenVisibleThenHiddenAndMoveInsideTheirGroup() {
    let models = ["a", "b", "c", "d", "e"].map { model($0) }
    let favorites: Set = ["d"], hidden: Set = ["b"]
    let display = ProviderModels.displayOrder(models, favorites: favorites, hidden: hidden, order: ["c", "a"])
    #expect(display.map(\.slug) == ["d", "c", "a", "e", "b"])
    #expect(ProviderModels.order(afterMoving: "c", by: 1, in: display, favorites: favorites, hidden: hidden) == ["d", "a", "c", "e", "b"])
    #expect(ProviderModels.order(afterMoving: "d", by: 1, in: display, favorites: favorites, hidden: hidden) == nil, "a favorite cannot cross into the visible group")
    #expect(ProviderModels.order(afterMoving: "e", by: 1, in: display, favorites: favorites, hidden: hidden) == nil)
  }

  @Test func bulkToggleHidesBuiltInsOnlyAndPreferencesStayTidy() {
    let models = [model("a"), model("b"), model("mine", custom: true)]
    #expect(ProviderModels.hiddenAfterBulkToggle(models, hidden: ["x"]) == ["x", "a", "b"])
    #expect(ProviderModels.hiddenAfterBulkToggle(models, hidden: ["x", "a", "b"]) == ["x"])
    #expect(ProviderModels.normalizedPreferences(hidden: [" ", ""], order: []) == nil)
    #expect(ProviderModels.normalizedPreferences(hidden: ["a", "a"], order: ["b"])?.hiddenModels == ["a"])
    let favorites = ProviderModels.favorites(
      [ClientSettingsSchemaFavoritesItem(provider: "codex", model: "keep"), ClientSettingsSchemaFavoritesItem(provider: "claudeAgent", model: "old")],
      instanceId: "claudeAgent", replacingWith: ["new", "new", " "])
    #expect(favorites.map(\.model) == ["keep", "new"])
  }

  @Test func customModelsRoundTripAsBareSlugsOrEntriesAndTheDraftIsValidated() throws {
    let config = JSONValue.object(["customModels": .array([.string("plain"), .string("plain"), .object(["slug": .string("named"), "name": .string("Named")])])])
    let entries = CustomModels.read(config)
    #expect(entries.map(\.slug) == ["plain", "named"] && entries[1].name == "Named")
    #expect(CustomModels.writing(entries, into: nil)["customModels"]?.arrayValue?.first == .string("plain"))

    #expect(throws: ProviderMessage.self) { try CustomModels.validatedNewSlug("plain", builtIn: [], existing: entries).get() }
    #expect(throws: ProviderMessage.self) { try CustomModels.validatedNewSlug("gpt", builtIn: [model("gpt")], existing: []).get() }
    #expect(try CustomModels.validatedNewSlug(" fresh ", builtIn: [], existing: entries).get() == "fresh")

    let preset = try #require(ProviderCatalog.driver("claudeAgent")).presets[0]
    var draft = CustomModels.Draft(slug: "fresh", name: " ", descriptors: [CustomModels.descriptor(from: preset)])
    #expect(CustomModels.validate(draft) == nil)
    let entry = CustomModels.entry(from: draft)
    #expect(entry.name == "fresh")
    let reread = CustomModels.draft(entry)
    #expect(reread.descriptors.first?.choices.first(where: \.isDefault)?.value == "high")
    #expect(ProviderModels.capabilityLabels(entry.descriptors) == ["Reasoning"])
    draft.descriptors[0].choices[1].value = "high"
    #expect(CustomModels.validate(draft)?.contains("used twice") == true)
  }

  @Test func environmentRowsWaitUntilTheyAreCompleteAndInstanceIdsAreChecked() {
    var row = ProviderInstances.EnvironmentDraft()
    #expect(ProviderInstances.publishedEnvironment([row])?.isEmpty == true, "an untouched new row is skipped")
    row.name = "1BAD"
    #expect(ProviderInstances.publishedEnvironment([row]) == nil)
    row.name = "API_KEY"
    #expect(ProviderInstances.publishedEnvironment([row])?.first?.name == "API_KEY")
    #expect(ProviderInstances.deriveInstanceId(driver: "codex", label: " Work Mac! ") == "codex_work_mac")
    #expect(ProviderInstances.idError("9x", existing: []) != nil && ProviderInstances.idError("codex", existing: ["codex"]) != nil)
    #expect(ProviderInstances.idError("codex_work", existing: []) == nil)
    #expect(ProviderInstances.normalizedAccent("#2563EB") == "#2563EB" && ProviderInstances.normalizedAccent("blue") == nil)
  }
}
