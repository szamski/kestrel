import SwiftUI
import T3ClientRuntime
import T3Contracts

struct SidebarView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var runtime = app.runtime
    @Bindable var model = app
    let sidebar = runtime.sidebar
    // Reading the tick makes relative times refresh once a minute.
    let now = { _ = app.minuteTick; return Date.now }()
    List(selection: $model.selection) {
      section("Pinned", rows: sidebar.pinned, now: now)
      section("Active", rows: sidebar.active, now: now)
      if sidebar.layout.snoozedCount > 0 {
        shelf(
          "Snoozed", count: sidebar.layout.snoozedCount, expanded: runtime.filter.snoozedShelfExpanded, rows: sidebar.snoozed, now: now,
          toggle: { app.setShelf(snoozed: true, expanded: $0) })
      }
      if sidebar.layout.settledCount > 0 {
        shelf(
          "Settled", count: sidebar.layout.settledCount, expanded: runtime.filter.settledShelfExpanded, rows: sidebar.settled, now: now,
          toggle: { app.setShelf(snoozed: false, expanded: $0) }
        ) {
          if sidebar.layout.hiddenSettledCount > 0 {
            Button("Show \(min(sidebar.layout.hiddenSettledCount, SidebarPaging.step)) more") { app.showMoreSettled() }
              .buttonStyle(.link).font(.callout)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $runtime.filter.searchQuery, placement: .sidebar, prompt: "Search threads")
    .onDeleteCommand { if let thread = app.selectedThread { app.archive(thread) } }
    .overlay { if sidebar.isEmpty { EmptySidebar(searching: !runtime.filter.searchQuery.isEmpty) } }
    .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    .toolbar {
      ToolbarItem { NewThreadMenu() }
    }
  }

  @ViewBuilder private func section(_ title: String, rows: [SidebarRow], now: Date) -> some View {
    if !rows.isEmpty {
      Section(title) {
        ForEach(rows) { row in
          ThreadRowView(row: row, now: now).tag(row.thread.key)
            .contextMenu { ThreadContextMenu(row: row) }
        }
      }
    }
  }

  private func shelf<Extra: View>(
    _ title: String, count: Int, expanded: Bool, rows: [SidebarRow], now: Date, toggle: @escaping (Bool) -> Void,
    @ViewBuilder extra: () -> Extra = { EmptyView() }
  ) -> some View {
    Section {
      ForEach(rows) { row in
        ThreadRowView(row: row, now: now).tag(row.thread.key)
          .contextMenu { ThreadContextMenu(row: row) }
      }
      if expanded { extra() }
    } header: {
      Button {
        toggle(!expanded)
      } label: {
        HStack(spacing: 4) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 10)
          Text("\(title) (\(count))")
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(title), \(count) threads, \(expanded ? "expanded" : "collapsed")")
    }
  }
}

enum SidebarPaging { static let step = 25 }

struct EmptySidebar: View {
  let searching: Bool
  @Environment(AppModel.self) private var app

  var body: some View {
    if searching {
      ContentUnavailableView.search(text: app.runtime.filter.searchQuery)
    } else if app.runtime.environments.isEmpty {
      EmptyView()
    } else if !app.runtime.hasShellData {
      ProgressView().controlSize(.small)
    } else {
      ContentUnavailableView("No threads", systemImage: "text.bubble", description: Text("Start one with the + button."))
    }
  }
}

struct NewThreadMenu: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let groups = app.runtime.projectGroups
    let multi = app.runtime.environments.count > 1
    Menu {
      ForEach(groups, id: \.key) { group in
        Button(multi ? "\(group.label) \u{2014} \(app.environmentLabel(group.representative.environmentId))" : group.label) {
          app.startNewThread(in: group)
        }
      }
    } label: {
      Label("New thread", systemImage: "square.and.pencil")
    } primaryAction: {
      if let group = app.currentGroup { app.startNewThread(in: group) }
    }
    .disabled(groups.isEmpty)
    .help("New thread in the current project (\u{2318}N)")
  }
}

extension AppModel {
  var selectedThread: EnvironmentThreadShell? { selection.flatMap { runtime.threadShell($0) } }

  func setShelf(snoozed: Bool, expanded: Bool) {
    if snoozed { runtime.filter.snoozedShelfExpanded = expanded } else { runtime.filter.settledShelfExpanded = expanded }
    UserDefaults.standard.set(expanded, forKey: snoozed ? "sidebar.snoozedExpanded" : "sidebar.settledExpanded")
  }

  func showMoreSettled() {
    runtime.filter.settledLimit = (runtime.filter.settledLimit ?? SidebarPaging.step) + SidebarPaging.step
  }
}
