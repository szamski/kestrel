import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Connections, as web and desktop lay it out: this machine (server, reach, access), the clients paired to it,
/// the environments it connects to, load balancing and T3 Connect.
struct ConnectionsPage: View {
  @Environment(SettingsModel.self) private var model

  var body: some View { ConnectionsContent(runtime: model.runtime) }
}

private struct ConnectionsContent: View {
  @Environment(SettingsModel.self) private var settings
  @Environment(AppModel.self) private var app
  @State private var access: ConnectionsAccessModel

  init(runtime: ClientRuntime) { _access = State(initialValue: ConnectionsAccessModel(runtime: runtime)) }

  var body: some View {
    let environments = settings.runtime.environments
    let localId = AppModel.storedLocalEnvironmentId
    let local = environments.first { $0.environmentId == localId }
    let switchedOn = environments.filter(\.enabled)
    let endpoints = endpoints(for: local)
    ScrollViewReader { proxy in
      Form {
        if let failure = access.failure {
          Section {
            HStack(alignment: .firstTextBaseline) {
              Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
              Spacer()
              Button("Dismiss") { access.failure = nil }.buttonStyle(.borderless)
            }
          }
        }
        ThisMacSection(local: local, access: access, endpoints: endpoints)
        if local != nil, access.session == nil || access.canRead || access.canWrite {
          AccessSection(model: access, endpoints: endpoints, connected: local?.connection.phase == .connected)
        }
        EnvironmentsSection(environments: environments.filter { $0.environmentId != localId })
        if switchedOn.count >= 2 {
          LoadBalancingSection(environments: switchedOn)
          GitHubSharingSection()
        }
        ConnectSettings()
      }
      .formStyle(.grouped)
      .task(id: local?.environmentId) { await access.run(environmentId: local?.environmentId) }
      #if DEBUG
      // `-T3SettingsScrollTo <row id>`: verification runs scroll a long page to the part under test.
      .task {
        guard let id = UserDefaults.standard.string(forKey: "T3SettingsScrollTo") else { return }
        try? await Task.sleep(for: .seconds(5))
        proxy.scrollTo(id, anchor: .center)
      }
      #endif
      .onChange(of: settings.jump?.token) {
        guard let id = settings.jump?.id else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  /// Where a pairing link can point: this Mac while the server runs, plus the addresses the server reports binding to.
  private func endpoints(for local: EnvironmentStatus?) -> [PairingEndpoint] {
    var port: Int?
    if case .running(let running) = app.localServer.state { port = running }
    let direct = local.flatMap { settings.runtime.serverConfigs[$0.environmentId]?.config.directEndpoints } ?? []
    return PairingEndpoint.endpoints(loopbackPort: port, direct: direct)
  }
}
