import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Timeline

/// Detail column: the selected thread's timeline with its composer, or an empty state.
struct ReadingWindow: View {
  @Environment(AppModel.self) private var app
  @Environment(RightPanelStore.self) private var panel

  var body: some View {
    Group {
      #if DEBUG
      if let fixture = TimelineFixture.projection {
        TimelineFixtureReader(app: app, panel: panel, projection: fixture)
      } else {
        content
      }
      #else
      content
      #endif
    }
    .background(Palette.canvas)
    .modifier(SourceControlHost())
  }

  @ViewBuilder private var content: some View {
    Group {
      if let key = app.selection {
        if let detail = app.detail, detail.key == key {
          ThreadReader(app: app, detail: detail, panel: panel).id(key)
        } else {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if let draft = app.draft {
        DraftReader(draft: draft).id(draft.key)
      } else {
        ContentUnavailableView {
          Label("No thread selected", systemImage: "text.bubble")
        } description: {
          Text("Pick a thread in the sidebar, or start a new one.")
        }
      }
    }
  }
}

struct ThreadReader: View {
  let app: AppModel
  let detail: ThreadDetailModel
  let panel: RightPanelStore
  @State private var model: TimelineModel
  @State private var host: TimelineHost
  @State private var diff: DiffPanelModel

  init(app: AppModel, detail: ThreadDetailModel, panel: RightPanelStore) {
    self.app = app
    self.detail = detail
    self.panel = panel
    let model = TimelineModel(detail: detail)
    let host = TimelineHost(key: detail.key, workspaceRoot: app.workspaceRoot(of: detail.key), assets: app.assets)
    host.toggleTurn = { [model] in model.toggleTurn($0) }
    host.toggleWorkGroup = { [model] in model.toggleWorkGroup($0) }
    host.toggleLocal = { [model] in model.toggleLocal($0) }
    host.toggleAttempt = { [model] in model.toggleAttempt($0) }
    host.openThread = { [weak app, key = detail.key] threadId in
      app?.selection = ScopedThreadKey(environmentId: key.environmentId, threadId: threadId)
    }
    host.openLink = { [weak app, key = detail.key] in app?.open($0, in: key) }
    host.openDiff = { [weak panel, key = detail.key] turnId, path in panel?.revealDiff(turnId: turnId.rawValue, filePath: path, in: key) }
    host.cancelWorktreeSetup = { [weak app, key = detail.key] in app?.sourceControl.cancelWorktreeSetup(key) }
    _model = State(initialValue: model)
    _host = State(initialValue: host)
    _diff = State(initialValue: DiffPanelModel(fetch: app.diffFetcher(for: detail.key)))
  }

  var body: some View {
    let shell = app.runtime.threadShell(detail.key)?.shell
    RightPanelLayout(key: detail.key, store: panel) {
      chat(shell: shell)
    } panel: {
      RightPanelView(app: app, key: detail.key, turns: model.checkpoints, store: panel, diff: diff)
    }
    .navigationTitle(shell?.title ?? "Thread")
    .navigationSubtitle(subtitle(shell))
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) { SourceControlToolbarItems(key: detail.key) }
      ToolbarItem(placement: .primaryAction) { SessionStatusLabel(shell: shell) }
      ToolbarItemGroup(placement: .primaryAction) {
        Button { panel.toggle(.diff, in: detail.key) } label: { Label("Diff", systemImage: "plusminus") }
          .help("Show or hide the diff")
        Button { panel.toggleVisibility(detail.key) } label: { Label("Panel", systemImage: "sidebar.right") }
          .help("Show or hide the right panel")
      }
    }
    // The bootstrap's worktree stages go to the card under the first message.
    .task(id: detail.key) { await app.sourceControl.followWorktreeSetup(detail.key) { [model] in model.worktreeSetup = $0 } }
    .onChange(of: detail.thread?.latestTurn?.completedAt, initial: true) { _, completedAt in
      // A turn finishing under the reader's eyes is not "unread", focused or not.
      Task { await app.runtime.markThreadRead(detail.key, completedAt: completedAt) }
    }
  }

  private func chat(shell: V1.OrchestrationThreadShell?) -> some View {
    VStack(spacing: 0) {
      ZStack {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "T3Timeline") == "lazy" {
          ScrollView {
            LazyVStack(spacing: 0) { ForEach(model.items) { TimelineRowContainer(item: $0) } }
              .environment(\.timelineHost, host)
          }
          .defaultScrollAnchor(.bottom)
        } else {
          TimelineTable(items: model.items, host: host, hasOlder: detail.hasOlderTurns) { Task { await detail.loadOlderTurns() } }
        }
        #else
        TimelineTable(items: model.items, host: host, hasOlder: detail.hasOlderTurns) { Task { await detail.loadOlderTurns() } }
        #endif
        overlay
      }
      if let error = detail.thread?.session?.lastError, shell?.session?.status == .error {
        ErrorBanner(title: "The provider reported an error", detail: error)
          .padding(.horizontal, 20).padding(.bottom, 8)
      }
      ComposerHost(key: detail.key)
    }
  }

  @ViewBuilder private var overlay: some View {
    switch detail.state.status {
    case .empty where detail.thread == nil, .synchronizing where detail.thread == nil:
      ProgressView().controlSize(.small)
    case .deleted:
      ContentUnavailableView("This thread was deleted", systemImage: "trash")
    default:
      if model.items.isEmpty && detail.thread != nil && detail.state.status == .live {
        Text("No messages yet").foregroundStyle(Palette.muted)
      }
    }
  }

  private func subtitle(_ shell: V1.OrchestrationThreadShell?) -> String {
    guard let shell, let thread = app.runtime.threadShell(detail.key) else { return "" }
    var parts = [app.projectTitle(of: thread)]
    if let branch = shell.branch, !branch.isEmpty { parts.append(branch) }
    return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
  }
}

struct SessionStatusLabel: View {
  let shell: V1.OrchestrationThreadShell?

  var body: some View {
    if let shell {
      let status = ThreadList.status(shell)
      Label(Self.title(status), systemImage: Self.symbol(status))
        .labelStyle(.titleAndIcon)
        .foregroundStyle(Self.tint(status))
        .help(shell.modelSelection.model)
    }
  }

  static func title(_ status: ThreadRowStatus) -> String {
    switch status {
    case .approval: "Waiting for approval"
    case .input: "Waiting for input"
    case .working: "Working"
    case .monitoring: "Monitoring"
    case .failed: "Error"
    case .ready: "Ready"
    }
  }

  static func symbol(_ status: ThreadRowStatus) -> String {
    switch status {
    case .approval: "exclamationmark.shield"
    case .input: "questionmark.bubble"
    case .working: "ellipsis.circle"
    case .monitoring: "binoculars"
    case .failed: "exclamationmark.triangle"
    case .ready: "checkmark.circle"
    }
  }

  static func tint(_ status: ThreadRowStatus) -> Color {
    switch status {
    case .approval: .orange
    case .input: .blue
    case .working: .accentColor
    case .failed: .red
    case .monitoring, .ready: .secondary
    }
  }
}
