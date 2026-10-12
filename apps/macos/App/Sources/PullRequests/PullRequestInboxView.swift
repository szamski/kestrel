import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The pull request inbox: the list of every pull request the connected environments can read, with filters, and the
/// detail of the selected one beside it. Shown in place of the reading window (`MainView`).
struct PullRequestInboxView: View {
  @Environment(AppModel.self) private var app
  private let store = PullRequestsStore.shared
  @State private var filtersOpen = false

  var body: some View {
    HSplitView {
      listPane.frame(minWidth: 320, idealWidth: 420, maxWidth: 560, maxHeight: .infinity)
      detailPane.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle("Pull Requests")
    .navigationSubtitle(subtitle)
    .task {
      store.attach(app)
      await store.loadIfNeeded()
    }
    .onAppear {
      store.attach(app)
      store.retainLive()
    }
    .onDisappear { store.releaseLive() }
    .onChange(of: store.environments.map(\.environmentId)) {
      store.syncLive()
      store.reloadSoon(after: 0.2)
    }
  }

  private var subtitle: String {
    let count = store.groups().reduce(0) { $0 + $1.entries.count }
    return store.phase == .loaded || !store.rows.isEmpty ? "\(count) \(store.prefs.state == .all ? "" : store.prefs.state.rawValue + " ")pull request\(count == 1 ? "" : "s")" : ""
  }

  // MARK: Detail

  @ViewBuilder private var detailPane: some View {
    if let target = store.selected {
      PullRequestDetailView(app: app, target: target, open: { store.selected = $0 }).id(target.id)
    } else {
      ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull", description: Text("Its description, checks, changes and conversation appear here."))
    }
  }

  // MARK: List

  private var listPane: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      listBody
    }
  }

  private var controls: some View {
    @Bindable var store = store
    return VStack(spacing: 8) {
      HStack(spacing: 8) {
        Picker("Involvement", selection: $store.prefs.involvement) {
          Text("All").tag(PullRequestInvolvement.all)
          Text("Reviewing").tag(PullRequestInvolvement.reviewing)
          Text("Authored").tag(PullRequestInvolvement.authored)
        }
        .pickerStyle(.segmented).labelsHidden()
        Menu {
          Picker("State", selection: $store.prefs.state) {
            Text("Open").tag(PullRequestListState.open)
            Text("Closed").tag(PullRequestListState.closed)
            Text("Merged").tag(PullRequestListState.merged)
            Text("All").tag(PullRequestListState.all)
          }
          .pickerStyle(.inline)
        } label: {
          Text(stateTitle)
        }
        .menuStyle(.button).fixedSize().help("State")
      }
      HStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
          TextField("Search, or label:bug author:me", text: $store.query).textFieldStyle(.plain)
          if !store.query.isEmpty {
            Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Clear search")
          }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
        sortMenu
        filtersMenu
        Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help("Refresh").accessibilityLabel("Refresh pull requests").disabled(store.refreshing)
      }
      if store.hasFilters { activeFilters }
    }
    .padding(10)
  }

  private var stateTitle: String {
    switch store.prefs.state {
    case .open: "Open"
    case .closed: "Closed"
    case .merged: "Merged"
    default: "All states"
    }
  }

  private var sortMenu: some View {
    @Bindable var store = store
    return Menu {
      Picker("Sort", selection: $store.prefs.sort) {
        ForEach(PullRequestListSort.allCases, id: \.rawValue) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: "arrow.up.arrow.down")
    }
    .menuStyle(.button).fixedSize().help("Sort: \(store.prefs.sort.title)").accessibilityLabel("Sort")
  }

  private var filtersMenu: some View {
    @Bindable var store = store
    let facets = store.facets
    return Menu {
      Menu("Project") {
        Picker("Project", selection: $store.prefs.projectKey) {
          Text("All projects").tag(String?.none)
          ForEach(store.projectOptions, id: \.key) { Text($0.label).tag(String?.some($0.key)) }
        }
        .pickerStyle(.inline)
      }
      Menu("Review") {
        Picker("Review", selection: $store.prefs.review) {
          Text("Any").tag(PullRequestListFiltersReview?.none)
          Text("Approved").tag(PullRequestListFiltersReview?.some(.approved))
          Text("Changes requested").tag(PullRequestListFiltersReview?.some(.changesRequested))
          Text("Review required").tag(PullRequestListFiltersReview?.some(.reviewRequired))
          Text("No reviews").tag(PullRequestListFiltersReview?.some(.noneValue))
        }
        .pickerStyle(.inline)
      }
      Menu("Checks") {
        Picker("Checks", selection: $store.prefs.checks) {
          Text("Any").tag(PullRequestListFiltersChecks?.none)
          Text("Passing").tag(PullRequestListFiltersChecks?.some(.passing))
          Text("Failing").tag(PullRequestListFiltersChecks?.some(.failing))
        }
        .pickerStyle(.inline)
      }
      Menu("Drafts") {
        Picker("Drafts", selection: $store.prefs.draft) {
          Text("Include drafts").tag(PullRequestListFiltersDraft?.none)
          Text("Only drafts").tag(PullRequestListFiltersDraft?.some(.only))
          Text("Hide drafts").tag(PullRequestListFiltersDraft?.some(.hide))
        }
        .pickerStyle(.inline)
      }
      if !facets.authors.isEmpty {
        Menu("Author") {
          Picker("Author", selection: $store.prefs.author) {
            Text("Anyone").tag(String?.none)
            ForEach(facets.authors.prefix(15)) { Text("\($0.actor.login) (\($0.count))").tag(String?.some($0.actor.login)) }
          }
          .pickerStyle(.inline)
        }
      }
      if !facets.labels.isEmpty {
        Menu("Labels") {
          ForEach(facets.labels.prefix(20)) { facet in
            Toggle("\(facet.name) (\(facet.count))", isOn: Binding(
              get: { store.prefs.labels.contains(facet.name) },
              set: { on in if on { store.prefs.labels.append(facet.name) } else { store.prefs.labels.removeAll { $0 == facet.name } } }))
          }
        }
      }
      if store.hasFilters {
        Divider()
        Button("Clear Filters") { store.clearFilters() }
      }
    } label: {
      Image(systemName: store.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
    }
    .menuStyle(.button).fixedSize().help("Filters").accessibilityLabel("Filters")
  }

  private var activeFilters: some View {
    HStack(spacing: 6) {
      let prefs = store.prefs
      if let key = prefs.projectKey { chip(store.projectOptions.first { $0.key == key }?.label ?? "Project") }
      if let review = prefs.review { chip("review: \(review.rawValue)") }
      if let checks = prefs.checks { chip("checks: \(checks.rawValue)") }
      if let draft = prefs.draft { chip(draft == .only ? "drafts only" : "no drafts") }
      if let author = prefs.author { chip("author: \(author)") }
      ForEach(prefs.labels, id: \.self) { chip("label: \($0)") }
      Spacer(minLength: 0)
      Button("Clear") { store.clearFilters() }.buttonStyle(.link).font(.caption)
    }
    .font(.caption)
  }

  private func chip(_ text: String) -> some View {
    Text(text).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
  }

  // MARK: Rows

  @ViewBuilder private var listBody: some View {
    let groups = store.groups()
    if store.rows.isEmpty, store.phase == .idle || store.phase == .loading {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if store.rows.isEmpty, case .failed(let message) = store.phase {
      unavailable(message)
    } else if groups.isEmpty {
      empty
    } else {
      list(groups)
    }
  }

  private func list(_ groups: [PullRequestGroup]) -> some View {
    List(selection: Binding(get: { store.selected?.id }, set: { id in store.selected = id.flatMap { PullRequestTarget(id: $0) } })) {
      ForEach(groups) { group in
        Section {
          ForEach(group.entries) { row in
            PullRequestRowView(row: row, stat: store.stat(for: row)).tag(PullRequestTarget(row).id)
              .contextMenu { rowMenu(row) }
          }
        } header: {
          if groups.count > 1 || group.key != .others { Text("\(group.title) \u{00B7} \(group.entries.count)") }
        }
      }
      if !store.issues.isEmpty {
        Section("Not everything loaded") {
          ForEach(store.issues) { issue in
            Label { Text("\(issue.title): \(issue.message)").font(.caption) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
          }
        }
      }
      if !store.nextCursors.isEmpty {
        Button { Task { await store.loadMore() } } label: {
          HStack { Spacer(); if store.loadingMore { ProgressView().controlSize(.small) } else { Text("Load more") }; Spacer() }
        }
        .buttonStyle(.borderless).disabled(store.loadingMore)
      }
    }
    .listStyle(.inset)
  }

  @ViewBuilder private func rowMenu(_ row: EnvironmentPullRequestEntry) -> some View {
    Button("Open on the Host") { if let url = URL(string: row.entry.url) { NSWorkspace.shared.open(url) } }
    Button("Copy Number") { PullRequestStyle.copy("#\(row.entry.number)") }
    Button("Copy Link") { PullRequestStyle.copy(row.entry.url) }
    Button("Copy Reference") { PullRequestStyle.copy("\(row.entry.repository)#\(row.entry.number)") }
  }

  private var empty: some View {
    VStack {
      if store.hasFilters || store.prefs.involvement != .all {
        ContentUnavailableView {
          Label("No pull requests match", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("Nothing fits the current filters.")
        } actions: {
          Button("Clear Filters") { store.clearFilters(); store.prefs.involvement = .all }
        }
      } else if let issue = store.issues.first {
        unavailable(issue.message)
      } else {
        ContentUnavailableView("No \(store.prefs.state == .all ? "" : store.prefs.state.rawValue + " ")pull requests", systemImage: "arrow.triangle.pull", description: Text("Nothing to show for the projects on the connected environments."))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func unavailable(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Could not load pull requests", systemImage: "arrow.triangle.pull")
    } description: {
      Text(message)
    } actions: {
      Button("Retry") { store.refreshNow() }
    }
  }
}

/// One pull request in the list: lifecycle glyph, title with the diff counts, then repository, author and time, and labels.
struct PullRequestRowView: View {
  let row: EnvironmentPullRequestEntry
  let stat: (additions: Int, deletions: Int)

  var body: some View {
    let entry = row.entry
    HStack(alignment: .top, spacing: 8) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: PullRequestStyle.symbol(entry.state, draft: entry.isDraft)).foregroundStyle(PullRequestStyle.tint(entry.state, draft: entry.isDraft))
          .help(PullRequestStyle.title(entry.state, draft: entry.isDraft))
        if entry.state == .open, entry.mergeability == .conflicting {
          Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.orange).offset(x: 4, y: 3).help("Merge conflicts")
        }
      }
      .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(entry.title).fontWeight(.medium).lineLimit(1)
          Spacer(minLength: 4)
          if let symbol = PullRequestStyle.reviewSymbol(entry.reviewDecision) { Image(systemName: symbol.name).foregroundStyle(symbol.tint).help(symbol.help) }
          if let symbol = PullRequestStyle.checksSymbol(entry.checksState) { Image(systemName: symbol.name).foregroundStyle(symbol.tint).help(symbol.help) }
          if stat.additions + stat.deletions > 0 { DiffStat(additions: stat.additions, deletions: stat.deletions).font(.caption) }
        }
        HStack(spacing: 6) {
          Text("#\(entry.number)").font(.caption.monospaced())
          Text(entry.repository).lineLimit(1).truncationMode(.middle)
          if let author = entry.author {
            PullRequestAvatar(actor: author, size: 13)
            Text(author.login).lineLimit(1)
          }
          Spacer(minLength: 4)
          if let stack = entry.stack { Label("\(stack.position)/\(stack.size)", systemImage: "square.stack.3d.up").labelStyle(.titleAndIcon).help("Layer \(stack.position) of \(stack.size) in a stack") }
          if entry.viewerReviewRequested { Image(systemName: "eye").help("Your review is requested") }
          Text(PullRequestStyle.relative(entry.updatedAt)).help(PullRequestStyle.absolute(entry.updatedAt))
        }
        .font(.caption).foregroundStyle(Palette.muted)
        if !entry.labels.isEmpty {
          HStack(spacing: 4) {
            ForEach(entry.labels.prefix(4), id: \.name) { PullRequestLabelChip(name: $0.name, color: $0.color) }
            if entry.labels.count > 4 { Text("+\(entry.labels.count - 4)").font(.caption2).foregroundStyle(Palette.muted) }
          }
        }
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(entry.title), #\(entry.number), \(PullRequestStyle.title(entry.state, draft: entry.isDraft))")
  }
}
