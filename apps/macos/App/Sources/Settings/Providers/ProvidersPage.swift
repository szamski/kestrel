import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Providers. Providers are machine state, so the page shows one environment at a time: the scope bar's
/// representative. Instances are configured per environment; model favorites, order and visibility stay on this device.
struct ProvidersPage: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    if let target = model.targets.first {
      ProvidersContent(model: model, environmentId: target.environmentId).id(target.environmentId)
    } else {
      ContentUnavailableView("Connect an environment to set up its providers.", systemImage: "cpu")
    }
  }
}

private struct ProvidersContent: View {
  @Environment(SettingsModel.self) private var model
  @State private var controller: ProvidersController

  init(model: SettingsModel, environmentId: EnvironmentId) {
    _controller = State(initialValue: ProvidersController(model: model, environmentId: environmentId))
  }

  var body: some View {
    @Bindable var controller = controller
    ScrollViewReader { proxy in
      Form {
        instanceList
        if let row = controller.selected {
          ProviderEditor(controller: controller, row: row).id(row.instanceId)
        }
        UsageProvidersSection(controller: controller)
        advanced
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
      }
    }
    .sheet(isPresented: $controller.showAddInstance) { AddProviderInstanceSheet(controller: controller) }
    .sheet(isPresented: $controller.showAddHub) { AddUsageLimitSourceSheet(controller: controller) }
  }

  // MARK: List

  private var instanceList: some View {
    let rows = controller.rows
    let selected = controller.selected?.instanceId
    return Section {
      if rows.isEmpty { Text("No providers configured.").foregroundStyle(.secondary) }
      ForEach(rows) { row in
        ProviderListRow(controller: controller, row: row, selected: row.instanceId == selected)
          .listRowBackground(row.instanceId == selected ? Color.accentColor.opacity(0.14) : nil)
      }
      if let error = controller.updateError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    } header: {
      HStack(spacing: 8) {
        Text("Providers on \(controller.environmentLabel)").id("providers")
        Spacer()
        CheckedLabel(date: controller.lastChecked, refreshing: controller.refreshing)
        Button { controller.refresh() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).disabled(controller.refreshing).help("Refresh provider status").accessibilityLabel("Refresh provider status")
        Button { controller.showAddInstance = true } label: { Image(systemName: "plus") }
          .buttonStyle(.borderless).help("Add provider").accessibilityLabel("Add provider")
      }
    } footer: {
      if model.scope.isProject {
        Text("Providers are set up per environment, not per project. Showing the environment of the selected project.")
      } else if model.scope.environmentIds.count > 1 {
        Text("Providers belong to one environment. Choose an environment in the bar above to configure another one.")
      }
    }
  }

  // MARK: Advanced

  private var advanced: some View {
    let settings = controller.settings
    let resolved = BackgroundActivityPolicy.resolved(settings)
    let preset = BackgroundActivityPolicy.preset(resolved.profile).providerHealthRefreshInterval
    func write(_ milliseconds: Double) {
      controller.save(BackgroundActivityPolicy.overridePatch(settings) { $0.providerHealthRefreshInterval = milliseconds }, failure: "Health check interval not saved.")
    }
    return Section("Advanced") {
      SettingRow(
        id: "provider-health-check-interval", title: "Health check interval",
        help: "Refresh provider status, versions, and models in the background. Set to 0 to disable. The shared Background activity policy still decides whether a probe may run when the timer fires.",
        isDefault: resolved.providerHealthRefreshInterval == preset, reset: { write(preset) }
      ) {
        HStack(spacing: 6) {
          IntervalField(seconds: Int((resolved.providerHealthRefreshInterval / 1000).rounded())) { write(Double($0) * 1000) }
          Text("seconds").foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// "Checked 2 minutes ago", refreshed once a minute.
private struct CheckedLabel: View {
  let date: Date?
  let refreshing: Bool

  var body: some View {
    if refreshing {
      Text("Refreshing providers").font(.callout).foregroundStyle(.secondary)
    } else if let date {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        Text("Checked \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
          .font(.callout).foregroundStyle(.secondary).id(context.date)
      }
    }
  }
}

/// A whole number of seconds, saved on Return or when you leave the field; anything else snaps back to the saved value.
private struct IntervalField: View {
  let seconds: Int
  let commit: (Int) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $draft)
      .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72).focused($focused)
      .onAppear { draft = String(seconds) }
      .onChange(of: seconds) { if !focused { draft = String(seconds) } }
      .onSubmit(save)
      .onChange(of: focused) { if !focused { save() } }
      .accessibilityLabel("Provider health check interval in seconds")
  }

  private func save() {
    guard let value = Int(draft.trimmingCharacters(in: .whitespaces)), value >= 0 else {
      draft = String(seconds)
      return
    }
    if value != seconds { commit(value) }
  }
}

// MARK: - List row

private struct ProviderListRow: View {
  let controller: ProvidersController
  let row: ProviderInstanceRow
  let selected: Bool

  var body: some View {
    let live = controller.live(row.instanceId)
    let enabled = ProviderInstances.isEnabled(row.instance)
    let summary = enabled ? ProviderStatus.summary(live) : ProviderStatusSummary(headline: "Disabled", detail: nil)
    let advisory = ProviderStatus.advisory(live, showCompatibility: enabled)
    let name = ProviderInstances.displayName(row.instance)
    let attention = enabled && (live?.status == .warning || live?.status == .error || live == nil)
    HStack(spacing: 10) {
      Button { controller.selectedId = row.instanceId } label: {
        HStack(spacing: 10) {
          ProviderGlyph(name: name, accent: ProviderInstances.normalizedAccent(row.instance.accentColor))
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(name).fontWeight(.medium).lineLimit(1)
              if row.instanceId != row.driver {
                Text(row.instanceId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
              }
              if let version = ProviderStatus.versionLabel(live?.version) { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            }
            HStack(spacing: 5) {
              if live?.status == .warning || live?.status == .error { Circle().fill(live?.status == .error ? Color.red : Color.orange).frame(width: 6, height: 6) }
              Text(statusLine(summary, attention: attention)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selected ? .isSelected : [])
      if let advisory { AdvisoryIcon(advisory: advisory, name: name) }
      Toggle(
        "Enable \(name)",
        isOn: Binding(get: { enabled }, set: { on in controller.edit(row.instanceId) { $0.enabled = on } })
      )
      .labelsHidden().toggleStyle(.switch)
    }
    .opacity(enabled || selected ? 1 : 0.7)
  }

  private func statusLine(_ summary: ProviderStatusSummary, attention: Bool) -> String {
    if attention, let detail = summary.detail { return "\(summary.headline) · \(detail)" }
    return summary.headline
  }
}

/// The small advisory mark of a list row: a warning for a compatibility problem, otherwise the update command to copy.
private struct AdvisoryIcon: View {
  let advisory: ProviderVersionAdvisory
  let name: String

  var body: some View {
    if advisory.isCompatibility {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(advisory.detail).accessibilityLabel(advisory.title)
    } else if let command = advisory.updateCommand {
      Button { ProvidersController.copy(command) } label: { Image(systemName: "arrow.up.circle") }
        .buttonStyle(.borderless).help("Copy update command").accessibilityLabel("Copy \(name) update command")
    } else {
      Image(systemName: "arrow.up.circle").foregroundStyle(.secondary).help(advisory.detail).accessibilityLabel(advisory.title)
    }
  }
}

// MARK: - Editor

/// The selected instance: identity, setup, runtime settings, environment variables and models.
private struct ProviderEditor: View {
  let controller: ProvidersController
  let row: ProviderInstanceRow
  @State private var advisoryOpen = false
  @State private var confirmDelete = false
  @State private var confirmReset = false

  var body: some View {
    let live = controller.live(row.instanceId)
    let driver = ProviderCatalog.driver(row.driver)
    let name = ProviderInstances.displayName(row.instance)
    let enabled = ProviderInstances.isEnabled(row.instance)
    let accent = ProviderInstances.normalizedAccent(row.instance.accentColor)
    let id = row.instanceId
    Group {
      Section {
        SettingRow(id: "\(id)-name", title: "Display name", help: nil, status: nil) {
          HStack(spacing: 8) {
            AccentColorControl(hex: accent) { hex in controller.edit(id) { $0.accentColor = hex } }
            DraftTextField(title: driver?.label ?? "Instance label", value: row.instance.displayName ?? "") { text in
              let trimmed = text.trimmingCharacters(in: .whitespaces)
              controller.edit(id) { $0.displayName = trimmed.isEmpty ? nil : trimmed }
            }
          }
        }
        statusRow(live: live, enabled: enabled)
      } header: {
        header(name: name, accent: accent, driver: driver, live: live, enabled: enabled)
      }

      if row.driver == "antigravity" || live?.setup != nil {
        ProviderSetupSection(controller: controller, row: row, live: live)
      }

      Section("Runtime") {
        if let driver {
          ForEach(driver.fields) { field in
            ProviderFieldRow(
              idPrefix: "provider-\(id)", field: field, config: row.instance.config,
              onChange: { config in controller.edit(id) { $0.config = config } })
          }
        } else {
          Text("This instance uses \(row.driver), which is not available in this build. Its configuration is preserved.").foregroundStyle(.secondary)
        }
      }

      Section("Environment") {
        EnvironmentVariablesEditor(environment: row.instance.environment ?? []) { variables in
          controller.edit(id) { $0.environment = variables.isEmpty ? nil : variables }
        }
      }

      if driver != nil { ProviderModelsSection(controller: controller, row: row, live: live) }
    }
    .confirmationDialog("Remove \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Remove instance", role: .destructive) { controller.delete(row) }
    } message: {
      Text("Its settings are deleted from \(controller.environmentLabel). Threads that used it keep their history.")
    }
    .confirmationDialog("Reset \(name) to its defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
      Button("Reset", role: .destructive) { controller.resetDefault(row) }
    }
  }

  // MARK: Pieces

  private func header(name: String, accent: String?, driver: ProviderDriver?, live: ServerConfigProvidersItem?, enabled: Bool) -> some View {
    let advisory = ProviderStatus.advisory(live, showCompatibility: enabled)
    return HStack(spacing: 8) {
      ProviderGlyph(name: name, accent: accent, size: 22)
      Text(name).font(.headline)
      Spacer()
      if let badge = driver?.badge {
        Text(badge).font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(.orange.opacity(0.2), in: Capsule())
      }
      if let version = ProviderStatus.versionLabel(live?.version) { Text(version).font(.callout.monospaced()).foregroundStyle(.secondary) }
      if let advisory, let live {
        Button { advisoryOpen = true } label: {
          Image(systemName: advisory.isCompatibility ? "exclamationmark.triangle.fill" : "arrow.up.circle").foregroundStyle(advisory.isCompatibility ? Color.orange : Color.secondary)
        }
        .buttonStyle(.borderless).help(advisory.title).accessibilityLabel("\(advisory.title), view details")
        .popover(isPresented: $advisoryOpen, arrowEdge: .bottom) { AdvisoryPopover(controller: controller, advisory: advisory, live: live, name: name) }
      }
      if row.isDefault, row.isDirty {
        Button { confirmReset = true } label: { Image(systemName: "arrow.uturn.backward") }
          .buttonStyle(.borderless).help("Reset to defaults").accessibilityLabel("Reset \(name) provider settings")
      }
      if !row.isDefault {
        Button { confirmDelete = true } label: { Image(systemName: "trash") }
          .buttonStyle(.borderless).help("Remove instance").accessibilityLabel("Delete instance \(row.instanceId)")
      }
    }
    .textCase(nil)
  }

  private func statusRow(live: ServerConfigProvidersItem?, enabled: Bool) -> some View {
    let summary = enabled ? ProviderStatus.summary(live) : ProviderStatusSummary(headline: "Disabled", detail: nil)
    let email = live?.auth.email?.trimmingCharacters(in: .whitespaces)
    let authenticated = enabled && live?.auth.status == .authenticated
    return HStack(alignment: .firstTextBaseline, spacing: 4) {
      if authenticated, let email, !email.isEmpty {
        Text("Authenticated as")
        RedactedEmail(email: email)
        if let label = live?.auth.label ?? live?.auth.type { Text("· \(label)") }
        if let detail = summary.detail { Text("· \(detail)") }
      } else {
        Text(summary.headline)
        if let detail = summary.detail { Text("· \(detail)") }
      }
      Spacer(minLength: 0)
    }
    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
  }
}

private struct AdvisoryPopover: View {
  let controller: ProvidersController
  let advisory: ProviderVersionAdvisory
  let live: ServerConfigProvidersItem
  let name: String

  var body: some View {
    let updating = controller.isUpdating(live)
    let canAct = advisory.targetVersion != nil ? live.versionAdvisory?.canInstallVersion == true : ProviderStatus.isUpdateCandidate(live)
    VStack(alignment: .leading, spacing: 10) {
      Text(advisory.title).font(.headline)
      Text(advisory.detail).font(.callout).foregroundStyle(advisory.strong ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
      if canAct {
        Button {
          controller.runUpdate(live, targetVersion: advisory.targetVersion)
        } label: {
          Text(updating ? "Updating" : advisory.targetVersion.map { "Install \(ProviderStatus.versionLabel($0) ?? $0)" } ?? "Update now")
        }
        .disabled(updating)
      }
      if let command = advisory.updateCommand {
        Text(canAct ? "or, update manually using" : "Update manually using").font(.caption).foregroundStyle(.secondary)
        HStack {
          Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
          Button { ProvidersController.copy(command) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy command").accessibilityLabel("Copy \(name) update command")
        }
        .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .padding(14).frame(width: 340)
  }
}
