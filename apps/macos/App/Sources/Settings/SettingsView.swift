import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The settings window: page list and search in the sidebar, the scope bar and the selected page in the detail.
struct SettingsView: View {
  @State var model: SettingsModel

  var body: some View {
    NavigationSplitView {
      Sidebar()
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    } detail: {
      Detail()
        .navigationTitle(model.page.title)
    }
    .environment(model)
    .searchable(text: $model.query, placement: .sidebar, prompt: "Search settings")
    .frame(minWidth: 860, minHeight: 560)
  }
}

private struct Sidebar: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    @Bindable var model = model
    if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
      List(SettingsPage.allCases, selection: $model.page) { page in
        Label(page.title, systemImage: page.symbol).tag(page)
      }
    } else {
      let results = model.results
      if results.isEmpty {
        ContentUnavailableView.search(text: model.query)
      } else {
        List(results) { item in
          Button { model.open(item) } label: {
            VStack(alignment: .leading, spacing: 1) {
              Text(item.title)
              Text(item.page.title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
    }
  }
}

private struct Detail: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      if !model.page.hidesScopeBar {
        SettingsScopeBar()
        Divider()
      }
      if let notice = model.notice {
        HStack(alignment: .firstTextBaseline) {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(notice).font(.callout)
          Spacer()
          Button("Dismiss") { model.dismissNotice() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 20).padding(.vertical, 8).background(.orange.opacity(0.1))
      }
      page
    }
    .toolbar {
      ToolbarItem { RestoreDefaultsButton() }
    }
  }

  /// A page that edits servers has nothing to show for a target that is gone or offline; device pages ignore the scope.
  @ViewBuilder private var page: some View {
    let scope = model.scope
    if !model.page.hidesScopeBar, model.page != .projects, scope.kind == .unavailable {
      Placeholder(text: scope.message ?? "This target is unavailable.")
    } else if !model.page.hidesScopeBar, model.page != .projects, scope.kind == .environment, model.targets.isEmpty {
      Placeholder(text: "Reconnect \(scope.label) to change its settings.")
    } else {
      switch model.page {
      case .general: GeneralPage()
      case .appearance: AppearancePage()
      case .connections: ConnectionsPage()
      case .providers: ProvidersPage()
      case .projects: ProjectsPage()
      case .keybindings: KeybindingsPage()
      case .sourceControl: SourceControlPage()
      case .storage: StoragePage()
      case .archived: ArchivedPage()
      case .licenses: LicensesPage()
      default: Placeholder(text: "\(model.page.title) settings arrive in a later stage.", title: model.page.title)
      }
    }
  }
}

private struct Placeholder: View {
  let text: String
  var title: String?

  var body: some View {
    ContentUnavailableView {
      Label(title ?? "Nothing to show", systemImage: "slider.horizontal.3")
    } description: {
      Text(text)
    }
  }
}

/// "Restore defaults" for the page in view, with the list of what it would reset.
private struct RestoreDefaultsButton: View {
  @Environment(SettingsModel.self) private var model
  @State private var confirming = false

  var body: some View {
    let labels = model.page == .general ? GeneralDefaults.changedLabels(model) : model.page == .appearance ? AppearanceDefaults.changedLabels(model) : []
    Button("Restore defaults", systemImage: "arrow.counterclockwise") { confirming = true }
      .disabled(labels.isEmpty)
      .help(labels.isEmpty ? "Everything on this page already has its default value." : "Reset this page to its defaults")
      .confirmationDialog("Restore default settings?", isPresented: $confirming) {
        Button("Restore defaults", role: .destructive) { model.page == .appearance ? AppearanceDefaults.restore(model) : GeneralDefaults.restore(model) }
      } message: {
        Text("This will reset: \(labels.joined(separator: ", ")).")
      }
  }
}

/// "Applying settings for [project] on [environment]": the target every server setting on the page is written to.
struct SettingsScopeBar: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    let search = model.scopeSearch
    let groups = model.runtime.projectGroups
    let environments = model.runtime.environments
    let group = groups.first { $0.key == search.project }
    let checkouts = group?.members.filter { search.machine == nil || $0.project.environmentId.rawValue == search.machine } ?? []
    HStack(spacing: 8) {
      Text("Applying settings for").foregroundStyle(.secondary).lineLimit(1).fixedSize()
      Picker("Project", selection: Binding(get: { search.project ?? "" }, set: { model.selectProject($0.isEmpty ? nil : $0) })) {
        Text("All projects").tag("")
        ForEach(groups, id: \.key) { Text($0.label).tag($0.key) }
        if let key = search.project, group == nil { Text("Unavailable project").tag(key) }
      }
      .labelsHidden().fixedSize()
      if checkouts.count > 1 {
        Picker("Checkout", selection: Binding(get: { search.checkout ?? "" }, set: { model.selectCheckout($0.isEmpty ? nil : $0) })) {
          Text("All checkouts").tag("")
          ForEach(checkouts, id: \.physicalProjectKey) { Text($0.project.project.workspaceRoot).tag($0.physicalProjectKey) }
        }
        .labelsHidden().fixedSize()
      }
      Text("on").foregroundStyle(.secondary)
      Picker("Environment", selection: Binding(get: { search.machine ?? "" }, set: { model.selectEnvironment($0.isEmpty ? nil : $0) })) {
        Text("All environments").tag("")
        ForEach(environments) { Text($0.label).tag($0.environmentId.rawValue) }
        if let id = search.machine, !environments.contains(where: { $0.environmentId.rawValue == id }) { Text("Unavailable environment").tag(id) }
      }
      .labelsHidden().fixedSize()
      Spacer()
      if model.scope.kind == .all, environments.count > 1 {
        Text("Edits apply to every connected environment.").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
  }
}
