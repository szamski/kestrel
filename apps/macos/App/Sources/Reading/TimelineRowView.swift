import AppKit
import SwiftUI
import T3Contracts
import T3Markdown
import T3Timeline

/// Column the conversation reads in, centred in the window (the web chat's max-w-3xl by default; Settings › Appearance › Chat
/// width makes it wider or unbounded).
@MainActor var timelineColumnWidth: CGFloat {
  switch ClientSettingsStore.shared.client.chatWidth {
  case .wide: 1152
  case .full: .infinity
  default: 760
  }
}
let timelineHorizontalInset: CGFloat = 28

/// A timeline row at its place in the column. Everything a row needs besides its value comes from
/// `TimelineHost`, so the same view serves the table cells, the offscreen height measurement and the
/// LazyVStack comparison.
struct TimelineRowContainer: View {
  let item: TimelineItem

  var body: some View {
    let inset = item.row.verticalInsets
    TimelineRowContent(item: item)
      .frame(maxWidth: timelineColumnWidth, alignment: .leading)
      .padding(.horizontal, timelineHorizontalInset)
      .padding(.top, inset.top)
      .padding(.bottom, inset.bottom)
      .frame(maxWidth: .infinity)
      .id(item.id)
  }
}

extension TimelineRow {
  /// Space above and below by kind: messages breathe, tool lines sit close together.
  var verticalInsets: (top: CGFloat, bottom: CGFloat) {
    switch self {
    case .message(let row):
      switch row.message.role {
      case .user: (18, 6)
      case .assistant: (6, 6)
      default: (2, 2)
      }
    case .assistantMeta: (0, 10)
    case .activityGroup, .work, .workLive, .workToggle, .working, .thinking: (2, 2)
    case .turnFold, .contextCompaction: (8, 8)
    case .proposedPlan, .worktreeSetup: (8, 8)
    case .queuedMessage: (6, 6)
    }
  }
}

struct TimelineRowContent: View {
  let item: TimelineItem

  var body: some View {
    switch item.row {
    case .message(let row): MessageRowView(row: row, expanded: item.expanded)
    case .assistantMeta(let row): AssistantMetaView(message: row.message, duration: nil, showsCopy: row.showAssistantCopyButton, streaming: row.assistantCopyStreaming)
    case .activityGroup(let row): ActivityGroupView(row: row)
    case .work(let row): WorkRowView(row: row)
    case .workLive(let row): WorkLiveView(row: row)
    case .workToggle(let row): WorkToggleView(row: row)
    case .turnFold(let row): TurnFoldView(row: row)
    case .contextCompaction(let row): DividerLabel(label: row.label)
    case .proposedPlan(let row): ProposedPlanCard(row: row, expanded: item.expanded)
    case .working(let row): WorkingView(startedAt: row.createdAt)
    case .thinking: ActivityLine(symbol: "brain", label: "Thinking", active: true)
    case .worktreeSetup(let row): WorktreeSetupCard(snapshot: row.snapshot)
    case .queuedMessage(let row): QueuedMessageView(row: row)
    }
  }
}

// MARK: - Messages

struct MessageRowView: View {
  let row: MessageRow
  let expanded: Bool
  @Environment(\.timelineHost) private var host

  var body: some View {
    let message = row.message
    switch message.role {
    case .user:
      UserBubble(message: message)
    case .assistant:
      VStack(alignment: .leading, spacing: 8) {
        MarkdownView(
          message.text, options: host?.markdownOptions ?? MarkdownOptions(), imageLoader: host?.imageLoader,
          onLink: { host?.openLink($0) })
        if let summary = row.assistantTurnDiffSummary, !summary.files.isEmpty { TurnDiffCard(summary: summary) }
        if row.showAssistantMeta {
          AssistantMetaView(
            message: message, duration: durationLabel, showsCopy: row.showAssistantCopyButton, streaming: row.assistantCopyStreaming)
        }
      }
    case .reasoning:
      ReasoningDisclosure(messageId: message.id.rawValue, text: message.text, expanded: expanded)
    default:
      Text(message.text).font(.callout).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
    }
  }

  private var durationLabel: String? {
    guard let start = IsoDateTime(row.durationStart).date, let end = row.message.updatedAt.date, end > start else { return nil }
    return formatDuration(end.timeIntervalSince(start) * 1000)
  }
}

struct UserBubble: View {
  let message: V1.OrchestrationMessage
  @Environment(\.timelineHost) private var host

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Spacer(minLength: 48)
      VStack(alignment: .trailing, spacing: 8) {
        ForEach(Array((message.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
          switch attachment {
          case .image(let image): AttachmentImage(image: image)
          case .file(let file): AttachmentChip(name: file.name)
          case .other(let other): AttachmentChip(name: other.name)
          case .unknown: EmptyView()
          }
        }
        if !message.text.isEmpty {
          MarkdownView(
            message.text, options: MarkdownOptions(softBreaksAsNewlines: true, baseDirectory: host?.workspaceRoot),
            imageLoader: host?.imageLoader, onLink: { host?.openLink($0) }
          )
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .frame(maxWidth: Self.hugWidth(message.text) ?? .infinity, alignment: .trailing)
          .background(Palette.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .contextMenu { Button("Copy") { host?.copy(message.text) } }
        }
      }
    }
  }

  /// Plain one-line messages hug their text; everything else takes the available width. The
  /// Markdown view has no intrinsic width, so the hug width is measured from the body font.
  static func hugWidth(_ text: String) -> CGFloat? {
    guard text.count < 80, !text.contains(where: { "\n`*_[]<>#|~\\".contains($0) }) else { return nil }
    let font = NSFont.systemFont(ofSize: MarkdownTheme.defaultBodySize)
    return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 28 + 6
  }
}

struct AttachmentImage: View {
  let image: ChatImageAttachment
  @Environment(\.timelineHost) private var host
  @State private var loaded: NSImage?

  var body: some View {
    Group {
      if let loaded {
        Image(nsImage: loaded).resizable().scaledToFit()
      } else {
        Color.clear.overlay { Image(systemName: "photo").foregroundStyle(Palette.muted) }
      }
    }
    .frame(width: 220, height: 150)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityLabel(image.name)
    .task(id: image.id) {
      guard let host else { return }
      loaded = await host.assets.attachment(image, in: host.key)
    }
  }
}

struct AttachmentChip: View {
  let name: String

  var body: some View {
    Label(name, systemImage: "doc")
      .font(.callout)
      .lineLimit(1)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Palette.surface, in: Capsule())
  }
}

struct AssistantMetaView: View {
  let message: V1.OrchestrationMessage
  let duration: String?
  let showsCopy: Bool
  let streaming: Bool
  @Environment(\.timelineHost) private var host

  var body: some View {
    HStack(spacing: 8) {
      if let date = message.updatedAt.date {
        Text(date, format: ClientSettingsStore.shared.timeStyle)
      }
      if let duration { Text(duration) }
      if showsCopy && !streaming {
        Button {
          host?.copy(message.text)
        } label: {
          Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help("Copy message")
      }
    }
    .font(.caption)
    .foregroundStyle(Palette.muted)
    .frame(minHeight: 20, alignment: .leading)
  }
}

struct ReasoningDisclosure: View {
  let messageId: String
  let text: String
  let expanded: Bool
  @Environment(\.timelineHost) private var host

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        host?.toggleLocal(messageId)
      } label: {
        ActivityLine(symbol: "brain", label: "Thought", chevron: expanded)
      }
      .buttonStyle(.plain)
      if expanded {
        MarkdownView(text, options: MarkdownOptions(), onLink: { host?.openLink($0) })
          .opacity(0.75)
          .padding(.leading, 24)
      }
    }
  }
}

// MARK: - Changed files, plan, setup

struct TurnDiffCard: View {
  let summary: V1.OrchestrationCheckpointSummary
  @Environment(\.timelineHost) private var host
  private static let shown = 8

  var body: some View {
    let stat = summarizeTurnDiffStats(summary.files)
    let files = summary.files.sorted { $0.path < $1.path }
    VStack(alignment: .leading, spacing: 6) {
      Button { host?.openDiff(summary.turnId, nil) } label: {
        HStack(spacing: 8) {
          Text("Changed files (\(files.count))").font(.callout.weight(.medium))
          Spacer(minLength: 0)
          DiffStat(additions: stat.additions, deletions: stat.deletions)
          Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("View diff")
      ForEach(files.prefix(Self.shown), id: \.path) { file in
        Button { host?.openDiff(summary.turnId, file.path) } label: {
          HStack(spacing: 8) {
            Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            DiffStat(additions: file.additions, deletions: file.deletions)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.muted)
        .help("View diff of \(file.path)")
      }
      if files.count > Self.shown {
        Text("+\(files.count - Self.shown) more").font(.caption).foregroundStyle(Palette.muted)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
  }
}

struct DiffStat: View {
  let additions: Int
  let deletions: Int

  var body: some View {
    HStack(spacing: 4) {
      Text("+\(additions)").foregroundStyle(.green)
      Text("\u{2212}\(deletions)").foregroundStyle(.red)
    }
    .font(.system(size: 12, weight: .medium, design: .monospaced))
  }
}

struct ProposedPlanCard: View {
  let row: ProposedPlanRow
  let expanded: Bool
  @Environment(\.timelineHost) private var host
  private static let collapsedHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Proposed plan", systemImage: "list.bullet.clipboard").font(.callout.weight(.medium))
        Spacer(minLength: 0)
        if row.proposedPlan.implementedAt != nil {
          Text("Implemented").font(.caption.weight(.medium)).foregroundStyle(.green)
        }
      }
      MarkdownView(row.proposedPlan.planMarkdown, options: host?.markdownOptions ?? MarkdownOptions(), onLink: { host?.openLink($0) })
        .frame(maxHeight: expanded ? nil : Self.collapsedHeight, alignment: .top)
        .clipped()
      Button(expanded ? "Collapse plan" : "Expand plan") { host?.toggleLocal(row.id) }
        .buttonStyle(.link)
        .font(.callout)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
  }
}

struct WorktreeSetupCard: View {
  let snapshot: WorktreeSetupSnapshot
  @Environment(\.timelineHost) private var host

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(title, systemImage: "arrow.triangle.branch").font(.callout.weight(.medium))
        Spacer()
        if snapshot.phase == .running { Button("Cancel") { host?.cancelWorktreeSetup() }.controlSize(.small) }
      }
      if let branch = snapshot.branch { Text(branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted) }
      ForEach(snapshot.stages, id: \.id) { stage in
        HStack(spacing: 8) {
          Image(systemName: Self.symbol(stage.status)).foregroundStyle(Self.tint(stage.status)).frame(width: 16)
          Text(Self.name(stage.id))
          if let detail = stage.detail { Text(detail).foregroundStyle(Palette.muted).lineLimit(1) }
        }
        .font(.callout)
      }
      if let error = snapshot.error { Text(error).font(.callout).foregroundStyle(.red) }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
  }

  private var title: String {
    switch snapshot.phase {
    case .running: "Preparing worktree"
    case .done: "Worktree ready"
    case .failed: "Worktree setup failed"
    case .cancelled: "Worktree setup cancelled"
    case .unknown: "Worktree"
    }
  }

  private static func name(_ id: WorktreeSetupStageId) -> String {
    switch id {
    case .fetch: "Fetch"
    case .checkout: "Checkout"
    case .submodules: "Submodules"
    case .setupScript: "Setup script"
    case .agent: "Start agent"
    case .unknown(let raw): raw
    }
  }

  private static func symbol(_ status: WorktreeSetupStageStatus) -> String {
    switch status {
    case .pending: "circle"
    case .running: "circle.dotted"
    case .done: "checkmark.circle.fill"
    case .skipped: "minus.circle"
    case .warning: "exclamationmark.triangle.fill"
    case .failed: "xmark.circle.fill"
    case .unknown: "circle"
    }
  }

  private static func tint(_ status: WorktreeSetupStageStatus) -> Color {
    switch status {
    case .done: .green
    case .warning: .orange
    case .failed: .red
    case .running: .accentColor
    default: Palette.muted
    }
  }
}

struct QueuedMessageView: View {
  let row: QueuedMessageRow

  var body: some View {
    HStack {
      Spacer(minLength: 48)
      Text(row.queuedMessage.text)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.bubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) { Text("Queued").font(.caption2).foregroundStyle(Palette.muted).offset(y: 14) }
    }
  }
}

// MARK: - Work log

/// One-line activity entry: icon, label, optional disclosure chevron. Always a single line so its
/// height is the same everywhere.
struct ActivityLine: View {
  var symbol: String
  var label: String
  var active = false
  var failed = false
  /// nil: not expandable; otherwise whether it is open.
  var chevron: Bool?
  var trailing: String?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(failed ? Color.red : active ? Color.accentColor : Palette.muted)
        .frame(width: 16)
      Text(label)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(failed ? Color.red : active ? Palette.text : Palette.muted)
      if let trailing { Text(trailing).font(.caption).foregroundStyle(Palette.muted) }
      if let chevron {
        Image(systemName: chevron ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 13))
    .frame(height: 24)
    .contentShape(Rectangle())
  }
}

enum WorkSymbols {
  static func symbol(_ entry: WorkLogEntry) -> String {
    if let presentation = resolveWorkEntryToolPresentation(entry) {
      switch presentation.icon {
      case .pullRequest: return "arrow.triangle.pull"
      case .browser: return "globe"
      case .device: return "iphone"
      case .t3Code: return "wrench.and.screwdriver"
      }
    }
    switch entry.itemType {
    case .commandExecution?: return "terminal"
    case .fileChange?: return "pencil"
    case .mcpToolCall?, .dynamicToolCall?: return "wrench.and.screwdriver"
    case .collabAgentToolCall?: return "person.2"
    case .webSearch?: return "magnifyingglass"
    case .imageView?: return "photo"
    case nil:
      switch entry.tone {
      case .thinking: return "brain"
      case .error: return "exclamationmark.triangle"
      case .info: return "info.circle"
      case .tool: return "wrench"
      }
    }
  }

  static func symbol(_ kind: ToolGroupSummaryKind) -> String {
    switch kind {
    case .pullRequest, .linkPR, .unlinkPR, .listPRs: "arrow.triangle.pull"
    case .read: "doc.text"
    case .edit, .update: "pencil"
    case .command: "terminal"
    case .browser: "globe"
    case .device: "iphone"
    case .codeSearch, .search: "magnifyingglass"
    case .agentTool: "person.2"
    case .dynamicTool, .toneTool, .other: "wrench"
    case .mixed: "square.stack.3d.up"
    }
  }
}

struct WorkEntryLine: View {
  let entry: WorkLogEntry
  var showsDetail = false
  @Environment(\.timelineHost) private var host

  var body: some View {
    let failed = workEntryDisplayIndicatesToolFailure(entry)
    if entry.tone == .error {
      ErrorBanner(title: entry.label, detail: entry.detail)
    } else {
      VStack(alignment: .leading, spacing: 2) {
        ActivityLine(symbol: WorkSymbols.symbol(entry), label: workEntryDisplayLabel(entry, workspaceRoot: host?.workspaceRoot), failed: failed)
        if showsDetail, let command = entry.command, !command.isEmpty, workEntryDisplayLabel(entry, workspaceRoot: host?.workspaceRoot) != command {
          Text(command)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Palette.muted)
            .lineLimit(2)
            .padding(.leading, 24)
        }
      }
    }
  }
}

struct ErrorBanner: View {
  let title: String
  let detail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.medium)).foregroundStyle(.red)
      if let detail, !detail.isEmpty {
        Text(detail).font(.callout).foregroundStyle(Palette.text).lineLimit(8).textSelection(.enabled)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct WorkRowView: View {
  let row: WorkRow

  var body: some View {
    if row.isExpandedToolGroup {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(row.groupedEntries) { WorkEntryLine(entry: $0, showsDetail: true) }
      }
      .padding(.leading, 12)
    } else if let first = row.groupedEntries.first {
      if first.tone == .error {
        ErrorBanner(title: first.label, detail: first.detail)
      } else if let answer = first.questionAnswer {
        UserInputAnswerView(answer: answer)
      } else {
        ActivityLine(
          symbol: WorkSymbols.symbol(first), label: row.displayLabel ?? first.label,
          failed: workEntryDisplayIndicatesToolFailure(first))
      }
    }
  }
}

struct UserInputAnswerView: View {
  let answer: UserInputAnswer

  var body: some View {
    ActivityLine(symbol: "text.bubble", label: "Answered \(answer.answers.count) question\(answer.answers.count == 1 ? "" : "s")")
  }
}

struct WorkLiveView: View {
  let row: WorkLiveRow
  @Environment(\.timelineHost) private var host

  var body: some View {
    let expandable = row.groupedEntries.count > 1
    Button {
      host?.toggleWorkGroup(row.groupId)
    } label: {
      ActivityLine(
        symbol: WorkSymbols.symbol(row.entry),
        label: liveWorkEntryLabel(row.entry, workspaceRoot: host?.workspaceRoot, active: row.active),
        active: row.active, failed: workEntryDisplayIndicatesToolFailure(row.entry), chevron: expandable ? row.expanded : nil)
    }
    .buttonStyle(.plain)
  }
}

struct WorkToggleView: View {
  let row: WorkToggleRow
  @Environment(\.timelineHost) private var host

  var body: some View {
    Button {
      host?.toggleWorkGroup(row.groupId)
    } label: {
      ActivityLine(
        symbol: WorkSymbols.symbol(row.summaryKind), label: row.summary, failed: row.hasFailure, chevron: row.expanded,
        trailing: row.hiddenCount > 1 ? "\(row.hiddenCount)" : nil)
    }
    .buttonStyle(.plain)
  }
}

struct ActivityGroupView: View {
  let row: ActivityGroupRow
  @Environment(\.timelineHost) private var host

  var body: some View {
    let works: [WorkLogEntry] = row.entries.compactMap {
      if case .work(let entry) = $0, workEntryIsVisibleInGroup(entry, expandedToolGroupEntry: row.active) { entry } else { nil }
    }
    let work = omitSupersededLifecycleMarkers(works, workEntryFor: { $0 })
    let thoughts = row.entries.filter { if case .message = $0 { true } else { false } }.count
    let lastThought = row.entries.lastIndex { if case .message = $0 { true } else { false } }
    let trailing = omitSupersededLifecycleMarkers(
      row.entries[(lastThought.map { $0 + 1 } ?? 0)...].compactMap {
        if case .work(let entry) = $0, workEntryIsVisibleInGroup(entry, expandedToolGroupEntry: row.active) { entry } else { nil }
      }, workEntryFor: { $0 })
    let live = trailing.last(where: workEntryIsActiveTurnActivity) ?? trailing.last
    let iconWork = row.active ? live : work.last
    let failed = iconWork.map(workEntryDisplayIndicatesToolFailure) ?? false
    let label =
      row.active
      ? (live.map { liveWorkEntryLabel($0, workspaceRoot: host?.workspaceRoot, active: true) } ?? "Thinking")
      : (work.isEmpty ? "Thought" + (thoughts > 1 ? " (\u{00D7}\(thoughts))" : "") : summarizeToolGroup(work))
    VStack(alignment: .leading, spacing: 4) {
      Button {
        host?.toggleWorkGroup(row.groupId)
      } label: {
        ActivityLine(
          symbol: iconWork.map(WorkSymbols.symbol) ?? "brain", label: label, active: row.active, failed: failed, chevron: row.expanded)
      }
      .buttonStyle(.plain)
      if row.expanded { details }
    }
  }

  @ViewBuilder private var details: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
        switch run {
        case .work(let entries):
          VStack(alignment: .leading, spacing: 0) { ForEach(entries) { WorkEntryLine(entry: $0, showsDetail: true) } }
        case .thoughts(let messages):
          MarkdownView(messages.map(\.text).joined(separator: "\n\n"), options: MarkdownOptions(), onLink: { host?.openLink($0) })
            .opacity(0.75)
        }
      }
    }
    .padding(.leading, 24)
  }

  private enum Run {
    case work([WorkLogEntry])
    case thoughts([V1.OrchestrationMessage])
  }

  private var runs: [Run] {
    var out: [Run] = []
    for entry in row.entries {
      switch entry {
      case .work(let work):
        if case .work(let previous)? = out.last { out[out.count - 1] = .work(previous + [work]) } else { out.append(.work([work])) }
      case .message(let message):
        if case .thoughts(let previous)? = out.last { out[out.count - 1] = .thoughts(previous + [message]) } else { out.append(.thoughts([message])) }
      }
    }
    return out.map {
      if case .work(let entries) = $0 { .work(omitSupersededLifecycleMarkers(entries, workEntryFor: { $0 })) } else { $0 }
    }
  }
}

struct TurnFoldView: View {
  let row: TurnFoldRow
  @Environment(\.timelineHost) private var host

  var body: some View {
    Button {
      host?.toggleTurn(row.turnId)
    } label: {
      HStack(spacing: 10) {
        Rectangle().fill(Palette.border).frame(height: 1)
        HStack(spacing: 4) {
          Text(row.label)
          Image(systemName: row.expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 12))
        .foregroundStyle(Palette.muted)
        .fixedSize()
        Rectangle().fill(Palette.border).frame(height: 1)
      }
      .frame(height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct DividerLabel: View {
  let label: String

  var body: some View {
    HStack(spacing: 10) {
      Rectangle().fill(Palette.border).frame(height: 1)
      Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize()
      Rectangle().fill(Palette.border).frame(height: 1)
    }
    .frame(height: 20)
  }
}

/// "Working for 1:20". The system updates the timer text itself; no view of ours repaints per tick.
struct WorkingView: View {
  let startedAt: String?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentColor).frame(width: 16)
      if let start = startedAt.flatMap({ IsoDateTime($0).date }) {
        Text("Working for \(Text(timerInterval: start...Date.distantFuture, pauseTime: nil, countsDown: false, showsHours: false))")
          .foregroundStyle(Palette.text)
      } else {
        Text("Working").foregroundStyle(Palette.text)
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 13))
    .frame(height: 24)
  }
}
