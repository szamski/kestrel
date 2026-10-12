import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › General. Same settings, scopes and wording as the web page; rows that edit a server follow the scope target,
/// device preferences are written to `ClientSettingsStore` whatever the target is.
struct GeneralPage: View {
  @Environment(SettingsModel.self) private var model
  @Environment(AppModel.self) private var app
  @State private var tokenWarning = false
  @State private var backgroundSheet = false
  @State private var legacyExpanded = false
  @AppStorage("settings.lastGroupingMode") private var lastGroupingMode = "repository"

  private let dc = ClientSettingsSchema()
  private let ds = ServerSettings()

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        newThreads
        organization
        behavior
        projectsAndThreads
        confirmations
        textGeneration
        about
        shortcuts
        legacy
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        if id == "legacy-plan-mode" || id == "legacy-context-window-indicator" || id == "legacy-sidebar" { legacyExpanded = true }
        // Let a page switch and the disclosure settle before scrolling.
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
    .sheet(isPresented: $backgroundSheet) { BackgroundActivitySheet() }
    .confirmationDialog("Token by token is a worse experience", isPresented: $tokenWarning) {
      Button("Use paragraphs") { setStreaming(.paragraph) }
      Button("Use token by token", role: .destructive) { setStreaming(.token) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Token streaming repaints the message on every delta. It is slower, harder to read, and costs more CPU on every connected device. This mode stays only for backwards compatibility. Use paragraph streaming instead.")
    }
  }

  // MARK: Helpers

  private func item(_ id: String) -> SettingsSearchItem { SettingsRegistry.items.first { $0.id == id }! }

  private func client<T: Equatable>(_ keyPath: WritableKeyPath<ClientSettingsSchema, T>) -> Binding<T> {
    Binding(get: { model.client[keyPath: keyPath] }, set: { value in model.updateClient { $0[keyPath: keyPath] = value } })
  }

  private func clientToggle(_ id: String, _ help: String?, _ keyPath: WritableKeyPath<ClientSettingsSchema, Bool>) -> some View {
    SettingToggleRow(
      id: id, title: item(id).title, help: help, isDefault: model.client[keyPath: keyPath] == dc[keyPath: keyPath],
      reset: { model.updateClient { $0[keyPath: keyPath] = dc[keyPath: keyPath] } }, isOn: client(keyPath))
  }

  private func clientMenu<T: Hashable>(
    _ id: String, _ help: String?, _ keyPath: WritableKeyPath<ClientSettingsSchema, T>, _ options: [(T, String)], title: String? = nil
  ) -> some View {
    SettingRow(
      id: id, title: title ?? item(id).title, help: help, isDefault: model.client[keyPath: keyPath] == dc[keyPath: keyPath],
      reset: { model.updateClient { $0[keyPath: keyPath] = dc[keyPath: keyPath] } }
    ) { menu(client(keyPath), options) }
  }

  private func menu<T: Hashable>(_ selection: Binding<T>, _ options: [(T, String)]) -> some View {
    Picker("", selection: selection) {
      ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
    }
    .labelsHidden().pickerStyle(.menu).fixedSize()
  }

  /// A server row: the value shown is the representative target's, an edit is written to every selected target.
  private func serverToggle(
    _ id: String, _ help: String?, keys: [String], value: Bool, default def: Bool, status: String? = nil, make: @escaping (Bool) -> ServerSettingsPatch
  ) -> some View {
    SettingToggleRow(
      id: id, title: item(id).title, help: help, keys: keys, isDefault: value == def, reset: { model.edit(make(def)) }, status: status,
      isOn: Binding(get: { value }, set: { model.edit(make($0)) }))
  }

  private func serverMenu<T: Hashable>(
    _ id: String, _ help: String?, keys: [String], value: T, default def: T, _ options: [(T, String)], title: String? = nil, status: String? = nil,
    make: @escaping (T) -> ServerSettingsPatch
  ) -> some View {
    SettingRow(
      id: id, title: title ?? item(id).title, help: help, keys: keys, isDefault: value == def, reset: { model.edit(make(def)) }, status: status
    ) { menu(Binding(get: { value }, set: { model.edit(make($0)) }), options) }
  }

  // MARK: New threads

  private var newThreads: some View {
    let server = model.server
    let selection = server.defaultModelSelection
    let projectScope = model.scope.isProject
    return Section("New threads") {
      SettingRow(
        id: "default-model", title: "Model", help: projectScope ? "Model for new threads in this project." : "Default model for new threads. Projects can override it.",
        keys: ["defaultModelSelection"], isDefault: selection == nil, reset: { model.edit(ServerSettingsPatch(defaultModelSelection: .some(nil))) },
        status: selection == nil && !model.isMixed(["defaultModelSelection"]) ? "Automatic" : nil
      ) {
        ModelMenu(providers: model.providers, instanceId: selection?.instanceId.rawValue, model: selection?.model, placeholder: "Automatic", textGeneration: false) {
          setDefaultModel($0, $1)
        }
      }
      serverMenu(
        "default-permissions", projectScope ? "Permissions for new threads in this project." : "Default permissions for new threads. Projects can override them.",
        keys: ["defaultRuntimeMode"], value: server.defaultRuntimeMode, default: ds.defaultRuntimeMode,
        [(.approvalRequired, "Supervised"), (.autoAcceptEdits, "Auto-accept edits"), (.auto, "Auto"), (.fullAccess, "Full access")]
      ) { ServerSettingsPatch(defaultRuntimeMode: $0) }
      SettingRow(
        id: "new-threads", title: "Workspace", help: projectScope ? "Where new threads in this project start." : "Where new threads start. Projects and their t3.json can override it.",
        keys: ["defaultThreadEnvMode"], isDefault: server.defaultThreadEnvMode == nil, reset: { model.edit(ServerSettingsPatch(defaultThreadEnvMode: .some(nil))) }
      ) {
        menu(
          Binding(get: { server.defaultThreadEnvMode ?? .local }, set: { model.edit(ServerSettingsPatch(defaultThreadEnvMode: .some($0))) }),
          [(.local, "Current checkout"), (.worktree, "New worktree")])
      }
      SettingRow(
        id: "worktree-submodules", title: item("worktree-submodules").title,
        help: projectScope ? "How new worktrees in this project populate git submodules." : "How new worktrees populate git submodules. Projects and their t3.json can override it.",
        keys: ["worktreeSubmodules"], isDefault: server.worktreeSubmodules == nil, reset: { model.edit(ServerSettingsPatch(worktreeSubmodules: .some(nil))) }
      ) {
        menu(
          Binding(get: { server.worktreeSubmodules ?? .recursive }, set: { model.edit(ServerSettingsPatch(worktreeSubmodules: .some($0))) }),
          [(.recursive, "Recursive"), (.topLevel, "Top level only"), (.noneValue, "Skip")])
      }
    }
  }

  /// A model must exist, be enabled and be listed on every selected environment before it is saved for all of them.
  private func modelUnavailableReason(_ instanceId: ProviderInstanceId, _ slug: String) -> String? {
    for target in model.targets {
      let providers = model.runtime.serverConfigs[target.environmentId]?.config.providers ?? []
      guard let provider = providers.first(where: { $0.instanceId == instanceId }), provider.enabled, provider.installed,
        provider.models.contains(where: { $0.slug == slug })
      else {
        return "This model is unavailable on \(target.label). Select that environment to choose its model separately."
      }
    }
    return nil
  }

  private func setDefaultModel(_ instanceId: ProviderInstanceId, _ slug: String) {
    if let reason = modelUnavailableReason(instanceId, slug) {
      model.report("Default model not saved. \(reason)")
      return
    }
    model.edit(ServerSettingsPatch(defaultModelSelection: .some(ModelSelection(instanceId: instanceId, model: slug, options: []))))
  }

  // MARK: Organization

  private var organization: some View {
    let server = model.server
    let grouping = model.client.sidebarProjectGroupingMode
    let days = server.sidebarAutoSettleAfterDays
    return Section("Organization") {
      SettingToggleRow(
        id: "project-grouping", title: item("project-grouping").title, help: "Combine matching repositories across environments.",
        isDefault: grouping == dc.sidebarProjectGroupingMode, reset: { model.updateClient { $0.sidebarProjectGroupingMode = dc.sidebarProjectGroupingMode } },
        isOn: Binding(
          get: { grouping != .separate },
          set: { enabled in
            if !enabled, grouping != .separate { lastGroupingMode = grouping.rawValue }
            model.updateClient {
              $0.sidebarProjectGroupingMode = enabled ? ClientSettingsSchemaSidebarProjectGroupingMode(rawValue: lastGroupingMode) : .separate
            }
          }))
      if model.supportsAutoSettlement {
        serverToggle(
          "auto-settle-merged-threads", "Settle a thread when its pull request merges. Closed pull requests still settle automatically.",
          keys: ["sidebarAutoSettleOnMerge"], value: server.sidebarAutoSettleOnMerge, default: ds.sidebarAutoSettleOnMerge
        ) { ServerSettingsPatch(sidebarAutoSettleOnMerge: $0) }
        serverToggle(
          "auto-settle-inactive-threads", "Sidebar threads with no activity for this long settle automatically.", keys: ["sidebarAutoSettleAfterDays"],
          value: days != nil, default: ds.sidebarAutoSettleAfterDays != nil
        ) { ServerSettingsPatch(sidebarAutoSettleAfterDays: .some($0 ? (ds.sidebarAutoSettleAfterDays ?? 3) : nil)) }
        if let days {
          SettingRow(
            id: "days-before-auto-settle", title: item("days-before-auto-settle").title, help: "Any new activity un-settles a thread automatically.",
            keys: ["sidebarAutoSettleAfterDays"], isDefault: days == ds.sidebarAutoSettleAfterDays,
            reset: { model.edit(ServerSettingsPatch(sidebarAutoSettleAfterDays: .some(ds.sidebarAutoSettleAfterDays))) }
          ) {
            AutoSettleDays(days: Int(days)) { model.edit(ServerSettingsPatch(sidebarAutoSettleAfterDays: .some(Double($0)))) }
          }
        }
      }
    }
  }

  // MARK: Behavior

  private func setStreaming(_ mode: ServerSettingsResponseStreamingMode) { model.edit(ServerSettingsPatch(responseStreamingMode: mode)) }

  private var behavior: some View {
    let server = model.server
    let client = model.client
    let mod = "\u{2318}"
    let streaming = server.responseStreamingMode
    let streamingHelp: [ServerSettingsResponseStreamingMode: String] = [
      .turn: "Text appears once the agent finishes its turn.", .paragraph: "Each paragraph or code block appears as soon as it is complete.",
      .token: "Every token repaints the answer as it arrives. Slower and harder to read. Thinking traces still arrive a paragraph at a time.",
    ]
    return Section("Behavior") {
      clientMenu(
        "thread-notifications",
        "System alerts when a thread finishes, fails, or needs input or approval. Applies to this device while T3 Code is open.", \.notificationMode,
        [(.off, "Off"), (.notifications, "Notifications only"), (.sound, "Sound only"), (.notificationsAndSound, "Notifications with sound")])
      NotificationPermissionHint(mode: client.notificationMode)
      clientToggle("in-app-notifications", "Show a toast when another thread finishes, fails, or needs input or approval while this app has focus.", \.inAppNotificationsEnabled)
      clientMenu("time-format", "System default follows your OS clock preference.", \.timestampFormat, [(.locale, "System default"), (.v12Hour, "12-hour"), (.v24Hour, "24-hour")])
      SettingRow(
        id: "response-streaming", title: item("response-streaming").title, help: model.isMixed(["responseStreamingMode"]) ? "The selected targets use different streaming modes." : streamingHelp[streaming],
        keys: ["responseStreamingMode"], isDefault: streaming == ds.responseStreamingMode, reset: { setStreaming(ds.responseStreamingMode) }
      ) {
        menu(
          Binding(get: { streaming }, set: { $0 == .token ? (tokenWarning = true) : setStreaming($0) }),
          [(.turn, "Wait for the full response"), (.paragraph, "Show finished paragraphs"), (.token, "Token by token (legacy)")])
      }
      clientToggle("hide-whitespace-changes", "Set whether the diff panel ignores whitespace-only edits by default.", \.diffIgnoreWhitespace)
      SettingRow(
        id: "default-diff-file-state", title: item("default-diff-file-state").title,
        help: "Start with files expanded or collapsed when opening diffs or a pull request's Code tab.", isDefault: client.diffFilesCollapsed == dc.diffFilesCollapsed,
        reset: { model.updateClient { $0.diffFilesCollapsed = dc.diffFilesCollapsed } }
      ) { menu(self.client(\.diffFilesCollapsed), [(false, "Expanded"), (true, "Collapsed")]) }
      clientMenu("diff-layout", "Show diffs stacked or side by side. The toggle in the diff toolbar changes this too.", \.diffLayout, [(.stacked, "Stacked"), (.split, "Split")])
      clientToggle("proactive-panels", "Open linked pull requests first. Otherwise, open the working tree diff for changes to at least 3 files or 50 lines.", \.proactivePanelsEnabled)
      clientToggle("skills-in-slash-menu", "Also include skills in the / command menu. Skills always appear when you type $.", \.showSkillsInSlashMenu)
      clientToggle("composer-rich-text", "Show formatted Markdown as you type.", \.composerRichTextEnabled)
      clientToggle(
        "composer-collapse", "Rest the composer of an existing thread into a single line when you scroll the conversation. Focus the composer or start typing to expand it again.",
        \.composerCollapseOnScroll)
      clientMenu(
        "send-shortcut", "Choose when Enter sends a prompt or inserts a new line", \.sendShortcut,
        [(.enter, "Enter"), (.modEnterMultiline, "\(mod) + Enter for multiline prompts"), (.modEnter, "\(mod) + Enter always")])
      clientMenu(
        "follow-up-behavior",
        "Queue follow-ups while the agent runs or steer the current run. "
          + (client.sendShortcut == .modEnterMultiline
            ? "Press \(mod) + Enter for single-line prompts or \(mod) + Shift + Enter for multiline prompts to do the opposite for one message."
            : "Press \(mod)\(client.sendShortcut == .modEnter ? " + Shift" : "") + Enter to do the opposite for one message."),
        \.followUpBehavior, [(.queue, "Queue"), (.steer, "Steer")])
      serverToggle(
        "provider-update-checks", "Check installed provider CLIs for newer available versions.", keys: ["enableProviderUpdateChecks"],
        value: server.enableProviderUpdateChecks, default: ds.enableProviderUpdateChecks
      ) { ServerSettingsPatch(enableProviderUpdateChecks: $0) }
      serverToggle(
        "continue-threads-after-server-update",
        "Automatically resume interrupted threads after an update, crash, or machine restart on the selected environments. Update older servers first.",
        keys: ["continueThreadsAfterServerUpdate"], value: server.continueThreadsAfterServerUpdate, default: ds.continueThreadsAfterServerUpdate,
        status: model.supportsRestartContinuation ? nil : "All selected connected environments must support restart continuation."
      ) { ServerSettingsPatch(continueThreadsAfterServerUpdate: $0) }
        .disabled(!model.supportsRestartContinuation)
      backgroundActivity
    }
  }

  private var backgroundActivity: some View {
    let server = model.server
    let preset = BackgroundActivityPolicy.matchingProfile(server)
    let resolved = BackgroundActivityPolicy.resolved(server)
    let names: [BackgroundActivityPolicy.Profile: String] = [.balanced: "Balanced", .performance: "Performance", .batterySaver: "Battery saver"]
    let descriptions: [BackgroundActivityPolicy.Profile: String] = [
      .balanced: "Pauses probes for idle clients, locked hosts, or low power mode.",
      .performance: "Allows scoped background probes while any subscribed client remains connected.",
      .batterySaver: "Also pauses background probes when the host or client is on battery.",
    ]
    let oneEnvironment = model.scope.environmentIds.count == 1 && model.targets.count == 1
    return SettingRow(
      id: "background-activity", title: item("background-activity").title,
      help: preset == nil ? "Uses custom intervals. Shared policy: \(names[resolved.profile] ?? "Balanced")." : descriptions[resolved.profile],
      keys: ["backgroundActivity"], isDefault: BackgroundActivityPolicy.isDefault(server),
      reset: { model.edit(BackgroundActivityPolicy.profilePatch(.balanced)) }
    ) {
      HStack(spacing: 6) {
        Picker(
          "", selection: Binding<String>(
            get: { preset?.rawValue ?? "advanced" },
            set: { value in
              if value == "advanced" { if oneEnvironment { backgroundSheet = true } } else if let profile = BackgroundActivityPolicy.Profile(rawValue: value) {
                model.edit(BackgroundActivityPolicy.profilePatch(profile))
              }
            })
        ) {
          ForEach(BackgroundActivityPolicy.Profile.allCases, id: \.rawValue) { Text(names[$0] ?? $0.rawValue).tag($0.rawValue) }
          Text(oneEnvironment ? "Advanced" : "Advanced (one environment)").tag("advanced").selectionDisabled(!oneEnvironment)
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        if preset == nil, oneEnvironment {
          Button("Configure", systemImage: "gearshape") { backgroundSheet = true }.labelStyle(.iconOnly).help("Configure background activity")
        }
      }
    }
  }

  // MARK: Projects & threads

  private var projectsAndThreads: some View {
    let server = model.server
    return Section("Projects & threads") {
      serverToggle(
        "start-from-origin", "Creates the worktree from the latest matching branch on origin instead of your local branch.", keys: ["newWorktreesStartFromOrigin"],
        value: server.newWorktreesStartFromOrigin, default: ds.newWorktreesStartFromOrigin
      ) { ServerSettingsPatch(newWorktreesStartFromOrigin: $0) }
      SettingRow(
        id: "add-project-starts-in", title: item("add-project-starts-in").title, help: "Leave empty to use \"~/\" when the Add Project browser opens.",
        keys: ["addProjectBaseDirectory"], isDefault: server.addProjectBaseDirectory == ds.addProjectBaseDirectory,
        reset: { model.edit(ServerSettingsPatch(addProjectBaseDirectory: ds.addProjectBaseDirectory)) }
      ) {
        CommitTextField(value: model.isMixed(["addProjectBaseDirectory"]) ? "" : server.addProjectBaseDirectory, placeholder: model.isMixed(["addProjectBaseDirectory"]) ? "Mixed" : "~/") {
          model.edit(ServerSettingsPatch(addProjectBaseDirectory: $0))
        }
        .frame(width: 260)
      }
    }
  }

  // MARK: Confirmations

  private var confirmations: some View {
    Section("Confirmations") {
      clientToggle("unpin-confirmation", "Ask before unpinning a thread from the pinned section.", \.confirmThreadUnpin)
      clientToggle("archive-confirmation", "Require a second click on the inline archive action before a thread is archived.", \.confirmThreadArchive)
      clientToggle("delete-confirmation", "Ask before deleting a thread and its chat history.", \.confirmThreadDelete)
      clientMenu("quit-confirmation", "Hold mode also quits on two quick presses.", \.confirmQuit, [(.direct, "Direct"), (.hold, "Hold"), (.doubleClick, "Double press")])
    }
  }

  // MARK: Text generation

  private var textGeneration: some View {
    let selection = model.server.textGenerationModelSelection
    let hasProviders = model.providers.contains { $0.enabled && $0.installed && $0.supportsTextGeneration != false }
    return Section("Text generation") {
      SettingRow(
        id: "text-generation-model", title: item("text-generation-model").title,
        help: "Used for thread titles and other generated text on connected devices with this provider. Source control can override it.",
        keys: ["textGenerationModelSelection"], isDefault: selection == ds.textGenerationModelSelection,
        reset: { model.edit(patch(ds.textGenerationModelSelection.instanceId, ds.textGenerationModelSelection.model)) }
      ) {
        if model.targets.isEmpty {
          Text("Connect an environment to choose its text generation model.").foregroundStyle(.secondary)
        } else if !hasProviders {
          Text("No text generation providers available.").foregroundStyle(.secondary)
        } else {
          ModelMenu(
            providers: model.providers, instanceId: selection.instanceId.rawValue, model: selection.model,
            placeholder: model.isMixed(["textGenerationModelSelection"]) ? "Mixed" : "Choose a model", textGeneration: true
          ) { instanceId, slug in
            if let reason = modelUnavailableReason(instanceId, slug) {
              model.report("Text generation model not saved. \(reason)")
            } else {
              model.edit(patch(instanceId, slug))
            }
          }
        }
      }
    }
  }

  private func patch(_ instanceId: ProviderInstanceId, _ slug: String) -> ServerSettingsPatch {
    ServerSettingsPatch(textGenerationModelSelection: ServerSettingsPatchTextGenerationModelSelection(instanceId: instanceId, model: slug, options: []))
  }

  // MARK: About

  private var about: some View {
    let info = Bundle.main
    let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return Section("About") {
      LabeledContent("Version") { Text(build.map { "\(version) (\($0))" } ?? version).monospaced().textSelection(.enabled) }
      LabeledContent("Update track") {
        Picker("", selection: .constant("latest")) { Text("Stable").tag("latest") }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(true)
      }
      LabeledContent("Links") {
        HStack(spacing: 12) {
          Link("T3 Code", destination: URL(string: "https://t3.codes")!)
          Link("Kestrel on GitHub", destination: URL(string: "https://github.com/szamski/kestrel")!)
        }
      }
    }
  }

  private var shortcuts: some View {
    Section {
      SettingRow(id: "diagnostics", title: "Diagnostics", help: model.targets.count == 1 ? "Inspect processes, resource use, and logs on this environment." : "Inspect processes, resource use, and logs on one environment at a time.") {
        Button("View diagnostics") { model.page = .diagnostics }
      }
      SettingRow(id: "welcome-setup", title: "Welcome setup", help: "Connect a computer, check your agents, and import projects.") {
        Button("Run setup") { app.onboarding.present() }
      }
      SettingRow(id: "open-source-licenses", title: "Open source licenses", help: "Notices for dependencies, assets, and optional tools used by T3 Code.") {
        Button("View licenses") { model.page = .licenses }
      }
    }
  }

  // MARK: Legacy

  private var legacy: some View {
    Section {
      DisclosureGroup("Legacy features", isExpanded: $legacyExpanded) {
        clientToggle("legacy-plan-mode", "Restore Build/Plan, /plan, /default, and Shift+Tab. Off uses build mode.", \.planModeEnabled)
        clientToggle("legacy-context-window-indicator", "Shows context window usage as a circular indicator in the composer.", \.contextWindowMeterEnabled)
        clientToggle("legacy-sidebar", "Restore per-project thread trees instead of the default flat sidebar.", \.legacySidebarEnabled)
      }
    }
  }
}

/// The model menu of a settings row: enabled providers, their models, a check on the current one.
struct ModelMenu: View {
  let providers: [ServerConfigProvidersItem]
  let instanceId: String?
  let model: String?
  let placeholder: String
  let textGeneration: Bool
  let onPick: (ProviderInstanceId, String) -> Void

  var body: some View {
    let usable = providers.filter { $0.enabled && $0.installed && (!textGeneration || $0.supportsTextGeneration != false) }
    let current = providers.first { $0.instanceId.rawValue == instanceId }?.models.first { $0.slug == model }
    Menu {
      ForEach(usable, id: \.instanceId) { provider in
        Section(provider.displayName ?? provider.driver.rawValue) {
          ForEach(provider.models, id: \.slug) { entry in
            Button {
              onPick(provider.instanceId, entry.slug)
            } label: {
              if provider.instanceId.rawValue == instanceId, entry.slug == model {
                Label(entry.name, systemImage: "checkmark")
              } else {
                Text(entry.name)
              }
            }
          }
        }
      }
    } label: {
      Text(current?.name ?? model ?? placeholder)
    }
    .fixedSize()
    .disabled(usable.isEmpty)
  }
}

/// Days field: the setting moves only on a whole number in range and snaps back to the saved value when editing ends.
private struct AutoSettleDays: View {
  let days: Int
  let commit: (Int) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $draft)
      .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64).focused($focused)
      .onAppear { draft = String(days) }
      .onChange(of: days) { if !focused { draft = String(days) } }
      .onChange(of: draft) { if let value = Int(draft), (1...90).contains(value), value != days { commit(value) } }
      .onChange(of: focused) { if !focused { draft = String(days) } }
      .accessibilityLabel("Days of inactivity before auto-settle")
  }
}

/// Text field that saves on Return or when it loses focus, so a half-typed path is never written.
struct CommitTextField: View {
  let value: String
  var placeholder = ""
  let commit: (String) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField(placeholder, text: $draft)
      .labelsHidden().textFieldStyle(.roundedBorder).focused($focused).autocorrectionDisabled()
      .onAppear { draft = value }
      .onChange(of: value) { if !focused { draft = value } }
      .onSubmit { if draft != value { commit(draft) } }
      .onChange(of: focused) { if !focused, draft != value { commit(draft) } }
  }
}
