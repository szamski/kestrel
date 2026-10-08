import Foundation
import T3Contracts

/// The traits control (effort, fast mode, thinking, context window, agent): a port of the logic
/// in `components/chat/TraitsPicker.tsx`.
public struct TraitsState: Sendable, Hashable {
  public var descriptors: [ProviderOptionDescriptor]
  public var selectDescriptors: [ProviderOptionDescriptorSelect]
  public var booleanDescriptors: [ProviderOptionDescriptorBoolean]
  public var primarySelect: ProviderOptionDescriptorSelect?
  public var effort: String?
  public var ultrathinkPromptControlled: Bool
  public var ultrathinkInBodyText: Bool
  public var modelIsUnavailable: Bool
  public var hasAnyControls: Bool
}

public enum Traits {
  private static let savedOptionLabels = ["agent": "Agent", "effort": "Effort", "reasoningEffort": "Reasoning effort", "variant": "Reasoning"]
  private static let ultrathinkPromptPrefix = "Ultrathink:\n"

  private static func savedOptionLabel(_ id: String) -> String {
    if let known = savedOptionLabels[id] { return known }
    var spaced = ""
    var previous: Character?
    for character in id {
      if let previous, (previous.isASCII && (previous.isLowercase || previous.isNumber)), character.isASCII, character.isUppercase { spaced += " " }
      spaced.append(character)
      previous = character
    }
    guard let first = spaced.first else { return spaced }
    return first.uppercased() + spaced.dropFirst()
  }

  /// Read-only descriptors for saved values whose OpenCode model metadata is unavailable.
  static func unavailableDescriptors(_ selections: [ProviderOptionSelection]?) -> [ProviderOptionDescriptor] {
    (selections ?? []).map { selection in
      switch selection.value {
      case .bool(let flag):
        return .boolean(ProviderOptionDescriptorBoolean(id: selection.id, label: savedOptionLabel(selection.id), currentValue: flag))
      case .string(let value):
        return .select(
          ProviderOptionDescriptorSelect(
            id: selection.id, label: savedOptionLabel(selection.id),
            options: [ProviderOptionDescriptorSelectOptionsItem(id: value, label: value)], currentValue: value))
      case .unknown:
        return .unknown(.null)
      }
    }
  }

  public static func state(
    driver: String, models: [ProviderModelSnapshot], model: String?, prompt: String, modelOptions: [ProviderOptionSelection]?,
    allowPromptInjectedEffort: Bool = true, planModeEnabled: Bool
  ) -> TraitsState {
    let caps = ModelOptions.capabilities(models: models, model: model, driver: driver, planModeEnabled: planModeEnabled)
    let unavailable = driver == "opencode" && !models.contains(where: { $0.slug == ModelCatalog.normalizeModelSlug(model, driver: driver) })
    let descriptors: [ProviderOptionDescriptor]
    if unavailable {
      descriptors = unavailableDescriptors(planModeEnabled ? modelOptions : modelOptions?.filter { $0.id != "agent" || $0.value != .string("plan") })
    } else {
      descriptors = ModelOptions.resolvedDescriptors(caps, selections: modelOptions)
    }
    let selects: [ProviderOptionDescriptorSelect] = descriptors.compactMap { if case .select(let value) = $0 { value } else { nil } }
    let booleans: [ProviderOptionDescriptorBoolean] = descriptors.compactMap { if case .boolean(let value) = $0 { value } else { nil } }
    let primary = selects.first
    let ultrathinkControlled = allowPromptInjectedEffort && (primary?.promptInjectedValues?.count ?? 0) > 0 && ComposerSubmission.isUltrathinkPrompt(prompt)
    let ultrathinkInBody = ultrathinkControlled && ComposerSubmission.isUltrathinkPrompt(stripUltrathinkPrefix(prompt))
    let primaryValue = primary.flatMap { ModelOptions.currentValue(.select($0))?.stringValue }
    let hasAny =
      primary != nil || booleans.contains(where: { $0.id == "thinking" }) || booleans.contains(where: { $0.id == "fastMode" })
      || selects.contains(where: { $0.id == "contextWindow" }) || selects.contains(where: { $0.id == "agent" })
      || (unavailable && !descriptors.isEmpty)
    return TraitsState(
      descriptors: descriptors, selectDescriptors: selects, booleanDescriptors: booleans, primarySelect: primary,
      effort: ultrathinkControlled ? "ultrathink" : primaryValue, ultrathinkPromptControlled: ultrathinkControlled,
      ultrathinkInBodyText: ultrathinkInBody, modelIsUnavailable: unavailable, hasAnyControls: hasAny)
  }

  /// `prompt.replace(/^Ultrathink:\s*/i, "")`
  static func stripUltrathinkPrefix(_ prompt: String) -> String {
    let prefix = "ultrathink:"
    guard prompt.lowercased().hasPrefix(prefix), prompt.jsLength >= prefix.count else { return prompt }
    return prompt.jsSlice(prefix.count).jsTrimStart()
  }

  public struct Display: Sendable, Hashable {
    public var label: String
    public var showFastModeIcon: Bool
  }

  /// The trigger's text label plus whether the fast-mode bolt renders.
  public static func triggerDisplay(driver: String, descriptors: [ProviderOptionDescriptor], primaryId: String?, ultrathinkPromptControlled: Bool) -> Display {
    var fallback: String?
    var fastEnabled = false
    var labels: [String] = []
    for descriptor in descriptors {
      if case .boolean(let value) = descriptor, value.id == "fastMode" {
        fastEnabled = value.currentValue == true
        fallback = fastEnabled ? "Fast" : "Normal"
        continue
      }
      if driver == "codex", case .select(let value) = descriptor, value.id == "serviceTier" {
        let current = ModelOptions.currentValue(descriptor)?.stringValue
        if let tier = value.options.first(where: { $0.label == "Fast" }), current == "default" || current == tier.id {
          fastEnabled = current == tier.id
          fallback = value.options.first(where: { $0.id == current })?.label ?? (fastEnabled ? "Fast" : "Normal")
          continue
        }
      }
      let label: String?
      if ultrathinkPromptControlled, descriptor.id == primaryId {
        label = "Ultrathink"
      } else if case .boolean(let value) = descriptor {
        label = "\(value.label) \(value.currentValue == true ? "On" : "Off")"
      } else {
        label = ModelOptions.currentLabel(descriptor)
      }
      if let label, !label.isEmpty { labels.append(label) }
    }
    if labels.isEmpty, let fallback { return Display(label: fallback, showFastModeIcon: false) }
    return Display(label: labels.joined(separator: " · "), showFastModeIcon: fastEnabled)
  }

  public struct Change: Sendable, Hashable {
    /// Replacement prompt text when the change rewrites the prompt (ultrathink).
    public var prompt: String?
    /// New selections to persist; nil leaves the stored options as they are.
    public var options: [ProviderOptionSelection]??
  }

  private static func replacing(_ descriptors: [ProviderOptionDescriptor], id: String, value: ProviderOptionSelectionValue) -> [ProviderOptionDescriptor] {
    descriptors.map { descriptor in
      guard descriptor.id == id else { return descriptor }
      switch descriptor {
      case .boolean(var boolean):
        if let flag = value.boolValue { boolean.currentValue = flag }
        return .boolean(boolean)
      case .select(var select):
        if let string = value.stringValue { select.currentValue = string }
        return .select(select)
      case .unknown: return descriptor
      }
    }
  }

  /// Picking an option in a select group.
  public static func selectChange(_ state: TraitsState, descriptor: ProviderOptionDescriptorSelect, value: String, prompt: String) -> Change? {
    if value.isEmpty { return nil }
    if descriptor.promptInjectedValues?.contains(value) == true {
      let next = prompt.jsTrim().isEmpty ? ultrathinkPromptPrefix : ComposerSubmission.applyClaudePromptEffortPrefix(prompt, effort: "ultrathink")
      return Change(prompt: next, options: nil)
    }
    if state.ultrathinkInBodyText && descriptor.id == state.primarySelect?.id { return nil }
    var nextPrompt: String?
    if state.ultrathinkPromptControlled && descriptor.id == state.primarySelect?.id { nextPrompt = stripUltrathinkPrefix(prompt) }
    let next = replacing(state.descriptors, id: descriptor.id, value: .string(value))
    return Change(prompt: nextPrompt, options: .some(ModelOptions.selections(from: next)))
  }

  /// Switching a boolean trait on or off.
  public static func booleanChange(_ state: TraitsState, id: String, isOn: Bool) -> [ProviderOptionSelection]? {
    ModelOptions.selections(from: replacing(state.descriptors, id: id, value: .bool(isOn)))
  }
}
