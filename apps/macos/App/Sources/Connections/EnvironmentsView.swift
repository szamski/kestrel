import SwiftUI
import T3ClientRuntime

/// Bottom of the sidebar: the worst connection state at a glance, a popover with the full list.
struct SidebarFooter: View {
  @Environment(AppModel.self) private var app
  @State private var showing = false

  var body: some View {
    let environments = app.runtime.environments
    VStack(alignment: .leading, spacing: 6) {
      LocalServerRow()
      HStack(spacing: 8) {
      Button {
        showing.toggle()
      } label: {
        HStack(spacing: 6) {
          Circle().fill(Self.tint(summary(environments))).frame(width: 8, height: 8)
          Text(environments.isEmpty ? "No environments" : environments.count == 1 ? environments[0].label : "\(environments.count) environments")
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .popover(isPresented: $showing, arrowEdge: .top) { EnvironmentsPopover() }
      Button {
        app.sheet = .addEnvironment
      } label: {
        Label("Add environment", systemImage: "plus")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Add environment")
      }
    }
    .font(.callout)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .themedBarBackground()
  }

  /// Worst state wins: blocked, then not connected, then connecting, else connected.
  private func summary(_ environments: [EnvironmentStatus]) -> ConnectionPhase? {
    let order: [ConnectionPhase] = [.blocked, .offline, .backoff, .available, .connecting, .connected]
    return environments.map { $0.enabled ? $0.connection.phase : .available }.min { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
  }

  static func tint(_ phase: ConnectionPhase?) -> Color {
    switch phase {
    case .connected?: .green
    case .connecting?: .yellow
    case .backoff?: .orange
    case .blocked?: .red
    case .offline?, .available?, nil: .gray
    }
  }
}

struct EnvironmentsPopover: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Environments").font(.headline)
      if app.runtime.environments.isEmpty {
        Text("No environments yet.").foregroundStyle(.secondary)
      }
      ForEach(app.runtime.environments) { status in EnvironmentRow(status: status) }
      Divider()
      Button("Add Environment\u{2026}") { app.sheet = .addEnvironment }
    }
    .padding(14)
    .frame(width: 340)
  }
}

struct EnvironmentRow: View {
  @Environment(AppModel.self) private var app
  let status: EnvironmentStatus

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(SidebarFooter.tint(status.enabled ? status.connection.phase : nil)).frame(width: 9, height: 9).padding(.top, 5)
      VStack(alignment: .leading, spacing: 2) {
        Text(status.label).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 4)
      if status.enabled && status.connection.phase != .connected {
        Button { Task { await app.runtime.retryConnection(status.environmentId) } } label: { Label("Retry", systemImage: "arrow.clockwise") }
          .labelStyle(.iconOnly).buttonStyle(.borderless).help("Retry now")
      }
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { status.enabled }, set: { value in Task { await app.runtime.setEnvironmentEnabled(status.environmentId, value) } })
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.small)
      Button(role: .destructive) {
        app.confirm(
          "Remove \u{201C}\(status.label)\u{201D}?", message: "Its saved credential and cached threads are removed from this Mac. The server keeps its data.",
          confirmTitle: "Remove"
        ) { await app.runtime.removeEnvironment(status.environmentId) }
      } label: { Label("Remove", systemImage: "trash") }
      .labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove environment")
    }
  }

  private var detail: String {
    guard status.enabled else { return "Disabled" }
    let state = status.connection
    switch state.phase {
    case .connected: return "Connected"
    case .connecting:
      switch state.stage {
      case .preparing?: return "Preparing\u{2026}"
      case .opening?: return "Connecting\u{2026}"
      case .synchronizing?: return "Synchronizing\u{2026}"
      case nil: return "Connecting\u{2026}"
      }
    case .backoff:
      let reason = state.lastFailure?.detail ?? "Connection lost."
      if let retryAt = state.retryAt {
        let seconds = max(0, Int((Double(retryAt) / 1000 - Date.now.timeIntervalSince1970).rounded()))
        return "\(reason) Retrying in \(seconds)s."
      }
      return reason
    case .offline: return "Offline"
    case .blocked: return state.lastFailure?.detail ?? "Blocked"
    case .available: return "Not connected"
    }
  }
}

/// Shown in the reading window until the first environment exists.
struct FirstRunView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    ContentUnavailableView {
      Label("Connect to T3 Code", systemImage: "network")
    } description: {
      Text("Add the environment you run agents in. A pairing link from `npx t3` or another T3 Code client is all it takes.")
    } actions: {
      Button("Add Environment\u{2026}") { app.sheet = .addEnvironment }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
  }
}
