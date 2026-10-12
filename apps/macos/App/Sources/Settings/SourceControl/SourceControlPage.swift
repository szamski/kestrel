import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Source control. Same rows, scopes and wording as the web page: repository defaults, what the server found
/// (Git, hosting integrations and their credentials), the Git fetch interval, and how change text and branches are written.
struct SourceControlPage: View {
  @Environment(SettingsModel.self) private var model

  private let ds = ServerSettings()

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        repositories
        SourceControlDiscoverySections()
        textGeneration
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  private func item(_ id: String) -> SettingsSearchItem { SettingsRegistry.items.first { $0.id == id }! }

  private func menu<T: Hashable>(_ selection: Binding<T>, _ options: [(T, String)]) -> some View {
    Picker("", selection: selection) {
      ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
    }
    .labelsHidden().pickerStyle(.menu).fixedSize()
  }

  // MARK: Repositories

  private var repositories: some View {
    let server = model.server
    let projectScope = model.scope.isProject
    let method = server.pullRequestMergeMethod
    return Section("Repositories") {
      SettingToggleRow(
        id: "automatic-pull", title: item("automatic-pull").title,
        help: projectScope
          ? "Keeps this project's default branch current when the checkout has no local changes or commits."
          : "Keeps the default branch current when the checkout has no local changes or commits. Projects can override it.",
        keys: ["defaultAutoPull"], isDefault: server.defaultAutoPull == ds.defaultAutoPull, reset: { model.edit(ServerSettingsPatch(defaultAutoPull: ds.defaultAutoPull)) },
        isOn: Binding(get: { server.defaultAutoPull }, set: { model.edit(ServerSettingsPatch(defaultAutoPull: $0)) }))
      SettingToggleRow(
        id: "remove-agent-credits-on-merge", title: item("remove-agent-credits-on-merge").title,
        help:
          "Remove recognized agent credit lines from GitHub merge and squash messages, keeping human co-authors. Includes auto-merge. Excludes merge queues, stack merges, and existing commits.",
        keys: ["removeAgentCreditsOnMerge"], isDefault: server.removeAgentCreditsOnMerge == ds.removeAgentCreditsOnMerge,
        reset: { model.edit(ServerSettingsPatch(removeAgentCreditsOnMerge: ds.removeAgentCreditsOnMerge)) },
        isOn: Binding(get: { server.removeAgentCreditsOnMerge }, set: { model.edit(ServerSettingsPatch(removeAgentCreditsOnMerge: $0)) }))
      SettingRow(
        id: "pull-request-merge-method", title: item("pull-request-merge-method").title,
        help: projectScope
          ? "Pull requests in this project start with this method."
          : "Pull requests start with this method. Last selected reuses whatever you chose most recently on this device.",
        keys: ["pullRequestMergeMethod"], isDefault: method == nil, reset: { model.edit(ServerSettingsPatch(pullRequestMergeMethod: .some(nil))) }
      ) {
        menu(
          Binding(get: { method?.rawValue ?? "last" }, set: { model.edit(ServerSettingsPatch(pullRequestMergeMethod: .some($0 == "last" ? nil : PullRequestMergeMethod(rawValue: $0)))) }),
          [("last", "Last selected"), ("merge", "Merge"), ("squash", "Squash and merge"), ("rebase", "Rebase and merge")])
      }
    }
  }

  // MARK: Text generation

  private var textGeneration: some View {
    let server = model.server
    let style = server.sourceControlWritingStyle
    let defaults = ds.sourceControlWritingStyle
    let targets = model.targets
    func differs(_ field: (ServerSettingsSourceControlWritingStyle) -> AnyHashable) -> Bool {
      guard let first = targets.first else { return false }
      return targets.contains { field($0.settings.sourceControlWritingStyle) != field(first.settings.sourceControlWritingStyle) }
    }
    let modeMixed = differs { $0.mode }
    let instructionsMixed = differs { $0.customInstructions }
    let templatesMixed = differs { $0.followChangeRequestTemplates }
    let keys = ["sourceControlWritingStyle"]
    let modes: [(ServerSettingsProjectSettingsOverridesValueSourceControlWritingStyleMode, String, String)] = [
      (.repo_conventions, "Repository conventions", "In each project, matches recent change descriptions and change request titles."),
      (.conventional_commits, "Conventional Commits", "Use Conventional Commit prefixes and keep change request text concise."),
      (.custom, "Custom instructions", "Use your instructions for change descriptions and change requests in every project."),
    ]
    return Section("Text generation") {
      BranchNamingRows()
      SettingRow(
        id: "source-control-writing-style", title: item("source-control-writing-style").title,
        help: modes.first { $0.0 == style.mode }?.2, keys: keys,
        isDefault: !modeMixed && !instructionsMixed && style.mode == defaults.mode && style.customInstructions == defaults.customInstructions,
        reset: { model.edit(ServerSettingsPatch(sourceControlWritingStyle: ServerSettingsPatchSourceControlWritingStyle(mode: defaults.mode, customInstructions: defaults.customInstructions))) }
      ) {
        Picker(
          "", selection: Binding(
            get: { modeMixed ? nil : style.mode },
            set: { if let mode = $0 { model.edit(ServerSettingsPatch(sourceControlWritingStyle: ServerSettingsPatchSourceControlWritingStyle(mode: mode))) } })
        ) {
          if modeMixed { Text("Mixed").tag(ServerSettingsProjectSettingsOverridesValueSourceControlWritingStyleMode?.none) }
          ForEach(modes.indices, id: \.self) { Text(modes[$0].1).tag(Optional(modes[$0].0)) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
      }
      if !modeMixed, style.mode == .custom {
        InstructionsEditor(
          value: instructionsMixed ? "" : style.customInstructions,
          placeholder: instructionsMixed ? "Mixed. Enter instructions to apply to all selected targets." : "Keep titles concise. Use short bullet points in descriptions.",
          label: "Custom source control writing instructions"
        ) { model.edit(ServerSettingsPatch(sourceControlWritingStyle: ServerSettingsPatchSourceControlWritingStyle(customInstructions: $0))) }
      }
      SettingToggleRow(
        id: "follow-change-request-templates", title: item("follow-change-request-templates").title,
        help: "Use the repository's template for change request descriptions when available.", keys: keys,
        isDefault: !templatesMixed && style.followChangeRequestTemplates == defaults.followChangeRequestTemplates,
        reset: { model.edit(ServerSettingsPatch(sourceControlWritingStyle: ServerSettingsPatchSourceControlWritingStyle(followChangeRequestTemplates: defaults.followChangeRequestTemplates))) },
        isOn: Binding(
          get: { !templatesMixed && style.followChangeRequestTemplates },
          set: { model.edit(ServerSettingsPatch(sourceControlWritingStyle: ServerSettingsPatchSourceControlWritingStyle(followChangeRequestTemplates: $0))) }))
      writerModel
    }
  }

  /// A separate model for source control text; off falls back to the environment's text generation model.
  private var writerModel: some View {
    let server = model.server
    let selection = server.sourceControlWriterModelSelection
    let base = server.textGenerationModelSelection
    let textProviders = model.providers.filter { $0.supportsTextGeneration != false }
    let canEnable = textProviders.contains { $0.instanceId == base.instanceId && $0.enabled && $0.installed }
    return SettingRow(
      id: "source-control-writer-model", title: item("source-control-writer-model").title,
      help: "Model for source control text and branch or bookmark names. Off uses the environment's text generation model.",
      keys: ["sourceControlWriterModelSelection"], isDefault: selection == nil, reset: { model.edit(ServerSettingsPatch(sourceControlWriterModelSelection: .some(nil))) }
    ) {
      if model.targets.isEmpty {
        Text("Connect an environment to choose its source control writer model.").foregroundStyle(.secondary)
      } else {
        HStack(spacing: 10) {
          if let selection {
            if canEnable {
              ModelMenu(
                providers: model.providers, instanceId: selection.instanceId.rawValue, model: selection.model,
                placeholder: model.isMixed(["sourceControlWriterModelSelection"]) ? "Mixed" : "Choose a model", textGeneration: true
              ) { instanceId, slug in
                if let reason = modelUnavailableReason(instanceId, slug) {
                  model.report("Source control writer model not saved. \(reason)")
                } else {
                  model.edit(ServerSettingsPatch(sourceControlWriterModelSelection: .some(ModelSelection(instanceId: instanceId, model: slug, options: []))))
                }
              }
            } else {
              Text("No text generation providers available.").foregroundStyle(.secondary)
            }
          }
          Toggle(
            "Use a separate source control writer model",
            isOn: Binding(
              get: { selection != nil },
              set: {
                model.edit(
                  ServerSettingsPatch(sourceControlWriterModelSelection: .some($0 ? ModelSelection(instanceId: base.instanceId, model: base.model, options: []) : nil)))
              })
          )
          .labelsHidden().toggleStyle(.switch).disabled(selection == nil && !canEnable)
        }
      }
    }
  }

  /// A model must exist, be enabled and be listed on every selected environment before it is saved for all of them.
  private func modelUnavailableReason(_ instanceId: ProviderInstanceId, _ slug: String) -> String? {
    for target in model.targets {
      let providers = model.runtime.serverConfigs[target.environmentId]?.config.providers ?? []
      guard let provider = providers.first(where: { $0.instanceId == instanceId }), provider.enabled, provider.installed,
        provider.models.contains(where: { $0.slug == slug })
      else { return "This model is unavailable on \(target.label). Select that environment to choose its model separately." }
    }
    return nil
  }
}

/// Worktree branch naming: the mode, then its prefix or instructions.
private struct BranchNamingRows: View {
  @Environment(SettingsModel.self) private var model
  private let ds = ServerSettings()

  var body: some View {
    let server = model.server
    let first = model.targets.first?.settings
    let modeMixed = model.targets.contains { $0.settings.branchNamingMode != first?.branchNamingMode }
    let prefixMixed = model.targets.contains { $0.settings.branchNamePrefix != first?.branchNamePrefix }
    let instructionsMixed = model.targets.contains { $0.settings.branchNameInstructions != first?.branchNameInstructions }
    let mode = server.branchNamingMode
    SettingRow(
      id: "worktree-branch-naming", title: "Worktree branch naming", help: "Choose how new worktree branches are named from your first message.",
      keys: ["branchNamingMode"], isDefault: !modeMixed && mode == ds.branchNamingMode, reset: { model.edit(ServerSettingsPatch(branchNamingMode: ds.branchNamingMode)) },
      status: !modeMixed && mode == .semantic ? "The model chooses a prefix that describes the work, such as feat/add-search, fix/login-timeout, or refactor/auth." : nil
    ) {
      Picker(
        "", selection: Binding(get: { modeMixed ? nil : mode }, set: { if let value = $0 { model.edit(ServerSettingsPatch(branchNamingMode: value)) } })
      ) {
        if modeMixed { Text("Mixed").tag(ServerSettingsProjectSettingsOverridesValueBranchNamingMode?.none) }
        Text("Static prefix").tag(Optional(ServerSettingsProjectSettingsOverridesValueBranchNamingMode.static))
        Text("Semantic prefix").tag(Optional(ServerSettingsProjectSettingsOverridesValueBranchNamingMode.semantic))
        Text("Custom instructions").tag(Optional(ServerSettingsProjectSettingsOverridesValueBranchNamingMode.custom))
      }
      .labelsHidden().pickerStyle(.menu).fixedSize()
    }
    if !modeMixed, mode == .static {
      SettingRow(
        id: "branch-name-prefix", title: "Branch prefix", help: "For example, t3 or t3/ produces t3/add-search. Leave empty for no prefix.", keys: ["branchNamePrefix"],
        isDefault: !prefixMixed && server.branchNamePrefix == ds.branchNamePrefix, reset: { model.edit(ServerSettingsPatch(branchNamePrefix: ds.branchNamePrefix)) }
      ) {
        CommitTextField(value: prefixMixed ? "" : server.branchNamePrefix, placeholder: prefixMixed ? "Mixed" : "No prefix") {
          model.edit(ServerSettingsPatch(branchNamePrefix: $0.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        .frame(width: 180)
      }
    }
    if !modeMixed, mode == .custom {
      SettingRow(
        id: "branch-name-instructions", title: "Branch naming instructions",
        help: "Appended to the naming prompt. The model returns the complete branch name; no prefix or suffix is added.", keys: ["branchNameInstructions"],
        isDefault: !instructionsMixed && server.branchNameInstructions == ds.branchNameInstructions, reset: { model.edit(ServerSettingsPatch(branchNameInstructions: ds.branchNameInstructions)) }
      ) { EmptyView() }
      InstructionsEditor(
        value: instructionsMixed ? "" : server.branchNameInstructions,
        placeholder: instructionsMixed ? "Mixed. Enter instructions to apply to all selected targets." : "Use julius/ followed by the issue ID and a short description.",
        label: "Branch naming instructions"
      ) { model.edit(ServerSettingsPatch(branchNameInstructions: $0)) }
    }
  }
}

/// A multi-line field that saves when it loses focus, and only when the text changed.
private struct InstructionsEditor: View {
  let value: String
  let placeholder: String
  let label: String
  let commit: (String) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextEditor(text: $draft)
      .font(.body).focused($focused).frame(minHeight: 84)
      .scrollContentBackground(.hidden).padding(6)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      .overlay(alignment: .topLeading) {
        if draft.isEmpty { Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false) }
      }
      .accessibilityLabel(label)
      .onAppear { draft = value }
      .onChange(of: value) { if !focused { draft = value } }
      .onChange(of: focused) {
        guard !focused else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != value { commit(text) }
        draft = text
      }
  }
}
