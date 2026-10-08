import Foundation
import T3Contracts

/// Model picker search, keys and selection resolution (`modelPickerSearch.ts`,
/// `modelPickerKeys.ts`, `providerInstances.ts`, `composerDraftStore.ts#deriveEffectiveComposerModelState`).
public enum ModelPicker {
  public struct Searchable: Sendable, Hashable {
    public var driverKind: String
    public var providerDisplayName: String
    public var name: String
    public var shortName: String?
    public var subProvider: String?
    public var isFavorite: Bool

    public init(driverKind: String, providerDisplayName: String, name: String, shortName: String? = nil, subProvider: String? = nil, isFavorite: Bool = false) {
      self.driverKind = driverKind
      self.providerDisplayName = providerDisplayName
      self.name = name
      self.shortName = shortName
      self.subProvider = subProvider
      self.isFavorite = isFavorite
    }
  }

  private static let favoriteScoreBoost = 24

  public static func searchText(_ model: Searchable) -> String {
    SearchRanking.normalizeQuery(
      [model.name, model.shortName, model.subProvider, model.driverKind, model.providerDisplayName]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
  }

  private static func fields(_ model: Searchable) -> [String] {
    [SearchRanking.normalizeQuery(model.name)]
      + (model.shortName.map { [SearchRanking.normalizeQuery($0)] } ?? [])
      + (model.subProvider.map { [SearchRanking.normalizeQuery($0)] } ?? [])
      + [SearchRanking.normalizeQuery(model.driverKind), SearchRanking.normalizeQuery(model.providerDisplayName), searchText(model)]
  }

  /// `split(/\s+/u)` on an already trimmed, lowercased query.
  private static func tokens(_ query: String) -> [String] {
    var out: [String] = []
    var current: [UInt16] = []
    for unit in query.utf16 {
      if JS.isSpace(unit) {
        if !current.isEmpty { out.append(String(decoding: current, as: UTF16.self)) }
        current = []
      } else {
        current.append(unit)
      }
    }
    if !current.isEmpty { out.append(String(decoding: current, as: UTF16.self)) }
    return out
  }

  /// Lower is better; nil when a token matches nothing. Favorites get a boost.
  public static func score(_ model: Searchable, query: String) -> Int? {
    let tokens = tokens(SearchRanking.normalizeQuery(query))
    if tokens.isEmpty { return 0 }
    let fields = fields(model)
    var total = 0
    for token in tokens {
      var best: Int?
      for (index, field) in fields.enumerated() {
        let base = index * 10
        let score = SearchRanking.queryScore(
          value: field, query: token, exactBase: base, prefixBase: base + 2, boundaryBase: base + 4, includesBase: base + 6,
          fuzzyBase: token.jsLength >= 3 ? base + 100 : nil)
        if let score, best == nil || score < best! { best = score }
      }
      guard let best else { return nil }
      total += best
    }
    return model.isFavorite ? total - favoriteScoreBoost : total
  }

  public static func modelKey(instanceId: String, slug: String) -> String { "model:\(instanceId.jsLength):\(instanceId)\(slug)" }

  public static func parseModelKey(_ key: String) -> (instanceId: String, slug: String)? {
    guard key.hasPrefix("model:") else { return nil }
    let encoded = key.jsSlice("model:".jsLength)
    let separator = encoded.jsIndex(of: 0x3A)
    if separator == -1 { return nil }
    let lengthText = encoded.jsSlice(0, separator)
    guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let length = Int(lengthText) else { return nil }
    let value = encoded.jsSlice(separator + 1)
    if length > value.jsLength { return nil }
    return (value.jsSlice(0, length), value.jsSlice(length))
  }

  public static func legacySectionKey(_ instanceId: String) -> String { "legacy-models:\(instanceId)" }

  public static func parseLegacySectionKey(_ key: String) -> String? {
    key.hasPrefix("legacy-models:") ? String(key.dropFirst("legacy-models:".count)) : nil
  }

  // MARK: Selection resolution

  /// A valid stored selection is preserved verbatim. Falling back to another instance also resets
  /// the model to that instance's own default.
  public static func resolveDefaultSelection(providers: [ProviderSnapshot], selection: ModelSelection?) -> ModelSelection? {
    let entries = ModelCatalog.deriveEntries(providers)
    guard let instanceId = ModelCatalog.resolveSelectableEntry(entries, instanceId: selection?.instanceId.rawValue)?.instanceId else { return nil }
    if selection?.instanceId.rawValue == instanceId { return selection }
    guard let model = ModelCatalog.defaultInstanceModel(providers, instanceId: instanceId) else { return nil }
    return ModelSelection(instanceId: ProviderInstanceId(instanceId), model: model, options: nil)
  }

  public struct EffectiveState: Sendable, Hashable {
    public var selectedModel: String
    public var modelOptions: [String: [ProviderOptionSelection]]?
  }

  /// The model shown in the composer and the options per instance (`deriveEffectiveComposerModelState`).
  public static func effectiveState(
    draftSelections: [String: ModelSelection], providers: [ProviderSnapshot], selectedDriver: String, selectedInstanceId: String?,
    threadSelection: ModelSelection?, projectSelection: ModelSelection?, settings: ComposerModelSettings
  ) -> EffectiveState {
    let baseCandidate = threadSelection?.model ?? projectSelection?.model
    let preserveThreadModel = selectedInstanceId != nil && threadSelection?.instanceId.rawValue == selectedInstanceId
    let baseModel: String = {
      if let selectedInstanceId,
        let resolved = ModelCatalog.resolveModel(
          instanceId: selectedInstanceId, settings: settings, providers: providers, selectedModel: baseCandidate, preserveUnavailableSelection: preserveThreadModel)
      {
        return resolved
      }
      if selectedDriver == "antigravity", selectedInstanceId != nil { return "" }
      return ModelCatalog.resolveAppModel(driver: selectedDriver, settings: settings, providers: providers, selectedModel: baseCandidate)
    }()
    let instanceSelection = selectedInstanceId.flatMap { draftSelections[$0] }
    let legacySelection: ModelSelection? =
      selectedDriver == "antigravity" && selectedInstanceId != nil && selectedInstanceId != selectedDriver ? nil : draftSelections[selectedDriver]
    let active = instanceSelection ?? legacySelection
    let activeInstanceId = instanceSelection != nil ? (selectedInstanceId ?? selectedDriver) : selectedDriver
    let selectedModel: String
    if let model = active?.model, !model.isEmpty {
      selectedModel =
        ModelCatalog.resolveModel(instanceId: activeInstanceId, settings: settings, providers: providers, selectedModel: model, preserveUnavailableSelection: true)
        ?? (selectedDriver == "antigravity" ? "" : ModelCatalog.resolveAppModel(driver: selectedDriver, settings: settings, providers: providers, selectedModel: model))
    } else {
      selectedModel = baseModel
    }
    func options(_ map: [String: ModelSelection]) -> [String: [ProviderOptionSelection]]? {
      var result: [String: [ProviderOptionSelection]] = [:]
      for (instance, selection) in map { if let options = selection.options, !options.isEmpty { result[instance] = options } }
      return result.isEmpty ? nil : result
    }
    func single(_ selection: ModelSelection?) -> [String: [ProviderOptionSelection]]? {
      guard let selection, let options = selection.options, !options.isEmpty else { return nil }
      return [selection.instanceId.rawValue: options]
    }
    return EffectiveState(selectedModel: selectedModel, modelOptions: options(draftSelections) ?? single(threadSelection) ?? single(projectSelection))
  }

  public struct ProviderResolution: Sendable {
    public var entry: ProviderInstanceEntry?
    public var requestedDriver: String
    public var lockedContinuationGroupKey: String?
    /// The instance the user asked for when none is usable (for the "enable it" hint).
    public var unavailableInstanceId: String?
  }

  /// The instance that will run the turn: the first candidate that is enabled and available among
  /// the compatible ones, else a ready one. A started thread stays on its driver (and continuation
  /// group), and Antigravity history never moves to another profile.
  public static func resolveComposerProvider(
    entries: [ProviderInstanceEntry], candidateInstanceIds: [String?], lockedDriver: String?, lockedInstanceId: String?
  ) -> ProviderResolution {
    let requested = candidateInstanceIds.first { $0 != nil && $0 != NoProvider.instanceId }.flatMap { $0 }
    let requestedDriver = lockedDriver ?? entries.first(where: { $0.instanceId == requested })?.driverKind ?? entries.first?.driverKind ?? "unconfigured"
    let lockedGroup = lockedDriver != nil ? entries.first(where: { $0.instanceId == lockedInstanceId })?.continuationGroupKey : nil
    let requiresExactInstance = lockedDriver == "antigravity" && lockedInstanceId != nil && lockedGroup == nil
    let compatible = entries.filter {
      (lockedDriver == nil || $0.driverKind == lockedDriver) && (lockedGroup == nil || $0.continuationGroupKey == lockedGroup)
        && (!requiresExactInstance || $0.instanceId == lockedInstanceId)
    }
    let entry =
      candidateInstanceIds.compactMap { candidate in compatible.first { $0.instanceId == candidate && $0.enabled && $0.isAvailable } }.first
      ?? ModelCatalog.resolveSelectableEntry(compatible.filter { $0.driverKind == requestedDriver }, instanceId: nil)
      ?? ModelCatalog.resolveSelectableEntry(compatible, instanceId: nil)
    let unavailable = entry != nil ? nil : (lockedDriver != nil ? (lockedInstanceId ?? requested) : requested)
    return ProviderResolution(entry: entry, requestedDriver: requestedDriver, lockedContinuationGroupKey: lockedGroup, unavailableInstanceId: unavailable)
  }

  /// Why a send to Antigravity cannot go out yet (nil for every other driver).
  public static func antigravitySendBlockReason(_ snapshot: ProviderSnapshot?, model: String) -> String? {
    guard let snapshot, snapshot.driver.rawValue == "antigravity" else { return nil }
    if !snapshot.installed { return "Install Antigravity in provider settings before sending." }
    if snapshot.auth.status.rawValue == "unauthenticated" { return "Sign in to Antigravity in provider settings before sending." }
    let slug = model.jsTrim()
    if slug.isEmpty { return "Choose an Antigravity model before sending." }
    if snapshot.auth.status.rawValue == "unknown" { return nil }
    if snapshot.models.isEmpty { return "Refresh Antigravity models in provider settings before sending." }
    if snapshot.status == .ready, slug != ModelConstants.antigravityDefaultModel,
      !snapshot.models.contains(where: { $0.slug == slug || $0.aliases?.contains(slug) == true })
    {
      return "That Antigravity model is no longer available. Choose another model."
    }
    return nil
  }
}

/// The placeholder selection a draft carries while no provider can run it.
public enum NoProvider {
  public static let instanceId = "t3code_no_provider"
}
