import Foundation
import T3Contracts

/// Provider instances, models and option descriptors as the composer sees them. Ports
/// `providerInstances.ts`, `providerModels.ts`, `modelSelection.ts`, `modelOrdering.ts` and the
/// option helpers of `packages/shared/src/model.ts`.
public typealias ProviderSnapshot = ServerConfigProvidersItem
public typealias ProviderModelSnapshot = ServerConfigProvidersItemModelsItem

/// A custom model the user authored in settings.
public struct CustomModelDefinition: Sendable, Hashable {
  public var slug: String
  public var name: String

  public init(slug: String, name: String? = nil) {
    self.slug = slug
    self.name = name ?? slug
  }
}

/// The slice of settings that decides which models the picker offers.
public struct ComposerModelSettings: Sendable, Hashable {
  /// Legacy plan mode: restores the Build/Plan toggle and `/plan`, `/default`.
  public var planModeEnabled: Bool
  /// `providerInstances[id].config.customModels` when that array is present.
  public var instanceCustomModels: [String: [CustomModelDefinition]]
  /// Legacy `providers[driverKind].customModels`, read only for default instances.
  public var legacyCustomModels: [String: [CustomModelDefinition]]
  public var hiddenModels: [String: [String]]
  public var modelOrder: [String: [String]]
  /// Instances explicitly configured in `providerInstances` with their resolved `enabled` flag.
  public var instanceEnabled: [String: Bool]
  /// Legacy per-driver `providers[driver].enabled`.
  public var legacyProviderEnabled: [String: Bool]
  /// `driverKind:slug`-style keys of favorite models (`instanceId:slug`).
  public var favoriteModelKeys: Set<String>

  public init(
    planModeEnabled: Bool = false, instanceCustomModels: [String: [CustomModelDefinition]] = [:],
    legacyCustomModels: [String: [CustomModelDefinition]] = [:], hiddenModels: [String: [String]] = [:],
    modelOrder: [String: [String]] = [:], instanceEnabled: [String: Bool] = [:],
    legacyProviderEnabled: [String: Bool] = [:], favoriteModelKeys: Set<String> = []
  ) {
    self.planModeEnabled = planModeEnabled
    self.instanceCustomModels = instanceCustomModels
    self.legacyCustomModels = legacyCustomModels
    self.hiddenModels = hiddenModels
    self.modelOrder = modelOrder
    self.instanceEnabled = instanceEnabled
    self.legacyProviderEnabled = legacyProviderEnabled
    self.favoriteModelKeys = favoriteModelKeys
  }
}

public struct ProviderInstanceEntry: Sendable, Hashable, Identifiable {
  public var instanceId: String
  public var driverKind: String
  public var displayName: String
  public var accentColor: String?
  public var continuationGroupKey: String?
  public var enabled: Bool
  public var installed: Bool
  public var status: ServerProviderState
  /// True when the instance id equals the driver's default instance id (the driver slug).
  public var isDefault: Bool
  public var isAvailable: Bool
  public var snapshot: ProviderSnapshot
  public var models: [ProviderModelSnapshot] { snapshot.models }

  public var id: String { instanceId }

  /// Whether an instance can contribute models to an interactive picker.
  public var isPickerReady: Bool { enabled && isAvailable && status == .ready }
  public var isSelectable: Bool { enabled && isAvailable }
}

public struct AppModelOption: Sendable, Hashable, Identifiable {
  public var slug: String
  public var name: String
  public var shortName: String?
  public var subProvider: String?
  public var aliases: [String]?
  public var badge: String?
  public var isCustom: Bool
  public var isDefault: Bool
  public var isLegacy: Bool
  public var isUnavailable: Bool

  public var id: String { slug }

  init(
    slug: String, name: String, shortName: String? = nil, subProvider: String? = nil, aliases: [String]? = nil,
    badge: String? = nil, isCustom: Bool, isDefault: Bool = false, isLegacy: Bool = false, isUnavailable: Bool = false
  ) {
    self.slug = slug
    self.name = name
    self.shortName = shortName
    self.subProvider = subProvider
    self.aliases = aliases
    self.badge = badge
    self.isCustom = isCustom
    self.isDefault = isDefault
    self.isLegacy = isLegacy
    self.isUnavailable = isUnavailable
  }
}

public enum ModelCatalog {
  static let maxCustomModelCount = 32
  public static let maxCustomModelLength = 256

  // MARK: Instances

  private static func humanizeSlug(_ slug: String) -> String {
    // camelCase boundaries, `_` / `-` runs to a space, then Title Case on word starts.
    var spaced = ""
    var previous: Character?
    for character in slug {
      if let previous, previous.isASCII, previous.isLowercase, character.isASCII, character.isUppercase { spaced += " " }
      spaced.append(character)
      previous = character
    }
    var words = ""
    var inRun = false
    for character in spaced {
      if character == "_" || character == "-" {
        if !inRun { words += " " }
        inRun = true
      } else {
        words.append(character)
        inRun = false
      }
    }
    var out = ""
    var atWordStart = true
    for unit in words.jsTrim().unicodeScalars {
      let isWord = (unit.value >= 0x30 && unit.value <= 0x39) || (unit.value >= 0x41 && unit.value <= 0x5A)
        || (unit.value >= 0x61 && unit.value <= 0x7A) || unit.value == 0x5F
      if isWord && atWordStart, unit.value >= 0x61, unit.value <= 0x7A {
        out.unicodeScalars.append(Unicode.Scalar(unit.value - 32)!)
      } else {
        out.unicodeScalars.append(unit)
      }
      atWordStart = !isWord
    }
    return out
  }

  /// A snapshot `displayName` that differs from the driver's brand label wins; otherwise
  /// non-default instances are told apart by a humanized instance id.
  public static func displayName(instanceId: String, driver: String, snapshotName: String?) -> String {
    let trimmed = snapshotName?.jsTrim()
    let kindLabel = ModelConstants.providerDisplayNames[driver] ?? humanizeSlug(driver)
    if let trimmed, !trimmed.isEmpty, trimmed != kindLabel { return trimmed }
    if instanceId != driver {
      let humanized = humanizeSlug(instanceId)
      if !humanized.isEmpty { return humanized }
    }
    if let trimmed, !trimmed.isEmpty { return trimmed }
    return kindLabel
  }

  /// Only `#rrggbb` accent colors render.
  public static func normalizeAccentColor(_ value: String?) -> String? {
    guard let trimmed = value?.jsTrim(), trimmed.utf16.count == 7, trimmed.hasPrefix("#"),
      trimmed.dropFirst().allSatisfy({ $0.isHexDigit })
    else { return nil }
    return trimmed
  }

  public static func deriveEntries(_ providers: [ProviderSnapshot]) -> [ProviderInstanceEntry] {
    providers.map { snapshot in
      ProviderInstanceEntry(
        instanceId: snapshot.instanceId.rawValue, driverKind: snapshot.driver.rawValue,
        displayName: displayName(instanceId: snapshot.instanceId.rawValue, driver: snapshot.driver.rawValue, snapshotName: snapshot.displayName),
        accentColor: normalizeAccentColor(snapshot.accentColor), continuationGroupKey: snapshot.continuation?.groupKey, enabled: snapshot.enabled,
        installed: snapshot.installed, status: snapshot.status, isDefault: snapshot.instanceId.rawValue == snapshot.driver.rawValue,
        isAvailable: snapshot.availability != .unavailable, snapshot: snapshot)
    }
  }

  /// Settings overlay: probes can briefly retain a stale `enabled` after a settings write.
  public static func applySettings(_ entries: [ProviderInstanceEntry], _ settings: ComposerModelSettings) -> [ProviderInstanceEntry] {
    entries.map { entry in
      var next = entry
      if let explicit = settings.instanceEnabled[entry.instanceId] {
        next.enabled = explicit
      } else if entry.isDefault, let legacy = settings.legacyProviderEnabled[entry.driverKind] {
        next.enabled = legacy
      } else {
        next.enabled = false
      }
      return next
    }
  }

  /// Default instance of each driver before its custom ones; stable across drivers.
  public static func sortEntries(_ entries: [ProviderInstanceEntry]) -> [ProviderInstanceEntry] {
    var order: [String] = []
    var buckets: [String: [ProviderInstanceEntry]] = [:]
    for entry in entries {
      if buckets[entry.driverKind] == nil { order.append(entry.driverKind) }
      buckets[entry.driverKind, default: []].append(entry)
    }
    return order.flatMap { kind in
      let bucket = buckets[kind]!
      return bucket.filter(\.isDefault) + bucket.filter { !$0.isDefault }
    }
  }

  /// Instance shown when the stored one is gone: ready first, then a non-error probe result.
  public static func resolveSelectableEntry(_ entries: [ProviderInstanceEntry], instanceId: String?) -> ProviderInstanceEntry? {
    if let instanceId, let requested = entries.first(where: { $0.instanceId == instanceId }), requested.isSelectable {
      return requested
    }
    return entries.first(where: \.isPickerReady) ?? entries.first { $0.isSelectable && $0.status != .error }
  }

  // MARK: Models

  static func normalizeCustomModelSlug(_ model: String?) -> String? {
    guard let trimmed = model?.jsTrim(), !trimmed.isEmpty else { return nil }
    return trimmed
  }

  public static func normalizeModelSlug(_ model: String?, driver: String = "codex") -> String? {
    guard let trimmed = normalizeCustomModelSlug(model) else { return nil }
    return ModelConstants.slugAliasesByProvider[driver]?[trimmed] ?? trimmed
  }

  /// Direct slug, then name, then alias, then the normalized slug.
  public static func resolveSelectableModel(driver: String, value: String?, options: [(slug: String, name: String, aliases: [String]?)]) -> String? {
    guard let value, !value.jsTrim().isEmpty else { return nil }
    let trimmed = value.jsTrim()
    if let direct = options.first(where: { $0.slug == trimmed }) { return direct.slug }
    let lowered = trimmed.lowercased()
    if let byName = options.first(where: { $0.name.lowercased() == lowered }) { return byName.slug }
    if let byAlias = options.first(where: { $0.aliases?.contains { $0.lowercased() == lowered } == true }) { return byAlias.slug }
    guard let normalized = normalizeModelSlug(trimmed, driver: driver) else { return nil }
    return options.first(where: { $0.slug == normalized })?.slug
  }

  static func selectable(_ models: [ProviderModelSnapshot]) -> [(slug: String, name: String, aliases: [String]?)] {
    models.map { ($0.slug, $0.name, $0.aliases) }
  }

  static func selectable(_ options: [AppModelOption]) -> [(slug: String, name: String, aliases: [String]?)] {
    options.map { ($0.slug, $0.name, $0.aliases) }
  }

  private static func toOption(_ model: ProviderModelSnapshot) -> AppModelOption {
    AppModelOption(
      slug: model.slug, name: model.name, shortName: model.shortName.flatMap { $0.isEmpty ? nil : $0 },
      subProvider: model.subProvider.flatMap { $0.isEmpty ? nil : $0 }, aliases: model.aliases,
      badge: model.badge.flatMap { $0.isEmpty ? nil : $0 }, isCustom: model.isCustom, isDefault: model.isDefault == true,
      isLegacy: model.isLegacy == true)
  }

  private static func customModels(_ settings: ComposerModelSettings, instanceId: String, driver: String) -> [CustomModelDefinition] {
    if driver == "antigravity" { return [] }
    if let explicit = settings.instanceCustomModels[instanceId] { return explicit }
    if instanceId != driver { return [] }
    return settings.legacyCustomModels[driver] ?? []
  }

  private static func normalizeCustomEntries(_ models: [CustomModelDefinition], builtIn: Set<String>) -> [CustomModelDefinition] {
    var seen = Set<String>()
    var out: [CustomModelDefinition] = []
    for candidate in models {
      if candidate.slug.jsLength > maxCustomModelLength || builtIn.contains(candidate.slug) || seen.contains(candidate.slug) { continue }
      seen.insert(candidate.slug)
      out.append(candidate)
      if out.count >= maxCustomModelCount { break }
    }
    return out
  }

  /// Stable order: explicit `modelOrder` ranks first, then the catalog's own order.
  public static func sortModels<T>(_ models: [T], slug: (T) -> String, modelOrder: [String] = [], favorites: Set<String> = [], groupFavorites: Bool = false) -> [T] {
    var orderRank: [String: Int] = [:]
    for (index, value) in modelOrder.enumerated() where orderRank[value] == nil { orderRank[value] = index }
    return models.enumerated().sorted { left, right in
      let ls = slug(left.element)
      let rs = slug(right.element)
      if groupFavorites {
        let lf = favorites.contains(ls)
        let rf = favorites.contains(rs)
        if lf != rf { return lf }
      }
      let lo = orderRank[ls] ?? Int.max
      let ro = orderRank[rs] ?? Int.max
      if lo != ro { return lo < ro }
      return left.offset < right.offset
    }.map(\.element)
  }

  private static func appendUnavailable(
    _ options: [AppModelOption], raw: [ProviderModelSnapshot], driver: String, selected: String?, hidden: [String]
  ) -> [AppModelOption] {
    guard driver == "opencode" || driver == "antigravity", let slug = normalizeCustomModelSlug(selected) else { return options }
    if driver == "antigravity" && slug == ModelConstants.antigravityDefaultModel { return options }
    if resolveSelectableModel(driver: driver, value: slug, options: selectable(raw)) != nil { return options }
    if hidden.contains(slug) || options.contains(where: { $0.slug == slug }) { return options }
    return options + [AppModelOption(slug: slug, name: slug, isCustom: false, isUnavailable: true)]
  }

  /// Built-ins from the instance snapshot, custom rows rebuilt from settings so a removed slug
  /// disappears without waiting for the next probe, hidden ones filtered, order applied.
  public static func modelOptions(for entry: ProviderInstanceEntry, settings: ComposerModelSettings, selectedModel: String? = nil) -> [AppModelOption] {
    var options = entry.models.filter { !$0.isCustom }.map(toOption)
    var seen = Set(options.map(\.slug))
    let builtIn = Set(entry.models.filter { !$0.isCustom }.map(\.slug))
    for custom in normalizeCustomEntries(customModels(settings, instanceId: entry.instanceId, driver: entry.driverKind), builtIn: builtIn) {
      if seen.contains(custom.slug) { continue }
      seen.insert(custom.slug)
      options.append(AppModelOption(slug: custom.slug, name: custom.name, isCustom: true))
    }
    let hidden = Set(settings.hiddenModels[entry.instanceId] ?? [])
    let visible = options.filter { $0.isCustom || !hidden.contains($0.slug) }
    let sorted = sortModels(visible, slug: \.slug, modelOrder: settings.modelOrder[entry.instanceId] ?? [])
    return appendUnavailable(sorted, raw: entry.models, driver: entry.driverKind, selected: selectedModel, hidden: settings.hiddenModels[entry.instanceId] ?? [])
  }

  public static func defaultInstanceModel(_ providers: [ProviderSnapshot], instanceId: String) -> String? {
    guard let entry = deriveEntries(providers).first(where: { $0.instanceId == instanceId }) else { return nil }
    return entry.models.first(where: { $0.isDefault == true && !$0.isCustom })?.slug
      ?? entry.models.first(where: { !$0.isCustom })?.slug ?? entry.models.first?.slug
      ?? ModelConstants.defaultModelByProvider[entry.driverKind]
  }

  /// Instance-scoped resolution of a stored model against what the instance offers now.
  public static func resolveModel(
    instanceId: String, settings: ComposerModelSettings, providers: [ProviderSnapshot], selectedModel: String?,
    preserveUnavailableSelection: Bool = false
  ) -> String? {
    guard let entry = deriveEntries(providers).first(where: { $0.instanceId == instanceId }) else { return nil }
    let options = modelOptions(for: entry, settings: settings, selectedModel: preserveUnavailableSelection ? selectedModel : nil)
    if let resolved = resolveSelectableModel(driver: entry.driverKind, value: selectedModel, options: selectable(options)) { return resolved }
    if preserveUnavailableSelection, entry.driverKind == "opencode" || entry.driverKind == "antigravity" {
      let hidden = settings.hiddenModels[entry.instanceId] ?? []
      if let unavailable = normalizeCustomModelSlug(selectedModel), !hidden.contains(unavailable),
        resolveSelectableModel(driver: entry.driverKind, value: selectedModel, options: selectable(entry.models)) == nil,
        entry.driverKind != "antigravity" || unavailable != ModelConstants.antigravityDefaultModel
      {
        return unavailable
      }
    }
    return options.first(where: \.isDefault)?.slug ?? options.first?.slug
  }

  // MARK: Per-driver (legacy) lookups

  static func defaultInstanceModels(_ providers: [ProviderSnapshot], driver: String) -> [ProviderModelSnapshot] {
    providers.first(where: { $0.instanceId.rawValue == driver })?.models ?? []
  }

  public static func defaultServerModel(_ providers: [ProviderSnapshot], driver: String) -> String {
    let models = defaultInstanceModels(providers, driver: driver)
    return models.first(where: { $0.isDefault == true && !$0.isCustom })?.slug ?? models.first(where: { !$0.isCustom })?.slug
      ?? models.first?.slug ?? ModelConstants.defaultModelByProvider[driver] ?? ModelConstants.defaultModel
  }

  /// A live enabled driver for a selection whose instance may be gone.
  public static func resolveSelectableDriver(_ providers: [ProviderSnapshot], instanceOrDriver: String?) -> String {
    if let requested = providers.first(where: { $0.instanceId.rawValue == instanceOrDriver }), requested.enabled { return requested.driver.rawValue }
    return providers.first(where: \.enabled)?.driver.rawValue ?? "codex"
  }

  public static func resolveAppModel(driver: String, settings: ComposerModelSettings, providers: [ProviderSnapshot], selectedModel: String?) -> String {
    let resolvedDriver = resolveSelectableDriver(providers, instanceOrDriver: driver)
    var options: [AppModelOption] = []
    if let entry = deriveEntries(providers).first(where: { $0.instanceId == resolvedDriver }) {
      options = modelOptions(for: entry, settings: settings, selectedModel: selectedModel)
    }
    return resolveSelectableModel(driver: resolvedDriver, value: selectedModel, options: selectable(options)) ?? defaultServerModel(providers, driver: resolvedDriver)
  }
}
