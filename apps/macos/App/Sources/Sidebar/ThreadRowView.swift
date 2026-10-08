import SwiftUI
import T3ClientRuntime
import T3Contracts

struct ThreadRowView: View {
  @Environment(AppModel.self) private var app
  let row: SidebarRow
  let now: Date

  var body: some View {
    let shell = row.thread.shell
    let slim = row.item.variant == .slim
    HStack(alignment: .center, spacing: 8) {
      StatusGlyph(row: row).frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(shell.title)
          .lineLimit(1)
          .fontWeight(row.isUnread ? .semibold : .regular)
          .foregroundStyle(slim ? .secondary : .primary)
        if !slim {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let badge = pullRequestBadge { badge }
      if row.isWoke { Text("Woke").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(Color.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange) }
      Text(timeLabel)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, slim ? 1 : 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(shell.title), \(statusDescription)")
  }

  private var subtitle: String {
    var parts = [app.projectTitle(of: row.thread)]
    if let branch = row.thread.shell.branch, !branch.isEmpty { parts.append(branch) }
    if app.runtime.environments.count > 1 { parts.append(app.environmentLabel(row.thread.environmentId)) }
    return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
  }

  private var timeLabel: String {
    if let wake = row.snoozeWakeLabel { return wake }
    let shell = row.thread.shell
    let stamp = row.section == .settled ? (shell.settledAt ?? shell.updatedAt) : shell.updatedAt
    return Self.relative(stamp, now: now)
  }

  /// "now", "5m", "2h", "3d", "6w".
  static func relative(_ iso: IsoDateTime, now: Date) -> String {
    guard let date = iso.date else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
    case ..<(86_400 * 60): return "\(Int(seconds / (86_400 * 7)))w"
    default: return "\(Int(seconds / (86_400 * 30)))mo"
    }
  }

  private var pullRequestBadge: AnyView? {
    let shell = row.thread.shell
    let links = shell.pullRequests.filter { $0.source != .stackDismissed }
    guard let link = links.first else { return nil }
    let tint: Color =
      switch link.snapshot?.state {
      case .merged?: .purple
      case .closed?: .red
      case .open?: .green
      default: .secondary
      }
    return AnyView(
      Label("#\(link.number)", systemImage: "arrow.triangle.pull")
        .font(.caption2)
        .foregroundStyle(tint)
        .help(link.snapshot?.title ?? "Pull request #\(link.number)"))
  }

  private var statusDescription: String {
    var parts: [String] = []
    switch row.status {
    case .approval: parts.append("waiting for approval")
    case .input: parts.append("waiting for input")
    case .working: parts.append("working")
    case .failed: parts.append("error")
    case .monitoring: parts.append("monitoring")
    case .ready: break
    }
    if row.isUnread { parts.append("unread") }
    if row.isWoke { parts.append("woke") }
    return parts.joined(separator: ", ")
  }
}

/// Leading status column: a static symbol for what needs attention, else the unread dot. Nothing
/// here animates: a working thread shows a fixed glyph, not a spinner that could outlive the work.
struct StatusGlyph: View {
  let row: SidebarRow
  @Environment(\.backgroundProminence) private var prominence

  /// Accent is invisible on a selected row, whose highlight is also the accent color.
  private var accent: Color { prominence == .increased ? .white : .accentColor }

  var body: some View {
    switch row.status {
    case .approval:
      Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange).help("Waiting for approval")
    case .input:
      Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue).help("Waiting for your answer")
    case .working:
      Image(systemName: "circle.dotted.circle").foregroundStyle(accent).help("Working")
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("The session ended with an error")
    case .monitoring:
      Image(systemName: "binoculars.fill").foregroundStyle(.secondary).help("Watching background work")
    case .ready:
      if row.isUnread {
        Circle().fill(accent).frame(width: 8, height: 8).help("Unread")
      } else if row.thread.shell.pinnedAt.flatMap({ $0 }) != nil {
        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
      } else {
        Color.clear
      }
    }
  }
}
