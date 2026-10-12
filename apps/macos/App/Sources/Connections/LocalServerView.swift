import SwiftUI

/// Sidebar footer line for the server this app runs itself: starting, running on a port, or the error with its actions.
struct LocalServerRow: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let server = app.localServer
    if server.state != .off {
      HStack(spacing: 6) {
        Circle().fill(tint(server.state)).frame(width: 8, height: 8)
        Text(title(server.state)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        switch server.state {
        case .failed:
          Button("Show log") { server.showLog() }
          Button("Restart") { server.restart() }
        case .foreignOwner(let origin):
          Button("Connect\u{2026}") {
            app.addEnvironmentHost = "\(origin.host() ?? "127.0.0.1"):\(origin.port ?? 0)"
            app.sheet = .addEnvironment
          }
          Button("Retry") { server.restart() }
        case .running:
          Button { server.showLog() } label: { Label("Show log", systemImage: "doc.text") }
            .labelStyle(.iconOnly).help("Show server log")
          Button { server.restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
            .labelStyle(.iconOnly).help("Restart local server")
        default: EmptyView()
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .font(.caption)
    }
  }

  private func title(_ state: LocalServer.State) -> String {
    switch state {
    case .off: ""
    case .starting(let attempt): attempt == 0 ? "Starting local server\u{2026}" : "Restarting local server (attempt \(attempt))\u{2026}"
    case .running(let port): "Local server \u{00B7} port \(port)"
    case .stopping: "Stopping local server\u{2026}"
    case .failed(let message): message
    case .foreignOwner(let origin):
      "T3 Code already runs on this Mac (port \(origin.port ?? 0)) with the same data. Connect to it instead of starting a second server."
    }
  }

  private func tint(_ state: LocalServer.State) -> Color {
    switch state {
    case .running: .green
    case .starting, .stopping: .yellow
    case .failed: .red
    case .foreignOwner: .orange
    case .off: .gray
    }
  }
}
