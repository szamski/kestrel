import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// Sign-in and runtime installation of one instance (`provider.auth.*`, `provider.install.*`). Both states are streams on the
/// environment; they belong to it and are never saved in settings. Today only Antigravity reports setup, the interaction
/// kinds below are everything the contract lets a provider ask for.
@MainActor @Observable
final class ProviderSetupModel {
  let controller: ProvidersController
  let instanceId: String

  private(set) var auth: ProviderAuthState?
  private(set) var install: ProviderInstallState?
  private(set) var pending: String?
  private(set) var streamFailed = false
  var error: String?
  @ObservationIgnored private var watchers: [Task<Void, Never>] = []

  init(controller: ProvidersController, instanceId: String) {
    self.controller = controller
    self.instanceId = instanceId
  }

  var authActive: Bool { [.starting, .waiting, .verifying].contains(auth?.phase) }
  var installActive: Bool { [.downloading, .extracting, .verifying].contains(install?.phase) }
  var interaction: ProviderAuthInteraction? { auth?.interaction ?? nil }
  private var input: ProviderSetupInput { ProviderSetupInput(instanceId: ProviderInstanceId(instanceId)) }

  // MARK: Streams

  /// Follows both streams on the current session; a reconnect replaces the session and the streams follow it.
  func observe() async {
    guard let environment = await controller.runtime.runtime(for: controller.environmentId) else { return }
    defer { stopWatching() }
    for await session in environment.supervisor.session.changes() {
      stopWatching()
      guard let session else { continue }
      watchers = [
        Task { @MainActor [weak self] in await self?.followAuth(session) },
        Task { @MainActor [weak self] in await self?.followInstall(session) },
      ]
    }
  }

  private func stopWatching() {
    watchers.forEach { $0.cancel() }
    watchers = []
  }

  private func followAuth(_ session: any EnvironmentSession) async {
    do {
      for try await state in session.subscribe(Rpc.providerAuthSubscribe, input) {
        auth = state
        streamFailed = false
      }
    } catch {
      if !Task.isCancelled { streamFailed = true }
    }
  }

  private func followInstall(_ session: any EnvironmentSession) async {
    do {
      for try await state in session.subscribe(Rpc.providerInstallSubscribe, input) {
        install = state
        streamFailed = false
      }
    } catch {
      if !Task.isCancelled { streamFailed = true }
    }
  }

  // MARK: Actions

  private func run(_ label: String, _ operation: (any EnvironmentSession) async throws -> Void) async {
    guard pending == nil else { return }
    pending = label
    error = nil
    defer { pending = nil }
    guard let session = await controller.currentSession() else {
      error = "The environment is not connected."
      return
    }
    do { try await operation(session) } catch { self.error = ProvidersController.message(error) }
  }

  func startSignIn(methodId: String? = nil) async {
    await run("Starting sign-in") { session in
      auth = try await session.call(Rpc.providerAuthStart, ProviderAuthStartInput(instanceId: ProviderInstanceId(instanceId), methodId: methodId))
    }
  }

  func cancelSignIn() async {
    guard let flowId = auth?.flowId else { return }
    await run("Cancelling sign-in") { session in
      auth = try await session.call(Rpc.providerAuthCancel, ProviderAuthCancelInput(instanceId: ProviderInstanceId(instanceId), flowId: flowId))
    }
  }

  func signOut() async {
    await run("Signing out") { session in auth = try await session.call(Rpc.providerAuthLogout, input) }
  }

  func submitCallback(_ url: String) async -> Bool {
    guard let flowId = auth?.flowId, auth?.phase == .waiting else { return false }
    var accepted = false
    await run("Checking redirect") { session in
      auth = try await session.call(
        Rpc.providerAuthComplete, ProviderAuthCompleteInput(instanceId: ProviderInstanceId(instanceId), flowId: flowId, callbackUrl: url.trimmingCharacters(in: .whitespacesAndNewlines)))
      accepted = true
    }
    return accepted
  }

  func respond(_ interactionId: String, _ response: ProviderAuthResponse) async {
    guard let flowId = auth?.flowId else { return }
    await run("Sending response") { session in
      auth = try await session.call(
        Rpc.providerAuthRespond,
        ProviderAuthRespondInput(instanceId: ProviderInstanceId(instanceId), flowId: flowId, interactionId: interactionId, response: response))
    }
  }

  func startInstall() async { await run("Starting installation") { session in install = try await session.call(Rpc.providerInstallStart, input) } }

  func cancelInstall() async {
    guard let operationId = install?.operationId else { return }
    await run("Cancelling installation") { session in
      install = try await session.call(
        Rpc.providerInstallCancel, ProviderInstallCancelInput(instanceId: ProviderInstanceId(instanceId), operationId: operationId))
    }
  }

  func removeRuntime() async { await run("Removing runtime") { session in install = try await session.call(Rpc.providerInstallRemove, input) } }
}

struct ProviderSetupSection: View {
  let controller: ProvidersController
  let row: ProviderInstanceRow
  let live: ServerConfigProvidersItem?
  @State private var setup: ProviderSetupModel
  @State private var callback = ""
  @State private var copiedFlow: String?
  @State private var confirmSignOut = false
  @State private var confirmRemove = false

  init(controller: ProvidersController, row: ProviderInstanceRow, live: ServerConfigProvidersItem?) {
    self.controller = controller
    self.row = row
    self.live = live
    _setup = State(initialValue: ProviderSetupModel(controller: controller, instanceId: row.instanceId))
  }

  private var enabled: Bool { ProviderInstances.isEnabled(row.instance) }
  private var driverLabel: String { ProviderCatalog.label(row.driver) }
  private var method: String {
    let value = ProviderConfig.string(row.instance.config, "authMethod")
    return value.isEmpty ? "oauth-personal" : value
  }
  /// Google accounts open a browser; API key and Agent Platform methods only check the saved credentials.
  private var usesBrowser: Bool { row.driver != "antigravity" || method == "oauth-personal" || method == "oauth-business" }

  var body: some View {
    Section("Setup") {
      SettingRow(id: "\(row.instanceId)-setup-environment", title: "Environment", help: "Device that runs this provider.") {
        HStack {
          Text(controller.environmentLabel).foregroundStyle(.secondary)
          if !enabled {
            Button("Enable \(driverLabel)") { controller.edit(row.instanceId) { $0.enabled = true } }
          }
        }
      }
      .task(id: row.instanceId) { await setup.observe() }
      .confirmationDialog("Sign out of \(driverLabel)?", isPresented: $confirmSignOut) {
        Button(usesBrowser ? "Sign out" : "Disconnect", role: .destructive) { Task { await setup.signOut() } }
      } message: {
        Text("This stops its running threads on \(controller.environmentLabel). Thread history is kept.")
      }
      .confirmationDialog("Remove the downloaded \(driverLabel) runtime?", isPresented: $confirmRemove) {
        Button("Remove runtime", role: .destructive) { Task { await setup.removeRuntime() } }
      } message: {
        Text("It is removed from \(controller.environmentLabel). Sign-in and thread history are kept.")
      }
      if let live, live.setup != nil {
        runtimeRow(live)
        signInRow(live)
        if let message = setup.error ?? (setup.streamFailed ? "Could not read setup status." : nil) {
          Text(message).foregroundStyle(.red).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
        }
      } else {
        SettingRow(id: "\(row.instanceId)-setup-update", title: "Update required", help: "Update this environment to manage \(driverLabel).") { EmptyView() }
      }
    }
  }

  // MARK: Runtime

  private func runtimeRow(_ live: ServerConfigProvidersItem) -> some View {
    let install = setup.install
    let custom = !ProviderConfig.string(row.instance.config, "binaryPath").trimmingCharacters(in: .whitespaces).isEmpty
    let installed = live.installed || (!custom && install?.installedVersion != nil)
    let canInstall = live.setup?.canInstall == true
    let busy = setup.pending != nil
    return SettingRow(id: "\(row.instanceId)-setup-runtime", title: "Runtime", help: custom ? "Uses the custom binary path below. Installation keeps that path." : "Install and manage \(driverLabel).") {
      VStack(alignment: .trailing, spacing: 6) {
        Text(installStatus(install, installed: installed, custom: custom)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        if install?.phase == .downloading, let total = install?.totalBytes, total > 0 {
          ProgressView(value: Double(install?.downloadedBytes ?? 0), total: Double(total)).frame(width: 200).accessibilityLabel("\(driverLabel) download")
        }
        if !setup.installActive, let message = install?.message, message != installStatus(install, installed: installed, custom: custom) {
          Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        if !installed, !canInstall {
          Text("Automatic installation unavailable. Set a binary path or use another environment.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        HStack {
          if setup.installActive {
            if install?.operationId != nil { Button("Cancel installation") { Task { await setup.cancelInstall() } }.disabled(busy) }
          } else if canInstall {
            Button(installLabel(install, installed: installed)) { Task { await setup.startInstall() } }.disabled(busy || install == nil || setup.authActive)
          }
          if install?.canRemove == true, !setup.installActive {
            Button { confirmRemove = true } label: { Image(systemName: "trash") }
              .buttonStyle(.borderless).help("Remove downloaded runtime").accessibilityLabel("Remove downloaded runtime").disabled(busy || setup.authActive)
          }
        }
      }
    }
  }

  private func installStatus(_ install: ProviderInstallState?, installed: Bool, custom: Bool) -> String {
    switch install?.phase {
    case .downloading:
      let done = String(format: "%.1f", Double(install?.downloadedBytes ?? 0) / 1_000_000)
      return "Downloading \(done) MB" + (install?.totalBytes.map { " of \(String(format: "%.1f", Double($0) / 1_000_000)) MB" } ?? "") + "."
    case .extracting: return "Extracting \(driverLabel)."
    case .verifying: return "Checking the downloaded runtime."
    default:
      if installed { return "Installed." }
      if custom { return enabled ? "The configured \(driverLabel) runtime is unavailable." : "The configured \(driverLabel) runtime has not been checked." }
      if let total = install?.totalBytes, total > 0 { return "\(Int((Double(total) / 1_000_000).rounded(.up))) MB download." }
      return "Not installed."
    }
  }

  private func installLabel(_ install: ProviderInstallState?, installed: Bool) -> String {
    if let current = install?.installedVersion {
      return install?.version != nil && install?.version != current ? "Update \(driverLabel)" : "Reinstall \(driverLabel)"
    }
    if install?.phase == .failed || install?.phase == .cancelled { return "Retry installation" }
    return installed ? "Install managed runtime" : "Install \(driverLabel)"
  }

  // MARK: Sign-in

  private func signInRow(_ live: ServerConfigProvidersItem) -> some View {
    let auth = setup.auth
    let authenticated = live.auth.status == .authenticated
    let installed = live.installed || setup.install?.installedVersion != nil
    let busy = setup.pending != nil
    let canAuthenticate = live.setup?.canAuthenticate == true
    let methods = auth?.methods ?? []
    let title = row.driver == "antigravity" ? (ProviderCatalog.antigravityAuthMethods.first { $0.value == method }?.label ?? "Google account") : "Account"
    return SettingRow(id: "\(row.instanceId)-setup-auth", title: title, help: usesBrowser ? "Connect your account in the browser." : "Connect with the credentials below.") {
      VStack(alignment: .trailing, spacing: 8) {
        Text(authStatus(auth, authenticated: authenticated)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        interactionView(auth)
        HStack {
          if setup.authActive, auth?.flowId != nil {
            Button("Cancel sign-in") { Task { await setup.cancelSignIn() } }.disabled(busy)
          } else if !authenticated, canAuthenticate {
            if methods.count > 1 {
              Menu(retryLabel(auth)) {
                ForEach(methods, id: \.id) { entry in Button(entry.name) { Task { await setup.startSignIn(methodId: entry.id) } } }
              }
              .fixedSize().disabled(busy || !installed || auth == nil || setup.installActive)
            } else {
              Button(signInLabel(auth)) { Task { await setup.startSignIn(methodId: methods.first?.id) } }.disabled(busy || !installed || auth == nil || setup.installActive)
            }
          }
          if !setup.authActive, canAuthenticate {
            Button(usesBrowser ? "Sign out" : "Disconnect") { confirmSignOut = true }.disabled(busy || auth == nil)
          }
        }
      }
    }
  }

  private func retryLabel(_ auth: ProviderAuthState?) -> String { auth?.phase == .failed || auth?.phase == .cancelled ? "Retry sign-in" : "Sign in" }

  private func signInLabel(_ auth: ProviderAuthState?) -> String {
    let failed = auth?.phase == .failed || auth?.phase == .cancelled
    return usesBrowser ? (failed ? "Retry sign-in" : "Sign in") : (failed ? "Retry connection" : "Connect")
  }

  private func authStatus(_ auth: ProviderAuthState?, authenticated: Bool) -> String {
    guard let auth else { return "Reading sign-in status." }
    let waiting = usesBrowser ? "Waiting for sign-in." : "Checking credentials."
    switch auth.phase {
    case .starting: return auth.message ?? (usesBrowser ? "Starting sign-in." : "Checking credentials.")
    case .waiting: return auth.message ?? waiting
    case .verifying: return auth.message ?? (usesBrowser ? "Checking sign-in and available models." : "Checking credentials and available models.")
    case .failed: return auth.message ?? (usesBrowser ? "Sign-in failed." : "Could not connect with the configured credentials.")
    case .cancelled: return auth.message ?? (usesBrowser ? "Sign-in cancelled." : "Connection cancelled.")
    default:
      if authenticated { return usesBrowser ? "Signed in." : "Connected." }
      return auth.phase == .idle ? (auth.message ?? (usesBrowser ? "Not signed in." : "Connect with the credentials in the provider settings.")) : "Not signed in."
    }
  }

  // MARK: Interactions

  /// What the provider is asking for now: a consent, a code to enter on a page, a terminal prompt or credentials.
  /// A plain authorization link (no interaction) is offered with the paste-the-redirect form.
  @ViewBuilder private func interactionView(_ auth: ProviderAuthState?) -> some View {
    let busy = setup.pending != nil
    if let interaction = setup.interaction, auth?.phase == .waiting {
      switch interaction {
      case .browser(let browser):
        if browser.requiresConsent {
          Text("Open \(host(browser.url)) to continue?").foregroundStyle(.secondary)
          HStack {
            Button("Open page") {
              Task { await setup.respond(browser.id, .browser(ProviderAuthResponseBrowser(action: .accept))) }
              if !ProvidersController.open(browser.url) { setup.error = "Could not open the sign-in page. Copy the link and open it in your browser." }
            }
            Button("Decline") { Task { await setup.respond(browser.id, .browser(ProviderAuthResponseBrowser(action: .decline))) } }
            Button("Copy link") { ProvidersController.copy(browser.url) }
          }
          .disabled(busy)
        } else {
          linkActions(browser.url, flow: auth?.flowId)
        }
        if browser.acceptsCallback == true { callbackForm(auth) }
      case .deviceCode(let device):
        Text("Enter this code on the sign-in page:").foregroundStyle(.secondary)
        HStack {
          Text(device.userCode).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
          Button { ProvidersController.copy(device.userCode) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy code").accessibilityLabel("Copy code")
        }
        linkActions(device.url, flow: auth?.flowId)
      case .terminal(let terminal):
        TerminalPrompt(output: terminal.output, busy: busy) { text in Task { await setup.respond(terminal.id, .terminal(ProviderAuthResponseTerminal(data: text + "\n"))) } }
      case .credentials(let credentials):
        CredentialsForm(fields: credentials.fields, busy: busy) { values in Task { await setup.respond(credentials.id, .credentials(ProviderAuthResponseCredentials(values: values))) } }
      case .unknown:
        Text("This sign-in needs a newer version of the app.").foregroundStyle(.secondary)
      }
    } else if auth?.phase == .waiting, let link = auth?.authorizationUrl {
      linkActions(link, flow: auth?.flowId)
      if let expires = auth?.expiresAt?.date {
        Text("Link expires at \(expires.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
      }
      callbackForm(auth)
    } else if auth?.phase == .waiting {
      Text("Sign-in is open in another client. Complete or cancel it there.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private func host(_ link: String) -> String { URL(string: link)?.host ?? link }

  private func linkActions(_ link: String, flow: String?) -> some View {
    HStack {
      Button("Open sign-in page") {
        if !ProvidersController.open(link) { setup.error = "Could not open the sign-in page. Copy the link and open it in your browser." } else { setup.error = nil }
      }
      Button(copiedFlow == flow && flow != nil ? "Link copied" : "Copy sign-in link") {
        ProvidersController.copy(link)
        copiedFlow = flow
      }
    }
  }

  /// The provider's loopback page may be on another machine: paste the final URL here to finish the sign-in.
  private func callbackForm(_ auth: ProviderAuthState?) -> some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text("If the final localhost page does not load, paste its full URL here.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
      HStack {
        TextField("http://127.0.0.1:...", text: $callback).textFieldStyle(.roundedBorder).frame(width: 220).autocorrectionDisabled()
        Button("Continue") {
          Task { if await setup.submitCallback(callback) { callback = "" } }
        }
        .disabled(callback.trimmingCharacters(in: .whitespaces).isEmpty || setup.pending != nil)
      }
    }
  }
}

private struct TerminalPrompt: View {
  let output: String
  let busy: Bool
  let send: (String) -> Void
  @State private var line = ""

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ScrollView {
        Text(output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 320, height: 90).padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
      HStack {
        TextField("Reply", text: $line).textFieldStyle(.roundedBorder).frame(width: 240).onSubmit(submit)
        Button("Send", action: submit).disabled(busy)
      }
    }
  }

  private func submit() {
    send(line)
    line = ""
  }
}

private struct CredentialsForm: View {
  let fields: [ProviderAuthInteractionCredentialsFieldsItem]
  let busy: Bool
  let submit: ([String: String]) -> Void
  @State private var values: [String: String] = [:]

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ForEach(fields, id: \.name) { field in
        let binding = Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0 })
        Group {
          if field.secret { SecureField(field.label, text: binding) } else { TextField(field.label, text: binding) }
        }
        .textFieldStyle(.roundedBorder).frame(width: 260).autocorrectionDisabled()
      }
      Button("Continue") { submit(values) }.disabled(busy || fields.contains { (values[$0.name] ?? "").isEmpty })
    }
  }
}
