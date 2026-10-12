import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// A pull request on the environment that owns its project: what every `pullRequests.*` RPC and every tab names.
struct PullRequestTarget: Hashable, Sendable, Identifiable {
  var environmentId: EnvironmentId
  var projectId: ProjectId
  var host: String
  var repository: String
  var number: Int

  var ref: PullRequestRef { PullRequestRef(projectId: projectId, host: host, repository: repository, number: number) }
  var id: String { [environmentId.rawValue, projectId.rawValue, host, repository, String(number)].joined(separator: "|") }
  var label: String { "#\(number)" }

  init(environmentId: EnvironmentId, projectId: ProjectId, host: String, repository: String, number: Int) {
    self.environmentId = environmentId
    self.projectId = projectId
    self.host = host
    self.repository = repository
    self.number = number
  }

  init(_ row: EnvironmentPullRequestEntry) {
    self.init(environmentId: row.environmentId, projectId: row.entry.projectId, host: row.entry.host, repository: row.entry.repository, number: row.entry.number)
  }

  init?(id: String) {
    let parts = id.components(separatedBy: "|")
    guard parts.count == 5, let number = Int(parts[4]) else { return nil }
    self.init(environmentId: EnvironmentId(rawValue: parts[0]), projectId: ProjectId(rawValue: parts[1]), host: parts[2], repository: parts[3], number: number)
  }
}

/// How a pull request looks in lists and headers: lifecycle glyph, checks and review glyphs, relative times.
@MainActor
enum PullRequestStyle {
  static func symbol(_ state: PullRequestState, draft: Bool) -> String {
    if draft && state == .open { return "arrow.triangle.pull" }
    switch state {
    case .merged: return "arrow.triangle.merge"
    case .closed: return "xmark.circle"
    default: return "arrow.triangle.pull"
    }
  }

  static func tint(_ state: PullRequestState, draft: Bool) -> Color {
    if draft && state == .open { return .secondary }
    switch state {
    case .open: return .green
    case .merged: return .purple
    case .closed: return .red
    default: return .secondary
    }
  }

  static func title(_ state: PullRequestState, draft: Bool) -> String {
    if draft && state == .open { return "Draft" }
    switch state {
    case .open: return "Open"
    case .merged: return "Merged"
    case .closed: return "Closed"
    case .unknown(let raw): return raw.capitalized
    }
  }

  static func checksSymbol(_ state: PullRequestChecksState?) -> (name: String, tint: Color, help: String)? {
    switch state {
    case .passing?: ("checkmark.circle.fill", .green, "Checks passing")
    case .failing?: ("xmark.circle.fill", .red, "Checks failing")
    case .pending?: ("circle.dotted", .orange, "Checks running")
    default: nil
    }
  }

  static func reviewSymbol(_ decision: PullRequestReviewDecision?) -> (name: String, tint: Color, help: String)? {
    switch decision {
    case .approved?: ("checkmark.seal.fill", .green, "Approved")
    case .changesRequested?: ("exclamationmark.bubble.fill", .orange, "Changes requested")
    case .reviewRequired?: ("eye", .secondary, "Review required")
    default: nil
    }
  }

  static func checkSymbol(_ status: PullRequestCheckStatus) -> (name: String, tint: Color) {
    switch status {
    case .success: ("checkmark.circle.fill", .green)
    case .failure: ("xmark.circle.fill", .red)
    case .cancelled: ("slash.circle.fill", .orange)
    case .pending: ("circle.dotted", .orange)
    case .actionRequired: ("exclamationmark.circle.fill", .orange)
    case .skipped, .neutral: ("minus.circle", .secondary)
    case .unknown: ("questionmark.circle", .secondary)
    }
  }

  static func relative(_ iso: IsoDateTime?, now: Date = .now) -> String {
    guard let iso, let date = iso.date else { return "" }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
  }

  static func absolute(_ iso: IsoDateTime) -> String { iso.date.map { ClientSettingsStore.shared.timestamp($0) } ?? iso.rawValue }

  /// `#rrggbb` of a host label, nil for anything else.
  static func labelColor(_ hex: String?) -> Color? {
    let hex = hex?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) ?? ""
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }

  static func emoji(_ content: PullRequestReactionContent) -> String {
    switch content {
    case .thumbsUp: "\u{1F44D}"
    case .thumbsDown: "\u{1F44E}"
    case .laugh: "\u{1F604}"
    case .hooray: "\u{1F389}"
    case .confused: "\u{1F615}"
    case .heart: "\u{2764}\u{FE0F}"
    case .rocket: "\u{1F680}"
    case .eyes: "\u{1F440}"
    case .unknown: "\u{2753}"
    }
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  static let reactionOrder: [PullRequestReactionContent] = [.thumbsUp, .thumbsDown, .laugh, .hooray, .confused, .heart, .rocket, .eyes]
}

/// A person's avatar, or their initial where there is none or it did not load.
struct PullRequestAvatar: View {
  let actor: PullRequestActor?
  var size: CGFloat = 18

  var body: some View {
    Group {
      if let url = actor?.avatarUrl.flatMap({ URL(string: $0) }), url.scheme == "https" {
        AsyncImage(url: url) { phase in
          if let image = phase.image { image.resizable().scaledToFill() } else { initial }
        }
      } else {
        initial
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var initial: some View {
    ZStack {
      Circle().fill(.quaternary)
      Text(String((actor?.login ?? "?").prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary)
    }
  }
}

struct PullRequestLabelChip: View {
  let name: String
  let color: String?

  var body: some View {
    let tint = PullRequestStyle.labelColor(color) ?? .secondary
    Text(name)
      .font(.caption2.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 6).padding(.vertical, 1)
      .background(tint.opacity(0.18), in: Capsule())
      .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
  }
}

/// State of the pull request as a small capsule: Open, Draft, Merged, Closed.
struct PullRequestStatePill: View {
  let state: PullRequestState
  let draft: Bool

  var body: some View {
    Label(PullRequestStyle.title(state, draft: draft), systemImage: PullRequestStyle.symbol(state, draft: draft))
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(PullRequestStyle.tint(state, draft: draft), in: Capsule())
  }
}
