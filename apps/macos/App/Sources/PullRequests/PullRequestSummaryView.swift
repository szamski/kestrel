import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Markdown

/// A pull request's description rendered as Markdown; web links open in the browser.
struct PullRequestMarkdown: View {
  let text: String

  var body: some View {
    MarkdownView(text, options: MarkdownOptions(), onLink: { link in
      if case .web(let url) = link { NSWorkspace.shared.open(url) }
    })
  }
}

/// Reactions on a body or comment: a chip per reaction already given, and a menu to add one.
struct PullRequestReactionBar: View {
  let reactions: [PullRequestReaction]
  let canReact: Bool
  let toggle: (PullRequestReactionContent, Bool) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(reactions.filter { $0.count > 0 }, id: \.content.rawValue) { reaction in
        Button { if canReact { toggle(reaction.content, !reaction.viewerHasReacted) } } label: {
          Text("\(PullRequestStyle.emoji(reaction.content)) \(reaction.count)").font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(reaction.viewerHasReacted ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(reaction.actors.prefix(5).joined(separator: ", "))
        .accessibilityLabel("\(reaction.content.rawValue), \(reaction.count)")
      }
      if canReact {
        Menu {
          ForEach(PullRequestStyle.reactionOrder, id: \.rawValue) { content in
            let held = reactions.first { $0.content == content }?.viewerHasReacted == true
            Button { toggle(content, !held) } label: {
              if held { Label(PullRequestStyle.emoji(content), systemImage: "checkmark") } else { Text(PullRequestStyle.emoji(content)) }
            }
          }
        } label: { Image(systemName: "face.smiling") }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Add reaction")
      }
    }
  }
}

/// The overview: description, merge status, checks, reviewers, labels, the stack it belongs to and the threads linked to it.
struct PullRequestSummaryView: View {
  let app: AppModel
  let model: PullRequestDetailModel
  let detail: PullRequestDetail
  let open: (PullRequestTarget) -> Void

  @State private var checksExpanded = false
  @State private var labelsOpen = false
  @State private var reviewersOpen = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        statusRows
        description
        checks
        reviewers
        labels
        stack
        linkedThreads
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer(minLength: 0)
        trailing()
      }
      content()
    }
  }

  // MARK: Merge status

  @ViewBuilder private var statusRows: some View {
    VStack(alignment: .leading, spacing: 6) {
      if PullRequestDetailLogic.isConflicting(detail) {
        Label("This branch has conflicts with \(detail.baseBranch) that must be resolved before it can merge.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      if detail.state == .open, detail.baseComparison == .behind {
        Label("This branch is \(detail.behindBy.map { "\($0) commit\($0 == 1 ? "" : "s") " } ?? "")behind \(detail.baseBranch).", systemImage: "arrow.down.to.line").foregroundStyle(Palette.muted)
      }
      if let required = detail.workflowApprovalsRequired, required > 0 {
        Label("\(required) workflow run\(required == 1 ? "" : "s") awaiting approval.", systemImage: "hourglass").foregroundStyle(.orange)
      }
    }
    .font(.callout)
  }

  // MARK: Description

  private var description: some View {
    section("Description") {
      EmptyView()
    } content: {
      let body = PullRequestDetailLogic.visibleBody(detail.body)
      if let body { PullRequestMarkdown(text: body) } else { Text("No description provided.").foregroundStyle(Palette.muted) }
      if detail.capabilities.reactions == true || !(model.activity?.reactions ?? []).isEmpty {
        PullRequestReactionBar(reactions: model.activity?.reactions ?? [], canReact: detail.capabilities.reactions == true && detail.viewerPermissions.comment) { content, reacted in
          Task { await model.react(content, subject: nil, reacted: reacted) }
        }
      }
    }
  }

  // MARK: Checks

  private var checks: some View {
    let summary = PullRequestDetailLogic.classify(detail.checks)
    let groups = PullRequestDetailLogic.grouped(detail.checks)
    return section("Checks") {
      if !detail.checks.isEmpty {
        Button(checksExpanded ? "Hide" : "Show all") { checksExpanded.toggle() }.buttonStyle(.link).font(.callout)
      }
    } content: {
      HStack(spacing: 6) {
        if let symbol = PullRequestStyle.checksSymbol(summary == .none ? nil : (summary == .passing ? .passing : summary == .failing ? .failing : .pending)) {
          Image(systemName: symbol.name).foregroundStyle(symbol.tint)
        }
        Text(PullRequestDetailLogic.describe(detail.checks)).font(.callout)
      }
      let shown = checksExpanded ? groups.attention + groups.running + groups.other : groups.attention
      ForEach(Array(shown.enumerated()), id: \.offset) { _, check in checkRow(check) }
    }
  }

  private func checkRow(_ check: PullRequestCheck) -> some View {
    let symbol = PullRequestStyle.checkSymbol(check.status)
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: symbol.name).foregroundStyle(symbol.tint).frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        if let url = check.url.flatMap({ URL(string: $0) }) {
          Button(check.name) { NSWorkspace.shared.open(url) }.buttonStyle(.link)
        } else {
          Text(check.name)
        }
        if let description = check.description, !description.isEmpty { Text(description).font(.caption).foregroundStyle(Palette.muted).lineLimit(2) }
      }
      if check.required == true { Text("Required").font(.caption2).foregroundStyle(Palette.muted).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
      Spacer(minLength: 0)
    }
    .font(.callout)
  }

  // MARK: Reviewers

  private struct ReviewerRow: Identifiable {
    var actor: PullRequestActor
    var outcome: PullRequestDetailLogic.ReviewOutcome?
    var stale: Bool
    var id: String { actor.login.lowercased() }
  }

  private var reviewerRows: [ReviewerRow] {
    let outcomes = PullRequestDetailLogic.latestReviewOutcomes(model.activity?.comments ?? [], commits: model.activity?.commits ?? [])
    var rows: [ReviewerRow] = outcomes.compactMap { entry in entry.actor.map { ReviewerRow(actor: $0, outcome: entry.outcome, stale: entry.stale) } }
    for requested in detail.reviewers where !rows.contains(where: { $0.id == requested.login.lowercased() }) {
      rows.append(ReviewerRow(actor: requested, outcome: nil, stale: false))
    }
    return rows
  }

  private var reviewers: some View {
    section("Reviewers") {
      if detail.viewerPermissions.requestReviewers, detail.capabilities.reviewers.request {
        Button("Request\u{2026}") { reviewersOpen = true }.buttonStyle(.link).font(.callout)
          .popover(isPresented: $reviewersOpen, arrowEdge: .bottom) { ReviewerPicker(model: model) }
      }
    } content: {
      if reviewerRows.isEmpty {
        Text("No reviewers requested.").foregroundStyle(Palette.muted).font(.callout)
      }
      ForEach(reviewerRows) { row in
        HStack(spacing: 8) {
          PullRequestAvatar(actor: row.actor)
          Text(row.actor.login).font(.callout)
          Spacer(minLength: 0)
          switch row.outcome {
          case .approved?: Label(row.stale ? "Approved (outdated)" : "Approved", systemImage: "checkmark.seal.fill").foregroundStyle(row.stale ? Color.secondary : .green)
          case .changesRequested?: Label(row.stale ? "Changes requested (outdated)" : "Changes requested", systemImage: "exclamationmark.bubble.fill").foregroundStyle(row.stale ? Color.secondary : .orange)
          default: Label("Requested", systemImage: "clock").foregroundStyle(Palette.muted)
          }
        }
        .font(.caption)
      }
    }
  }

  // MARK: Labels

  private var labels: some View {
    section("Labels") {
      if detail.capabilities.labels == true, detail.viewerPermissions.labels == true {
        Button("Edit\u{2026}") { labelsOpen = true }.buttonStyle(.link).font(.callout)
          .popover(isPresented: $labelsOpen, arrowEdge: .bottom) { LabelPicker(model: model) }
      }
    } content: {
      if detail.labels.isEmpty {
        Text("None yet.").foregroundStyle(Palette.muted).font(.callout)
      } else {
        PullRequestFlow(spacing: 6) { ForEach(detail.labels, id: \.name) { PullRequestLabelChip(name: $0.name, color: $0.color) } }
      }
    }
  }

  // MARK: Stack

  /// The host's stack, or what the threads' saved links say about it while that read is unavailable.
  private var stackLayers: PullRequestStack? {
    if let stack = model.stack { return stack }
    let links = app.runtime.shells[model.target.environmentId]?.snapshot?.threads.flatMap(\.pullRequests) ?? []
    return PullRequestDetailLogic.savedStack(from: links, host: model.target.host, repository: model.target.repository, number: model.target.number)
  }

  @ViewBuilder private var stack: some View {
    if let stack = stackLayers, stack.layers.count > 1 {
      section("Stack") {
        Text("\(stack.layers.count) layers on \(stack.base)").font(.caption).foregroundStyle(Palette.muted)
      } content: {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(stack.layers.enumerated().reversed()), id: \.element.number) { index, layer in
            let current = layer.number == detail.number
            Button {
              if !current {
                open(PullRequestTarget(environmentId: model.target.environmentId, projectId: model.target.projectId, host: model.target.host, repository: model.target.repository, number: layer.number))
              }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: PullRequestStyle.symbol(layer.state, draft: layer.isDraft == true)).foregroundStyle(PullRequestStyle.tint(layer.state, draft: layer.isDraft == true))
                Text("#\(layer.number)").font(.callout.monospaced()).foregroundStyle(Palette.muted)
                Text(layer.title ?? layer.headBranch).lineLimit(1).fontWeight(current ? .semibold : .regular)
                Spacer(minLength: 0)
                if current { Text("this").font(.caption).foregroundStyle(Palette.muted) }
              }
              .padding(.leading, CGFloat(min(stack.layers.count - 1 - index, 4)) * 0)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Pull request \(layer.number), \(layer.title ?? layer.headBranch)\(current ? ", this pull request" : "")")
          }
        }
      }
    }
  }

  // MARK: Linked threads

  @ViewBuilder private var linkedThreads: some View {
    let environmentId = model.target.environmentId
    let mode = app.runtime.threadPullRequestLinkMode(environmentId)
    let current = app.selection.flatMap { $0.environmentId == environmentId ? $0 : nil }
    if mode != .unsupported {
      section("Linked threads") {
        if let current {
          let linked = ThreadPullRequestLinking.isLinked(current, url: detail.url, in: app)
          Button(linked ? "Unlink from this thread" : "Link to this thread") {
            app.run { try await ThreadPullRequestLinking.change(current, url: detail.url, linked: !linked, in: app) }
          }
          .buttonStyle(.link).font(.callout)
        }
      } content: {
        if model.linkedThreads.isEmpty {
          Text("No thread is linked to this pull request.").foregroundStyle(Palette.muted).font(.callout)
        }
        ForEach(model.linkedThreads, id: \.id) { thread in
          Button {
            PullRequestsStore.shared.hide()
            app.selection = ScopedThreadKey(environmentId: environmentId, threadId: thread.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "text.bubble").foregroundStyle(Palette.muted)
              Text(thread.title).lineLimit(1)
              if thread.archivedAt != nil { Text("Archived").font(.caption2).foregroundStyle(Palette.muted).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .font(.callout)
          .accessibilityLabel("Open thread \(thread.title)")
        }
      }
    }
  }
}

/// A row that wraps like text (labels).
struct PullRequestFlow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      maxX = max(maxX, x - spacing)
    }
    return CGSize(width: maxX, height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}

/// Toggle the labels of a pull request; the host's list is searchable.
struct LabelPicker: View {
  let model: PullRequestDetailModel
  @State private var candidates: PullRequestLabelCandidateList?
  @State private var applied: Set<String> = []
  @State private var search = ""
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Filter labels", text: $search).textFieldStyle(.roundedBorder)
      if !loaded {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      } else if let candidates {
        let shown = candidates.candidates.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(shown, id: \.name) { candidate in
              Toggle(isOn: Binding(get: { applied.contains(candidate.name) }, set: { on in
                if on { applied.insert(candidate.name) } else { applied.remove(candidate.name) }
                Task { await model.setLabel(candidate.name, applied: on) }
              })) {
                HStack { PullRequestLabelChip(name: candidate.name, color: candidate.color); if let d = candidate.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
        if candidates.truncated { Text("Only the first labels are listed. Type to narrow them.").font(.caption).foregroundStyle(.secondary) }
      } else {
        Text("Could not load the repository's labels.").foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(width: 300, height: 320)
    .task {
      candidates = await model.labelCandidates()
      applied = Set(candidates?.candidates.filter(\.isApplied).map(\.name) ?? [])
      loaded = true
    }
  }
}

/// Request (or take back) the review of a person or team.
struct ReviewerPicker: View {
  let model: PullRequestDetailModel
  @State private var candidates: PullRequestReviewerCandidateList?
  @State private var requested: Set<String> = []
  @State private var search = ""
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Filter people and teams", text: $search).textFieldStyle(.roundedBorder)
      if !loaded {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      } else if let candidates {
        let shown = candidates.candidates.filter { search.isEmpty || $0.login.localizedCaseInsensitiveContains(search) || ($0.name ?? "").localizedCaseInsensitiveContains(search) }
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(shown, id: \.id) { candidate in
              Toggle(isOn: Binding(get: { requested.contains(candidate.id) }, set: { on in
                if on { requested.insert(candidate.id) } else { requested.remove(candidate.id) }
                Task { await model.setReviewer(candidate, requested: on) }
              })) {
                HStack(spacing: 6) {
                  PullRequestAvatar(actor: PullRequestActor(login: candidate.login, name: candidate.name, avatarUrl: candidate.avatarUrl))
                  Text(candidate.login)
                  if let name = candidate.name, !name.isEmpty, name != candidate.login { Text(name).font(.caption).foregroundStyle(.secondary) }
                  if candidate.kind == .team { Text("team").font(.caption2).foregroundStyle(.secondary) }
                }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
        if candidates.truncated { Text("Only the first candidates are listed. Type to narrow them.").font(.caption).foregroundStyle(.secondary) }
      } else {
        Text("Could not load reviewer candidates.").foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(width: 300, height: 320)
    .task {
      candidates = await model.reviewerCandidates()
      requested = Set(candidates?.candidates.filter(\.isRequested).map(\.id) ?? [])
      loaded = true
    }
  }
}
