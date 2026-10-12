import AppKit
import Foundation
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Theme

/// One selectable row of the command palette.
struct PaletteItem: Identifiable {
  var id: String
  var title: String
  var subtitle: String?
  var symbol: String
  var shortcut: String?
  var trailing: String?
  /// What the row matches against besides its title.
  var terms: [String] = []
  /// Rows that switch the palette to another list stay open; every other row closes it first.
  var keepsOpen = false
  var run: @MainActor () -> Void
}

struct PaletteSection: Identifiable {
  var title: String
  var items: [PaletteItem]
  var id: String { title }
}

enum PaletteMode: Equatable {
  case root
  /// The project picker behind "New thread in…".
  case newThreadIn
}

/// The palette's content for a query. Without a query: recent threads, then actions. With one: actions,
/// threads, projects and environments, each ranked by `SearchRanking` (the web palette's scoring).
@MainActor
struct PaletteContent {
  let app: AppModel
  let commands: CommandCenter
  /// Closes the palette, then runs the action (rows that open a panel or sheet need the palette gone first).
  let finish: (@escaping @MainActor () -> Void) -> Void
  let switchMode: (PaletteMode) -> Void

  static let recentLimit = 12
  static let resultLimit = 30

  func sections(mode: PaletteMode, query rawQuery: String) -> [PaletteSection] {
    let query = SearchRanking.normalizeQuery(rawQuery)
    if mode == .newThreadIn { return [PaletteSection(title: "New thread in", items: rank(projectItems(), query: query))] }
    if query.isEmpty {
      return [
        PaletteSection(title: "Recent threads", items: Array(threadItems().prefix(Self.recentLimit))),
        PaletteSection(title: "Actions", items: actionItems()),
      ].filter { !$0.items.isEmpty }
    }
    return [
      PaletteSection(title: "Actions", items: rank(actionItems(), query: query)),
      PaletteSection(title: "Threads", items: rank(threadItems(), query: query)),
      PaletteSection(title: "Projects", items: rank(projectItems(), query: query)),
      PaletteSection(title: "Environments", items: rank(environmentItems(), query: query)),
    ].filter { !$0.items.isEmpty }
  }

  private func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
    guard !query.isEmpty else { return items }
    var ranked: [(item: PaletteItem, score: Int, order: Int)] = []
    for (order, item) in items.enumerated() {
      let scores = ([item.title] + (item.subtitle.map { [$0] } ?? []) + item.terms).compactMap {
        SearchRanking.queryScore(
          value: $0.lowercased(), query: query, exactBase: 0, prefixBase: 100, boundaryBase: 200, includesBase: 300, fuzzyBase: 400)
      }
      if let best = scores.min() { ranked.append((item, best, order)) }
    }
    // Equal scores keep the input order (newest thread first).
    ranked.sort { ($0.score, $0.order) < ($1.score, $1.order) }
    return ranked.prefix(Self.resultLimit).map(\.item)
  }

  // MARK: Rows

  private var multipleEnvironments: Bool { app.runtime.environments.count > 1 }

  private func commandItem(_ command: KeybindingCommand, title: String, symbol: String, terms: [String] = []) -> PaletteItem? {
    guard commands.isAvailable(command) else { return nil }
    return PaletteItem(
      id: "command:\(command.rawValue)", title: title, symbol: symbol, shortcut: commands.shortcutLabel(command), terms: terms,
      run: { finish { commands.perform(command) } })
  }

  private func actionItems() -> [PaletteItem] {
    let row = app.selection.flatMap { key in app.runtime.sidebar.rows.first { $0.thread.key == key } }
    let settled = row?.section == .settled || row?.thread.shell.settledOverride == .settled
    let items: [PaletteItem?] = [
      commandItem(.chatNew, title: "New thread", symbol: "square.and.pencil"),
      app.runtime.projectGroups.isEmpty
        ? nil
        : PaletteItem(
          id: "action:new-thread-in", title: "New thread in\u{2026}", symbol: "folder.badge.plus", keepsOpen: true, run: { switchMode(.newThreadIn) }),
      PaletteItem(id: "action:add-project", title: "Add project\u{2026}", symbol: "folder.badge.plus", terms: ["open folder"], run: { finish { commands.addProject() } }),
      PaletteItem(id: "action:add-environment", title: "Add environment\u{2026}", symbol: "externaldrive.badge.plus", terms: ["connect", "server"], run: { finish { app.sheet = .addEnvironment } }),
      commandItem(.threadPrevious, title: "Previous thread", symbol: "chevron.up"),
      commandItem(.threadNext, title: "Next thread", symbol: "chevron.down"),
      commandItem(.navigationBack, title: "Go back", symbol: "chevron.left"),
      commandItem(.navigationForward, title: "Go forward", symbol: "chevron.right"),
      commandItem(.threadSettle, title: settled ? "Un-settle thread" : "Settle thread", symbol: "checkmark.circle"),
      commandItem(.threadPin, title: row?.section == .pinned ? "Unpin thread" : "Pin thread", symbol: "pin"),
      commandItem(.threadStop, title: "Stop turn", symbol: "stop.circle", terms: ["interrupt"]),
      commandItem(.threadCopyReference, title: "Copy thread ID", symbol: "doc.on.doc", terms: ["reference"]),
      PaletteItem(
        id: "action:pull-requests", title: "Open pull requests", symbol: "arrow.triangle.pull", terms: ["review", "merge", "PR", "inbox"],
        run: { finish { PullRequestsStore.shared.show() } }),
      app.selection.flatMap { key in
        app.runtime.threadPullRequestLinkMode(key.environmentId) == .unsupported
          ? nil
          : PaletteItem(
            id: "action:link-pull-request", title: "Link pull request\u{2026}", symbol: "link", terms: ["PR", "attach"],
            run: { finish { PullRequestsStore.shared.linkRequest = key } })
      },
      commandItem(.pullRequestCopyNumber, title: "Copy pull request link", symbol: "link", terms: ["PR", "number", "url"]),
      commandItem(.modelPickerToggle, title: "Choose model", symbol: "cpu", terms: ["provider"]),
      commandItem(.composerMode, title: "Toggle plan mode", symbol: "list.bullet.clipboard", terms: ["build"]),
      commandItem(.sidebarToggle, title: "Toggle sidebar", symbol: "sidebar.left"),
      commandItem(.rightPanelToggle, title: "Toggle right panel", symbol: "sidebar.right"),
      commandItem(.diffToggle, title: "Toggle diff", symbol: "plusminus", terms: ["changes", "review"]),
      commandItem(.terminalToggle, title: "Toggle terminal", symbol: "terminal", terms: ["shell", "console"]),
      commandItem(.terminalNew, title: "New terminal", symbol: "plus.rectangle", terms: ["shell", "tab"]),
      commandItem(.terminalSplit, title: "Split terminal", symbol: "square.split.2x1"),
      commandItem(.terminalSplitVertical, title: "Split terminal vertically", symbol: "square.split.1x2"),
      commandItem(.terminalClose, title: "Close terminal", symbol: "xmark.rectangle"),
      commandItem(.appearanceCycle, title: "Cycle appearance", symbol: "circle.lefthalf.filled", terms: ["theme", "dark", "light"]),
      PaletteItem(id: "action:settings", title: "Open settings", symbol: "gearshape", shortcut: "\u{2318},", terms: ["preferences"], run: { finish { commands.openSettings() } }),
    ]
    return items.compactMap { $0 } + themeItems(finish: finish)
  }

  /// "Theme: Ocean": every theme in the library, so one can be picked without opening Settings.
  private func themeItems(finish: @escaping (@escaping @MainActor () -> Void) -> Void) -> [PaletteItem] {
    let library: [ThemeDefinition?] = [nil] + AppTheme.shared.library.map { Optional($0) }
    return library.map { theme in
      PaletteItem(
        id: "theme:\(theme?.id ?? "standard")", title: "Theme: \(theme?.label ?? "T3 Code")", symbol: "paintpalette", terms: ["appearance", "colors", "palette"],
        run: { finish { AppTheme.shared.use(theme?.id) } })
    }
  }

  /// Newest first.
  private func threadItems() -> [PaletteItem] {
    var threads: [EnvironmentThreadShell] = []
    for (environmentId, state) in app.runtime.shells {
      for shell in state.snapshot?.threads ?? [] where shell.archivedAt == nil { threads.append(EnvironmentThreadShell(environmentId: environmentId, shell: shell)) }
    }
    threads.sort { $0.shell.updatedAt.rawValue > $1.shell.updatedAt.rawValue }
    return threads.map { thread in
      let project = app.projectTitle(of: thread)
      let subtitle = multipleEnvironments ? "\(project) \u{2014} \(app.environmentLabel(thread.environmentId))" : project
      return PaletteItem(
        id: "thread:\(thread.id)", title: thread.shell.title.isEmpty ? "Untitled thread" : thread.shell.title, subtitle: subtitle,
        symbol: "bubble.left", trailing: thread.shell.updatedAt.date.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) },
        run: { finish { app.selection = thread.key } })
    }
  }

  private func projectItems() -> [PaletteItem] {
    app.runtime.projectGroups.map { group in
      let environment = app.environmentLabel(group.representative.environmentId)
      return PaletteItem(
        id: "project:\(group.key)", title: group.label, subtitle: multipleEnvironments ? environment : group.representative.project.workspaceRoot,
        symbol: "folder", terms: [group.representative.project.workspaceRoot], run: { finish { app.startNewThread(in: group) } })
    }
  }

  /// Picking an environment shows only its threads in the sidebar; picking it again shows all.
  private func environmentItems() -> [PaletteItem] {
    app.runtime.environments.map { environment in
      let filtered = app.runtime.filter.environmentId == environment.environmentId
      return PaletteItem(
        id: "environment:\(environment.environmentId.rawValue)", title: environment.label,
        subtitle: filtered ? "Showing only its threads \u{2014} choose to show all" : "Show only its threads", symbol: "externaldrive",
        run: { finish { app.runtime.filter.environmentId = filtered ? nil : environment.environmentId } })
    }
  }
}
