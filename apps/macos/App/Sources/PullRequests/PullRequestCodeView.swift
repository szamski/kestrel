import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Diff

/// The pull request's changes: the virtualized diff with the files list (and what was viewed), the review threads under
/// the lines they are on, and inline comments that go into a pending review.
struct PullRequestCodeView: View {
  let app: AppModel
  let model: PullRequestDetailModel
  let detail: PullRequestDetail

  private let store = PullRequestsStore.shared
  @State private var diff: DiffPanelModel
  @State private var viewed: [String: PullRequestFileViewedState] = [:]
  @State private var threadsOpen = false
  @State private var treePopover = false
  @State private var panelWidth: CGFloat = 0
  @State private var refresh = 0
  @State private var commentText = ""
  @FocusState private var commentFocused: Bool

  private static let inlineTreeMinimum: CGFloat = 760

  init(app: AppModel, model: PullRequestDetailModel, detail: PullRequestDetail) {
    self.app = app
    self.model = model
    self.detail = detail
    _diff = State(initialValue: DiffPanelModel(fetch: { _ in
      let result = try await model.diffPatch()
      return DiffFetchResult(patch: result.patch, truncated: result.truncated)
    }))
  }

  private var threads: [PullRequestReviewThread] { model.activity?.reviewThreads ?? [] }
  private var drafts: [PullRequestReviewCommentDraft] { store.drafts(for: model.target) }
  private var canComment: Bool { detail.capabilities.review.inlineComment && detail.viewerPermissions.comment && detail.state == .open }
  private var docked: Bool { panelWidth >= Self.inlineTreeMinimum && !diff.files.isEmpty }

  private struct LoadID: Hashable {
    var target: String
    var revision: Int
    var head: String?
    var refresh: Int
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      HStack(spacing: 0) {
        if docked && diff.showTree {
          fileList.frame(width: 240)
          Divider()
        }
        VStack(spacing: 0) {
          diffBody
          if diff.selection != nil { commentBar }
          if threadsOpen && !threads.isEmpty { Divider(); threadsPanel.frame(height: 240) }
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
    .task(id: LoadID(target: model.target.id, revision: store.revision, head: detail.headSha, refresh: refresh)) {
      async let files = model.filesViewed()
      await diff.load(
        DiffRequest(source: .branch, ignoreWhitespace: false), scopeKey: "pr:\(model.target.id):\(detail.headSha ?? "")", sectionId: "pull-request:\(detail.number)",
        sectionTitle: "PR #\(detail.number)", revealPath: nil, revealToken: 0)
      viewed = await files
    }
    .task(id: annotationID) { diff.annotations = annotations() }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        if !diff.files.isEmpty {
          Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")").foregroundStyle(Palette.muted)
          DiffStat(additions: diff.totalAdditions, deletions: diff.totalDeletions)
          if detail.capabilities.viewedFiles != nil {
            let count = diff.files.filter { viewed[$0.path] == .viewed }.count
            Text("\(count)/\(diff.files.count) viewed").foregroundStyle(Palette.muted)
          }
        }
        Spacer(minLength: 4)
        if !threads.isEmpty {
          Toggle(isOn: $threadsOpen) {
            Label("\(threads.filter { !$0.isResolved }.count)", systemImage: "text.bubble")
          }
          .toggleStyle(.button).buttonStyle(.borderless).help("Review threads (\(threads.count), \(threads.filter { !$0.isResolved }.count) unresolved)")
          .accessibilityLabel("Review threads")
        }
        iconButton("arrow.clockwise", "Refresh diff") { refresh += 1 }
        iconButton(diff.allCollapsed ? "chevron.up.chevron.down" : "arrow.up.and.line.horizontal.and.arrow.down", diff.allCollapsed ? "Expand all files" : "Collapse all files") { diff.toggleAllCollapsed() }
          .disabled(diff.files.isEmpty)
        Picker("Layout", selection: Bindable(diff).layout) {
          Image(systemName: "rectangle.split.1x2").tag(DiffLayoutMode.stacked).accessibilityLabel("Stacked diff view")
          Image(systemName: "rectangle.split.2x1").tag(DiffLayoutMode.split).accessibilityLabel("Split diff view")
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 64).help("Diff layout")
        Toggle(isOn: Bindable(diff).wordWrap) { Image(systemName: "arrow.turn.down.left") }
          .toggleStyle(.button).buttonStyle(.borderless).help("Wrap lines").accessibilityLabel("Wrap lines")
        iconButton("list.bullet.indent", "Files") {
          if docked { diff.showTree.toggle() } else { treePopover.toggle() }
        }
        .disabled(diff.files.isEmpty)
        .popover(isPresented: $treePopover, arrowEdge: .bottom) { fileList.frame(width: 320, height: min(460, CGFloat(diff.files.count) * 28 + 16)) }
      }
      .font(.caption)
      if diff.truncated || !model.omittedFiles.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "scissors").foregroundStyle(.orange)
          Text(truncationText).foregroundStyle(Palette.muted)
          Spacer(minLength: 0)
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  private var truncationText: String {
    let omitted = model.omittedFiles
    if omitted.isEmpty { return "The host cut this diff short. Open the pull request on the host to see all of it." }
    let names = omitted.prefix(3).map(\.path).joined(separator: ", ")
    return "\(omitted.count) large \(omitted.count == 1 ? "file is" : "files are") not shown: \(names)\(omitted.count > 3 ? ", \u{2026}" : "")"
  }

  private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
  }

  // MARK: Files

  private var fileList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(diff.files) { file in
          let state = viewed[file.path] ?? .unviewed
          HStack(spacing: 6) {
            if detail.capabilities.viewedFiles != nil {
              Button { toggleViewed(file) } label: {
                Image(systemName: state == .viewed ? "checkmark.circle.fill" : state == .dismissed ? "arrow.triangle.2.circlepath.circle" : "circle")
                  .foregroundStyle(state == .viewed ? Color.green : state == .dismissed ? Color.orange : Palette.muted)
              }
              .buttonStyle(.plain)
              .help(state == .viewed ? "Viewed. Mark as not viewed" : state == .dismissed ? "Changed since you viewed it" : "Mark as viewed")
              .accessibilityLabel(state == .viewed ? "Viewed" : "Not viewed")
            }
            Button { diff.revealFile(path: file.path) } label: {
              HStack(spacing: 6) {
                Text(file.fileName).lineLimit(1).truncationMode(.middle)
                Text(file.directory).font(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                DiffStat(additions: file.additions, deletions: file.deletions).font(.caption)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 10)
          .frame(height: 28)
          .font(.callout)
          .accessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions")
        }
      }
      .padding(.vertical, 6)
    }
  }

  private func toggleViewed(_ file: DiffFile) {
    let wasViewed = viewed[file.path] == .viewed
    viewed[file.path] = wasViewed ? .unviewed : .viewed
    Task {
      if await model.setFiles(viewed: !wasViewed, paths: [file.path]) {
        // A file marked viewed folds away, like the host's own diff.
        if !wasViewed, !diff.isCollapsed(path: file.path) { diff.toggleCollapse(fileId: file.id) }
      } else {
        viewed[file.path] = wasViewed ? .viewed : .unviewed
      }
    }
  }

  // MARK: Diff

  @ViewBuilder private var diffBody: some View {
    switch diff.phase {
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView {
        Label("Could not load the diff", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { refresh += 1 }
      }
    case .ready where diff.files.isEmpty:
      ContentUnavailableView("No changes", systemImage: "checkmark.circle", description: Text("This pull request changes no files."))
    case .ready:
      DiffTable(
        files: diff.files, rows: diff.rows, revision: diff.revision, layout: diff.layout, wordWrap: diff.wordWrap, selection: diff.selection, markers: [:], reveal: diff.reveal,
        actions: DiffTableActions(
          toggleCollapse: { diff.toggleCollapse(fileId: $0) }, select: { diff.selection = $0 },
          copyPath: { PullRequestStyle.copy($0.path) }, openInEditor: { _ in }, reveal: { _ in }))
    }
  }

  // MARK: Inline notes

  private struct AnnotationID: Hashable {
    var revision: Int
    var threads: [PullRequestReviewThread]
    var drafts: Int
  }

  private var annotationID: AnnotationID { AnnotationID(revision: diff.revision, threads: threads, drafts: drafts.count) }

  /// Index in `file.lines` of a review thread's or comment's line.
  private func lineIndex(in file: DiffFile, line: Int, side: PullRequestDiffSide) -> Int? {
    file.lines.firstIndex { candidate in
      switch candidate.kind {
      case .addition: side != .left && candidate.newNumber == line
      case .deletion: side == .left && candidate.oldNumber == line
      case .context: (side == .left ? candidate.oldNumber : candidate.newNumber) == line
      case .noNewline: false
      }
    }
  }

  private func annotations() -> [String: [Int: [String]]] {
    var result: [String: [Int: [String]]] = [:]
    func firstLine(_ text: String) -> String {
      let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      return line.count > 110 ? String(line.prefix(110)) + "\u{2026}" : line
    }
    for thread in threads {
      guard let line = thread.line, let file = diff.files.first(where: { $0.path == thread.path }), let index = lineIndex(in: file, line: line, side: thread.side),
        let first = thread.comments.first
      else { continue }
      let count = thread.commentCount ?? thread.comments.count
      let tags = (thread.isResolved ? " [resolved]" : "") + (thread.isOutdated ? " [outdated]" : "")
      result[file.id, default: [:]][index, default: []].append(
        "\u{1F4AC} \(first.author?.login ?? "ghost"): \(firstLine(first.body))\(count > 1 ? " (+\(count - 1))" : "")\(tags)")
    }
    for draft in drafts {
      guard let file = diff.files.first(where: { $0.path == draft.path }) else { continue }
      let index: Int?
      switch draft.position {
      case .added(let position): index = lineIndex(in: file, line: position.newLine, side: .right)
      case .deleted(let position): index = lineIndex(in: file, line: position.oldLine, side: .left)
      case .context(let position): index = lineIndex(in: file, line: position.newLine, side: .right)
      case .unknown: index = nil
      }
      if let index { result[file.id, default: [:]][index, default: []].append("\u{1F4DD} Pending: \(firstLine(draft.body))") }
    }
    return result
  }

  // MARK: Comment bar

  private var commentBar: some View {
    let selection = diff.selection
    let file = selection.flatMap { diff.file(id: $0.fileId) }
    return VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "text.bubble").foregroundStyle(Palette.muted)
        if let file, let selection { Text("\(file.fileName) \u{00B7} line \(lineNumber(file, selection))").font(.caption.weight(.medium)).lineLimit(1) }
        if canComment {
          TextField("Add a review comment", text: $commentText).textFieldStyle(.plain).focused($commentFocused).onSubmit(addDraft)
          Button("Add to Review", action: addDraft).buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
          Text(detail.state == .open ? "You cannot comment on this pull request." : "This pull request is not open.").font(.caption).foregroundStyle(Palette.muted)
          Spacer(minLength: 0)
        }
        Button("Cancel") { diff.clearSelection(); commentText = "" }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
    }
    .background(Palette.surface)
  }

  private func lineNumber(_ file: DiffFile, _ selection: DiffSelection) -> Int {
    guard selection.hi < file.lines.count else { return 0 }
    let line = file.lines[selection.hi]
    return line.newNumber > 0 ? line.newNumber : line.oldNumber
  }

  /// A comment on the last selected line, held for the review the user submits.
  private func addDraft() {
    let body = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, let selection = diff.selection, let file = diff.file(id: selection.fileId), selection.hi < file.lines.count else { return }
    let line = file.lines[selection.hi]
    let position: PullRequestReviewPosition
    switch line.kind {
    case .addition: position = .added(PullRequestReviewPositionAdded(newLine: line.newNumber))
    case .deletion: position = .deleted(PullRequestReviewPositionDeleted(oldLine: line.oldNumber))
    case .context: position = .context(PullRequestReviewPositionContext(oldLine: line.oldNumber, newLine: line.newNumber, side: .right))
    case .noNewline: return
    }
    store.addDraft(PullRequestReviewCommentDraft(path: file.path, oldPath: file.oldPath == file.newPath ? nil : file.oldPath, position: position, body: body), for: model.target)
    commentText = ""
    diff.clearSelection()
  }

  // MARK: Threads

  private var threadsPanel: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(threads, id: \.id) { thread in
          ReviewThreadCard(model: model, detail: detail, thread: thread) { diff.revealFile(path: thread.path) }
        }
      }
      .padding(12)
    }
    .background(Palette.canvas)
  }
}

private struct ReviewThreadCard: View {
  let model: PullRequestDetailModel
  let detail: PullRequestDetail
  let thread: PullRequestReviewThread
  let reveal: () -> Void

  @State private var reply = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button(action: reveal) {
          Text("\(thread.path)\(thread.line.map { ":\($0)" } ?? "")").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.link).help("Show in the diff")
        if thread.isResolved { tag("Resolved", .green) }
        if thread.isOutdated { tag("Outdated", .orange) }
        Spacer(minLength: 0)
        if detail.capabilities.review.resolve, detail.viewerPermissions.resolve {
          Button(thread.isResolved ? "Reopen" : "Resolve") { Task { await model.setResolved(thread, resolved: !thread.isResolved) } }
            .buttonStyle(.borderless).font(.caption).disabled(model.pending.contains("thread:\(thread.id)"))
        }
      }
      let comments = thread.comments + (model.moreReplies[thread.id] ?? [])
      ForEach(comments, id: \.id) { comment in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            PullRequestAvatar(actor: comment.author, size: 16)
            Text(comment.author?.login ?? "ghost").fontWeight(.medium)
            Text(PullRequestStyle.relative(comment.createdAt)).foregroundStyle(Palette.muted)
          }
          .font(.caption)
          if let body = PullRequestDetailLogic.visibleBody(comment.body) { PullRequestMarkdown(text: body) }
        }
      }
      let cursor = model.moreRepliesCursor[thread.id] ?? thread.nextCommentsCursor
      if cursor != nil {
        Button("Show more replies") { Task { await model.loadMoreReplies(thread) } }.buttonStyle(.link).font(.caption)
      }
      if detail.capabilities.review.reply, detail.viewerPermissions.comment {
        HStack(spacing: 6) {
          TextField("Reply", text: $reply).textFieldStyle(.roundedBorder).onSubmit(send)
          Button("Reply", action: send).controlSize(.small).disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pending.contains("thread:\(thread.id)"))
        }
      }
    }
    .padding(10)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
    .opacity(thread.isResolved ? 0.7 : 1)
  }

  private func tag(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.2), in: Capsule())
  }

  private func send() {
    let body = reply
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task { if await model.reply(to: thread, body: body) { reply = "" } }
  }
}
