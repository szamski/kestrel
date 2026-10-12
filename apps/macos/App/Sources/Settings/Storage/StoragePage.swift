import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Storage: where worktrees live and when old ones, browser artifacts and rotated logs are cleaned up.
/// An environment writes its rules to `storageCleanup`; a project can inherit them, turn cleanup off, or carry its own
/// rules in its `worktreeCleanup` override.
struct StoragePage: View {
  @Environment(SettingsModel.self) private var model

  private let ds = ServerSettings()
  private var projectScope: Bool { model.scope.isProject }

  /// The cleanup rules a target effectively uses (`resolveWorktreeCleanup`): its project policy, else the environment's.
  private func rules(_ settings: ServerSettings) -> ServerSettingsStorageCleanup {
    var rules = settings.storageCleanup
    switch settings.worktreeCleanup {
    case .custom(let custom)?:
      rules.worktreeAfterDays = custom.rules.worktreeAfterDays
      rules.worktreeOnMerge = custom.rules.worktreeOnMerge
      rules.worktreeOnDelete = custom.rules.worktreeOnDelete
      rules.worktreeUnchanged = custom.rules.worktreeUnchanged
    case .off?:
      (rules.worktreeAfterDays, rules.worktreeOnMerge, rules.worktreeOnDelete, rules.worktreeUnchanged) = (nil, false, false, false)
    default: break
    }
    return rules
  }

  private enum Mode: String { case inherit, off, custom }

  private func mode(_ target: SettingsTarget) -> Mode {
    guard target.overridden.contains("worktreeCleanup") else { return .inherit }
    switch target.settings.worktreeCleanup {
    case .off?: return .off
    case .custom?: return .custom
    default: return .inherit
    }
  }

  var body: some View {
    let connected = model.environments.filter { $0.connected && model.scope.environmentIds.contains($0.environmentId) }
    if projectScope, connected.contains(where: { $0.capabilities?.projectWorktreeCleanup != true }) {
      ContentUnavailableView("Update the environments", systemImage: "internaldrive", description: Text("Update the selected machines to configure project worktree cleanup."))
    } else if connected.contains(where: { $0.capabilities?.storageCleanup != true }) {
      ContentUnavailableView(
        "Storage cleanup is not available", systemImage: "internaldrive",
        description: Text("Update the selected environments to use storage cleanup, or choose a machine that supports it."))
    } else {
      ScrollViewReader { proxy in
        Form {
          worktrees(supportsDirectory: connected.allSatisfy { $0.capabilities?.worktreesDirectory == true })
          if !projectScope { artifacts }
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
  }

  // MARK: Worktrees

  @ViewBuilder private func worktrees(supportsDirectory: Bool) -> some View {
    let targets = model.targets
    let modes = Set(targets.map(mode))
    let mixedModes = modes.count > 1
    let current = modes.first ?? .inherit
    let effective = rules(model.server)
    Section("Worktrees") {
      if !projectScope, supportsDirectory {
        let mixed = model.isMixed(["worktreesDirectory"])
        SettingRow(
          id: "storage-worktrees-location", title: "Worktree location",
          help: "Folder where new worktrees are created, on any drive, such as ~/worktrees. Existing worktrees stay where they are. Leave empty to use the T3 home folder.",
          keys: ["worktreesDirectory"], isDefault: !mixed && model.server.worktreesDirectory == "",
          reset: { model.edit(ServerSettingsPatch(worktreesDirectory: "")) }
        ) {
          CommitTextField(value: mixed ? "" : model.server.worktreesDirectory, placeholder: mixed ? "Mixed" : "Default") {
            model.edit(ServerSettingsPatch(worktreesDirectory: $0.trimmingCharacters(in: .whitespacesAndNewlines)))
          }
          .frame(width: 240)
        }
      }
      if projectScope {
        SettingRow(
          id: "storage-worktrees", title: "Automatic worktree cleanup",
          help: mixedModes
            ? nil
            : current == .off
              ? "Keep this project's worktrees until you delete them manually."
              : current == .custom ? "Use these rules for this project." : "Use each machine's worktree cleanup settings.",
          keys: ["worktreeCleanup"], isDefault: true
        ) {
          Picker("", selection: Binding(get: { mixedModes ? nil : current }, set: { if let value = $0 { setMode(value, effective) } })) {
            if mixedModes { Text("Mixed").tag(Mode?.none) }
            Text("Inherit").tag(Mode?.some(.inherit))
            Text("Off").tag(Mode?.some(.off))
            Text("Custom").tag(Mode?.some(.custom))
          }
          .labelsHidden().pickerStyle(.menu).fixedSize()
        }
      }
      if !projectScope || (!mixedModes && current == .custom) {
        let keys = [projectScope ? "worktreeCleanup" : "storageCleanup"]
        rule(
          "storage-worktree-on-delete", "Delete worktrees with deleted threads",
          "Remove unused worktrees when active or archived threads are deleted. Worktrees with local changes are kept.", keys,
          value: effective.worktreeOnDelete, default: ds.storageCleanup.worktreeOnDelete
        ) { change(effective, $0) { $0.worktreeOnDelete = $1 } }
        SettingRow(
          id: "storage-worktree-after-days", title: "Delete inactive worktrees",
          help: "Remove worktrees after their threads have been inactive for this many days. Branches and thread history are kept.", keys: keys,
          isDefault: effective.worktreeAfterDays == ds.storageCleanup.worktreeAfterDays,
          reset: { change(effective, ds.storageCleanup.worktreeAfterDays) { $0.worktreeAfterDays = $1 } }
        ) {
          Retention(label: "Delete inactive worktrees", days: effective.worktreeAfterDays) { change(effective, $0) { $0.worktreeAfterDays = $1 } }
        }
        rule(
          "storage-worktree-on-merge", "Delete merged worktrees",
          "Remove worktrees whose pull request is merged and whose commits are included in the default branch.", keys,
          value: effective.worktreeOnMerge, default: ds.storageCleanup.worktreeOnMerge
        ) { change(effective, $0) { $0.worktreeOnMerge = $1 } }
        rule(
          "storage-worktree-unchanged", "Delete unchanged worktrees", "Remove worktrees with no commits beyond the default branch.", keys,
          value: effective.worktreeUnchanged, default: ds.storageCleanup.worktreeUnchanged
        ) { change(effective, $0) { $0.worktreeUnchanged = $1 } }
      }
    }
  }

  private func rule(
    _ id: String, _ title: String, _ help: String, _ keys: [String], value: Bool, default def: Bool, set: @escaping (Bool) -> Void
  ) -> some View {
    SettingToggleRow(id: id, title: title, help: help, keys: keys, isDefault: value == def, reset: { set(def) }, isOn: Binding(get: { value }, set: set))
  }

  // MARK: Artifacts and logs

  private var artifacts: some View {
    let cleanup = model.server.storageCleanup
    return Section("Artifacts and logs") {
      SettingRow(
        id: "storage-artifacts", title: "Delete old browser artifacts",
        help: "Delete saved browser captures after this many days. Older capture links will no longer open.", keys: ["storageCleanup"],
        isDefault: cleanup.browserArtifactsAfterDays == ds.storageCleanup.browserArtifactsAfterDays,
        reset: { model.edit(ServerSettingsPatch(storageCleanup: ServerSettingsPatchStorageCleanup(browserArtifactsAfterDays: .some(nil)))) }
      ) {
        Retention(label: "Delete old browser artifacts", days: cleanup.browserArtifactsAfterDays) {
          model.edit(ServerSettingsPatch(storageCleanup: ServerSettingsPatchStorageCleanup(browserArtifactsAfterDays: .some($0))))
        }
      }
      SettingRow(
        id: "storage-logs", title: "Delete old rotated logs", help: "Delete inactive rotated log files after this many days. Current logs are kept.",
        keys: ["storageCleanup"], isDefault: cleanup.logsAfterDays == ds.storageCleanup.logsAfterDays,
        reset: { model.edit(ServerSettingsPatch(storageCleanup: ServerSettingsPatchStorageCleanup(logsAfterDays: .some(nil)))) }
      ) {
        Retention(label: "Delete old rotated logs", days: cleanup.logsAfterDays) {
          model.edit(ServerSettingsPatch(storageCleanup: ServerSettingsPatchStorageCleanup(logsAfterDays: .some($0))))
        }
      }
    }
  }

  // MARK: Writes

  /// One rule edit. An environment writes the single field; a project writes its complete rule set, because a project
  /// override has no partial form (the planner cannot merge into rules the project does not have yet).
  private func change<Value>(_ rules: ServerSettingsStorageCleanup, _ value: Value, _ apply: (inout ServerSettingsStorageCleanup, Value) -> Void) {
    var next = rules
    apply(&next, value)
    if projectScope {
      model.edit(ServerSettingsPatch(worktreeCleanup: .some(custom(next))))
    } else {
      model.edit(
        ServerSettingsPatch(
          storageCleanup: ServerSettingsPatchStorageCleanup(
            worktreeAfterDays: .some(next.worktreeAfterDays), worktreeOnMerge: next.worktreeOnMerge, worktreeOnDelete: next.worktreeOnDelete, worktreeUnchanged: next.worktreeUnchanged)))
    }
  }

  private func custom(_ rules: ServerSettingsStorageCleanup) -> WorktreeCleanup2 {
    .custom(
      WorktreeCleanup2Custom(
        rules: WorktreeCleanup2CustomRules(
          worktreeAfterDays: .some(rules.worktreeAfterDays), worktreeOnMerge: rules.worktreeOnMerge, worktreeOnDelete: rules.worktreeOnDelete, worktreeUnchanged: rules.worktreeUnchanged)))
  }

  private func setMode(_ mode: Mode, _ effective: ServerSettingsStorageCleanup) {
    switch mode {
    case .inherit: model.clearOverrides(["worktreeCleanup"])
    case .off: model.edit(ServerSettingsPatch(worktreeCleanup: .some(WorktreeCleanup2.off)))
    case .custom: model.edit(ServerSettingsPatch(worktreeCleanup: .some(custom(model.targets.first.map { rules($0.settings) } ?? effective))))
    }
  }
}

/// A day count that can be turned off: switch plus a field that saves a whole number from 1 to 3650 when editing ends.
private struct Retention: View {
  let label: String
  let days: Int?
  let commit: (Int?) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 10) {
      if let days {
        HStack(spacing: 4) {
          TextField("", text: $draft).labelsHidden().multilineTextAlignment(.trailing).frame(width: 56).focused($focused).accessibilityLabel("\(label) in days")
            .onAppear { draft = String(days) }
            .onChange(of: days) { if !focused { draft = String(days) } }
            .onSubmit { save(days) }
            .onChange(of: focused) { if !focused { save(days) } }
          Text("days").foregroundStyle(.secondary)
        }
      } else {
        Text("Off").foregroundStyle(.secondary)
      }
      Toggle(label, isOn: Binding(get: { days != nil }, set: { commit($0 ? 8 : nil) })).labelsHidden().toggleStyle(.switch)
    }
  }

  private func save(_ current: Int) {
    if let value = Int(draft.trimmingCharacters(in: .whitespaces)) {
      let clamped = min(3650, max(1, value))
      draft = String(clamped)
      if clamped != current { commit(clamped) }
    } else {
      draft = String(current)
    }
  }
}
