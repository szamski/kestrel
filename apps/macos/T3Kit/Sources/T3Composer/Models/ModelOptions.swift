import Foundation
import T3Contracts

/// Option descriptors (effort, fast mode, ...) and the selections made against them. Ports the
/// option helpers of `packages/shared/src/model.ts` and `composerProviderState.tsx`.
extension ProviderOptionDescriptor {
  public var id: String? {
    switch self {
    case .select(let value): value.id
    case .boolean(let value): value.id
    case .unknown: nil
    }
  }

  public var label: String {
    switch self {
    case .select(let value): value.label
    case .boolean(let value): value.label
    case .unknown: ""
    }
  }

  public var optionDescription: String? {
    switch self {
    case .select(let value): value.description
    case .boolean(let value): value.description
    case .unknown: nil
    }
  }
}

extension ProviderOptionSelectionValue {
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
}

public enum ModelOptions {
  /// `[ProviderOptionDescriptor]` of a model snapshot.
  public static func descriptors(of model: ProviderModelSnapshot?) -> [ProviderOptionDescriptor] {
    model?.capabilities?.optionDescriptors ?? []
  }

  private static func rawSelectionValue(_ selections: [ProviderOptionSelection]?, id: String) -> ProviderOptionSelectionValue? {
    selections?.first(where: { $0.id == id })?.value
  }

  public static func stringSelection(_ selections: [ProviderOptionSelection]?, id: String) -> String? {
    rawSelectionValue(selections, id: id)?.stringValue
  }

  public static func boolSelection(_ selections: [ProviderOptionSelection]?, id: String) -> Bool? {
    rawSelectionValue(selections, id: id)?.boolValue
  }

  private static func trimOrNil(_ value: String?) -> String? {
    guard let trimmed = value?.jsTrim(), !trimmed.isEmpty else { return nil }
    return trimmed
  }

  private static func resolveChoice(_ descriptor: SelectProviderOptionDescriptor, raw: String?) -> String? {
    guard let trimmed = trimOrNil(raw) else {
      return descriptor.currentValue ?? descriptor.options.first(where: { $0.isDefault == true })?.id
    }
    if descriptor.options.isEmpty { return trimmed }
    if descriptor.promptInjectedValues?.contains(trimmed) == true, descriptor.options.contains(where: { $0.id == trimmed }) {
      return descriptor.options.first(where: { $0.isDefault == true })?.id
    }
    if descriptor.options.contains(where: { $0.id == trimmed }) { return trimmed }
    return descriptor.currentValue ?? descriptor.options.first(where: { $0.isDefault == true })?.id
  }

  private static func withCurrentValue(_ descriptor: ProviderOptionDescriptor, raw: ProviderOptionSelectionValue?) -> ProviderOptionDescriptor {
    switch descriptor {
    case .boolean(var value):
      if let flag = raw?.boolValue { value.currentValue = flag }
      return .boolean(value)
    case .select(var value):
      let current = raw?.stringValue != nil ? resolveChoice(value, raw: raw?.stringValue) : resolveChoice(value, raw: value.currentValue)
      value.currentValue = current.flatMap { $0.isEmpty ? nil : $0 }
      return .select(value)
    case .unknown:
      return descriptor
    }
  }

  /// Descriptors with the user's selections applied as `currentValue`.
  public static func resolvedDescriptors(_ descriptors: [ProviderOptionDescriptor], selections: [ProviderOptionSelection]?) -> [ProviderOptionDescriptor] {
    descriptors.map { descriptor in
      guard let id = descriptor.id else { return descriptor }
      let selected = rawSelectionValue(selections, id: id)
      let fallback: ProviderOptionSelectionValue? = {
        switch descriptor {
        case .boolean(let value): value.currentValue.map(ProviderOptionSelectionValue.bool)
        case .select(let value): value.currentValue.map(ProviderOptionSelectionValue.string)
        case .unknown: nil
        }
      }()
      return withCurrentValue(descriptor, raw: selected ?? fallback)
    }
  }

  public static func currentValue(_ descriptor: ProviderOptionDescriptor?) -> ProviderOptionSelectionValue? {
    switch descriptor {
    case .boolean(let value)?: return value.currentValue.map(ProviderOptionSelectionValue.bool)
    case .select(let value)?:
      if let current = value.currentValue, !current.isEmpty { return .string(current) }
      return value.options.first(where: { $0.isDefault == true }).map { .string($0.id) }
    default: return nil
    }
  }

  public static func currentLabel(_ descriptor: ProviderOptionDescriptor?) -> String? {
    switch descriptor {
    case .boolean(let value)?: return value.currentValue.map { $0 ? "On" : "Off" }
    case .select(let value)?:
      guard let current = currentValue(descriptor)?.stringValue else { return nil }
      return value.options.first(where: { $0.id == current })?.label
    default: return nil
    }
  }

  public static func selections(from descriptors: [ProviderOptionDescriptor]?) -> [ProviderOptionSelection]? {
    guard let descriptors, !descriptors.isEmpty else { return nil }
    let next = descriptors.compactMap { descriptor -> ProviderOptionSelection? in
      guard let id = descriptor.id, let value = currentValue(descriptor) else { return nil }
      return ProviderOptionSelection(id: id, value: value)
    }
    return next.isEmpty ? nil : next
  }

  /// Only options the user touched travel on the wire; descriptor defaults stay implicit.
  public static func explicitSelections(descriptors: [ProviderOptionDescriptor]?, selections: [ProviderOptionSelection]?) -> [ProviderOptionSelection]? {
    guard let selections, !selections.isEmpty else { return nil }
    let explicit = Set(selections.map(\.id))
    let normalized = self.selections(from: descriptors)?.filter { explicit.contains($0.id) }
    return normalized?.isEmpty == false ? normalized : nil
  }

  /// The effort value if it is prompt-injected according to any select descriptor of the model.
  public static func promptInjectedEffort(descriptors: [ProviderOptionDescriptor], raw: String?) -> String? {
    guard let trimmed = trimOrNil(raw) else { return nil }
    for descriptor in resolvedDescriptors(descriptors, selections: nil) {
      if case .select(let value) = descriptor, value.promptInjectedValues?.contains(trimmed) == true { return trimmed }
    }
    return nil
  }

  public static func makeSelection(instanceId: String, model: String, options: [ProviderOptionSelection]?) -> ModelSelection {
    let copies = options ?? []
    return ModelSelection(instanceId: ProviderInstanceId(instanceId), model: model, options: copies.isEmpty ? nil : copies)
  }

  // MARK: Capabilities and provider state

  /// The opencode "plan" agent is only reachable while legacy plan mode is on.
  static func withoutPlanAgent(_ descriptors: [ProviderOptionDescriptor]) -> [ProviderOptionDescriptor] {
    descriptors.flatMap { descriptor -> [ProviderOptionDescriptor] in
      guard case .select(var value) = descriptor, value.id == "agent" else { return [descriptor] }
      let options = value.options.filter { $0.id != "plan" }
      if options.isEmpty { return [] }
      value.options = options
      if let current = value.currentValue, options.contains(where: { $0.id == current }) {
        // keep
      } else {
        value.currentValue = options.first(where: { $0.isDefault == true })?.id ?? options.first?.id
      }
      return [.select(value)]
    }
  }

  public static func capabilities(
    models: [ProviderModelSnapshot], model: String?, driver: String, planModeEnabled: Bool = true
  ) -> [ProviderOptionDescriptor] {
    let slug = ModelCatalog.resolveSelectableModel(driver: driver, value: model, options: ModelCatalog.selectable(models))
    let descriptors = descriptors(of: models.first(where: { $0.slug == slug }))
    return planModeEnabled ? descriptors : withoutPlanAgent(descriptors)
  }

  /// Cursor ACP can report `fastMode: true` as the provider default; T3 only treats Fast as
  /// selected when the user chose it, so an explicit `false` is injected otherwise.
  public static func withImplicitFastModeDefault(_ descriptors: [ProviderOptionDescriptor], selections: [ProviderOptionSelection]?) -> [ProviderOptionSelection]? {
    if selections?.contains(where: { $0.id == "fastMode" }) == true { return selections }
    let hasDescriptor = descriptors.contains { if case .boolean(let value) = $0 { value.id == "fastMode" } else { false } }
    if !hasDescriptor { return selections }
    return (selections ?? []) + [ProviderOptionSelection(id: "fastMode", value: .bool(false))]
  }

  public struct ProviderState: Sendable, Hashable {
    public var driver: String
    public var promptEffort: String?
    public var modelOptionsForDispatch: [ProviderOptionSelection]?
    public var ultrathinkActive: Bool
  }

  /// What the composer sends for a model: the effort written into the prompt (for providers that
  /// read it there) and the explicit option selections.
  public static func providerState(
    driver: String, model: String, models: [ProviderModelSnapshot], modelOptions: [ProviderOptionSelection]?,
    promptInjectionUltrathink: Bool = false, planModeEnabled: Bool
  ) -> ProviderState {
    if driver == "opencode" {
      let normalized = ModelCatalog.normalizeModelSlug(model, driver: driver)
      if !models.contains(where: { $0.slug == normalized }) {
        let preserved = modelOptions?.filter { planModeEnabled || $0.id != "agent" || $0.value != .string("plan") }
        return ProviderState(driver: driver, promptEffort: nil, modelOptionsForDispatch: preserved?.isEmpty == false ? preserved : nil, ultrathinkActive: false)
      }
    }
    let caps = capabilities(models: models, model: model, driver: driver, planModeEnabled: planModeEnabled)
    let selections = withImplicitFastModeDefault(caps, selections: modelOptions)
    let resolved = resolvedDescriptors(caps, selections: selections)
    var primary: SelectProviderOptionDescriptor?
    for descriptor in resolved {
      if case .select(let value) = descriptor {
        primary = value
        break
      }
    }
    let primaryValue = primary.flatMap { currentValue(.select($0))?.stringValue }
    return ProviderState(
      driver: driver, promptEffort: primaryValue,
      modelOptionsForDispatch: explicitSelections(descriptors: resolved, selections: selections),
      ultrathinkActive: (primary?.promptInjectedValues?.count ?? 0) > 0 && promptInjectionUltrathink)
  }

  /// Whether the traits menu has anything to show for the model.
  public static func shouldShowTraits(driver: String, model: String, models: [ProviderModelSnapshot], planModeEnabled: Bool) -> Bool {
    !resolvedDescriptors(capabilities(models: models, model: model, driver: driver, planModeEnabled: planModeEnabled), selections: nil).isEmpty
  }
}
