import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// What `server.discoverSourceControl` found on one environment: version control tools and hosting integrations, with
/// the credentials forms of GitHub and Bitbucket. Discovery scans one machine, so it follows the scope's first connected
/// environment (named in the title when several are selected).
struct SourceControlDiscoverySections: View {
  @Environment(SettingsModel.self) private var model
  @State private var result: SourceControlDiscoveryResult?
  @State private var failure: String?
  @State private var scanning = false

  private var environmentId: EnvironmentId? { model.targets.first?.environmentId }

  var body: some View {
    let suffix = suffix()
    Group {
      if let environmentId {
        if let result, !result.versionControlSystems.isEmpty || !result.sourceControlProviders.isEmpty {
          if !result.versionControlSystems.isEmpty {
            Section {
              ForEach(result.versionControlSystems, id: \.kind) { item in
                DiscoveryRow(
                  id: item.kind == .git ? "source-control" : "vcs-\(item.kind.rawValue)", label: item.label, version: item.version, available: item.status == .available && item.implemented,
                  badge: item.implemented ? nil : "Coming soon", icon: item.kind == .git ? "arrow.triangle.branch" : "arrow.triangle.2.circlepath",
                  summary: Text(item.implemented ? (item.status == .available ? "Available" : "Not available on this server: \(item.installHint)") : "Support for \(item.label) is coming soon.")
                )
              }
              GitFetchIntervalRow()
            } header: {
              header("Version Control\(suffix)")
            }
          }
          if !result.sourceControlProviders.isEmpty {
            Section {
              ForEach(result.sourceControlProviders, id: \.kind) { item in
                ProviderRow(item: item, environmentId: environmentId, rescan: { Task { await scan() } })
              }
            } header: {
              header(result.versionControlSystems.isEmpty ? "Source Control Providers\(suffix)" : "Source Control Providers", showScan: result.versionControlSystems.isEmpty)
            }
          }
        } else {
          Section {
            if scanning && result == nil {
              HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning the server environment…").foregroundStyle(.secondary) }
            } else {
              ContentUnavailableView {
                Label(failure == nil ? "Nothing detected yet" : "Could not scan the server environment", systemImage: "arrow.triangle.pull")
              } description: {
                Text(failure ?? "Install Git on the server, add optional hosting integrations or credentials your workspace needs, then rescan.")
              } actions: {
                Button("Scan") { Task { await scan() } }.disabled(scanning)
              }
            }
          } header: {
            header("Server environment")
          }
        }
      } else {
        Section("Server environment") {
          Text("Connect an environment to inspect its version control tools and hosting integrations.").foregroundStyle(.secondary)
        }
      }
    }
    .task(id: environmentId) {
      result = nil
      failure = nil
      await scan()
    }
  }

  private func suffix() -> String {
    guard model.scope.environmentIds.count != 1, model.targets.count > 1, let id = environmentId,
      let label = model.environments.first(where: { $0.environmentId == id })?.label
    else { return "" }
    return " · \(label)"
  }

  private func header(_ title: String, showScan: Bool = true) -> some View {
    HStack {
      Text(title)
      Spacer()
      if showScan, environmentId != nil {
        Button { Task { await scan() } } label: {
          if scanning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.borderless).disabled(scanning).help("Rescan Git and hosting integrations").accessibilityLabel("Rescan server environment")
      }
    }
  }

  private func scan() async {
    guard let id = environmentId, !scanning else { return }
    scanning = true
    defer { scanning = false }
    guard let session = await model.runtime.runtime(for: id)?.supervisor.session.value else {
      failure = "The environment is not connected."
      return
    }
    do {
      let found = try await session.call(Rpc.serverDiscoverSourceControl, EmptyObject())
      guard id == environmentId else { return }
      result = found
      failure = nil
    } catch {
      guard id == environmentId else { return }
      failure = "The server could not scan its source control tools."
    }
  }
}

/// One discovered tool: status dot and icon, name, version, one line about its state, optional credentials details.
private struct DiscoveryRow: View {
  let id: String
  let label: String
  let version: String?
  /// Usable right now (tool found, and for a provider signed in).
  let available: Bool
  var warning = false
  var badge: String?
  let icon: String
  let summary: Text
  var expanded: Binding<Bool> = .constant(false)
  var details: AnyView?

  var body: some View {
    let dot: Color = warning ? .orange : available ? .green : badge != nil ? .secondary : .orange
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon).frame(width: 22).overlay(alignment: .topLeading) { Circle().fill(dot).frame(width: 7, height: 7).offset(x: -3, y: -2) }
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(label).fontWeight(.medium)
            if let version { Text(version).font(.caption).monospaced().foregroundStyle(.secondary) }
            if let badge { Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(.orange.opacity(0.18), in: Capsule()) }
          }
          summary.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if details != nil {
          Button { withAnimation(.snappy(duration: 0.2)) { expanded.wrappedValue.toggle() } } label: { Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down") }
            .buttonStyle(.borderless).accessibilityLabel("Toggle \(label) details")
        }
        Image(systemName: available ? "checkmark.circle.fill" : "circle").foregroundStyle(available ? Color.green : Color.secondary)
          .accessibilityLabel("\(label) \(available ? "available" : "not available")")
      }
      if expanded.wrappedValue, let details { details.padding(.leading, 32) }
    }
    .padding(.vertical, 2)
    .id(id)
  }
}

private struct ProviderRow: View {
  @Environment(SettingsModel.self) private var model
  let item: SourceControlProviderDiscoveryItem
  let environmentId: EnvironmentId
  let rescan: () -> Void
  @State private var expanded = false

  private var anchor: String? { item.kind == .github ? "github-accounts" : item.kind == .bitbucket ? "bitbucket-credentials" : nil }

  var body: some View {
    let auth = item.auth
    let authenticated = auth.status == .authenticated
    let available = item.status == .available && authenticated
    let hasDetails = item.kind == .github || item.kind == .bitbucket
    DiscoveryRow(
      id: anchor ?? "provider-\(item.kind.rawValue)", label: item.label, version: item.version, available: available,
      warning: item.status == .available && auth.status == .unauthenticated, badge: auth.status == .unauthenticated ? "Not authenticated" : nil,
      icon: item.kind == .github || item.kind == .gitlab ? "arrow.triangle.pull" : "shippingbox", summary: summary(authenticated: authenticated),
      expanded: $expanded,
      details: hasDetails
        ? AnyView(
          Group {
            if item.kind == .bitbucket {
              BitbucketCredentialsForm(environmentId: environmentId, onSaved: rescan).id(environmentId)
            } else {
              VStack(alignment: .leading, spacing: 18) {
                GitHubTokenForm(environmentId: environmentId, onSaved: rescan).id("token-\(environmentId.rawValue)")
                if item.status == .available { GitHubAccountsForm(environmentId: environmentId, auth: auth, onSaved: rescan).id(environmentId) }
              }
            }
          }) : nil
    )
    .onChange(of: model.jump?.token) {
      if let anchor, model.jump?.id == anchor { expanded = true }
    }
  }

  private func summary(authenticated: Bool) -> Text {
    let auth = item.auth
    if item.status != .available { return Text("Not available on this server: \(item.installHint)") }
    if authenticated {
      let account = auth.account.map { Text(" as \(Text($0).monospaced())") } ?? Text("")
      return Text("Authenticated\(account)\(Text(auth.detail.map { " · \($0)" } ?? ""))")
    }
    // API integrations have no CLI to sign in with.
    if item.executable == nil, auth.status == .unauthenticated { return Text("Available. \(item.installHint)") }
    if auth.status == .unauthenticated, auth.accounts?.contains(where: \.authenticated) == true {
      return Text(auth.detail ?? "Every \(item.label) host is turned off.")
    }
    if auth.status == .unauthenticated {
      return Text(
        "\(item.label) is not authenticated on this server. Sign in or configure credentials using the \(item.executable ?? "provider") tool on the server host to enable change request features."
      )
    }
    return Text("Could not verify \(item.label). \(auth.detail ?? item.installHint)")
  }
}

// MARK: Git fetch interval

/// Automatic Git fetch interval in seconds; 0 turns it off. Stored in the shared background activity policy.
private struct GitFetchIntervalRow: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    let server = model.server
    let resolved = BackgroundActivityPolicy.resolved(server)
    let seconds = Int((resolved.automaticGitFetchInterval / 1000).rounded())
    let preset = Int((BackgroundActivityPolicy.preset(resolved.profile).automaticGitFetchInterval / 1000).rounded())
    SettingRow(
      id: "git-fetch-interval", title: "Git fetch interval",
      help: "Refresh remote branches in the background. Set to 0 to avoid automatic Git prompts. The shared Background activity policy still decides whether Git refreshes may run when the timer fires.",
      keys: ["backgroundActivity"], isDefault: seconds == preset, reset: { set(preset) }
    ) {
      HStack(spacing: 6) {
        CommitTextField(value: String(seconds)) { text in
          if let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 0, value != seconds { set(value) }
        }
        .multilineTextAlignment(.trailing).frame(width: 72).accessibilityLabel("Automatic Git fetch interval in seconds")
        Text("seconds").foregroundStyle(.secondary)
      }
    }
  }

  private func set(_ seconds: Int) {
    model.edit(BackgroundActivityPolicy.overridePatch(model.server) { $0.automaticGitFetchInterval = Double(seconds) * 1000 })
  }
}
