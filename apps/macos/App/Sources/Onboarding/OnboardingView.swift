import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The first-run setup sheet: connect a computer, check its agents, import projects. Every step past the connection
/// is skippable, and the whole setup can be skipped; Settings › General opens it again.
struct OnboardingView: View {
  @Environment(AppModel.self) private var app
  @State private var addingComputer = false

  var body: some View {
    let model = app.onboarding
    VStack(spacing: 0) {
      StepBar(model: model)
      Divider()
      Group {
        switch model.step {
        case .connection: ConnectionStep(addingComputer: $addingComputer)
        case .agents: AgentsStep()
        case .projects: ImportStep()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Footer(model: model)
    }
    .frame(width: 640, height: 620)
    .interactiveDismissDisabled()
    .sheet(isPresented: $addingComputer) { AddEnvironmentSheet() }
  }
}

private struct StepBar: View {
  let model: OnboardingModel

  var body: some View {
    HStack(spacing: 6) {
      Text("Set up Kestrel").font(.headline)
      Spacer()
      ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
        let current = step == model.step
        Button { if step.rawValue < model.step.rawValue { model.go(to: step) } } label: {
          HStack(spacing: 5) {
            Text("\(step.rawValue + 1)").font(.caption.weight(.semibold)).frame(width: 18, height: 18)
              .background(current ? Color.accentColor : Color.secondary.opacity(0.25), in: .circle)
              .foregroundStyle(current ? Color.white : Color.secondary)
            Text(step.title).font(.callout).foregroundStyle(current ? .primary : .secondary)
          }
        }
        .buttonStyle(.plain)
        .disabled(step.rawValue >= model.step.rawValue || model.importing)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3, \(step.title)")
        .accessibilityAddTraits(current ? .isSelected : [])
        if step != OnboardingModel.Step.allCases.last { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }
}

private struct Footer: View {
  let model: OnboardingModel

  var body: some View {
    HStack {
      Button("Skip setup") { model.close() }
        .keyboardShortcut(.cancelAction)
        .disabled(model.importing)
        .help("You can open this again from Settings \u{203A} General")
      Spacer()
      if model.step != .connection { Button("Back") { model.go(to: OnboardingModel.Step(rawValue: model.step.rawValue - 1)!) }.disabled(model.importing) }
      switch model.step {
      case .connection:
        Button("Continue") { model.go(to: .agents) }.keyboardShortcut(.defaultAction).disabled(model.connected.isEmpty)
      case .agents:
        Button("Continue") { model.go(to: .projects) }.keyboardShortcut(.defaultAction)
      case .projects:
        let count = model.selected.count
        Button(count == 0 ? "Finish" : "Import \(count) \(count == 1 ? "project" : "projects")") {
          if count == 0 { model.close() } else { model.runImport() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.importing || model.scanning)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }
}

/// Title and one line of explanation above a step's form.
struct StepHeader: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.title2.weight(.semibold))
      Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowBackground(Color.clear)
  }
}

// MARK: Step 1

private struct ConnectionStep: View {
  @Environment(AppModel.self) private var app
  @Binding var addingComputer: Bool

  var body: some View {
    let runtime = app.runtime
    Form {
      Section { StepHeader(title: "Connect your computers", text: "Choose where your agents run. Kestrel sets up agents and projects on every connected computer.") }
      Section("This Mac") { ThisMacRow(addingComputer: $addingComputer) }
      Section("Computers") {
        if runtime.environments.isEmpty {
          Text("No computer is connected yet.").foregroundStyle(.secondary)
        }
        ForEach(runtime.environments) { status in
          HStack(spacing: 8) {
            Circle().fill(SidebarFooter.tint(status.enabled ? status.connection.phase : nil)).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(status.label)
            if status.route == .relay { Image(systemName: "cloud").foregroundStyle(.secondary).help("Connected through T3 Connect") }
            Spacer()
            Text(Self.phase(status)).font(.callout).foregroundStyle(.secondary)
          }
        }
      }
      Section("Add a computer") {
        LabeledContent {
          Button("Pair\u{2026}") { addingComputer = true }
        } label: {
          Text("Pair with a link or code")
          Text("Run `npx t3` or `t3 pair` on the other computer to get a pairing link.")
        }
      }
      if app.connect.isAvailable { ConnectSettings() }
    }
    .formStyle(.grouped)
  }

  private static func phase(_ status: EnvironmentStatus) -> String {
    guard status.enabled else { return "Disabled" }
    switch status.connection.phase {
    case .connected: return "Connected"
    case .connecting: return "Connecting\u{2026}"
    case .backoff: return "Reconnecting\u{2026}"
    case .offline: return "Offline"
    case .blocked: return "Blocked"
    case .available: return "Not connected"
    }
  }
}

/// The server Kestrel starts itself: the usual way to connect on a Mac with the agents installed.
private struct ThisMacRow: View {
  @Environment(AppModel.self) private var app
  @Binding var addingComputer: Bool

  var body: some View {
    let server = app.localServer
    if !app.runsLocalServer {
      LabeledContent {
        Button("Turn on") { app.setRunsLocalServer(true) }
      } label: {
        Text("Run a server on this Mac")
        Text("Kestrel starts its own T3 Code server, so no setup is needed.")
      }
    } else {
      switch server.state {
      case .off, .stopping:
        Label("Local server is off", systemImage: "circle").foregroundStyle(.secondary)
      case .starting:
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting the local server\u{2026}") }
      case .running:
        Label(app.runtime.environments.contains { $0.environmentId == AppModel.storedLocalEnvironmentId && $0.connection.phase == .connected } ? "This Mac is connected" : "Connecting to this Mac\u{2026}", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .failed(let message):
        VStack(alignment: .leading, spacing: 6) {
          Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          HStack { Button("Show log") { server.showLog() }; Button("Restart") { server.restart() } }
        }
      case .foreignOwner(let origin):
        VStack(alignment: .leading, spacing: 6) {
          Text("T3 Code already runs on this Mac (port \(origin.port ?? 0)). Connect to it instead of starting a second server.").fixedSize(horizontal: false, vertical: true)
          Button("Connect\u{2026}") {
            app.addEnvironmentHost = "\(origin.host() ?? "127.0.0.1"):\(origin.port ?? 0)"
            addingComputer = true
          }
        }
      }
    }
  }
}

// MARK: Step 2

private struct AgentsStep: View {
  @Environment(AppModel.self) private var app

  private static let agents: [(driver: String, name: String)] = [("claudeAgent", "Claude Code"), ("codex", "Codex")]

  var body: some View {
    let connected = app.onboarding.connected
    Form {
      Section { StepHeader(title: "Connect your agents", text: "Kestrel checks Claude Code and Codex on each connected computer. Install or sign in with the commands below, then continue.") }
      ForEach(connected) { status in
        let config = app.runtime.serverConfigs[status.environmentId]?.config
        let best = ProviderReadiness.bestByDriver(config?.providers ?? [])
        Section(connected.count > 1 ? status.label : "Agents") {
          ForEach(Self.agents, id: \.driver) { agent in
            AgentRow(
              name: agent.name, driver: agent.driver, provider: best[ProviderDriverKind(agent.driver)], windows: config?.environment.platform.os == .windows,
              loading: config == nil)
          }
        }
      }
      Section {
        LabeledContent {
          Button("Open Providers settings") {
            app.settingsPageRequest = .providers
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          }
        } label: {
          Text("Other providers")
          Text("Cursor, OpenCode and more can be enabled in Settings \u{203A} Providers, where agents are also refreshed.")
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct AgentRow: View {
  let name: String
  let driver: String
  let provider: ServerConfigProvidersItem?
  let windows: Bool
  let loading: Bool

  var body: some View {
    let state = loading ? ProviderReadiness.checking : ProviderReadiness.of(provider)
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(name)
        Spacer()
        switch state {
        case .ready: Label(provider?.version.map { "Ready \u{00B7} \($0)" } ?? "Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking\u{2026}").foregroundStyle(.secondary) }
        case .install: Label("Not installed", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .signIn: Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
        case .disabled: Label("Disabled", systemImage: "circle.slash").foregroundStyle(.secondary)
        case .attention: Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
      }
      if state == .install, let command = ProviderReadiness.installCommand(driver: driver, windows: windows) { CommandSnippet(prefix: "Run in a terminal on that computer", command: command) }
      if state == .signIn, let command = ProviderReadiness.loginCommand(driver: driver) { CommandSnippet(prefix: "Run in a terminal on that computer", command: command) }
      if state == .attention, let message = provider?.message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
  }
}

private struct CommandSnippet: View {
  let prefix: String
  let command: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(prefix).font(.caption).foregroundStyle(.secondary)
      HStack {
        Text(command).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
        }
        .controlSize(.small)
      }
      .padding(8).background(.quaternary, in: .rect(cornerRadius: 6))
    }
  }
}
