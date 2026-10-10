import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Diff
import T3Markdown
import T3Timeline

/// The diff tab: scope menu and view controls, the file list (or a popover of it), the virtualized diff and the
/// comment bar that appears while lines are selected.
struct DiffPanelView: View {
  let app: AppModel
  let key: ScopedThreadKey
  /// The thread's checkpoints, one per turn that changed files.
  let turns: [V1.OrchestrationCheckpointSummary]
  let store: RightPanelStore
  let model: DiffPanelModel

  @State private var refreshToken = 0
  @State private var treePopover = false
  @State private var panelWidth: CGFloat = 0
  @FocusState private var commentFocused: Bool

  private static let inlineTreeMinimum: CGFloat = 760
  /// Wide panels (maximized, say) dock the tree beside the diff; narrow ones offer it as a popover.
  private var dockedTree: Bool { panelWidth >= Self.inlineTreeMinimum && !model.tree.isEmpty }

  /// Checkpoint turns, newest first (`DiffPanel.tsx` `orderedTurnDiffSummaries`).
  private var orderedTurns: [V1.OrchestrationCheckpointSummary] {
    turns.sorted {
      $0.checkpointTurnCount != $1.checkpointTurnCount ? $0.checkpointTurnCount > $1.checkpointTurnCount : $0.completedAt.rawValue > $1.completedAt.rawValue
    }
  }

  private struct Resolved {
    var request: DiffRequest
    var scopeKey: String
    var sectionId: String
    var sectionTitle: String
    var revealPath: String?
    var revealToken: Int
    var label: String
  }

  private func resolve(_ scope: DiffScope, turns: [V1.OrchestrationCheckpointSummary]) -> Resolved? {
    let ignore = model.ignoreWhitespace
    switch scope {
    case .workingTree:
      return Resolved(request: .init(source: .workingTree, ignoreWhitespace: ignore), scopeKey: "unstaged", sectionId: "unstaged", sectionTitle: "Working tree", revealPath: nil, revealToken: 0, label: "Working tree")
    case .branch:
      return Resolved(request: .init(source: .branch, ignoreWhitespace: ignore), scopeKey: "branch", sectionId: "branch", sectionTitle: "Branch changes", revealPath: nil, revealToken: 0, label: "Branch changes")
    case .allTurns:
      guard let latest = turns.first else { return nil }
      return Resolved(request: .init(source: .allTurns(upTo: latest.checkpointTurnCount), ignoreWhitespace: ignore), scopeKey: "thread", sectionId: "thread", sectionTitle: "All turns", revealPath: nil, revealToken: 0, label: "All turns")
    case .turn(let id, let path, let token):
      guard let latest = turns.first else { return nil }
      let turn = turns.first { $0.turnId.rawValue == id } ?? latest
      let section = "turn:\(turn.turnId.rawValue)"
      let label = turn.turnId == latest.turnId ? "Latest turn" : "Turn \(turn.checkpointTurnCount)"
      return Resolved(
        request: .init(source: .turn(count: turn.checkpointTurnCount), ignoreWhitespace: ignore), scopeKey: section, sectionId: section,
        sectionTitle: "Turn \(turn.checkpointTurnCount)", revealPath: path, revealToken: token, label: label)
    }
  }

  /// Everything a reload depends on; a change restarts the load task.
  private struct LoadID: Hashable {
    var scope: DiffScope
    var ignoreWhitespace: Bool
    var turns: [Int]
    var refresh: Int
  }

  var body: some View {
    let turns = orderedTurns
    let scope = store.scope(key)
    let resolved = resolve(scope, turns: turns)
    VStack(spacing: 0) {
      header(resolved: resolved, turns: turns, scope: scope)
      Divider()
      HStack(spacing: 0) {
        if dockedTree && model.showTree {
          DiffTreeList(rows: model.tree) { model.revealFile(path: $0) }.frame(width: 220)
          Divider()
        }
        bodyContent(resolved: resolved)
      }
      if model.selection != nil { commentBar }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
    .task(id: LoadID(scope: scope, ignoreWhitespace: model.ignoreWhitespace, turns: turns.map(\.checkpointTurnCount), refresh: refreshToken)) {
      guard let resolved else { return }
      await model.load(
        resolved.request, scopeKey: resolved.scopeKey, sectionId: resolved.sectionId, sectionTitle: resolved.sectionTitle, revealPath: resolved.revealPath,
        revealToken: resolved.revealToken)
    }
  }

  // MARK: Header

  private enum Choice: Hashable {
    case workingTree, branch, latest, allTurns
    case turn(String)
  }

  private func choice(for scope: DiffScope, turns: [V1.OrchestrationCheckpointSummary]) -> Choice {
    switch scope {
    case .workingTree: .workingTree
    case .branch: .branch
    case .allTurns: .allTurns
    case .turn(let id, _, _): id == turns.first?.turnId.rawValue || turns.first(where: { $0.turnId.rawValue == id }) == nil ? .latest : .turn(id)
    }
  }

  private func select(_ choice: Choice, turns: [V1.OrchestrationCheckpointSummary]) {
    switch choice {
    case .workingTree: store.selectScope(.workingTree, in: key)
    case .branch: store.selectScope(.branch, in: key)
    case .allTurns: store.selectScope(.allTurns, in: key)
    case .latest: if let latest = turns.first { store.revealDiff(turnId: latest.turnId.rawValue, filePath: nil, in: key) }
    case .turn(let id): store.revealDiff(turnId: id, filePath: nil, in: key)
    }
    model.clearSelection()
  }

  private func header(resolved: Resolved?, turns: [V1.OrchestrationCheckpointSummary], scope: DiffScope) -> some View {
    let current = choice(for: scope, turns: turns)
    let binding = Binding<Choice>(get: { current }, set: { select($0, turns: turns) })
    return VStack(spacing: 6) {
      HStack(spacing: 8) {
        Menu {
          Picker("Compare", selection: binding) {
            Text("Working tree").tag(Choice.workingTree)
            Text("Branch changes").tag(Choice.branch)
            if !turns.isEmpty {
              Text("Latest turn").tag(Choice.latest)
              Text("All turns").tag(Choice.allTurns)
            }
          }
          .pickerStyle(.inline)
          if !turns.isEmpty {
            Menu("Turn") {
              Picker("Turn", selection: binding) {
                ForEach(turns, id: \.turnId) { turn in Text("Turn \(turn.checkpointTurnCount)  \(Self.time(turn.completedAt))").tag(Choice.turn(turn.turnId.rawValue)) }
              }
              .pickerStyle(.inline)
            }
          }
        } label: {
          Text(resolved?.label ?? "Latest turn")
        }
        .menuStyle(.button)
        .fixedSize()
        .accessibilityLabel("Diff scope: \(resolved?.label ?? "none")")

        Spacer(minLength: 4)

        iconButton("arrow.clockwise", "Refresh diff") { refreshToken += 1 }
        iconButton(model.allCollapsed ? "chevron.up.chevron.down" : "arrow.up.and.line.horizontal.and.arrow.down", model.allCollapsed ? "Expand all files" : "Collapse all files") { model.toggleAllCollapsed() }
          .disabled(model.files.isEmpty)
        Picker("Layout", selection: Bindable(model).layout) {
          Image(systemName: "rectangle.split.1x2").tag(DiffLayoutMode.stacked).accessibilityLabel("Stacked diff view")
          Image(systemName: "rectangle.split.2x1").tag(DiffLayoutMode.split).accessibilityLabel("Split diff view")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 64)
        .help("Diff layout")
        Toggle(isOn: Bindable(model).wordWrap) { Image(systemName: "arrow.turn.down.left") }
          .toggleStyle(.button).buttonStyle(.borderless).help(model.wordWrap ? "Disable line wrapping" : "Enable line wrapping")
          .accessibilityLabel("Wrap lines")
        Toggle(isOn: Bindable(model).ignoreWhitespace) { Image(systemName: "paragraphsign") }
          .toggleStyle(.button).buttonStyle(.borderless).help(model.ignoreWhitespace ? "Show whitespace changes" : "Hide whitespace changes")
          .accessibilityLabel("Ignore whitespace changes")
        iconButton("list.bullet.indent", "File tree") {
          if panelWidth >= Self.inlineTreeMinimum { model.showTree.toggle() } else { treePopover.toggle() }
        }
        .disabled(model.tree.isEmpty)
        .popover(isPresented: $treePopover, arrowEdge: .bottom) {
          DiffTreeList(rows: model.tree) { path in
            treePopover = false
            model.revealFile(path: path)
          }
          .frame(width: 280, height: min(420, CGFloat(model.tree.count) * 26 + 16))
        }
      }
      if !model.files.isEmpty {
        HStack(spacing: 8) {
          Text("\(model.files.count) \(model.files.count == 1 ? "file" : "files") changed").foregroundStyle(Palette.muted)
          DiffStat(additions: model.totalAdditions, deletions: model.totalDeletions)
          if model.truncated { Label("Truncated by the server", systemImage: "scissors").foregroundStyle(.orange).labelStyle(.titleAndIcon) }
          Spacer(minLength: 0)
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol) }
      .buttonStyle(.borderless)
      .help(title)
      .accessibilityLabel(title)
  }

  private static func time(_ date: IsoDateTime) -> String {
    date.date.map { ClientSettingsStore.shared.timestamp($0) } ?? date.rawValue
  }

  // MARK: Body

  @ViewBuilder
  private func bodyContent(resolved: Resolved?) -> some View {
    switch model.phase {
    case _ where resolved == nil:
      ContentUnavailableView("No turns with changes yet", systemImage: "plusminus", description: Text("Diffs appear here once the agent finishes a turn."))
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView {
        Label("Could not load the diff", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { refreshToken += 1 }
      }
    case .ready where model.files.isEmpty:
      ContentUnavailableView("No changes", systemImage: "checkmark.circle", description: Text("Nothing differs for \(resolved?.label.lowercased() ?? "this scope")."))
    case .ready:
      DiffTable(
        files: model.files, rows: model.rows, revision: model.revision, layout: model.layout, wordWrap: model.wordWrap, selection: model.selection,
        markers: model.markers(for: app.draftReviewComments(in: key, sectionId: model.sectionId)), reveal: model.reveal, actions: actions)
    }
  }

  private var actions: DiffTableActions {
    let root = app.runtime.threadShell(key)?.shell.worktreePath ?? app.workspaceRoot(of: key)
    func absolute(_ file: DiffFile) -> String { root.map { ($0 as NSString).appendingPathComponent(file.path) } ?? file.path }
    return DiffTableActions(
      toggleCollapse: { model.toggleCollapse(fileId: $0) },
      select: { model.selection = $0 },
      copyPath: { file in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
      },
      openInEditor: { file in app.open(.file(MarkdownFileTarget(path: absolute(file))), in: key) },
      reveal: { file in
        let url = URL(fileURLWithPath: absolute(file))
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { app.errorMessage = "\(file.path) is not on this Mac." }
      })
  }

  // MARK: Comment bar

  private var commentBar: some View {
    let draft = model.pendingComment()
    return VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "text.bubble").foregroundStyle(Palette.muted)
        if let draft {
          Text("\((draft.filePath as NSString).lastPathComponent) \u{00B7} \(draft.rangeLabel)")
            .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
        }
        TextField("Comment for the agent (optional)", text: Bindable(model).commentText)
          .textFieldStyle(.plain)
          .focused($commentFocused)
          .onSubmit(submitComment)
        Button("Cancel") { model.clearSelection() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
        Button("Add to Message", action: submitComment).buttonStyle(.borderedProminent).controlSize(.small).keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .background(Palette.surface)
  }

  private func submitComment() {
    guard let draft = model.pendingComment() else { return }
    if app.insertReviewComment(draft, in: key) {
      model.clearSelection()
    } else {
      app.errorMessage = "Open the thread's composer to attach a review comment."
    }
  }
}

/// The changed files as an always-expanded tree with per-directory and per-file stats.
struct DiffTreeList: View {
  let rows: [DiffTreeRow]
  let open: (String) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(rows) { row in
          Button { if !row.isDirectory { open(row.path) } } label: {
            HStack(spacing: 6) {
              Image(systemName: row.isDirectory ? "folder" : "doc.text").foregroundStyle(Palette.muted).frame(width: 14)
              Text(row.name).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 4)
              if !row.isDirectory { DiffStat(additions: row.additions, deletions: row.deletions).font(.caption) }
            }
            .padding(.leading, CGFloat(row.depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(row.isDirectory)
          .font(.callout)
          .foregroundStyle(row.isDirectory ? Palette.muted : Palette.text)
          .accessibilityLabel(row.isDirectory ? "Folder \(row.name)" : "\(row.name), \(row.additions) additions, \(row.deletions) deletions")
        }
      }
      .padding(.vertical, 8)
    }
  }
}
