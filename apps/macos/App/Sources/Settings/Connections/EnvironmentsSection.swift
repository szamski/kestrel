import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Connections › Environments: the servers this Mac connects to besides its own, saved by pairing link or
/// host and code (or through T3 Connect), with the add sheet of the sidebar.
struct EnvironmentsSection: View {
  @Environment(AppModel.self) private var app
  /// Every saved environment but this Mac's own server.
  let environments: [EnvironmentStatus]

  @State private var adding = false
  @State private var removing: EnvironmentStatus?

  var body: some View {
    Section {
      if environments.isEmpty {
        Text("No other environments yet. Add one with a pairing link from `npx t3` or another T3 Code client.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(environments) { status in
        EnvironmentRow(status: status) { removing = $0 }
      }
      sshPlaceholder
    } header: {
      HStack {
        Text("Environments").id("remote-environments")
        Spacer()
        Button("Add environment", systemImage: "plus") { adding = true }
      }
    }
    .sheet(isPresented: $adding) { AddEnvironmentSheet() }
    .confirmationDialog(
      "Remove \u{201C}\(removing?.label ?? "")\u{201D}?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Remove", role: .destructive) {
        if let removing { Task { await app.runtime.removeEnvironment(removing.environmentId) } }
      }
    } message: {
      Text(EnvironmentRow.removalMessage)
    }
  }

  /// The decided approach is a `t3` CLI subcommand that starts or reuses a server over SSH; it is not built yet.
  private var sshPlaceholder: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "terminal").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("SSH")
        Text("Use your SSH config and agent to start or reuse a T3 Code server on another machine.").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Text("Coming soon").font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
    }
    .opacity(0.7)
  }
}

/// Settings › Connections › Load balancing: how often each machine receives new threads in shared projects. Preferences
/// are saved on this device; the choice itself is `LoadBalancing.choose`. Shown once two or more machines are switched on.
struct LoadBalancingSection: View {
  @Environment(SettingsModel.self) private var settings
  let environments: [EnvironmentStatus]

  var body: some View {
    let client = settings.client
    Section {
      Text("New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine's preference.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ForEach(environments) { status in
        HStack {
          Text(status.label)
          Spacer()
          Picker(
            "\(status.label) load preference",
            selection: Binding(
              get: { LoadBalancing.Preference(weight: client.loadBalancingWeights[status.environmentId.rawValue]) },
              set: { value in settings.updateClient { $0.loadBalancingWeights[status.environmentId.rawValue] = value.rawValue } })
          ) {
            ForEach(LoadBalancing.Preference.allCases) { Text($0.label).tag($0) }
          }
          .labelsHidden().fixedSize().disabled(!client.loadBalancingEnabled)
        }
      }
    } header: {
      HStack {
        Text("Load balancing").id("load-balancing")
        if let summary = summary(client) { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        Spacer()
        Toggle("Automatically balance load", isOn: Binding(get: { client.loadBalancingEnabled }, set: { value in settings.updateClient { $0.loadBalancingEnabled = value } }))
          .labelsHidden().toggleStyle(.switch).controlSize(.small)
      }
    }
  }

  private func summary(_ client: ClientSettingsSchema) -> String? {
    guard client.loadBalancingEnabled else { return "Off" }
    return LoadBalancing.summary(environments.map { ($0.environmentId.rawValue, $0.label) }, weights: client.loadBalancingWeights)
  }
}

/// Settings › Connections › GitHub sharing. Web lets machines read pull request data through each other's GitHub access;
/// this app has no pull request surface yet, so there is nothing to grant.
struct GitHubSharingSection: View {
  var body: some View {
    Section {
      Text("Sharing GitHub access between machines applies to pull request views that read through the server, which this app does not have yet.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } header: {
      Text("GitHub sharing").id("github-routing")
    }
  }
}
