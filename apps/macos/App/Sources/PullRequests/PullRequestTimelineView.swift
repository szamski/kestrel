import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Activity of a pull request newest first: commits, comments, reviews, and the verdicts that say whether it was approved.
struct PullRequestTimelineView: View {
  let model: PullRequestDetailModel
  let detail: PullRequestDetail

  @State private var draft = ""
  @State private var editing: String?
  @State private var editText = ""
  @State private var expanded: Set<String> = []

  private var canComment: Bool { detail.capabilities.comment && detail.viewerPermissions.comment }
  private var canReact: Bool { detail.capabilities.reactions == true && detail.viewerPermissions.comment }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        if canComment { composer }
        if let error = model.activityError, model.activity == nil {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        } else if let activity = model.activity {
          if activity.commentsTruncated { Label("Only the latest comments are shown.", systemImage: "scissors").font(.caption).foregroundStyle(Palette.muted) }
          ForEach(PullRequestDetailLogic.group(PullRequestDetailLogic.timeline(detail, activity: activity))) { row in
            switch row {
            case .event(let event): eventRow(event, outcome: PullRequestDetailLogic.reviewOutcome(event.reviewState))
            case .comments(let events): conversation(events)
            }
          }
        } else {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: Composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextEditor(text: $draft)
        .font(.body)
        .frame(minHeight: 70, maxHeight: 140)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
        .overlay(alignment: .topLeading) { if draft.isEmpty { Text("Leave a comment").foregroundStyle(Palette.muted).padding(12).allowsHitTesting(false) } }
        .accessibilityLabel("Comment")
      HStack {
        Spacer()
        Button("Comment") {
          let body = draft
          Task { if await model.comment(body) { draft = "" } }
        }
        .buttonStyle(.borderedProminent)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pending.contains("comment"))
      }
    }
  }

  // MARK: Rows

  private func eventRow(_ event: PullRequestDetailLogic.TimelineEvent, outcome: PullRequestDetailLogic.ReviewOutcome?) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol(event, outcome)).foregroundStyle(tint(event, outcome)).frame(width: 18).padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if let actor = event.actor { PullRequestAvatar(actor: actor, size: 16); Text(actor.login).fontWeight(.medium) }
          Text(title(event, outcome)).foregroundStyle(event.kind == .merged ? Color.purple : Palette.text)
          Text(PullRequestStyle.relative(event.at)).foregroundStyle(Palette.muted).help(PullRequestStyle.absolute(event.at))
          if event.kind == .commit, let additions = event.additions, let deletions = event.deletions { DiffStat(additions: additions, deletions: deletions).font(.caption) }
        }
        .font(.callout)
        if event.kind == .commit, let body = event.body { Text(body).font(.callout).foregroundStyle(Palette.muted).lineLimit(2) }
        if let body = event.body, event.kind == .review, outcome != nil { PullRequestMarkdown(text: body) }
      }
      Spacer(minLength: 0)
    }
  }

  private func symbol(_ event: PullRequestDetailLogic.TimelineEvent, _ outcome: PullRequestDetailLogic.ReviewOutcome?) -> String {
    switch event.kind {
    case .opened: "arrow.triangle.pull"
    case .commit: "smallcircle.filled.circle"
    case .merged: "arrow.triangle.merge"
    case .closed: "xmark.circle"
    case .comment, .review:
      switch outcome {
      case .approved?: "checkmark.seal.fill"
      case .changesRequested?: "exclamationmark.bubble.fill"
      default: "text.bubble"
      }
    }
  }

  private func tint(_ event: PullRequestDetailLogic.TimelineEvent, _ outcome: PullRequestDetailLogic.ReviewOutcome?) -> Color {
    switch event.kind {
    case .opened: .green
    case .merged: .purple
    case .closed: .red
    case .comment, .review:
      switch outcome {
      case .approved?: .green
      case .changesRequested?: .orange
      default: .secondary
      }
    case .commit: .secondary
    }
  }

  private func title(_ event: PullRequestDetailLogic.TimelineEvent, _ outcome: PullRequestDetailLogic.ReviewOutcome?) -> String {
    switch outcome {
    case .approved?: "approved these changes"
    case .changesRequested?: "requested changes"
    default: event.title
    }
  }

  /// Consecutive comments: the first ones shown, the rest behind a button, like the web's conversation section.
  private func conversation(_ events: [PullRequestDetailLogic.TimelineEvent]) -> some View {
    let key = events.first?.id ?? ""
    let limit = 4
    let shown = expanded.contains(key) ? events : Array(events.prefix(limit))
    return VStack(alignment: .leading, spacing: 8) {
      ForEach(shown) { event in commentCard(event) }
      if events.count > limit, !expanded.contains(key) {
        Button("Show \(events.count - limit) more comment\(events.count - limit == 1 ? "" : "s")") { expanded.insert(key) }.buttonStyle(.link).font(.callout)
      }
    }
  }

  private func commentCard(_ event: PullRequestDetailLogic.TimelineEvent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        PullRequestAvatar(actor: event.actor, size: 18)
        Text(event.actor?.login ?? "ghost").fontWeight(.medium)
        Text(event.kind == .review ? "reviewed" : "commented").foregroundStyle(Palette.muted)
        Text(PullRequestStyle.relative(event.at)).foregroundStyle(Palette.muted).help(PullRequestStyle.absolute(event.at))
        if event.comment?.editedAt.flatMap({ $0 }) != nil { Text("edited").font(.caption).foregroundStyle(Palette.muted) }
        Spacer(minLength: 0)
        if let comment = event.comment, detail.capabilities.edit?.comment == true, model.isMine(comment.author), comment.kind != .review {
          Button { editing = comment.id; editText = comment.body } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless).help("Edit comment").accessibilityLabel("Edit comment")
        }
        if let url = event.url.flatMap({ URL(string: $0) }) {
          Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
            .buttonStyle(.borderless).help("Open on the host").accessibilityLabel("Open comment on the host")
        }
      }
      .font(.callout)
      if let path = event.path { Text(path).font(.caption.monospaced()).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle) }
      if editing == event.id, let comment = event.comment {
        TextEditor(text: $editText).frame(minHeight: 70, maxHeight: 160).padding(6).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        HStack {
          Spacer()
          Button("Cancel") { editing = nil }
          Button("Save") { Task { if await model.updateComment(comment, body: editText) { editing = nil } } }
            .buttonStyle(.borderedProminent).disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } else if let body = event.body {
        PullRequestMarkdown(text: body)
      } else {
        Text("No content.").foregroundStyle(Palette.muted).font(.callout)
      }
      if canReact || !event.reactions.isEmpty, let comment = event.comment, comment.kind != .review {
        PullRequestReactionBar(reactions: event.reactions, canReact: canReact) { content, reacted in
          Task { await model.react(content, subject: comment.id, reacted: reacted) }
        }
      }
    }
    .padding(10)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
  }
}
