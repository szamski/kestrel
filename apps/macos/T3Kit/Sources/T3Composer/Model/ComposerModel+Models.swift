import Foundation
import T3Contracts

/// A row of the model picker.
public struct ModelPickerRow: Identifiable, Sendable, Hashable {
  public var instanceId: String
  public var driverKind: String
  public var providerName: String
  public var accentColor: String?
  public var option: AppModelOption
  public var isSelected: Bool
  public var isFavorite: Bool
  /// Why this model cannot be picked in this thread (provider locked after the first message).
  public var disabledReason: String?
  /// ⌘1…⌘9 jumps to the first nine selectable rows.
  public var jumpIndex: Int?

  public var id: String { ModelPicker.modelKey(instanceId: instanceId, slug: option.slug) }
}

extension ComposerModel {
  // MARK: Provider and model

  var instanceEntries: [ProviderInstanceEntry] { catalog.instanceEntries }

  /// A started thread stays on its driver (and continuation group).
  var lockedInstanceId: String? {
    thread.isFirstMessage ? nil : (thread.sessionProviderInstanceId ?? thread.threadModelSelection?.instanceId.rawValue)
  }

  var lockedDriver: String? {
    guard let id = lockedInstanceId else { return nil }
    return instanceEntries.first { $0.instanceId == id }?.driverKind ?? catalog.providers.first { $0.instanceId.rawValue == id }?.driver.rawValue ?? id
  }

  var providerResolution: ModelPicker.ProviderResolution {
    ModelPicker.resolveComposerProvider(
      entries: instanceEntries,
      candidateInstanceIds: [draft.activeProvider, thread.sessionProviderInstanceId, thread.threadModelSelection?.instanceId.rawValue, thread.projectModelSelection?.instanceId.rawValue, catalog.defaultModelSelection?.instanceId.rawValue],
      lockedDriver: lockedDriver, lockedInstanceId: lockedInstanceId)
  }

  public var selectedEntry: ProviderInstanceEntry? { providerResolution.entry }
  public var showProviderUnavailable: Bool { selectedEntry == nil && !catalog.providers.isEmpty }
  public var providerCatalogPending: Bool { selectedEntry == nil && catalog.providers.isEmpty }

  var effectiveModelState: ModelPicker.EffectiveState {
    let entry = selectedEntry
    return ModelPicker.effectiveState(
      draftSelections: draft.modelSelectionByProvider, providers: catalog.providers, selectedDriver: entry?.driverKind ?? providerResolution.requestedDriver,
      selectedInstanceId: entry?.instanceId, threadSelection: thread.threadModelSelection, projectSelection: thread.projectModelSelection ?? catalog.defaultModelSelection,
      settings: settings.models)
  }

  public var selectedModel: String { effectiveModelState.selectedModel }

  public var selectedModelDisplayName: String {
    guard let entry = selectedEntry else { return "No provider" }
    let slug = selectedModel
    if let option = ModelCatalog.modelOptions(for: entry, settings: settings.models, selectedModel: slug).first(where: { $0.slug == slug }) {
      return option.shortName ?? option.name
    }
    return slug.isEmpty ? "Choose a model" : slug
  }

  var selectedModelOptions: [ProviderOptionSelection]? { selectedEntry.flatMap { effectiveModelState.modelOptions?[$0.instanceId] } }

  public var providerState: ModelOptions.ProviderState {
    ModelOptions.providerState(
      driver: selectedEntry?.driverKind ?? providerResolution.requestedDriver, model: selectedModel, models: selectedEntry?.models ?? [], modelOptions: selectedModelOptions,
      promptInjectionUltrathink: ComposerSubmission.isUltrathinkPrompt(draft.prompt), planModeEnabled: settings.models.planModeEnabled)
  }

  /// The selection a send carries: the resolved model plus the options the user set.
  public var modelSelectionForSend: ModelSelection {
    guard let entry = selectedEntry else { return ModelSelection(instanceId: ProviderInstanceId(NoProvider.instanceId), model: "", options: nil) }
    return ModelOptions.makeSelection(instanceId: entry.instanceId, model: selectedModel, options: providerState.modelOptionsForDispatch)
  }

  public var traits: TraitsState {
    Traits.state(
      driver: selectedEntry?.driverKind ?? providerResolution.requestedDriver, models: selectedEntry?.models ?? [], model: selectedModel, prompt: draft.prompt,
      modelOptions: selectedModelOptions, planModeEnabled: settings.models.planModeEnabled)
  }

  public var traitsDisplay: Traits.Display {
    let state = traits
    return Traits.triggerDisplay(
      driver: selectedEntry?.driverKind ?? "", descriptors: state.descriptors, primaryId: state.primarySelect?.id, ultrathinkPromptControlled: state.ultrathinkPromptControlled)
  }

  // MARK: Picking

  /// The picker's rows: every pickable model of every enabled instance, filtered and ranked by
  /// `query`, favorites first when not searching.
  public func modelPickerRows(query: String, instanceFilter: String? = nil) -> [ModelPickerRow] {
    let entries = instanceEntries.filter { $0.enabled }
    let selectedEntry = selectedEntry
    let selectedSlug = selectedModel
    var rows: [(ModelPickerRow, Int)] = []
    for entry in entries where instanceFilter == nil || entry.instanceId == instanceFilter {
      let options = ModelCatalog.modelOptions(for: entry, settings: settings.models, selectedModel: entry.instanceId == selectedEntry?.instanceId ? selectedSlug : nil)
      for option in options where !option.isLegacy || option.slug == selectedSlug {
        let key = "\(entry.instanceId):\(option.slug)"
        let favorite = settings.models.favoriteModelKeys.contains(key)
        let searchable = ModelPicker.Searchable(
          driverKind: entry.driverKind, providerDisplayName: entry.displayName, name: option.name, shortName: option.shortName, subProvider: option.subProvider, isFavorite: favorite)
        guard let score = ModelPicker.score(searchable, query: query) else { continue }
        rows.append((
          ModelPickerRow(
            instanceId: entry.instanceId, driverKind: entry.driverKind, providerName: entry.displayName, accentColor: entry.accentColor, option: option,
            isSelected: entry.instanceId == selectedEntry?.instanceId && option.slug == selectedSlug, isFavorite: favorite,
            disabledReason: modelDisabledReason(entry: entry, model: option.slug), jumpIndex: nil),
          score
        ))
      }
    }
    let searching = !query.jsTrim().isEmpty
    var ordered: [ModelPickerRow]
    if searching {
      ordered = rows.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    } else {
      // Favorites first, then the catalog order the entries already carry.
      ordered = rows.map(\.0)
      ordered = ordered.enumerated().sorted { left, right in
        if left.element.isFavorite != right.element.isFavorite { return left.element.isFavorite }
        return left.offset < right.offset
      }.map(\.element)
    }
    var jump = 0
    for index in ordered.indices where ordered[index].disabledReason == nil && jump < 9 {
      ordered[index].jumpIndex = jump
      jump += 1
    }
    return ordered
  }

  func modelDisabledReason(entry: ProviderInstanceEntry, model: String) -> String? {
    if let locked = lockedDriver, locked != entry.driverKind { return "This thread already runs on another provider." }
    if lockedInstanceId != nil, let group = providerResolution.lockedContinuationGroupKey, entry.continuationGroupKey != group {
      return "This conversation cannot continue on that provider."
    }
    if let blocked = startedThreadModelChangeBlockReason(instanceId: entry.instanceId, model: model) { return blocked }
    return nil
  }

  /// Providers that cannot switch models once a conversation has started.
  func startedThreadModelChangeBlockReason(instanceId: String, model: String) -> String? {
    guard !thread.isFirstMessage, let current = thread.threadModelSelection else { return nil }
    let currentInstance = thread.sessionProviderInstanceId ?? current.instanceId.rawValue
    if currentInstance == instanceId && current.model == model { return nil }
    let providers = catalog.providers
    let currentRequires = providers.first { $0.instanceId.rawValue == currentInstance }?.requiresNewThreadForModelChange == true
    let nextRequires = providers.first { $0.instanceId.rawValue == instanceId }?.requiresNewThreadForModelChange == true
    return currentRequires || nextRequires ? "This provider does not allow switching models after a conversation has started." : nil
  }

  /// Picks a model (explicit: it becomes the thread's choice and the sticky default for new threads).
  public func selectModel(instanceId: String, slug: String) {
    guard let entry = instanceEntries.first(where: { $0.instanceId == instanceId }) else { return }
    guard modelDisabledReason(entry: entry, model: slug) == nil else {
      if let reason = modelDisabledReason(entry: entry, model: slug) {
        services.post(ComposerNotice(kind: .warning, title: "Start a new chat to change models", message: reason))
      }
      return
    }
    guard let resolved = ModelCatalog.resolveModel(instanceId: instanceId, settings: settings.models, providers: catalog.providers, selectedModel: slug) else { return }
    let selection = ModelSelection(instanceId: ProviderInstanceId(instanceId), model: resolved, options: nil)
    services.editDrafts {
      $0.setModelSelection(target.key, selection, explicit: true)
      $0.setStickyModelSelection(selection)
    }
    isModelPickerOpen = false
    requestFocus()
  }

  public func toggleFavorite(_ row: ModelPickerRow) {
    let environment = services.environment
    let next = !row.isFavorite
    Task { await environment.setFavoriteModel(instanceId: row.instanceId, slug: row.option.slug, isFavorite: next) }
  }

  // MARK: Traits

  /// Writes a trait selection (effort, fast mode, ...) for the picked model.
  public func applyTraitSelections(_ options: [ProviderOptionSelection]?) {
    guard let entry = selectedEntry else { return }
    // Read the model before the edit: the closure holds exclusive access to the drafts.
    let model = selectedModel
    services.editDrafts { $0.setProviderModelOptions(target.key, instanceId: entry.instanceId, model: model, options: options, persistSticky: true) }
  }

  public func selectTrait(_ descriptor: SelectProviderOptionDescriptor, value: String) {
    guard let change = Traits.selectChange(traits, descriptor: descriptor, value: value, prompt: draft.prompt) else { return }
    if let prompt = change.prompt {
      setActiveText(prompt)
      reloadEditor(markdown: prompt, cursor: ComposerLogic.collapseExpandedCursor(prompt, prompt.jsLength), undoable: true)
    }
    if let options = change.options { applyTraitSelections(options) }
  }

  public func setTrait(boolean id: String, isOn: Bool) { applyTraitSelections(Traits.booleanChange(traits, id: id, isOn: isOn)) }

  // MARK: Modes

  public var runtimeMode: RuntimeMode { draft.runtimeMode ?? thread.runtimeMode ?? catalog.defaultRuntimeMode }

  public func setRuntimeMode(_ mode: RuntimeMode) { services.editDrafts { $0.setRuntimeMode(target.key, mode) } }

  /// Legacy plan mode: the Build/Plan toggle exists only when enabled and the provider supports it.
  public var planModeUiEnabled: Bool {
    settings.models.planModeEnabled && selectedEntry != nil && selectedEntry?.snapshot.showInteractionModeToggle != false
  }

  public var interactionMode: ProviderInteractionMode {
    planModeUiEnabled ? (draft.interactionMode ?? thread.interactionMode ?? .default) : .default
  }

  public func setInteractionMode(_ mode: ProviderInteractionMode) {
    guard planModeUiEnabled else { return }
    services.editDrafts { $0.setInteractionMode(target.key, mode) }
  }

  public func toggleInteractionMode() { setInteractionMode(interactionMode == .plan ? .default : .plan) }

  /// Everything a queued send needs to go out later, on whatever thread is on screen then.
  var sendSettings: QueuedMessageSendSettings {
    QueuedMessageSendSettings(modelSelection: modelSelectionForSend, runtimeMode: runtimeMode, interactionMode: interactionMode, promptEffort: providerState.promptEffort)
  }
}
