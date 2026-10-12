import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

enum PullRequestTab: String, CaseIterable, Identifiable {
  case summary = "Summary"
  case code = "Code"
  case timeline = "Timeline"
  var id: String { rawValue }
}

/// A pull request: header with its state and merge controls, then Summary, Code and Timeline. Used by the inbox and, with
/// `compact`, by the right panel's pull request tab.
struct PullRequestDetailView: View {
  let app: AppModel
  let target: PullRequestTarget
  /// Opens another pull request (a stack layer): the inbox selects it, a panel tab opens a new tab.
  var open: (PullRequestTarget) -> Void = { _ in }
  /// The panel's tab is already inside a thread; the inbox pane has room for more.
  var compact = false

  private let store = PullRequestsStore.shared
  @State private var model: PullRequestDetailModel
  @State private var tab: PullRequestTab = .summary
  @State private var confirming: PendingConfirmation?
  @State private var reviewing = false
  @State private var editing = false
  @State private var linking = false
  @AppStorage("pullRequests.mergeMethod") private var preferredMethod = ""

  struct PendingConfirmation: Identifiable {
    var action: PullRequestAction
    var method: PullRequestMergeMethod?
    var id: String { action.rawValue }
  }

  init(app: AppModel, target: PullRequestTarget, compact: Bool = false, open: @escaping (PullRequestTarget) -> Void = { _ in }) {
    self.app = app
    self.target = target
    self.compact = compact
    self.open = open
    _model = State(initialValue: PullRequestDetailModel(target: target, runtime: app.runtime))
  }

  var body: some View {
    VStack(spacing: 0) {
      switch model.phase {
      case .loading:
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message, let kind):
        failure(message, kind)
      case .ready:
        if let detail = model.detail {
          header(detail)
          if let notice = model.notice { noticeBar(notice) }
          Divider()
          content(detail)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: "\(target.id)#\(store.revision)") { await model.load(fresh: store.revision > 0) }
    .onAppear { store.retainLive() }
    .onDisappear { store.releaseLive() }
    .onChange(of: store.requestedTab) { _, requested in
      if let requested { tab = requested; store.requestedTab = nil }
    }
    .confirmationDialog(
      confirming.map { PullRequestDetailLogic.actionTitle($0.action) + "?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
      titleVisibility: .visible, presenting: confirming
    ) { pending in
      Button(confirmTitle(pending), role: pending.action == .close ? .destructive : nil) {
        Task { await model.perform(pending.action, method: pending.method) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { pending in
      Text(confirmMessage(pending))
    }
    .sheet(isPresented: $reviewing) {
      if let detail = model.detail { PullRequestReviewSheet(model: model, detail: detail) }
    }
    .sheet(isPresented: $editing) {
      if let detail = model.detail { PullRequestEditSheet(model: model, detail: detail) }
    }
  }

  // MARK: Failure

  private func failure(_ message: String, _ kind: PullRequestsFailure.Kind) -> some View {
    ContentUnavailableView {
      Label(kind == .notFound ? "Pull request not found" : "Could not load this pull request", systemImage: "arrow.triangle.pull")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again") { Task { await model.load(fresh: true) } }
      if let url = hostURL { Button("Open on the Host") { NSWorkspace.shared.open(url) } }
    }
  }

  private var hostURL: URL? {
    if let detail = model.detail, let url = URL(string: detail.url) { return url }
    return ChangeRequestURL.webURL(kind: "github", host: target.host, repository: target.repository, number: target.number).flatMap { URL(string: $0) }
  }

  // MARK: Header

  private func header(_ detail: PullRequestDetail) -> some View {
    let checks = PullRequestDetailLogic.classify(detail.checks)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        PullRequestStatePill(state: detail.state, draft: detail.isDraft)
        Text("\(detail.repository) #\(detail.number)").font(.callout.monospaced()).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        if model.pending.isEmpty == false { ProgressView().controlSize(.small) }
        Button { Task { await model.load(fresh: true) } } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help("Refresh").accessibilityLabel("Refresh pull request")
        if let url = URL(string: detail.url) {
          Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
            .buttonStyle(.borderless).help("Open on \(detail.provider.rawValue.capitalized)").accessibilityLabel("Open on the host")
        }
        actionsMenu(detail)
      }
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(detail.title).font(.title3.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if detail.capabilities.edit?.changeRequest == true, detail.viewerPermissions.comment || model.isMine(detail.author) {
          Button { editing = true } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless).help("Edit title and description").accessibilityLabel("Edit title and description")
        }
      }
      HStack(spacing: 8) {
        PullRequestAvatar(actor: detail.author)
        Text(detail.author?.login ?? "ghost").fontWeight(.medium)
        Text("\(detail.headBranch) \u{2192} \(detail.baseBranch)").font(.callout.monospaced()).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.callout)
      HStack(spacing: 10) {
        DiffStat(additions: detail.additions, deletions: detail.deletions)
        Text("\(detail.changedFiles) \(detail.changedFiles == 1 ? "file" : "files")").foregroundStyle(Palette.muted)
        Text("updated \(PullRequestStyle.relative(detail.updatedAt))").foregroundStyle(Palette.muted)
        if let symbol = PullRequestStyle.checksSymbol(detail.checks.isEmpty ? nil : checksState(checks)) {
          Image(systemName: symbol.name).foregroundStyle(symbol.tint).help(PullRequestDetailLogic.describe(detail.checks))
        }
        Spacer(minLength: 0)
      }
      .font(.caption)
      controls(detail, checks: checks)
      Picker("", selection: $tab) {
        ForEach(PullRequestTab.allCases) { Text(label(for: $0)).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden()
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  private func label(for tab: PullRequestTab) -> String {
    switch tab {
    case .summary: "Summary"
    case .code: model.detail.map { "Code (\($0.changedFiles))" } ?? "Code"
    case .timeline: model.activity.map { "Timeline (\($0.comments.count + $0.commits.count))" } ?? "Timeline"
    }
  }

  private func checksState(_ summary: PullRequestChecksSummary) -> PullRequestChecksState? {
    switch summary {
    case .passing: .passing
    case .failing: .failing
    case .pending: .pending
    case .none: nil
    }
  }

  private func noticeBar(_ notice: PullRequestDetailModel.Notice) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(notice.isError ? .orange : .green)
      VStack(alignment: .leading, spacing: 2) {
        Text(notice.title).fontWeight(.medium)
        if let detail = notice.detail, !detail.isEmpty { Text(detail).foregroundStyle(Palette.muted).textSelection(.enabled) }
      }
      Spacer(minLength: 0)
      Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
    }
    .font(.callout)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(Palette.surface)
  }

  // MARK: Merge area and actions

  @ViewBuilder private func controls(_ detail: PullRequestDetail, checks: PullRequestChecksSummary) -> some View {
    let control = PullRequestDetailLogic.primaryControl(detail, checks: checks)
    let methods = PullRequestDetailLogic.allowedMergeMethods(detail)
    let method = PullRequestDetailLogic.selectedMergeMethod(allowed: methods, preferred: preferred ?? defaultMethod)
    HStack(spacing: 8) {
      switch control {
      case .merge?:
        Menu {
          ForEach(methods, id: \.rawValue) { candidate in
            Button { preferredMethod = candidate.rawValue } label: {
              if candidate == method { Label(PullRequestDetailLogic.mergeLabel(candidate), systemImage: "checkmark") } else { Text(PullRequestDetailLogic.mergeLabel(candidate)) }
            }
          }
        } label: {
          Text(PullRequestDetailLogic.mergeLabel(method))
        } primaryAction: {
          confirming = PendingConfirmation(action: .merge, method: method)
        }
        .menuStyle(.button).buttonStyle(.borderedProminent).tint(.green).fixedSize().help("Merge method: \(PullRequestDetailLogic.mergeLabel(method))")
        .disabled(!model.pending.isEmpty)
      case .ready?:
        Button("Ready for review") { Task { await model.perform(.ready) } }.buttonStyle(.borderedProminent).disabled(!model.pending.isEmpty)
      case .enableAutoMerge?:
        Button("Enable auto-merge") { confirming = PendingConfirmation(action: .enableAutoMerge, method: method) }.disabled(!model.pending.isEmpty)
      case .autoMergeArmed?:
        Label("Auto-merge on" + (detail.autoMergeMethod.map { " (\($0.rawValue))" } ?? ""), systemImage: "bolt.fill").foregroundStyle(.green)
        if PullRequestDetailLogic.canPerform(.disableAutoMerge, in: detail) { Button("Disable") { Task { await model.perform(.disableAutoMerge) } } }
      case .resolve?:
        Label("Has merge conflicts", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      case .merged?:
        Label("Merged \(PullRequestStyle.relative(detail.mergedAt))", systemImage: "arrow.triangle.merge").foregroundStyle(.purple)
      case .closed?:
        Label("Closed \(PullRequestStyle.relative(detail.closedAt))", systemImage: "xmark.circle").foregroundStyle(.red)
        if PullRequestDetailLogic.canPerform(.reopen, in: detail) { Button("Reopen") { Task { await model.perform(.reopen) } }.disabled(!model.pending.isEmpty) }
      case nil:
        EmptyView()
      }
      if detail.state == .open, detail.baseComparison == .behind, PullRequestDetailLogic.canPerform(.updateBranch, in: detail) {
        Button { Task { await model.perform(.updateBranch) } } label: { Label("Update branch", systemImage: "arrow.down.to.line") }
          .help("Behind \(detail.baseBranch)\(detail.behindBy.map { " by \($0)" } ?? "")").disabled(!model.pending.isEmpty)
      }
      Spacer(minLength: 0)
      if detail.state == .open, !(detail.viewerPermissions.verdicts.isEmpty && !detail.viewerPermissions.comment) {
        Button { reviewing = true } label: {
          let count = store.drafts(for: target).count
          Label(count > 0 ? "Review (\(count))" : "Review\u{2026}", systemImage: "text.bubble")
        }
        .help("Approve, request changes or comment")
      }
    }
    .controlSize(.small)
  }

  private var preferred: PullRequestMergeMethod? {
    switch preferredMethod {
    case "merge": .merge
    case "squash": .squash
    case "rebase": .rebase
    default: nil
    }
  }

  private var defaultMethod: PullRequestMergeMethod? {
    app.runtime.serverConfigs[target.environmentId]?.config.settings.pullRequestMergeMethod
  }

  private func confirmTitle(_ pending: PendingConfirmation) -> String {
    pending.action == .merge ? (pending.method.map(PullRequestDetailLogic.mergeLabel) ?? "Merge") : PullRequestDetailLogic.actionTitle(pending.action)
  }

  private func confirmMessage(_ pending: PendingConfirmation) -> String {
    let name = "\(target.repository) #\(target.number)"
    switch pending.action {
    case .merge: return "This merges \(name) into \(model.detail?.baseBranch ?? "the base branch") on the host. It cannot be undone from here."
    case .close: return "This closes \(name) on the host without merging. You can reopen it later."
    case .enableAutoMerge: return "\(name) merges by itself once its required checks pass."
    default: return "This changes \(name) on the host."
    }
  }

  private func actionsMenu(_ detail: PullRequestDetail) -> some View {
    Menu {
      Button("Copy Number") { PullRequestStyle.copy("#\(detail.number)") }
      Button("Copy Link") { PullRequestStyle.copy(detail.url) }
      Button("Copy Reference") { PullRequestStyle.copy("\(detail.repository)#\(detail.number)") }
      Divider()
      if let thread = app.selection, app.runtime.threadPullRequestLinkMode(thread.environmentId) != .unsupported {
        Button("Link to Current Thread\u{2026}") { store.linkRequest = thread }
      }
      let actions: [PullRequestAction] = [.draft, .updateBranch, .revert, .approveWorkflows, .close]
      let offered = actions.filter { PullRequestDetailLogic.canPerform($0, in: detail) && isOffered($0, detail) }
      if !offered.isEmpty { Divider() }
      ForEach(offered, id: \.rawValue) { action in
        Button(PullRequestDetailLogic.actionTitle(action), role: action == .close ? .destructive : nil) {
          if action == .close { confirming = PendingConfirmation(action: .close, method: nil) } else { Task { await model.perform(action) } }
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
  }

  /// Which of the host's actions make sense in the current state.
  private func isOffered(_ action: PullRequestAction, _ detail: PullRequestDetail) -> Bool {
    switch action {
    case .draft: detail.state == .open && !detail.isDraft
    case .updateBranch: detail.state == .open
    case .revert: detail.state == .merged
    case .close: detail.state == .open
    case .approveWorkflows: (detail.workflowApprovalsRequired ?? 0) > 0
    default: true
    }
  }

  // MARK: Tabs

  @ViewBuilder private func content(_ detail: PullRequestDetail) -> some View {
    switch tab {
    case .summary:
      PullRequestSummaryView(app: app, model: model, detail: detail, open: open)
    case .code:
      PullRequestCodeView(app: app, model: model, detail: detail)
    case .timeline:
      PullRequestTimelineView(model: model, detail: detail)
    }
  }
}
