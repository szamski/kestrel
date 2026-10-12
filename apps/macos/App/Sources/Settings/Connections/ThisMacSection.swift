import SwiftUI
import T3ClientRuntime
import T3Contracts

extension EnvironmentMachineKind {
  /// The kinds the server knows, in the order of web's icon picker.
  static let choices: [EnvironmentMachineKind] = [.server, .cloud, .linux, .desktop, .laptop, .macMini, .macStudio]

  var symbol: String {
    switch self {
    case .server: "server.rack"
    case .cloud: "cloud"
    case .linux: "terminal"
    case .desktop: "desktopcomputer"
    case .laptop: "laptopcomputer"
    case .macMini: "macmini"
    case .macStudio: "macstudio"
    case .unknown: "externaldrive"
    }
  }

  var title: String {
    switch self {
    case .server: "Server"
    case .cloud: "Cloud"
    case .linux: "Linux"
    case .desktop: "Desktop"
    case .laptop: "Laptop"
    case .macMini: "Mac mini"
    case .macStudio: "Mac Studio"
    case .unknown(let raw): raw
    }
  }

  /// The icon the environment shows: the user's choice, else what the server detected, else a generic server.
  static func resolved(_ config: ServerConfig?) -> EnvironmentMachineKind {
    config?.settings.environmentIcon ?? config?.environment.platform.machine ?? .server
  }
}

/// Settings › Connections › This Mac: the server this app runs, how far it reaches, and what this session may do on it.
struct ThisMacSection: View {
  @Environment(AppModel.self) private var app
  @Environment(SettingsModel.self) private var settings
  /// The saved environment of the local server; nil until it has registered.
  let local: EnvironmentStatus?
  let access: ConnectionsAccessModel
  let endpoints: [PairingEndpoint]

  @State private var pendingNetwork: Bool?
  @State private var settingUpTailscale = false
  @State private var disablingTailscale = false

  private var server: LocalServer { app.localServer }
  private var config: ServerConfig? { local.flatMap { settings.runtime.serverConfigs[$0.environmentId]?.config } }
  /// The server restarts for a moment on every exposure change; its toggles wait for it.
  private var serverBusy: Bool {
    switch server.state {
    case .starting, .stopping: true
    default: false
    }
  }
  private var canChangeExposure: Bool { app.runsLocalServer && !serverBusy }

  var body: some View {
    Section {
      SettingRow(
        id: "local-environment", title: "Run local server",
        help: "Starts a T3 Code server on this Mac so threads work without an external server. Environments you add yourself are not affected."
      ) {
        Toggle("Run local server", isOn: Binding(get: { app.runsLocalServer }, set: { app.setRunsLocalServer($0) })).labelsHidden().toggleStyle(.switch)
      }
      LocalServerRow()
      if let config {
        SettingRow(id: "server-version", title: "Version", help: versionDetail(config)) { EmptyView() }
      }
      SettingRow(id: "network-access", title: "Network access", help: networkDetail) {
        Toggle(
          "Network access",
          isOn: Binding(get: { server.exposure.networkAccessible }, set: { pendingNetwork = $0 })
        )
        .labelsHidden().toggleStyle(.switch).disabled(!canChangeExposure)
      }
      SettingRow(id: "tailscale-https", title: "Tailscale HTTPS", help: tailscaleDetail) {
        Toggle(
          "Tailscale HTTPS",
          isOn: Binding(get: { server.exposure.tailscaleServe }, set: { if $0 { settingUpTailscale = true } else { disablingTailscale = true } })
        )
        .labelsHidden().toggleStyle(.switch).disabled(!canChangeExposure)
      }
      SettingRow(id: "publish-agent-activity", title: "Publish agent activity", help: publishDetail) {
        Toggle(
          "Publish agent activity",
          isOn: Binding(get: { access.cloudLink?.publishAgentActivity ?? false }, set: { on in Task { await access.setPublishAgentActivity(on) } })
        )
        .labelsHidden().toggleStyle(.switch).disabled(!publishAvailable)
      }
      if !access.heldScopes.isEmpty { permissions }
    } header: {
      header
    }
    .confirmationDialog(
      pendingNetwork == true ? "Enable network access?" : "Disable network access?", isPresented: Binding(get: { pendingNetwork != nil }, set: { if !$0 { pendingNetwork = nil } })
    ) {
      let enable = pendingNetwork == true
      Button(enable ? "Restart and enable" : "Restart and disable", role: enable ? nil : .destructive) {
        var next = server.exposure
        next.networkAccessible = enable
        server.setExposure(next)
      }
    } message: {
      Text(
        pendingNetwork == true
          ? "The local server will answer on every network interface, so devices on your network can reach it. They still need a pairing link, but anyone who gets one controls agents that run commands as you. Only do this on networks you trust. The server restarts."
          : "Devices connected over your local network will disconnect. Existing tunnels, such as T3 Connect or Tailscale HTTPS, keep working. The server restarts.")
    }
    .confirmationDialog("Disable Tailscale HTTPS?", isPresented: $disablingTailscale) {
      Button("Restart and disable", role: .destructive) {
        var next = server.exposure
        next.tailscaleServe = false
        server.setExposure(next)
      }
    } message: {
      Text("The local server restarts without Tailscale Serve.")
    }
    .sheet(isPresented: $settingUpTailscale) {
      TailscaleSetupSheet(port: server.exposure.tailscalePort) { port in
        var next = server.exposure
        next.tailscaleServe = true
        next.tailscalePort = port
        server.setExposure(next)
      }
    }
  }

  // MARK: Header and icon

  private var header: some View {
    HStack {
      Image(systemName: EnvironmentMachineKind.resolved(config).symbol)
      Text(local?.label ?? "This Mac").id("connections-environment")
      Spacer()
      iconMenu
    }
  }

  /// Why the icon cannot change, in the order the user can do something about it.
  private var iconLock: String? {
    guard let config else { return "Connect to this Mac's server to change its icon." }
    if config.environment.capabilities.environmentIcon != true { return "This server is too old to keep an icon." }
    if access.session != nil, !(access.session.map { AuthAccess.grants(.settingsWrite, in: $0) } ?? false) { return "Your session cannot change this server's settings." }
    return nil
  }

  private var iconMenu: some View {
    let detected = config?.environment.platform.machine ?? .server
    let current = EnvironmentMachineKind.resolved(config)
    return Menu {
      Picker(
        "Icon",
        selection: Binding(
          get: { current },
          set: { next in
            guard let local else { return }
            // Picking what the server detected clears the override.
            let patch = ServerSettingsPatch(environmentIcon: next == detected ? .some(nil) : .some(next))
            Task {
              do { try await settings.runtime.updateServerSettings(environmentId: local.environmentId, patch: patch) } catch {
                settings.report("Icon not saved. \(AppModel.describe(error))")
              }
            }
          })
      ) {
        ForEach(EnvironmentMachineKind.choices, id: \.rawValue) { kind in
          Label(kind == detected ? "\(kind.title) (detected)" : kind.title, systemImage: kind.symbol).tag(kind)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton).fixedSize()
    .disabled(iconLock != nil)
    .help(iconLock ?? "Change this machine's icon")
    .accessibilityLabel("Change icon of this machine")
  }

  // MARK: Row text

  private func versionDetail(_ config: ServerConfig) -> String {
    var parts = [config.environment.serverVersion]
    if case .running(let port) = server.state { parts.append("http://127.0.0.1:\(port)") }
    return parts.joined(separator: " \u{00B7} ")
  }

  private var networkDetail: String {
    if !app.runsLocalServer { return "Turn on the local server to change network access." }
    guard server.exposure.networkAccessible else { return "Limited to this Mac." }
    let lan = endpoints.filter { $0.reach == .lan || $0.reach == .tailnet }
    if let first = lan.first { return "Reachable at \(first.baseURL.absoluteString)" + (lan.count > 1 ? " and \(lan.count - 1) more." : "") }
    return "Exposed on all interfaces. No network address was found yet, so links fall back to this Mac."
  }

  private var tailscaleDetail: String {
    if !app.runsLocalServer { return "Turn on the local server to change Tailscale HTTPS." }
    guard server.exposure.tailscaleServe else { return "Use Tailscale Serve to expose this Mac through a MagicDNS HTTPS URL." }
    if let https = endpoints.first(where: { $0.reach == .tailnetHTTPS }) { return https.baseURL.absoluteString }
    return "Tailscale Serve is on, but the server has not reported an HTTPS address. Check that Tailscale is running and HTTPS is enabled for your tailnet."
  }

  private var publishAvailable: Bool { access.cloudLink?.linked == true && access.canManageRelay && !access.updatingPublish }

  private var publishDetail: String {
    if access.cloudLink?.linked == true { return "Send activity to mobile notifications and Live Activities without T3 Connect." }
    return "Send activity to mobile notifications and Live Activities. Link this Mac in T3 Connect below to turn this on."
  }

  // MARK: Permissions

  private var permissions: some View {
    DisclosureGroup("Permissions") {
      VStack(alignment: .leading, spacing: 6) {
        Text("What this app may do on this Mac's server.").font(.caption).foregroundStyle(.secondary)
        ForEach(access.heldScopes, id: \.rawValue) { scope in
          let option = PairingScopes.options.first { $0.scope.rawValue == scope.rawValue }
          VStack(alignment: .leading, spacing: 0) {
            Text(option?.title ?? scope.rawValue)
            Text(scope.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.top, 4)
    }
  }
}

/// Confirms Tailscale Serve: finds the MagicDNS name, takes the HTTPS port and shows the address that results.
struct TailscaleSetupSheet: View {
  let port: Int
  let enable: (Int) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var reading: TailscaleCLI.Reading?
  @State private var portText = ""

  var body: some View {
    let chosen = Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
    VStack(alignment: .leading, spacing: 14) {
      Text("Set up Tailscale HTTPS?").font(.headline)
      Text("The local server restarts with Tailscale Serve enabled and asks Tailscale to proxy HTTPS traffic to it.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField("HTTPS port", text: $portText).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
      if chosen == nil { Text("Enter a port from 1 to 65535.").font(.caption).foregroundStyle(.red) }
      VStack(alignment: .leading, spacing: 4) {
        Text("HTTPS endpoint").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        switch reading {
        case nil: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking Tailscale\u{2026}") }
        case .ready(let name)?: Text(chosen.flatMap { TailscaleCLI.httpsURL(magicDNSName: name, port: $0)?.absoluteString } ?? name).textSelection(.enabled)
        case .notInstalled?: Text("Tailscale was not found on this Mac. Install it from tailscale.com, sign in, then check again.").foregroundStyle(.secondary)
        case .unavailable?: Text("Tailscale did not report a MagicDNS name. Open Tailscale, sign in and turn it on, then check again.").foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(10)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        if !ready { Button("Check again") { Task { await check() } }.disabled(reading == nil) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Enable") {
          if let chosen { enable(chosen) }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(chosen == nil || !ready)
      }
    }
    .padding(20)
    .frame(width: 420)
    .task {
      portText = String(port)
      await check()
    }
  }

  private var ready: Bool {
    if case .ready? = reading { true } else { false }
  }

  private func check() async {
    reading = nil
    reading = await TailscaleCLI.read()
  }
}
