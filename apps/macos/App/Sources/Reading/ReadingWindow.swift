import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Timeline

/// Detail column: the selected thread's timeline with its composer, or an empty state.
struct ReadingWindow: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    Group {
      if let key = app.selection {
        if let detail = app.detail, detail.key == key {
          ThreadReader(app: app, detail: detail).id(key)
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
    .background(Palette.canvas)
  }
}

struct ThreadReader: View {
  let app: AppModel
  let detail: ThreadDetailModel
  @State private var model: TimelineModel
  @State private var host: TimelineHost

  init(app: AppModel, detail: ThreadDetailModel) {
    self.app = app
    self.detail = detail
    let model = TimelineModel(detail: detail)
    let host = TimelineHost(key: detail.key, workspaceRoot: app.workspaceRoot(of: detail.key), assets: app.assets)
    host.toggleTurn = { [model] in model.toggleTurn($0) }
    host.toggleWorkGroup = { [model] in model.toggleWorkGroup($0) }
    host.toggleLocal = { [model] in model.toggleLocal($0) }
    host.openLink = { [weak app, key = detail.key] in app?.open($0, in: key) }
    _model = State(initialValue: model)
    _host = State(initialValue: host)
  }

  var body: some View {
    let shell = app.runtime.threadShell(detail.key)?.shell
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
    .navigationTitle(shell?.title ?? "Thread")
    .navigationSubtitle(subtitle(shell))
    .toolbar {
      ToolbarItem(placement: .primaryAction) { SessionStatusLabel(shell: shell) }
    }
    .onChange(of: detail.thread?.latestTurn?.completedAt, initial: true) { _, completedAt in
      // A turn finishing under the reader's eyes is not "unread", focused or not.
      Task { await app.runtime.markThreadRead(detail.key, completedAt: completedAt) }
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

  private func subtitle(_ shell: OrchestrationThreadShell?) -> String {
    guard let shell, let thread = app.runtime.threadShell(detail.key) else { return "" }
    var parts = [app.projectTitle(of: thread)]
    if let branch = shell.branch, !branch.isEmpty { parts.append(branch) }
    return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
  }
}

struct SessionStatusLabel: View {
  let shell: OrchestrationThreadShell?

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
