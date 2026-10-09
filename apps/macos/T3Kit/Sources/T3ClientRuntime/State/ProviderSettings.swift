import Foundation
import T3Contracts

// Pure rules of Settings › Providers (web: ProviderSettingsPanel, providerStatus, ProviderModelsSection, customModelEditor.logic,
// modelOrdering). Instances, driver fields and custom models are handled as JSON because the server keeps driver config opaque.

extension JSONValue {
  public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
  public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }

  /// Any encodable value as JSON (nil when it does not encode).
  public init?<T: Encodable>(encoding value: T) {
    guard let data = try? JSONEncoder().encode(value), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
    self = json
  }

  func decoded<T: Decodable>(_ type: T.Type) -> T? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}

// MARK: - Drivers

public struct ProviderFieldOption: Sendable, Equatable, Hashable {
  public var value: String
  public var label: String
}

/// One driver-specific setting of an instance (`providerSettingsForm` annotations in `settings.ts`).
public struct ProviderField: Sendable, Equatable, Identifiable {
  public enum Control: Sendable { case text, password, toggle, select }
  public var key: String
  public var label: String
  public var help: String?
  public var placeholder: String?
  public var control: Control = .text
  /// `clearWhenEmpty: "omit"`: an empty value removes the key instead of storing "".
  public var omitWhenEmpty = true
  /// The first option is the default and is stored as an omitted key.
  public var options: [ProviderFieldOption] = []
  public var defaultBool = false
  /// A value that must match to be saved (the server rejects the whole patch otherwise).
  public var pattern: String?
  public var patternMessage: String?
  public var id: String { key }

  public func error(for value: String) -> String? {
    guard let pattern else { return nil }
    return value.trimmingCharacters(in: .whitespaces).range(of: pattern, options: .regularExpression) == nil ? patternMessage : nil
  }
}

public enum ProviderFieldValue: Sendable, Equatable {
  case text(String)
  case toggle(Bool)
}

/// A reasoning/fast-mode style option a custom model can offer in the composer.
public struct DescriptorPreset: Sendable, Equatable, Identifiable {
  public struct Choice: Sendable, Equatable {
    public var id: String
    public var label: String
    public var isDefault = false
  }
  public var id: String
  public var label: String
  public var isToggle: Bool
  public var choices: [Choice] = []
}

public struct ProviderDriver: Sendable, Equatable, Identifiable {
  public var slug: String
  public var label: String
  public var badge: String?
  public var fields: [ProviderField]
  public var modelPlaceholder: String
  public var presets: [DescriptorPreset]
  public var id: String { slug }
}

public enum ProviderCatalog {
  public static let antigravityAuthMethods: [ProviderFieldOption] = [
    ProviderFieldOption(value: "oauth-personal", label: "Google account"),
    ProviderFieldOption(value: "oauth-business", label: "Gemini Enterprise"),
    ProviderFieldOption(value: "gemini-api-key", label: "Gemini API key"),
    ProviderFieldOption(value: "agent-platform", label: "Agent Platform (Vertex AI)"),
  ]

  private static let effort: [DescriptorPreset.Choice] = [
    .init(id: "low", label: "Low"), .init(id: "medium", label: "Medium", isDefault: true), .init(id: "high", label: "High"),
    .init(id: "xhigh", label: "Extra High"),
  ]

  private static func binary(_ placeholder: String, _ help: String) -> ProviderField {
    ProviderField(key: "binaryPath", label: "Binary path", help: help, placeholder: placeholder)
  }

  /// In the order the add-instance wizard lists them.
  public static let drivers: [ProviderDriver] = [
    ProviderDriver(
      slug: "codex", label: "Codex",
      fields: [
        binary("codex", "Path to the Codex binary used by this instance."),
        ProviderField(key: "homePath", label: "CODEX_HOME path", help: "Custom Codex home and config directory.", placeholder: "~/.codex"),
        ProviderField(
          key: "shadowHomePath", label: "Shadow home path",
          help: "Account-specific Codex home. Keeps auth.json separate while sharing state from CODEX_HOME.", placeholder: "~/.codex-t3/personal"),
        ProviderField(key: "launchArgs", label: "Launch arguments", help: "Additional CLI arguments passed to codex app-server on session start."),
      ],
      modelPlaceholder: "gpt-6.7-codex-ultra-preview",
      presets: [
        DescriptorPreset(id: "reasoningEffort", label: "Reasoning", isToggle: false, choices: effort),
        DescriptorPreset(
          id: "serviceTier", label: "Speed", isToggle: false, choices: [.init(id: "default", label: "Standard", isDefault: true), .init(id: "fast", label: "Fast")]),
      ]),
    ProviderDriver(
      slug: "claudeAgent", label: "Claude",
      fields: [
        binary("claude", "Path to the Claude binary used by this instance."),
        ProviderField(
          key: "homePath", label: "CLAUDE_CONFIG_DIR path", help: "Custom Claude home and config directory. Keeps .claude.json and .claude separate.",
          placeholder: "~/.claude"),
        ProviderField(
          key: "autoCompactWindow", label: "Auto-compact after", help: "Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default.",
          placeholder: "e.g. 300000", pattern: "^(|[1-9][0-9]{5}|1000000)$", patternMessage: "Use a whole number from 100,000 to 1,000,000, or leave it empty."),
        ProviderField(key: "launchArgs", label: "Launch arguments", help: "Additional CLI arguments passed on session start.", placeholder: "e.g. --chrome"),
      ],
      modelPlaceholder: "claude-sonnet-5",
      presets: [
        DescriptorPreset(
          id: "effort", label: "Reasoning", isToggle: false,
          choices: [
            .init(id: "low", label: "Low"), .init(id: "medium", label: "Medium"), .init(id: "high", label: "High", isDefault: true),
            .init(id: "xhigh", label: "Extra High"), .init(id: "max", label: "Max"),
          ]),
        DescriptorPreset(id: "fastMode", label: "Fast Mode", isToggle: true),
        DescriptorPreset(id: "thinking", label: "Thinking", isToggle: true),
      ]),
    ProviderDriver(
      slug: "cursor", label: "Cursor", badge: "Early Access",
      fields: [
        binary("cursor-agent", "Path to the Cursor agent binary."),
        ProviderField(key: "apiEndpoint", label: "API endpoint", help: "Override the Cursor API endpoint for this instance.", placeholder: "https://..."),
      ],
      modelPlaceholder: "claude-sonnet-4-6",
      presets: [
        DescriptorPreset(id: "reasoning", label: "Reasoning", isToggle: false, choices: effort),
        DescriptorPreset(id: "fastMode", label: "Fast Mode", isToggle: true),
        DescriptorPreset(id: "thinking", label: "Thinking", isToggle: true),
      ]),
    ProviderDriver(
      slug: "grok", label: "Grok", badge: "Early Access", fields: [binary("grok", "Path to the Grok CLI binary.")], modelPlaceholder: "model-slug",
      presets: [DescriptorPreset(id: "reasoningEffort", label: "Reasoning", isToggle: false, choices: effort)]),
    ProviderDriver(
      slug: "opencode", label: "OpenCode",
      fields: [
        binary("opencode", "Path to the OpenCode binary."),
        ProviderField(key: "serverUrl", label: "Server URL", help: "Leave blank to let T3 Code spawn the server when needed.", placeholder: "http://127.0.0.1:4096"),
        ProviderField(key: "serverPassword", label: "Server password", help: "Stored in plain text on disk.", placeholder: "Optional", control: .password),
      ],
      modelPlaceholder: "openai/gpt-5",
      presets: [
        DescriptorPreset(id: "variant", label: "Reasoning", isToggle: false, choices: effort),
        DescriptorPreset(
          id: "agent", label: "Agent", isToggle: false, choices: [.init(id: "build", label: "Build", isDefault: true), .init(id: "plan", label: "Plan")]),
      ]),
    ProviderDriver(
      slug: "antigravity", label: "Antigravity",
      fields: [
        ProviderField(
          key: "authMethod", label: "Sign-in method", help: "Google accounts use your subscription; API keys and Agent Platform bill usage.", control: .select,
          options: antigravityAuthMethods),
        ProviderField(key: "apiKey", label: "API key", help: "Gemini or Vertex AI express key. Stored in plain text.", placeholder: "Optional", control: .password),
        ProviderField(
          key: "gcpProject", label: "GCP project", help: "Required for Gemini Enterprise. Agent Platform uses it when no API key is set.", placeholder: "my-project-id"),
        ProviderField(key: "gcpLocation", label: "GCP location", help: "Region for Gemini Enterprise or Agent Platform.", placeholder: "us-central1"),
        ProviderField(
          key: "binaryPath", label: "Binary path", help: "Custom ACP executable. Leave empty to select automatically.", placeholder: "Automatic", omitWhenEmpty: false),
      ],
      modelPlaceholder: "model-slug", presets: []),
  ]

  public static func driver(_ slug: String) -> ProviderDriver? { drivers.first { $0.slug == slug } }
  public static func label(_ slug: String) -> String { driver(slug)?.label ?? humanize(slug) }

  /// `codex_personal` -> "Codex Personal", `myCustomInstance` -> "My Custom Instance".
  public static func humanize(_ slug: String) -> String {
    var words: [String] = []
    var current = ""
    var previous: Character?
    for character in slug {
      if character == "_" || character == "-" {
        if !current.isEmpty { words.append(current) }
        current = ""
      } else {
        if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
          words.append(current)
          current = ""
        }
        current.append(character)
      }
      previous = character
    }
    if !current.isEmpty { words.append(current) }
    return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }
}

// MARK: - Driver config

public enum ProviderConfig {
  public static func string(_ config: JSONValue?, _ key: String) -> String {
    if case .string(let value)? = config?[key] { value } else { "" }
  }

  public static func bool(_ config: JSONValue?, _ key: String, default fallback: Bool) -> Bool { config?[key]?.boolValue ?? fallback }

  /// The config after one field changed (`nextProviderConfigWithFieldValue`); nil when nothing is left, so the key is dropped.
  public static func applying(_ value: ProviderFieldValue, to field: ProviderField, in config: JSONValue?) -> JSONValue? {
    var base = config?.objectValue ?? [:]
    switch value {
    case .toggle(let on):
      if field.omitWhenEmpty, on == field.defaultBool { base[field.key] = nil } else { base[field.key] = .bool(on) }
    case .text(let text):
      if field.omitWhenEmpty, text.trimmingCharacters(in: .whitespaces).isEmpty { base[field.key] = nil } else { base[field.key] = .string(text) }
    }
    return base.isEmpty ? nil : .object(base)
  }

  /// A select stores its default (the first option) as an omitted key.
  public static func selection(_ config: JSONValue?, _ field: ProviderField) -> String {
    let current = string(config, field.key)
    return current.isEmpty ? (field.options.first?.value ?? "") : current
  }

  public static func applyingSelection(_ choice: String, to field: ProviderField, in config: JSONValue?) -> JSONValue? {
    applying(.text(choice == field.options.first?.value ? "" : choice), to: field, in: config)
  }
}

// MARK: - Instances

public struct ProviderInstanceRow: Sendable, Equatable, Identifiable {
  public var instanceId: String
  public var instance: ProviderInstanceConfig
  public var driver: String
  public var isDefault: Bool
  /// A default slot that differs from the built-in defaults (offers the reset action).
  public var isDirty: Bool
  public var id: String { instanceId }
}

public enum ProviderInstances {
  public static let instanceIdPattern = "^[a-zA-Z][a-zA-Z0-9_-]*$"
  static let environmentNamePattern = "^[a-zA-Z_][a-zA-Z0-9_]*$"

  public static func config(_ value: ServerSettingsProviderInstancesValue) -> ProviderInstanceConfig {
    ProviderInstanceConfig(
      driver: value.driver, displayName: value.displayName, accentColor: value.accentColor,
      environment: value.environment?.map {
        ProviderInstanceEnvironmentVariable(name: $0.name, value: $0.value, sensitive: $0.sensitive, valueRedacted: $0.valueRedacted)
      }, enabled: value.enabled, config: value.config)
  }

  public static func explicitInstances(_ settings: ServerSettings) -> [String: ProviderInstanceConfig] { settings.providerInstances.mapValues(config) }

  private static func legacyBlob(_ settings: ServerSettings) -> [String: JSONValue] { JSONValue(encoding: settings.providers)?.objectValue ?? [:] }
  private static let legacyDefaults: [String: JSONValue] = JSONValue(encoding: ServerSettingsProviders())?.objectValue ?? [:]

  /// Whether an instance is enabled: an explicit false on the envelope or in-config flag wins, then the driver's default.
  public static func isEnabled(_ instance: ProviderInstanceConfig) -> Bool {
    let inConfig = instance.config?["enabled"]?.boolValue
    if instance.enabled == false || inConfig == false { return false }
    return instance.enabled ?? inConfig ?? legacyDefaults[instance.driver.rawValue]?["enabled"]?.boolValue ?? true
  }

  /// The rows of the instance list: each built-in driver's default slot (from the explicit instance, else the legacy
  /// `providers` blob), its custom instances, then instances of drivers this build does not know.
  /// `liveInstanceIds` hides Cursor until the server reports it.
  public static func rows(settings: ServerSettings, liveInstanceIds: Set<String>) -> [ProviderInstanceRow] {
    let explicit = explicitInstances(settings)
    let legacy = legacyBlob(settings)
    let visible = ProviderCatalog.drivers.map(\.slug).filter { $0 != "cursor" || liveInstanceIds.contains("cursor") }
    var rows: [ProviderInstanceRow] = []
    for driver in visible {
      let slot = explicit[driver]
      if let legacyConfig = legacy[driver], var blob = legacyConfig.objectValue {
        let flag = blob.removeValue(forKey: "enabled")?.boolValue
        let effective = slot ?? ProviderInstanceConfig(driver: ProviderDriverKind(driver), enabled: flag, config: .object(blob))
        rows.append(
          ProviderInstanceRow(
            instanceId: driver, instance: effective, driver: driver, isDefault: true, isDirty: slot != nil || legacyConfig != legacyDefaults[driver]))
      } else if let slot {
        rows.append(ProviderInstanceRow(instanceId: driver, instance: slot, driver: driver, isDefault: true, isDirty: true))
      }
      for (id, instance) in explicit.sorted(by: { $0.key < $1.key }) where instance.driver.rawValue == driver && id != driver {
        rows.append(ProviderInstanceRow(instanceId: id, instance: instance, driver: driver, isDefault: false, isDirty: false))
      }
    }
    for (id, instance) in explicit.sorted(by: { $0.key < $1.key }) where !visible.contains(instance.driver.rawValue) {
      rows.append(
        ProviderInstanceRow(instanceId: id, instance: instance, driver: instance.driver.rawValue, isDefault: visible.contains(id), isDirty: false))
    }
    return rows
  }

  // MARK: Patches

  /// `buildProviderInstanceUpdatePatch`: the whole instance map goes back (the server replaces it); editing a default slot
  /// also resets its legacy blob so the explicit instance becomes the source of truth.
  public static func updatePatch(
    settings: ServerSettings, row: ProviderInstanceRow, next: ProviderInstanceConfig, resetTextGeneration: Bool = false
  ) -> ServerSettingsPatch {
    var patch = ServerSettingsPatch()
    if row.isDefault, let fallback = legacyDefaults[row.driver] {
      var blob = legacyBlob(settings)
      blob[row.driver] = fallback
      patch.providers = JSONValue.object(blob).decoded(ServerSettingsPatchProviders.self)
    }
    var instances = explicitInstances(settings)
    instances[row.instanceId] = next
    patch.providerInstances = instances
    if resetTextGeneration {
      patch.textGenerationModelSelection = JSONValue(encoding: ServerSettings().textGenerationModelSelection)?.decoded(
        ServerSettingsPatchTextGenerationModelSelection.self)
    }
    return patch
  }

  public static func addPatch(settings: ServerSettings, instanceId: String, instance: ProviderInstanceConfig) -> ServerSettingsPatch {
    var instances = explicitInstances(settings)
    instances[instanceId] = instance
    return ServerSettingsPatch(providerInstances: instances)
  }

  public static func deletePatch(settings: ServerSettings, instanceId: String) -> ServerSettingsPatch {
    var instances = explicitInstances(settings)
    instances[instanceId] = nil
    return ServerSettingsPatch(providerInstances: instances)
  }

  /// Back to the built-in defaults for a driver's default slot.
  public static func resetDefaultPatch(settings: ServerSettings, driver: String) -> ServerSettingsPatch? {
    guard let fallback = legacyDefaults[driver] else { return nil }
    var blob = legacyBlob(settings)
    blob[driver] = fallback
    var patch = deletePatch(settings: settings, instanceId: driver)
    patch.providers = JSONValue.object(blob).decoded(ServerSettingsPatchProviders.self)
    return patch
  }

  // MARK: Identity

  public static func slugify(_ label: String) -> String {
    let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var out = ""
    var pendingSeparator = false
    for scalar in lowered.unicodeScalars {
      if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
        if pendingSeparator, !out.isEmpty { out.append("_") }
        pendingSeparator = false
        out.unicodeScalars.append(scalar)
      } else {
        pendingSeparator = true
      }
    }
    return String(out.prefix(48))
  }

  public static func deriveInstanceId(driver: String, label: String) -> String {
    let slug = slugify(label)
    return slug.isEmpty ? "" : "\(driver)_\(slug)"
  }

  public static func idError(_ id: String, existing: Set<String>) -> String? {
    if id.isEmpty { return "Instance ID is required." }
    if id.count > 64 { return "Instance ID must be 64 characters or fewer." }
    if id.range(of: instanceIdPattern, options: .regularExpression) == nil {
      return "Instance ID must start with a letter and use only letters, digits, '-', or '_'."
    }
    if existing.contains(id) { return "An instance named '\(id)' already exists." }
    return nil
  }

  /// Only `#rrggbb` accents render.
  public static func normalizedAccent(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
    return trimmed.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) == nil ? nil : trimmed
  }

  // MARK: Environment variables

  public struct EnvironmentDraft: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name = ""
    public var value = ""
    public var sensitive = true
    public var valueRedacted: Bool?

    public init(_ variable: ProviderInstanceEnvironmentVariable? = nil) {
      if let variable {
        name = variable.name
        value = variable.value
        sensitive = variable.sensitive
        valueRedacted = variable.valueRedacted
      }
    }
  }

  public static func isValidEnvironmentName(_ name: String) -> Bool { name.range(of: environmentNamePattern, options: .regularExpression) != nil }

  /// The variables to save for the rows being edited. Nil while a row is half-typed (invalid name), so nothing is saved
  /// until it is complete; a fully untouched new row is skipped.
  public static func publishedEnvironment(_ rows: [EnvironmentDraft]) -> [ProviderInstanceEnvironmentVariable]? {
    var published: [ProviderInstanceEnvironmentVariable] = []
    for row in rows {
      let name = row.name.trimmingCharacters(in: .whitespaces)
      if !isValidEnvironmentName(name) {
        if !name.isEmpty || !row.value.isEmpty || !row.sensitive || row.valueRedacted != nil { return nil }
        continue
      }
      published.append(ProviderInstanceEnvironmentVariable(name: name, value: row.value, sensitive: row.sensitive, valueRedacted: row.valueRedacted))
    }
    return published
  }

  public static func displayName(_ instance: ProviderInstanceConfig) -> String {
    let trimmed = instance.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
    return trimmed.isEmpty ? ProviderCatalog.label(instance.driver.rawValue) : trimmed
  }
}

// MARK: - Status

public struct ProviderStatusSummary: Sendable, Equatable {
  public var headline: String
  public var detail: String?

  public init(headline: String, detail: String?) {
    self.headline = headline
    self.detail = detail
  }
}

public struct ProviderVersionAdvisory: Sendable, Equatable {
  public var title: String
  public var detail: String
  public var updateCommand: String?
  public var strong: Bool
  public var targetVersion: String?
  /// A compatibility warning rather than a plain update.
  public var isCompatibility: Bool
}

public enum ProviderStatus {
  public static func summary(_ provider: ServerConfigProvidersItem?) -> ProviderStatusSummary {
    guard let provider else {
      return ProviderStatusSummary(headline: "Checking provider status", detail: "Waiting for the server to report installation and authentication details.")
    }
    if !provider.enabled || provider.status == .disabled {
      return ProviderStatusSummary(headline: "Disabled", detail: provider.message ?? "This provider is installed but disabled for new sessions in T3 Code.")
    }
    if !provider.installed { return ProviderStatusSummary(headline: "Not found", detail: provider.message ?? "CLI not detected on PATH.") }
    if provider.auth.status == .unauthenticated { return ProviderStatusSummary(headline: "Not authenticated", detail: provider.message) }
    if provider.status == .warning {
      return ProviderStatusSummary(headline: "Needs attention", detail: provider.message ?? "The provider is installed, but the server could not fully verify it.")
    }
    if provider.status == .error { return ProviderStatusSummary(headline: "Unavailable", detail: provider.message ?? "The provider failed its startup checks.") }
    if provider.auth.status == .authenticated {
      let label = provider.auth.label ?? provider.auth.type
      return ProviderStatusSummary(headline: label.map { "Authenticated · \($0)" } ?? "Authenticated", detail: provider.message)
    }
    return ProviderStatusSummary(headline: "Available", detail: provider.message)
  }

  /// "1.2.3" -> "v1.2.3"; Antigravity release tags (`agy_acp_server_20260818_01_RC01`) show their date and candidate.
  public static func versionLabel(_ version: String?) -> String? {
    guard let version, !version.isEmpty else { return nil }
    let prefix = "agy_acp_server_"
    if version.hasPrefix(prefix) {
      let parts = version.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false)
      if let date = parts.first, date.count == 8, date.allSatisfy(\.isNumber) {
        let day = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
        return parts.count > 2 ? "\(day) \(parts[2])" : day
      }
    }
    return version.first?.isNumber == true ? "v\(version)" : version
  }

  public static func advisory(_ provider: ServerConfigProvidersItem?, showCompatibility: Bool = true) -> ProviderVersionAdvisory? {
    guard let provider else { return nil }
    let advisory = provider.versionAdvisory
    let compatibility = provider.compatibilityAdvisory
    let latestBlocked = compatibility?.latestVersionStatus == .broken || compatibility?.latestVersionStatus == .unsupported
    if showCompatibility, let compatibility, [.graceful, .unsupported, .broken].contains(compatibility.status) {
      let target = compatibility.recommendedVersion
      let recommendation = versionLabel(target) ?? compatibility.recommendedRange
      let title =
        compatibility.status == .graceful ? "Limited support" : compatibility.status == .unsupported ? "Unsupported version" : "Known broken version"
      return ProviderVersionAdvisory(
        title: title, detail: compatibility.message ?? (recommendation.map { "Use \($0) for full support." } ?? "Update for full support."),
        updateCommand: target != nil || latestBlocked ? nil : advisory?.updateCommand, strong: compatibility.status != .graceful, targetVersion: target,
        isCompatibility: true)
    }
    guard let advisory, advisory.status != .current, advisory.status != .unknownValue, !latestBlocked else { return nil }
    let label = versionLabel(advisory.latestVersion)
    return ProviderVersionAdvisory(
      title: "Update available", detail: advisory.message ?? (label.map { "Update available: install \($0)." } ?? "Update available: install the latest provider version."),
      updateCommand: advisory.updateCommand, strong: false, targetVersion: nil, isCompatibility: false)
  }

  /// A one-click update is offered for an enabled provider that is behind a compatible latest version.
  public static func isUpdateCandidate(_ provider: ServerConfigProvidersItem) -> Bool {
    provider.enabled && provider.compatibilityAdvisory?.latestVersionStatus != .broken && provider.compatibilityAdvisory?.latestVersionStatus != .unsupported
      && provider.versionAdvisory?.status == .behind_latest && provider.versionAdvisory?.canUpdate == true && provider.versionAdvisory?.updateCommand != nil
  }

  public static func isUpdateActive(_ provider: ServerConfigProvidersItem) -> Bool { provider.updateState?.status == .queued || provider.updateState?.status == .running }
}

// MARK: - Models

public struct ProviderModelItem: Sendable, Equatable, Identifiable {
  public var slug: String
  public var name: String
  public var isCustom: Bool
  public var capabilities: [String] = []
  public var id: String { slug }
}

public enum ProviderModels {
  public static let filterThreshold = 8
  public static let maxCustomSlugLength = 256

  /// Favorites first (when grouped), then the user's order, then the server's order.
  public static func sorted(_ models: [ProviderModelItem], favorites: Set<String>, order: [String], groupFavorites: Bool) -> [ProviderModelItem] {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return models.enumerated().sorted { left, right in
      if groupFavorites {
        let (a, b) = (favorites.contains(left.element.slug), favorites.contains(right.element.slug))
        if a != b { return a }
      }
      let (ra, rb) = (rank[left.element.slug] ?? Int.max, rank[right.element.slug] ?? Int.max)
      return ra != rb ? ra < rb : left.offset < right.offset
    }.map(\.element)
  }

  public enum Bucket: Sendable { case favorite, visible, hidden }

  public static func bucket(_ model: ProviderModelItem, favorites: Set<String>, hidden: Set<String>) -> Bucket {
    favorites.contains(model.slug) ? .favorite : (!model.isCustom && hidden.contains(model.slug)) ? .hidden : .visible
  }

  /// What the picker shows, top to bottom: favorites, visible, then hidden models.
  public static func displayOrder(_ models: [ProviderModelItem], favorites: Set<String>, hidden: Set<String>, order: [String]) -> [ProviderModelItem] {
    let ordered = sorted(models, favorites: favorites, order: order, groupFavorites: true)
    return [Bucket.favorite, .visible, .hidden].flatMap { bucket in ordered.filter { self.bucket($0, favorites: favorites, hidden: hidden) == bucket } }
  }

  /// "Disable all" hides every built-in model, "Enable all" shows them again (custom models are never hidden).
  public static func hiddenAfterBulkToggle(_ models: [ProviderModelItem], hidden: [String]) -> [String] {
    let builtIn = models.filter { !$0.isCustom }.map(\.slug)
    if builtIn.allSatisfy(hidden.contains) { return hidden.filter { !builtIn.contains($0) } }
    return hidden + builtIn.filter { !hidden.contains($0) }
  }

  /// The order after moving a row one step; rows only trade places inside their own group.
  public static func order(afterMoving slug: String, by step: Int, in display: [ProviderModelItem], favorites: Set<String>, hidden: Set<String>) -> [String]? {
    guard let index = display.firstIndex(where: { $0.slug == slug }) else { return nil }
    let target = index + step
    guard display.indices.contains(target),
      bucket(display[index], favorites: favorites, hidden: hidden) == bucket(display[target], favorites: favorites, hidden: hidden)
    else { return nil }
    var slugs = display.map(\.slug)
    slugs.swapAt(index, target)
    return slugs
  }

  /// Trimmed, de-duplicated preference lists; nil when both are empty (the entry is removed).
  public static func normalizedPreferences(hidden: [String], order: [String]) -> ClientSettingsSchemaProviderModelPreferencesValue? {
    func clean(_ values: [String]) -> [String] {
      var seen = Set<String>()
      return values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
    }
    let (hidden, order) = (clean(hidden), clean(order))
    return hidden.isEmpty && order.isEmpty ? nil : ClientSettingsSchemaProviderModelPreferencesValue(hiddenModels: hidden, modelOrder: order)
  }

  /// This instance's favorites replaced by `slugs`; other instances' favorites are kept.
  public static func favorites(
    _ current: [ClientSettingsSchemaFavoritesItem], instanceId: String, replacingWith slugs: [String]
  ) -> [ClientSettingsSchemaFavoritesItem] {
    var seen = Set<String>()
    let cleaned = slugs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    return current.filter { $0.provider.rawValue != instanceId } + cleaned.map { ClientSettingsSchemaFavoritesItem(provider: ProviderInstanceId(instanceId), model: $0) }
  }

  /// Short capability words after a model name: fast mode, thinking, reasoning.
  public static func capabilityLabels(_ descriptors: [JSONValue]) -> [String] {
    var labels: [String] = []
    func options(_ descriptor: JSONValue) -> [JSONValue] { descriptor["options"]?.arrayValue ?? [] }
    let isSelect: (JSONValue) -> Bool = { $0["type"]?.stringValue == "select" }
    let hasFast = descriptors.contains { descriptor in
      descriptor["id"]?.stringValue == "fastMode"
        || (descriptor["id"]?.stringValue == "serviceTier" && isSelect(descriptor)
          && options(descriptor).contains { $0["id"]?.stringValue == "fast" || $0["label"]?.stringValue == "Fast" })
    }
    if hasFast { labels.append("Fast mode") }
    if descriptors.contains(where: { $0["id"]?.stringValue == "thinking" }) { labels.append("Thinking") }
    if descriptors.contains(where: { isSelect($0) && ["reasoningEffort", "effort", "reasoning", "variant"].contains($0["id"]?.stringValue ?? "") }) {
      labels.append("Reasoning")
    }
    return labels
  }

  /// Built-in models come from the server's probe, custom ones from the instance config so edits show at once.
  public static func items(live: [ServerConfigProvidersItemModelsItem]?, custom: [CustomModelDefinition]) -> [ProviderModelItem] {
    func descriptors(_ model: ServerConfigProvidersItemModelsItem) -> [JSONValue] {
      (model.capabilities?.optionDescriptors ?? []).compactMap { JSONValue(encoding: $0) }
    }
    let liveCustom = Dictionary((live ?? []).filter(\.isCustom).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    let builtIn = (live ?? []).filter { !$0.isCustom }.map { ProviderModelItem(slug: $0.slug, name: $0.name, isCustom: false, capabilities: capabilityLabels(descriptors($0))) }
    let customItems = custom.map { entry in
      ProviderModelItem(
        slug: entry.slug, name: entry.name, isCustom: true,
        capabilities: capabilityLabels(entry.descriptors.isEmpty ? liveCustom[entry.slug].map(descriptors) ?? [] : entry.descriptors))
    }
    return builtIn + customItems
  }
}

// MARK: - Custom models

public struct CustomModelDefinition: Sendable, Equatable {
  public var slug: String
  public var name: String
  /// `capabilities.optionDescriptors` as stored (wire JSON).
  public var descriptors: [JSONValue] = []
  public init(slug: String, name: String, descriptors: [JSONValue] = []) {
    self.slug = slug
    self.name = name
    self.descriptors = descriptors
  }
}

public enum CustomModels {
  public static func normalizeSlug(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `customModels` of an instance config: bare slugs and entries, duplicates and malformed rows dropped.
  public static func read(_ config: JSONValue?) -> [CustomModelDefinition] {
    var seen = Set<String>()
    return (config?["customModels"]?.arrayValue ?? []).compactMap { raw in
      let object = raw.stringValue.map { ["slug": JSONValue.string($0)] } ?? raw.objectValue
      guard let slug = normalizeSlug(object?["slug"]?.stringValue ?? ""), seen.insert(slug).inserted else { return nil }
      let name = normalizeSlug(object?["name"]?.stringValue ?? "") ?? slug
      return CustomModelDefinition(slug: slug, name: name, descriptors: object?["capabilities"]?["optionDescriptors"]?.arrayValue ?? [])
    }
  }

  /// A bare slug when the entry carries nothing custom.
  public static func setting(_ entry: CustomModelDefinition) -> JSONValue {
    let name = entry.name != entry.slug ? entry.name : nil
    if name == nil, entry.descriptors.isEmpty { return .string(entry.slug) }
    var object: [String: JSONValue] = ["slug": .string(entry.slug)]
    if let name { object["name"] = .string(name) }
    if !entry.descriptors.isEmpty { object["capabilities"] = .object(["optionDescriptors": .array(entry.descriptors)]) }
    return .object(object)
  }

  /// `customModels: []` is stored explicitly: it means "the user cleared the list".
  public static func writing(_ entries: [CustomModelDefinition], into config: JSONValue?) -> JSONValue {
    var object = config?.objectValue ?? [:]
    object["customModels"] = .array(entries.map(setting))
    return .object(object)
  }

  /// The slug to add, or why it cannot be added.
  public static func validatedNewSlug(_ raw: String, builtIn: [ProviderModelItem], existing: [CustomModelDefinition]) -> Result<String, ProviderMessage> {
    guard let slug = normalizeSlug(raw) else { return .failure(ProviderMessage("Enter a model slug.")) }
    if builtIn.contains(where: { !$0.isCustom && $0.slug == slug }) { return .failure(ProviderMessage("That model is already built in.")) }
    if slug.count > ProviderModels.maxCustomSlugLength {
      return .failure(ProviderMessage("Model slugs must be \(ProviderModels.maxCustomSlugLength) characters or less."))
    }
    if existing.contains(where: { $0.slug == slug }) { return .failure(ProviderMessage("That custom model is already saved.")) }
    return .success(slug)
  }

  // MARK: Editor draft

  public struct EditorChoice: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var value = ""
    public var label = ""
    public var isDefault = false
    public var description: String?
    public init() {}
    init(value: String, label: String, isDefault: Bool = false) {
      self.value = value
      self.label = label
      self.isDefault = isDefault
    }
  }

  public struct EditorDescriptor: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var isToggle = false
    public var optionId = ""
    public var label = ""
    public var choices: [EditorChoice] = []
    public var toggleValue: Bool?
    public var description: String?
    public init() {}
    init(isToggle: Bool, optionId: String, label: String, choices: [EditorChoice] = []) {
      self.isToggle = isToggle
      self.optionId = optionId
      self.label = label
      self.choices = choices
    }
  }

  public struct Draft: Sendable, Equatable {
    public var slug: String
    public var name: String
    public var descriptors: [EditorDescriptor]
  }

  public static func draft(_ entry: CustomModelDefinition) -> Draft {
    Draft(slug: entry.slug, name: entry.name == entry.slug ? "" : entry.name, descriptors: entry.descriptors.compactMap(editorDescriptor))
  }

  /// Prompt-injected choices (Claude's `ultrathink`) need built-in runtime profiles a custom entry lacks, so they are dropped.
  static func editorDescriptor(_ json: JSONValue) -> EditorDescriptor? {
    guard let type = json["type"]?.stringValue, type == "select" || type == "boolean" else { return nil }
    var descriptor = EditorDescriptor(isToggle: type == "boolean", optionId: json["id"]?.stringValue ?? "", label: json["label"]?.stringValue ?? "")
    descriptor.description = json["description"]?.stringValue
    if type == "boolean" {
      descriptor.toggleValue = json["currentValue"]?.boolValue
      return descriptor
    }
    let injected = Set((json["promptInjectedValues"]?.arrayValue ?? []).compactMap(\.stringValue))
    let options = (json["options"]?.arrayValue ?? []).filter { !injected.contains($0["id"]?.stringValue ?? "") }
    let current = json["currentValue"]?.stringValue
    let defaultId = options.first { $0["id"]?.stringValue == current }?["id"]?.stringValue ?? options.first { $0["isDefault"]?.boolValue == true }?["id"]?.stringValue
    descriptor.choices = options.map {
      var choice = EditorChoice(value: $0["id"]?.stringValue ?? "", label: $0["label"]?.stringValue ?? "", isDefault: $0["id"]?.stringValue == defaultId)
      choice.description = $0["description"]?.stringValue
      return choice
    }
    return descriptor
  }

  /// Options of a built-in model, to start a custom one from.
  public static func descriptors(copiedFrom descriptors: [JSONValue], driver: String) -> [EditorDescriptor] {
    descriptors.filter { driver != "claudeAgent" || $0["id"]?.stringValue != "contextWindow" }.compactMap(editorDescriptor)
  }

  public static func descriptor(from preset: DescriptorPreset) -> EditorDescriptor {
    EditorDescriptor(
      isToggle: preset.isToggle, optionId: preset.id, label: preset.label,
      choices: preset.choices.map { EditorChoice(value: $0.id, label: $0.label, isDefault: $0.isDefault) })
  }

  /// The first problem in reading order, or nil when the draft can be saved.
  public static func validate(_ draft: Draft) -> String? {
    var seenIds = Set<String>()
    for (index, descriptor) in draft.descriptors.enumerated() {
      let position = "Option \(index + 1)"
      let id = descriptor.optionId.trimmingCharacters(in: .whitespaces)
      if id.isEmpty { return "\(position) needs an id." }
      if !seenIds.insert(id).inserted { return "\(position): id \"\(id)\" is used twice." }
      if descriptor.label.trimmingCharacters(in: .whitespaces).isEmpty { return "\(position) needs a label." }
      if descriptor.isToggle { continue }
      if descriptor.choices.isEmpty { return "\(position) needs at least one choice." }
      var seenChoices = Set<String>()
      for choice in descriptor.choices {
        let value = choice.value.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return "\(position) has a choice without a value." }
        if !seenChoices.insert(value).inserted { return "\(position): choice \"\(value)\" is used twice." }
      }
    }
    return nil
  }

  /// A validated draft as an entry; a blank name falls back to the slug.
  public static func entry(from draft: Draft) -> CustomModelDefinition {
    let descriptors: [JSONValue] = draft.descriptors.map { descriptor in
      var object: [String: JSONValue] = [
        "id": .string(descriptor.optionId.trimmingCharacters(in: .whitespaces)),
        "label": .string(descriptor.label.trimmingCharacters(in: .whitespaces)),
        "type": .string(descriptor.isToggle ? "boolean" : "select"),
      ]
      if let description = descriptor.description { object["description"] = .string(description) }
      if descriptor.isToggle {
        if let value = descriptor.toggleValue { object["currentValue"] = .bool(value) }
        return .object(object)
      }
      let options: [JSONValue] = descriptor.choices.map { choice in
        let value = choice.value.trimmingCharacters(in: .whitespaces)
        let label = choice.label.trimmingCharacters(in: .whitespaces)
        var option: [String: JSONValue] = ["id": .string(value), "label": .string(label.isEmpty ? value : label)]
        if let description = choice.description { option["description"] = .string(description) }
        if choice.isDefault { option["isDefault"] = .bool(true) }
        return .object(option)
      }
      object["options"] = .array(options)
      if let defaultChoice = descriptor.choices.first(where: \.isDefault) { object["currentValue"] = .string(defaultChoice.value.trimmingCharacters(in: .whitespaces)) }
      return .object(object)
    }
    let name = draft.name.trimmingCharacters(in: .whitespaces)
    return CustomModelDefinition(slug: draft.slug, name: name.isEmpty ? draft.slug : name, descriptors: descriptors)
  }
}

/// A user-facing reason, usable as a `Result` failure.
public struct ProviderMessage: Error, Sendable, Equatable {
  public var text: String
  public init(_ text: String) { self.text = text }
}

// MARK: - Usage sources

public enum ProviderUsageSources {
  /// Stable per hub: dots and dashes of the host are kept, anything else folds to a dash.
  public static func sourceId(fromURL url: String) -> String {
    var host = url
    if let parsed = URL(string: url), let name = parsed.host { host = parsed.port.map { "\(name):\($0)" } ?? name }
    var slug = ""
    var inRun = false
    for scalar in host.lowercased().unicodeScalars {
      let keep = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) || scalar == "." || scalar == "-"
      if keep {
        slug.unicodeScalars.append(scalar)
        inRun = false
      } else if !inRun {
        slug.append("-")
        inRun = true
      }
    }
    let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "cliproxy-\(trimmed.isEmpty ? "hub" : trimmed)"
  }

  /// The patch names only this entry; the server merges it into its map.
  public static func addPatch(label: String, url: String, managementKey: String) -> ServerSettingsPatch {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    let trimmedURL = url.trimmingCharacters(in: .whitespaces)
    let source = UsageLimitSourceConfig(label: trimmedLabel.isEmpty ? nil : trimmedLabel, url: trimmedURL, managementKey: managementKey.trimmingCharacters(in: .whitespaces), enabled: true)
    return ServerSettingsPatch(usageLimitSources: [sourceId(fromURL: trimmedURL): source])
  }

  /// `null` removes the entry (and the key the server stored for it).
  public static func removePatch(id: String) -> ServerSettingsPatch {
    ServerSettingsPatch(usageLimitSources: [id: nil])
  }
}
