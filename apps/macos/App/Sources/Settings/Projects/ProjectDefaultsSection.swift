import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The new-thread, repository and browser settings a project may override. At a project scope an edit writes that
/// project's override (and the reset arrow drops it); at an environment scope it edits the environment default.
/// Same keys, wording and planner as the General, Source control and Integrations pages.
struct ProjectDefaultsSection: View {
  @Environment(SettingsModel.self) private var model

  private let ds = ServerSettings()

  var body: some View {
    let server = model.server
    let project = model.scope.isProject
    Section("New threads") {
      SettingRow(
        id: "project-default-model", title: "Model", help: project ? "Model for new threads in this project." : "Default model for new threads. Projects can override it.",
        keys: ["defaultModelSelection"], isDefault: server.defaultModelSelection == nil,
        reset: { model.edit(ServerSettingsPatch(defaultModelSelection: .some(nil))) },
        status: server.defaultModelSelection == nil && !model.isMixed(["defaultModelSelection"]) ? "Automatic" : nil
      ) {
        ModelMenu(
          providers: model.providers, instanceId: server.defaultModelSelection?.instanceId.rawValue, model: server.defaultModelSelection?.model,
          placeholder: "Automatic", textGeneration: false
        ) { setModel($0, $1) }
      }
      SettingRow(
        id: "project-default-permissions", title: "Permissions",
        help: project ? "Permissions for new threads in this project." : "Default permissions for new threads. Projects can override them.",
        keys: ["defaultRuntimeMode"], isDefault: server.defaultRuntimeMode == ds.defaultRuntimeMode,
        reset: { model.edit(ServerSettingsPatch(defaultRuntimeMode: ds.defaultRuntimeMode)) }
      ) {
        menu(
          Binding(get: { server.defaultRuntimeMode }, set: { model.edit(ServerSettingsPatch(defaultRuntimeMode: $0)) }),
          [(.approvalRequired, "Supervised"), (.autoAcceptEdits, "Auto-accept edits"), (.auto, "Auto"), (.fullAccess, "Full access")])
      }
      SettingRow(
        id: "project-default-workspace", title: "Workspace", help: project ? "Where new threads in this project start." : "Where new threads start. Projects and their t3.json can override it.",
        keys: ["defaultThreadEnvMode"], isDefault: server.defaultThreadEnvMode == nil,
        reset: { model.edit(ServerSettingsPatch(defaultThreadEnvMode: .some(nil))) }
      ) {
        menu(
          Binding(get: { server.defaultThreadEnvMode ?? .local }, set: { model.edit(ServerSettingsPatch(defaultThreadEnvMode: .some($0))) }),
          [(.local, "Current checkout"), (.worktree, "New worktree")])
      }
      SettingRow(
        id: "project-worktree-submodules", title: "Submodules",
        help: project ? "How new worktrees in this project populate git submodules." : "How new worktrees populate git submodules. Projects and their t3.json can override it.",
        keys: ["worktreeSubmodules"], isDefault: server.worktreeSubmodules == nil,
        reset: { model.edit(ServerSettingsPatch(worktreeSubmodules: .some(nil))) }
      ) {
        menu(
          Binding(get: { server.worktreeSubmodules ?? .recursive }, set: { model.edit(ServerSettingsPatch(worktreeSubmodules: .some($0))) }),
          [(.recursive, "Recursive"), (.topLevel, "Top level only"), (.noneValue, "Skip")])
      }
    }
    Section("Repository") {
      SettingToggleRow(
        id: "project-automatic-pull", title: "Automatically pull",
        help: project
          ? "Keeps this project's default branch current when the checkout has no local changes or commits."
          : "Keeps the default branch current when the checkout has no local changes or commits. Projects can override it.",
        keys: ["defaultAutoPull"], isDefault: server.defaultAutoPull == ds.defaultAutoPull,
        reset: { model.edit(ServerSettingsPatch(defaultAutoPull: ds.defaultAutoPull)) },
        isOn: Binding(get: { server.defaultAutoPull }, set: { model.edit(ServerSettingsPatch(defaultAutoPull: $0)) }))
      SettingRow(
        id: "project-merge-method", title: "Default merge method",
        help: project
          ? "Pull requests in this project start with this method."
          : "Pull requests start with this method. Last selected reuses whatever you chose most recently on this device.",
        keys: ["pullRequestMergeMethod"], isDefault: server.pullRequestMergeMethod == nil,
        reset: { model.edit(ServerSettingsPatch(pullRequestMergeMethod: .some(nil))) }
      ) {
        menu(
          Binding<PullRequestMergeMethod?>(get: { server.pullRequestMergeMethod }, set: { model.edit(ServerSettingsPatch(pullRequestMergeMethod: .some($0))) }),
          [(nil, "Last selected"), (.merge, "Merge"), (.squash, "Squash and merge"), (.rebase, "Rebase and merge")])
      }
    }
    Section("Browser") {
      SettingToggleRow(
        id: "project-agent-browser-access", title: "Agent browser access",
        help: project
          ? "Allow agents in this project to use the shared browser. Applies when the agent session next starts."
          : "Allow agents to use the shared browser. Projects can override it.",
        keys: ["enableAgentBrowserAccess"], isDefault: server.enableAgentBrowserAccess == ds.enableAgentBrowserAccess,
        reset: { model.edit(ServerSettingsPatch(enableAgentBrowserAccess: ds.enableAgentBrowserAccess)) },
        isOn: Binding(get: { server.enableAgentBrowserAccess }, set: { model.edit(ServerSettingsPatch(enableAgentBrowserAccess: $0)) }))
    }
  }

  private func menu<T: Hashable>(_ selection: Binding<T>, _ options: [(T, String)]) -> some View {
    Picker("", selection: selection) { ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) } }
      .labelsHidden().pickerStyle(.menu).fixedSize()
  }

  /// A model must exist, be enabled and be listed on every selected environment before it is saved for all of them.
  private func setModel(_ instanceId: ProviderInstanceId, _ slug: String) {
    for target in model.targets {
      let providers = model.runtime.serverConfigs[target.environmentId]?.config.providers ?? []
      guard let provider = providers.first(where: { $0.instanceId == instanceId }), provider.enabled, provider.installed, provider.models.contains(where: { $0.slug == slug })
      else {
        model.report("Default model not saved. This model is unavailable on \(target.label). Select that environment to choose its model separately.")
        return
      }
    }
    model.edit(ServerSettingsPatch(defaultModelSelection: .some(ModelSelection(instanceId: instanceId, model: slug, options: []))))
  }
}
