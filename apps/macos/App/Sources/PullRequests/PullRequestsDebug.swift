#if DEBUG
import AppKit
import T3ClientRuntime
import T3Contracts

/// `-T3Driver` steps for the pull request inbox (read-only browsing): `pr:show`, `pr:wait`, `pr:log`, `pr:involvement:<all|reviewing|authored>`,
/// `pr:state:<open|closed|merged|all>`, `pr:query:<text>`, `pr:select:<index>` (of the visible rows), `pr:tab:<summary|code|timeline>`,
/// `pr:panel` (the open thread's Pull requests tab), `pr:hide`. Never performs a write.
@MainActor
enum PullRequestsDebug {
  static func run(_ arg: String, app: AppModel, say: (String) -> Void, sleep: (Double) async -> Void) async {
    let store = PullRequestsStore.shared
    store.attach(app)
    let bits = arg.split(separator: ":", maxSplits: 1).map(String.init)
    let value = bits.count > 1 ? bits[1] : ""
    switch bits.first ?? "" {
    case "show":
      store.show()
      await sleep(0.5)
    case "hide": store.hide()
    case "link": store.linkRequest = app.selection  // the link dialog of the open thread (nothing is linked until Link is pressed)
    case "wait":
      for _ in 0..<300 where store.phase == .idle || store.phase == .loading || store.refreshing { await sleep(0.1) }
      await sleep(0.5)
      say("pr phase=\(store.phase) rows=\(store.rows.count) issues=\(store.issues.map(\.message))")
    case "log":
      let groups = store.groups()
      say("pr phase=\(store.phase) rows=\(store.rows.count) visible=\(groups.reduce(0) { $0 + $1.entries.count }) groups=\(groups.map { "\($0.title):\($0.entries.count)" }) selected=\(store.selected?.id ?? "-") issues=\(store.issues.map(\.message)) cursors=\(store.nextCursors.count) live=\(store.liveCount)")
      for row in groups.flatMap(\.entries).prefix(12) { say("  #\(row.entry.number) \(row.entry.state.rawValue) \(row.entry.repository) \(row.entry.title.prefix(60))") }
    case "involvement":
      store.prefs.involvement = PullRequestInvolvement(rawValue: value)
      await sleep(0.3)
    case "state":
      store.prefs.state = PullRequestListState(rawValue: value)
      await sleep(0.3)
    case "query": store.query = value
    case "select":
      let rows = store.groups().flatMap(\.entries)
      if let index = Int(value), rows.indices.contains(index) { store.selected = PullRequestTarget(rows[index]) } else { say("pr: no row \(value)") }
      await sleep(0.5)
    case "tab":
      store.requestedTab = PullRequestTab.allCases.first { $0.rawValue.lowercased() == value }
      await sleep(0.5)
    case "panel":
      if let key = app.selection, let panel = RightPanelStore.live { panel.open(.pullRequests, in: key) } else { say("pr: no selected thread") }
      await sleep(0.5)
    case "panelpr":  // `panelpr:<index>`: the thread's n-th linked pull request as a tab of its right panel
      if let key = app.selection, let panel = RightPanelStore.live, let shell = app.runtime.threadShell(key)?.shell {
        let links = ThreadPullRequests.lines(ThreadPullRequests.chains(shell.pullRequests)).map(\.link)
        if let index = Int(value), links.indices.contains(index), let parsed = ChangeRequestURL.parse(links[index].url),
          let project = PullRequestProjects.project(for: parsed, in: app.runtime.projects.filter { $0.environmentId == key.environmentId })?.projectId ?? Optional(shell.projectId)
        {
          let link = links[index]
          panel.openSurface(.pullRequest(PullRequestTarget(environmentId: key.environmentId, projectId: project, host: link.host, repository: link.repository, number: link.number)), in: key)
        } else { say("pr: no linked pull request \(value)") }
      } else { say("pr: no selected thread") }
      await sleep(0.5)
    default: say("pr: unknown step \(arg)")
    }
  }
}
#endif
