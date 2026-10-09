import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Models of one instance: favorites, order and picker visibility (device preferences) and custom models (saved on the
/// environment, in the instance config).
struct ProviderModelsSection: View {
  let controller: ProvidersController
  let row: ProviderInstanceRow
  let live: ServerConfigProvidersItem?

  @State private var filter = ""
  @State private var adding = false
  @State private var newSlug = ""
  @State private var addError: String?
  @State private var editingSlug: String?
  @FocusState private var addFocused: Bool

  private var instanceId: String { row.instanceId }
  private var customAllowed: Bool { row.driver != "antigravity" }

  var body: some View {
    let custom = row.driver == "antigravity" ? [] : CustomModels.read(row.instance.config)
    let models = ProviderModels.items(live: live?.models, custom: custom)
    let preferences = controller.modelPreferences(instanceId)
    let favoriteList = controller.favorites(instanceId)
    let favorites = Set(favoriteList), hidden = Set(preferences.hiddenModels)
    let display = ProviderModels.displayOrder(models, favorites: favorites, hidden: hidden, order: preferences.modelOrder)
    let builtIn = models.filter { !$0.isCustom }
    let filtering = models.count > ProviderModels.filterThreshold && !filter.trimmingCharacters(in: .whitespaces).isEmpty
    let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
    let visible = filtering ? display.filter { $0.name.lowercased().contains(needle) || $0.slug.lowercased().contains(needle) } : display
    let favoriteCount = display.filter { favorites.contains($0.slug) }.count
    let hiddenCount = display.filter { !$0.isCustom && hidden.contains($0.slug) }.count

    Section {
      toolbar(models: models, builtIn: builtIn, hidden: preferences.hiddenModels, favoriteCount: favoriteCount, hiddenCount: hiddenCount)
      if visible.isEmpty {
        Text(filtering ? "No models match." : "No models reported for this provider yet.").foregroundStyle(.secondary)
      }
      ForEach(Array(visible.enumerated()), id: \.element.slug) { index, item in
        let bucket = ProviderModels.bucket(item, favorites: favorites, hidden: hidden)
        VStack(alignment: .leading, spacing: 6) {
          if index == 0 || ProviderModels.bucket(visible[index - 1], favorites: favorites, hidden: hidden) != bucket, let title = groupTitle(bucket, favoriteCount: favoriteCount) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 8)
          }
          modelRow(item, bucket: bucket, display: display, favorites: favorites, hidden: hidden, preferences: preferences, favoriteList: favoriteList, filtering: filtering, custom: custom)
          if item.isCustom, editingSlug == item.slug, let entry = custom.first(where: { $0.slug == item.slug }) {
            CustomModelEditorView(driver: row.driver, entry: entry, builtIn: live?.models.filter { !$0.isCustom } ?? []) { saved in
              saveCustom(custom.map { $0.slug == saved.slug ? saved : $0 })
              editingSlug = nil
            } onCancel: {
              editingSlug = nil
            }
          }
        }
      }
      if customAllowed { addCustom(custom: custom, builtIn: builtIn) }
    } header: {
      Text("Models")
    } footer: {
      Text("Favorites, visibility, and ordering are saved on this device. Custom models are saved on \(controller.environmentLabel).")
    }
  }

  // MARK: Toolbar

  private func toolbar(models: [ProviderModelItem], builtIn: [ProviderModelItem], hidden: [String], favoriteCount: Int, hiddenCount: Int) -> some View {
    HStack(spacing: 10) {
      if models.count > ProviderModels.filterThreshold {
        TextField("Filter models", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
      }
      Text(summary(models.count, favoriteCount, hiddenCount)).font(.callout).foregroundStyle(.secondary)
      Spacer()
      if !builtIn.isEmpty {
        let allHidden = builtIn.allSatisfy { hidden.contains($0.slug) }
        Button(allHidden ? "Enable all" : "Disable all") {
          let order = controller.modelPreferences(instanceId).modelOrder
          controller.setModelPreferences(instanceId, hidden: ProviderModels.hiddenAfterBulkToggle(models, hidden: hidden), order: order)
        }
      }
    }
  }

  private func summary(_ count: Int, _ favorites: Int, _ hidden: Int) -> String {
    var text = "\(count) model\(count == 1 ? "" : "s")"
    if favorites > 0 { text += " · \(favorites) favorite\(favorites == 1 ? "" : "s")" }
    if hidden > 0 { text += " · \(hidden) hidden" }
    return text
  }

  private func groupTitle(_ bucket: ProviderModels.Bucket, favoriteCount: Int) -> String? {
    switch bucket {
    case .favorite: favoriteCount > 0 ? "Favorites" : nil
    case .visible: favoriteCount > 0 ? "All" : nil
    case .hidden: "Hidden from picker"
    }
  }

  // MARK: Rows

  private func modelRow(
    _ item: ProviderModelItem, bucket: ProviderModels.Bucket, display: [ProviderModelItem], favorites: Set<String>, hidden: Set<String>,
    preferences: ClientSettingsSchemaProviderModelPreferencesValue, favoriteList: [String], filtering: Bool, custom: [CustomModelDefinition]
  ) -> some View {
    let isFavorite = bucket == .favorite
    let isHidden = !item.isCustom && hidden.contains(item.slug)
    let index = display.firstIndex { $0.slug == item.slug } ?? 0
    func canMove(_ step: Int) -> Bool {
      !filtering && ProviderModels.order(afterMoving: item.slug, by: step, in: display, favorites: favorites, hidden: hidden) != nil && index + step >= 0
    }
    func move(_ step: Int) {
      guard let order = ProviderModels.order(afterMoving: item.slug, by: step, in: display, favorites: favorites, hidden: hidden) else { return }
      controller.setModelPreferences(instanceId, hidden: preferences.hiddenModels, order: order)
    }
    return HStack(spacing: 8) {
      Button {
        controller.setFavorites(instanceId, isFavorite ? favoriteList.filter { $0 != item.slug } : favoriteList + [item.slug])
      } label: {
        Image(systemName: isFavorite ? "star.fill" : "star").foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
      }
      .buttonStyle(.borderless).help(isFavorite ? "Remove from favorites" : "Add to favorites")
      .accessibilityLabel("\(isFavorite ? "Remove" : "Add") \(item.name) \(isFavorite ? "from" : "to") favorites")
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(item.name).lineLimit(1).foregroundStyle(isHidden ? .secondary : .primary)
        if item.name != item.slug { Text(item.slug).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
        if item.isCustom { Text("custom").font(.caption).foregroundStyle(.tertiary) }
      }
      Spacer(minLength: 8)
      if !item.capabilities.isEmpty { Text(item.capabilities.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
      if !isHidden, !filtering {
        Button { move(-1) } label: { Image(systemName: "chevron.up") }
          .buttonStyle(.borderless).disabled(!canMove(-1)).help("Move up").accessibilityLabel("Move \(item.name) up")
        Button { move(1) } label: { Image(systemName: "chevron.down") }
          .buttonStyle(.borderless).disabled(!canMove(1)).help("Move down").accessibilityLabel("Move \(item.name) down")
      }
      if item.isCustom {
        Button { editingSlug = editingSlug == item.slug ? nil : item.slug } label: { Image(systemName: "pencil") }
          .buttonStyle(.borderless).help("Edit name and options").accessibilityLabel("Edit \(item.slug)")
        Button { remove(item.slug, custom: custom, preferences: preferences, favoriteList: favoriteList) } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless).help("Remove custom model").accessibilityLabel("Remove \(item.slug)")
      }
      Toggle(
        "Show \(item.name) in the model picker",
        isOn: Binding(
          get: { !isHidden },
          set: { shown in
            let next = shown ? preferences.hiddenModels.filter { $0 != item.slug } : preferences.hiddenModels + [item.slug]
            controller.setModelPreferences(instanceId, hidden: next, order: preferences.modelOrder)
          })
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(item.isCustom)
      .help(item.isCustom ? "Custom models are always shown in the picker" : isHidden ? "Hidden from picker" : "Shown in picker")
    }
    .opacity(isHidden ? 0.6 : 1)
  }

  // MARK: Custom models

  private func addCustom(custom: [CustomModelDefinition], builtIn: [ProviderModelItem]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if adding {
        HStack {
          TextField("Model slug", text: $newSlug, prompt: Text(ProviderCatalog.driver(row.driver)?.modelPlaceholder ?? "model-slug"))
            .textFieldStyle(.roundedBorder).font(.body.monospaced()).autocorrectionDisabled().focused($addFocused)
            .onSubmit { add(custom: custom, builtIn: builtIn) }
            .onChange(of: newSlug) { addError = nil }
            .onExitCommand { cancelAdd() }
          Button("Add") { add(custom: custom, builtIn: builtIn) }
          Button("Cancel", role: .cancel) { cancelAdd() }
        }
        if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
      } else {
        Button("Add custom model", systemImage: "plus") {
          adding = true
          addFocused = true
        }
      }
    }
  }

  private func add(custom: [CustomModelDefinition], builtIn: [ProviderModelItem]) {
    switch CustomModels.validatedNewSlug(newSlug, builtIn: builtIn, existing: custom) {
    case .failure(let message): addError = message.text
    case .success(let slug):
      filter = ""
      saveCustom(custom + [CustomModelDefinition(slug: slug, name: slug)])
      cancelAdd()
    }
  }

  private func cancelAdd() {
    adding = false
    newSlug = ""
    addError = nil
  }

  private func remove(_ slug: String, custom: [CustomModelDefinition], preferences: ClientSettingsSchemaProviderModelPreferencesValue, favoriteList: [String]) {
    if editingSlug == slug { editingSlug = nil }
    saveCustom(custom.filter { $0.slug != slug })
    controller.setModelPreferences(instanceId, hidden: preferences.hiddenModels, order: preferences.modelOrder.filter { $0 != slug })
    controller.setFavorites(instanceId, favoriteList.filter { $0 != slug })
  }

  private func saveCustom(_ entries: [CustomModelDefinition]) {
    controller.edit(instanceId) { $0.config = CustomModels.writing(entries, into: $0.config) }
  }
}

/// Inline editor for one custom model: its display name and the options the composer offers for it. Nothing is saved until Save.
struct CustomModelEditorView: View {
  let driver: String
  let entry: CustomModelDefinition
  let builtIn: [ServerConfigProvidersItemModelsItem]
  let onSave: (CustomModelDefinition) -> Void
  let onCancel: () -> Void
  @State private var draft: CustomModels.Draft
  @State private var error: String?

  init(
    driver: String, entry: CustomModelDefinition, builtIn: [ServerConfigProvidersItemModelsItem], onSave: @escaping (CustomModelDefinition) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.driver = driver
    self.entry = entry
    self.builtIn = builtIn
    self.onSave = onSave
    self.onCancel = onCancel
    _draft = State(initialValue: CustomModels.draft(entry))
  }

  private var presets: [DescriptorPreset] { ProviderCatalog.driver(driver)?.presets ?? [] }
  private var copyable: [ServerConfigProvidersItemModelsItem] { builtIn.filter { !($0.capabilities?.optionDescriptors ?? []).isEmpty } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledContent("Display name") {
        TextField("Display name", text: $draft.name, prompt: Text(draft.slug)).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 260)
      }
      HStack {
        Text("Options shown in the composer").font(.callout).foregroundStyle(.secondary)
        Spacer()
        if !copyable.isEmpty {
          Menu("Copy from…") {
            ForEach(copyable, id: \.slug) { model in
              Button(model.name) {
                let json = (model.capabilities?.optionDescriptors ?? []).compactMap { JSONValue(encoding: $0) }
                draft.descriptors = CustomModels.descriptors(copiedFrom: json, driver: driver)
                error = nil
              }
            }
          }
          .fixedSize()
        }
      }
      if draft.descriptors.isEmpty {
        Text("No custom options. The composer uses the provider's default options.").font(.caption).foregroundStyle(.tertiary)
      }
      ForEach($draft.descriptors) { $descriptor in
        descriptorEditor($descriptor)
      }
      HStack {
        ForEach(presets.filter { preset in !draft.descriptors.contains { $0.optionId == preset.id } }) { preset in
          Button(preset.label, systemImage: "plus") { draft.descriptors.append(CustomModels.descriptor(from: preset)) }
        }
        Button("Custom option", systemImage: "plus") { draft.descriptors.append(CustomModels.EditorDescriptor()) }
      }
      .buttonStyle(.borderless)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Save") {
          if let problem = CustomModels.validate(draft) { error = problem } else { onSave(CustomModels.entry(from: draft)) }
        }
        .keyboardShortcut(.defaultAction)
        Button("Cancel", role: .cancel, action: onCancel)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    .onChange(of: draft) { error = nil }
    .onExitCommand(perform: onCancel)
  }

  private func descriptorEditor(_ descriptor: Binding<CustomModels.EditorDescriptor>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        TextField("optionId", text: descriptor.optionId).font(.body.monospaced()).frame(width: 120)
        if presets.contains(where: { $0.id != descriptor.wrappedValue.optionId }) {
          Menu {
            ForEach(presets) { preset in
              Button("\(preset.id) · \(preset.label)") {
                descriptor.wrappedValue = descriptorKeepingIdentity(descriptor.wrappedValue, from: preset)
              }
            }
          } label: {
            Image(systemName: "list.bullet")
          }
          .menuStyle(.borderlessButton).fixedSize().help("Use a known option id")
        }
        TextField("Label", text: descriptor.label)
        Picker("Type", selection: descriptor.isToggle) {
          Text("Choices").tag(false)
          Text("Toggle").tag(true)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        Button { draft.descriptors.removeAll { $0.id == descriptor.wrappedValue.id } } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless).help("Remove option").accessibilityLabel("Remove option \(descriptor.wrappedValue.optionId)")
      }
      .textFieldStyle(.roundedBorder)
      if !descriptor.wrappedValue.isToggle {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(descriptor.choices) { $choice in
            HStack(spacing: 6) {
              TextField("value", text: $choice.value).font(.body.monospaced()).frame(width: 110)
              TextField("Label", text: $choice.label)
              Toggle("Default", isOn: Binding(get: { choice.isDefault }, set: { makeDefault($0, choice.id, in: descriptor) })).toggleStyle(.checkbox)
              Button { descriptor.wrappedValue.choices.removeAll { $0.id == choice.id } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Remove choice")
            }
            .textFieldStyle(.roundedBorder)
          }
          Button("Add choice", systemImage: "plus") { descriptor.wrappedValue.choices.append(CustomModels.EditorChoice()) }.buttonStyle(.borderless)
        }
        .padding(.leading, 16)
      }
    }
    .padding(8)
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
  }

  /// Only one choice can be the default.
  private func makeDefault(_ on: Bool, _ id: UUID, in descriptor: Binding<CustomModels.EditorDescriptor>) {
    for index in descriptor.wrappedValue.choices.indices {
      let match = descriptor.wrappedValue.choices[index].id == id
      if match { descriptor.wrappedValue.choices[index].isDefault = on } else if on { descriptor.wrappedValue.choices[index].isDefault = false }
    }
  }

  private func descriptorKeepingIdentity(_ current: CustomModels.EditorDescriptor, from preset: DescriptorPreset) -> CustomModels.EditorDescriptor {
    var next = CustomModels.descriptor(from: preset)
    next.id = current.id
    return next
  }
}
