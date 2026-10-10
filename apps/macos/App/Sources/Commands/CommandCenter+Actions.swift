import AppKit
import T3ClientRuntime
import T3Contracts

/// Actions that have no keybinding but live in the palette and the menus.
extension CommandCenter {
  func openSettings() { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }

  /// "Add project": pick a folder and create the project on the environment running on this Mac
  /// (the path is a path on that machine, so a remote environment cannot take it), then open a new
  /// thread in it. An existing project at that path is just opened.
  func addProject() {
    guard let environmentId = localEnvironmentId else {
      app.errorMessage = "Adding a project from a folder needs an environment running on this Mac."
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose the folder of the project"
    let completion: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let url = panel.url else { return }
      create(project: url, in: environmentId)
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) } else { panel.begin(completionHandler: completion) }
  }

  private func create(project url: URL, in environmentId: EnvironmentId) {
    let path = ProjectGrouping.normalizePath(url.path)
    if let existing = app.runtime.projects.first(where: { $0.environmentId == environmentId && ProjectGrouping.normalizePath($0.project.workspaceRoot) == path }) {
      openNewThread(in: existing)
      return
    }
    app.run { [self] in
      guard let runtime = await app.runtime.runtime(for: environmentId) else { throw CommandError.notConnected(environment: environmentId.rawValue) }
      let meta = CommandMeta.fresh()
      let projectId = ProjectId(rawValue: UUID().uuidString.lowercased())
      try await runtime.dispatch(
        .projectCreate(
          V1.ProjectCreateCommand(commandId: meta.commandId, projectId: projectId, title: url.lastPathComponent, workspaceRoot: path, createdAt: meta.createdAt)))
      // The project reaches the shell through the event stream; open its draft as soon as it does.
      for _ in 0..<60 {
        if let created = app.runtime.projects.first(where: { $0.environmentId == environmentId && $0.projectId == projectId }) {
          openNewThread(in: created)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }

  private func openNewThread(in project: EnvironmentProject) {
    if let group = app.runtime.projectGroups.first(where: { $0.memberProjectRefs.contains(ScopedProjectRef(environmentId: project.environmentId, projectId: project.projectId)) }) {
      app.startNewThread(in: group)
    }
  }

  /// The environment whose server runs on this Mac: the open thread's, else the first one.
  private var localEnvironmentId: EnvironmentId? {
    let local = app.runtime.environments.map(\.environmentId).filter { id in
      ["localhost", "127.0.0.1", "::1", "[::1]"].contains(app.runtime.connectionEntry(id)?.httpBaseURL.host(percentEncoded: false) ?? "")
    }
    return local.first { $0 == app.selection?.environmentId } ?? local.first
  }
}
