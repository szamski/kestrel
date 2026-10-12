import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Projects. Without a project in the scope bar it lists them; with one it edits that project: name, icon,
/// new-thread defaults, actions, checkouts, and the danger zone.
struct ProjectsPage: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    let scope = model.scope
    if scope.kind == .unavailable {
      ContentUnavailableView(scope.message ?? "This target is unavailable.", systemImage: "rectangle.3.group")
    } else if scope.isProject, let key = model.scopeSearch.project, let group = model.runtime.projectGroups.first(where: { $0.key == key }) {
      ProjectDetailView(group: group, scope: scope).id("\(key):\(model.scopeSearch.machine ?? ""):\(model.scopeSearch.checkout ?? "")")
    } else {
      ProjectListView()
    }
  }
}

// MARK: List

private struct ProjectListView: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    let machine = model.scopeSearch.machine
    let groups = model.runtime.projectGroups.filter { group in machine == nil || group.members.contains { $0.project.environmentId.rawValue == machine } }
    Form {
      Section {
        if groups.isEmpty {
          Text(model.runtime.projects.isEmpty ? "Add a project from the sidebar to configure it here." : "No projects on this environment.").foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.key) { group in
          let members = group.members.filter { machine == nil || $0.project.environmentId.rawValue == machine }
          Button { model.selectProject(group.key) } label: {
            HStack(spacing: 10) {
              ProjectGlyph(project: group.representative)
              VStack(alignment: .leading, spacing: 1) {
                Text(group.label)
                Text(members.map { environmentLabel($0.project.environmentId) }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              Text(members.count == 1 ? "1 checkout" : "\(members.count) checkouts").font(.caption).foregroundStyle(.secondary)
              Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("Choose a project to manage its name, icon, checkouts and actions.")
      }
    }
    .formStyle(.grouped)
    #if DEBUG
    // Verification runs open straight on a project: `-T3SettingsProject <label>`.
    .task {
      guard let label = UserDefaults.standard.string(forKey: "T3SettingsProject") else { return }
      for _ in 0..<100 {
        if let group = model.runtime.projectGroups.first(where: { $0.label == label }) { return model.selectProject(group.key) }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    #endif
  }

  private func environmentLabel(_ id: EnvironmentId) -> String { model.runtime.environments.first { $0.environmentId == id }?.label ?? id.rawValue }
}

// MARK: Detail

private struct ProjectDetailView: View {
  @Environment(SettingsModel.self) private var model
  let group: ProjectGroup
  let scope: SettingsScope
  @State private var iconPicker = false
  @State private var faviconPicker = false
  @State private var removing: [ProjectGroup.Member]?
  @State private var saving = false

  /// The checkouts the scope covers (all of the group's, or the chosen environment's or checkout's).
  private var members: [ProjectGroup.Member] {
    let keys = Set(scope.members.map(\.physicalProjectKey))
    return group.members.filter { keys.contains($0.physicalProjectKey) }
  }

  private var projects: [EnvironmentProject] { members.map(\.project) }
  private var representative: EnvironmentProject { projects.first { isConnected($0.environmentId) } ?? projects.first ?? group.representative }
  private var hasOtherMembers: Bool { members.count < group.members.count }

  var body: some View {
    let projects = projects
    ScrollViewReader { proxy in
      Form {
        if projects.isEmpty {
          Text("This checkout is no longer available in the selected project and environment.").foregroundStyle(.secondary)
        } else {
          overview
          ProjectDefaultsSection()
          ProjectActionsSection(runtime: model.runtime, members: projects)
          if members.count > 1 { checkouts }
          danger
        }
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
    .sheet(isPresented: $iconPicker) {
      ProjectIconPickerSheet(current: representative.iconChoice, projectName: group.label) { choice in
        update(failure: "Failed to update project icon", icon: .some(choice.override), favicon: .some(nil))
      }
    }
    .sheet(isPresented: $faviconPicker) {
      ProjectFaviconPickerSheet(
        runtime: model.runtime, environmentId: representative.environmentId, cwd: representative.project.workspaceRoot, projectName: group.label
      ) { path in update(failure: "Failed to update project icon", icon: .some(nil), favicon: .some(path)) }
    }
    .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { members in
      Button(hasOtherMembers || members.count < group.members.count ? "Remove checkout" : "Remove project", role: .destructive) { remove(members) }
    } message: { members in
      Text(removalMessage(members))
    }
  }

  // MARK: Overview

  private var overview: some View {
    let hasIcon = projects.contains { $0.iconChoice != nil || $0.faviconPath != nil }
    return Section {
      SettingRow(id: "project-overview", title: "Name", help: "The shared name for this project group in the sidebar and thread lists.") {
        CommitTextField(value: group.label, placeholder: "Project name") { rename($0) }.frame(width: 240)
      }
      SettingRow(
        id: "project-icon", title: "Project icon",
        help: representative.iconChoice?.summary ?? representative.faviconPath ?? "Automatic", isDefault: !hasIcon,
        reset: { update(failure: "Failed to update project icon", icon: .some(nil), favicon: .some(nil)) }
      ) {
        HStack(spacing: 8) {
          ProjectGlyph(project: representative)
          Button("Choose icon") { iconPicker = true }
          Button("Choose file") { faviconPicker = true }
        }
        .disabled(saving)
      }
      Text("Can't find a setting? Keep this project picked above and hop to any other settings page.").font(.callout).foregroundStyle(.secondary)
    } header: {
      Text("Project")
    }
  }

  // MARK: Checkouts and removal

  private var checkouts: some View {
    Section("Checkouts") {
      ForEach(members, id: \.physicalProjectKey) { member in
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(environmentLabel(member.project.environmentId))
            Text(member.project.project.workspaceRoot).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          Spacer()
          Button("Remove") { removing = [member] }.accessibilityLabel("Remove checkout \(member.project.project.workspaceRoot)")
        }
      }
    }
  }

  private var danger: some View {
    let whole = !hasOtherMembers
    return Section("Danger") {
      SettingRow(
        id: "project-remove", title: hasOtherMembers ? "Remove checkout" : members.count > 1 ? "Remove this project everywhere" : "Remove project",
        help: hasOtherMembers
          ? "Deletes the selected machine's checkout entries and their threads. Other machines and files on disk are not touched."
          : members.count > 1
            ? "Deletes all \(members.count) checkout entries and their threads on every machine. Files on disk are not touched."
            : "Deletes the project entry and its threads. Files on disk are not touched."
      ) {
        Button(role: .destructive) { removing = members } label: {
          Label(hasOtherMembers ? "Remove checkout" : members.count > 1 ? "Remove all entries" : "Remove project", systemImage: "trash")
        }
        .disabled(saving || (whole && members.isEmpty))
      }
    }
  }

  private var removalTitle: String {
    guard let target = removing else { return "Remove project?" }
    let kind = hasOtherMembers || target.count < group.members.count ? "checkout" : "project"
    let name = target.count == 1 ? target[0].project.project.title : group.label
    let threads = threadCount(target)
    return threads > 0 ? "Remove \(kind) \u{201C}\(name)\u{201D} and delete its \(threads) thread\(threads == 1 ? "" : "s")?" : "Remove \(kind) \u{201C}\(name)\u{201D}?"
  }

  private func removalMessage(_ target: [ProjectGroup.Member]) -> String {
    var lines: [String] = []
    if target.count == 1 {
      lines.append("Path: \(target[0].project.project.workspaceRoot)")
      lines.append("Environment: \(environmentLabel(target[0].project.environmentId))")
    } else {
      lines.append("This removes \(target.count) grouped project entries.")
    }
    lines.append(
      threadCount(target) > 0
        ? "This permanently clears conversation history for those threads and any archived threads."
        : "This permanently clears any archived conversation history.")
    lines.append(
      target.count == group.members.count ? "This removes only the project entries, not the files on disk." : "Other entries in this grouped project are unaffected.")
    lines.append("This action cannot be undone.")
    return lines.joined(separator: "\n")
  }

  private func threadCount(_ target: [ProjectGroup.Member]) -> Int {
    target.reduce(0) { total, member in
      let threads = model.runtime.shells[member.project.environmentId]?.snapshot?.threads ?? []
      return total + threads.filter { $0.projectId == member.project.projectId }.count
    }
  }

  // MARK: Writes

  private func environmentLabel(_ id: EnvironmentId) -> String { model.runtime.environments.first { $0.environmentId == id }?.label ?? id.rawValue }
  private func isConnected(_ id: EnvironmentId) -> Bool { model.runtime.environments.first { $0.environmentId == id }?.connection.phase == .connected }

  private func rename(_ text: String) {
    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      model.report("Project title cannot be empty.")
      return
    }
    guard projects.contains(where: { $0.project.title != title }) else { return }
    update(failure: "Failed to rename project", title: title)
  }

  /// Group-shared fields live on each checkout's project record, so an edit goes to every checkout in the scope, in order.
  private func update(failure: String, title: String? = nil, icon: ProjectIconOverride?? = nil, favicon: String?? = nil) {
    let targets = projects
    saving = true
    Task {
      defer { saving = false }
      for project in targets {
        let label = environmentLabel(project.environmentId)
        guard isConnected(project.environmentId) else {
          model.report("\(failure). Connect \(label) and try again.")
          return
        }
        do {
          try await model.runtime.updateProject(environmentId: project.environmentId, projectId: project.projectId, title: title, projectIcon: icon, faviconPath: favicon)
        } catch {
          // An earlier checkout may already have taken the write; name the one that stopped it.
          model.report("\(failure)\(targets.count > 1 ? " on \(label)" : ""). \(AppModel.describe(error))")
          return
        }
      }
    }
  }

  private func remove(_ target: [ProjectGroup.Member]) {
    let whole = target.count == group.members.count
    saving = true
    Task {
      defer { saving = false }
      for member in target {
        let project = member.project
        guard isConnected(project.environmentId) else {
          model.report("Failed to remove project. Connect \(environmentLabel(project.environmentId)) and try again.")
          return
        }
        do {
          try await model.runtime.deleteProject(environmentId: project.environmentId, projectId: project.projectId)
        } catch {
          model.report("Failed to remove \u{201C}\(project.project.title)\u{201D}. \(AppModel.describe(error))")
          return
        }
      }
      if whole { model.selectProject(nil) }
    }
  }
}
