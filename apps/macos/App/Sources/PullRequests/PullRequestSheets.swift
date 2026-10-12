import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Submit a review: the verdict, a message, and the inline comments written in the Code tab.
struct PullRequestReviewSheet: View {
  let model: PullRequestDetailModel
  let detail: PullRequestDetail

  @Environment(\.dismiss) private var dismiss
  @State private var verdict: PullRequestReviewVerdict = .comment
  @State private var text = ""
  @State private var submitting = false

  private let store = PullRequestsStore.shared

  /// Verdicts this host supports and this account may give.
  private var verdicts: [PullRequestReviewVerdict] {
    let allowed = detail.capabilities.review.verdicts.filter { detail.viewerPermissions.verdicts.contains($0) }
    return allowed.isEmpty ? [.comment] : allowed
  }

  private var current: [PullRequestReviewCommentDraft] { store.drafts(for: model.target) }

  private func title(_ verdict: PullRequestReviewVerdict) -> String {
    switch verdict {
    case .comment: "Comment"
    case .approve: "Approve"
    case .requestChanges: "Request changes"
    case .unknown(let raw): raw
    }
  }

  private func hint(_ verdict: PullRequestReviewVerdict) -> String {
    switch verdict {
    case .comment: "General feedback without an explicit approval."
    case .approve: "Approve merging these changes."
    case .requestChanges: "Feedback that must be addressed before merging."
    case .unknown: ""
    }
  }

  private var canSubmit: Bool {
    let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !current.isEmpty
    return verdict == .approve || hasContent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review #\(detail.number)").font(.headline)
      Text(detail.title).foregroundStyle(.secondary).lineLimit(2)
      Picker("Verdict", selection: $verdict) {
        ForEach(verdicts, id: \.rawValue) { candidate in
          VStack(alignment: .leading) { Text(title(candidate)); Text(hint(candidate)).font(.caption).foregroundStyle(.secondary) }.tag(candidate)
        }
      }
      .pickerStyle(.radioGroup)
      TextEditor(text: $text)
        .frame(minHeight: 100)
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Review message")
      if !current.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(current.count) inline comment\(current.count == 1 ? "" : "s")").font(.subheadline.weight(.medium))
          ForEach(Array(current.enumerated()), id: \.offset) { index, draft in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text("\((draft.path as NSString).lastPathComponent):\(line(draft))").font(.caption.monospaced())
              Text(draft.body).lineLimit(1).font(.caption).foregroundStyle(.secondary)
              Spacer(minLength: 0)
              Button { store.removeDraft(at: index, for: model.target) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).accessibilityLabel("Remove comment")
            }
          }
        }
      }
      HStack {
        if !current.isEmpty { Button("Discard Comments", role: .destructive) { store.clearDrafts(for: model.target) } }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(submitting ? "Submitting\u{2026}" : "Submit Review") {
          submitting = true
          Task {
            let ok = await model.submitReview(verdict, body: text, comments: current)
            submitting = false
            if ok { store.clearDrafts(for: model.target); dismiss() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit || submitting)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { if !verdicts.contains(verdict) { verdict = verdicts[0] } }
  }

  private func line(_ draft: PullRequestReviewCommentDraft) -> String {
    switch draft.position {
    case .added(let position): String(position.newLine)
    case .deleted(let position): String(position.oldLine)
    case .context(let position): String(position.newLine)
    case .unknown: "?"
    }
  }
}

/// Edit the title and description.
struct PullRequestEditSheet: View {
  let model: PullRequestDetailModel
  let detail: PullRequestDetail

  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var text = ""
  @State private var saving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit pull request").font(.headline)
      TextField("Title", text: $title)
      Text("Description").font(.subheadline.weight(.medium))
      TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 220).padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6)).accessibilityLabel("Description")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(saving ? "Saving\u{2026}" : "Save") {
          saving = true
          Task {
            let ok = await model.update(title: title == detail.title ? nil : title, body: text == detail.body ? nil : text)
            saving = false
            if ok { dismiss() }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || (title == detail.title && text == detail.body))
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      title = detail.title
      text = detail.body
    }
  }
}

/// Link a pull request to a thread by URL, or by number for the thread's own repository.
struct LinkPullRequestSheet: View {
  let key: ScopedThreadKey

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var reference = ""
  @State private var dirty = false
  @State private var error: String?
  @State private var pending = false
  @FocusState private var focused: Bool

  private var project: LinkPullRequestProject? {
    guard let projectId = app.runtime.threadShell(key)?.shell.projectId,
      let entry = app.runtime.projects.first(where: { $0.environmentId == key.environmentId && $0.projectId == projectId })
    else { return nil }
    return PullRequestProjects.linkProject(for: entry)
  }

  private var resolved: LinkPullRequestResolution? {
    LinkPullRequestInput.resolve(reference, project: project) { ThreadPullRequestLinking.canLink($0, environmentId: key.environmentId, in: app) }
  }

  private var validation: String? {
    if !dirty { return nil }
    if reference.trimmingCharacters(in: .whitespaces).isEmpty { return "Paste a pull request URL or enter 123 / #123." }
    switch resolved {
    case nil: return "Use a pull request URL, 123, or #123."
    case .invalid(let message)?: return message
    case .link?: return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Link pull request").font(.headline)
      Text("Attach a pull request to \u{201C}\(app.runtime.threadShell(key)?.shell.title ?? "this thread")\u{201D} by its URL, or by its number for this thread's repository.")
        .font(.callout).foregroundStyle(.secondary)
      TextField("Pull request URL or #42", text: $reference)
        .focused($focused)
        .onSubmit(submit)
        .onChange(of: reference) { dirty = true }
      if case .link(let link, _)? = resolved { Text("\(link.host)/\(link.repository) #\(link.number)").font(.caption).foregroundStyle(.secondary) }
      if let message = validation ?? error { Text(message).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.disabled(pending)
        Button(pending ? "Linking\u{2026}" : "Link", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(pending || { if case .link? = resolved { false } else { true } }())
      }
    }
    .padding(20)
    .frame(width: 440)
    .onAppear { focused = true }
  }

  private func submit() {
    dirty = true
    guard case .link(_, let url)? = resolved else { return }
    error = nil
    pending = true
    Task {
      do {
        try await ThreadPullRequestLinking.change(key, url: url, linked: true, in: app)
        dismiss()
      } catch {
        self.error = AppModel.describe(error)
      }
      pending = false
    }
  }
}
