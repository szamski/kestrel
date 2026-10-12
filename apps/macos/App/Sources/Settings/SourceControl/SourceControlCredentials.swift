import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Saves one credentials patch on a single environment (credentials belong to a machine, not to a scope target).
@MainActor
private func saveCredentials(_ model: SettingsModel, _ environmentId: EnvironmentId, _ patch: ServerSettingsPatch) async -> Bool {
  do {
    try await model.runtime.updateServerSettings(environmentId: environmentId, patch: patch)
    return true
  } catch {
    model.report("Setting not saved. \(AppModel.describe(error))")
    return false
  }
}

@MainActor
private func settings(_ model: SettingsModel, _ environmentId: EnvironmentId) -> ServerSettings {
  model.runtime.serverConfigs[environmentId]?.config.settings ?? ServerSettings()
}

// MARK: GitHub token

/// A GitHub token for one host, kept in the server's secret store. It is used before `GH_TOKEN` and the `gh` login, so it
/// also works on a server without `gh`. Write-only: the saved token is never shown, only whether one is set.
struct GitHubTokenForm: View {
  @Environment(SettingsModel.self) private var model
  let environmentId: EnvironmentId
  let onSaved: () -> Void
  @State private var host = "github.com"
  @State private var draft = ""
  @State private var saving = false

  var body: some View {
    let tokens = settings(model, environmentId).github.tokens
    let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
    let saved = !(tokens[normalized] ?? "").isEmpty
    let savedHosts = tokens.filter { !$0.value.isEmpty }.keys.sorted()
    VStack(alignment: .leading, spacing: 8) {
      Text("A token saved here is used before GH_TOKEN and the gh login, so GitHub works without the GitHub CLI. Give it read and write access to pull requests and contents.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let url = URL(string: "https://\(normalized.isEmpty ? "github.com" : normalized)/settings/personal-access-tokens/new") { Link("Create a token", destination: url).font(.callout) }
      HStack(spacing: 8) {
        TextField("Host", text: $host, prompt: Text("github.com")).textFieldStyle(.roundedBorder).frame(width: 170).autocorrectionDisabled()
        SecureField("Token", text: $draft, prompt: Text(saved ? "Stored secret, enter a new value to replace" : "Not set")).textFieldStyle(.roundedBorder)
      }
      HStack {
        Text(savedHosts.isEmpty ? "No token saved; the server uses GH_TOKEN or the gh login." : "Saved for \(savedHosts.joined(separator: ", ")).")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if saved { Button("Remove") { save(normalized, "") }.disabled(saving) }
        Button("Save") { save(normalized, draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
          .disabled(normalized.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
      }
      .controlSize(.small)
    }
    .disabled(saving)
  }

  private func save(_ host: String, _ token: String) {
    saving = true
    Task { @MainActor in
      defer { saving = false }
      if await saveCredentials(model, environmentId, ServerSettingsPatch(github: ServerSettingsPatchGithub(tokens: [host: token]))) {
        draft = ""
        onSaved()
      }
    }
  }
}

// MARK: GitHub accounts

/// Per-host GitHub choices: turn a host off, or pin which of the logins `gh` holds is used instead of its active one.
struct GitHubAccountsForm: View {
  @Environment(SettingsModel.self) private var model
  let environmentId: EnvironmentId
  let auth: SourceControlProviderAuth
  let onSaved: () -> Void
  @State private var revealed = false
  @State private var saving = false

  private struct HostGroup {
    var host: String
    var active: String?
    var selectable: [String]
    var broken: [SourceControlProviderAuthAccountsItem]
    var environmentVariable: String?
  }

  /// gh's logins by host, in the order gh reported the hosts.
  private var groups: [HostGroup] {
    let accounts = auth.accounts ?? []
    var hosts: [String] = []
    for entry in accounts where !hosts.contains(entry.host) { hosts.append(entry.host) }
    return hosts.map { host in
      let entries = accounts.filter { $0.host == host }
      let stored = entries.filter { $0.environmentVariable == nil }
      let selectable = stored.filter(\.authenticated)
      return HostGroup(
        host: host, active: (selectable.first(where: \.active) ?? selectable.first)?.account, selectable: selectable.map(\.account),
        broken: stored.filter { !$0.authenticated }, environmentVariable: entries.first { $0.environmentVariable != nil }?.environmentVariable)
    }
  }

  var body: some View {
    let hosts = settings(model, environmentId).github.hosts
    if groups.isEmpty {
      Text("Sign in with gh auth login on the server host, then rescan to choose accounts here.").font(.callout).foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Choose which gh login each GitHub host uses, or turn a host off.").font(.callout).foregroundStyle(.secondary)
          Spacer()
          Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
            .buttonStyle(.borderless).help(revealed ? "Hide GitHub accounts" : "Reveal GitHub accounts").accessibilityLabel(revealed ? "Hide GitHub accounts" : "Reveal GitHub accounts")
        }
        ForEach(groups, id: \.host) { group in host(group, choice: hosts[group.host]) }
      }
      .disabled(saving)
    }
  }

  private func label(_ account: String, _ index: Int?) -> String { revealed ? account : "Account \((index ?? 0) + 1)" }

  @ViewBuilder private func host(_ group: HostGroup, choice: ServerSettingsGithubHostsValue?) -> some View {
    let enabled = choice?.enabled ?? true
    let stale = choice?.account.map { !group.selectable.contains($0) } ?? false
    let pinned = choice?.account.flatMap { stale ? nil : $0 }
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(group.host).fontWeight(.medium)
          if group.selectable.count == 1, let account = group.selectable.first {
            Text("Signed in as \(Text(account).monospaced().blur(radius: revealed ? 0 : 4))").font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Toggle("Use GitHub on \(group.host)", isOn: Binding(get: { enabled }, set: { save(group.host, enabled: $0) })).labelsHidden().toggleStyle(.switch)
      }
      if group.selectable.count > 1 {
        LabeledContent("Account") {
          Picker("", selection: Binding(get: { pinned ?? "" }, set: { save(group.host, account: .some($0.isEmpty ? nil : $0)) })) {
            Text("Active gh account\(group.active.map { " (\(revealed ? $0 : "hidden"))" } ?? "")").tag("")
            ForEach(Array(group.selectable.enumerated()), id: \.element) { index, account in Text(label(account, index)).tag(account) }
          }
          .labelsHidden().pickerStyle(.menu).fixedSize().disabled(!enabled)
        }
        .font(.callout)
      }
      if stale {
        HStack {
          Text("The chosen login is no longer signed in, so the active gh login is used.").font(.caption).foregroundStyle(.orange)
          Button("Use active login") { save(group.host, account: .some(nil)) }.controlSize(.small)
        }
      }
      ForEach(group.broken, id: \.account) { entry in
        Text("\(Text(entry.account).monospaced().blur(radius: revealed ? 0 : 4)) can't be used: \(entry.error ?? "gh reports this login as invalid.")")
          .font(.caption).foregroundStyle(.tertiary)
      }
      if let variable = group.environmentVariable {
        Text("\(variable) is set on the server, so it overrides the account chosen here until it is unset.").font(.caption).foregroundStyle(.orange)
      }
    }
  }

  /// The full `hosts` map after one host changes; hosts left on gh's defaults (enabled, nothing pinned) are dropped.
  private func save(_ host: String, enabled: Bool? = nil, account: String?? = nil) {
    var next = settings(model, environmentId).github.hosts.mapValues { GitHubHostSettings(account: $0.account, enabled: $0.enabled) }
    let previous = next[host]
    let isEnabled = enabled ?? previous?.enabled ?? true
    let pin: String? = account == nil ? previous?.account : account!
    next[host] = isEnabled && pin == nil ? nil : GitHubHostSettings(account: pin, enabled: isEnabled)
    saving = true
    Task { @MainActor in
      defer { saving = false }
      if await saveCredentials(model, environmentId, ServerSettingsPatch(github: ServerSettingsPatchGithub(hosts: next))) { onSaved() }
    }
  }
}

// MARK: Bitbucket

/// Bitbucket credentials: an access token or an Atlassian account email plus API token, never both. Tokens are write-only.
struct BitbucketCredentialsForm: View {
  @Environment(SettingsModel.self) private var model
  let environmentId: EnvironmentId
  let onSaved: () -> Void
  @State private var choice: Method?
  @State private var accessToken = ""
  @State private var email: String?
  @State private var apiToken = ""
  @State private var saving = false

  enum Method: String, CaseIterable {
    case access, api
    var label: String { self == .access ? "Access token" : "API token" }
    var help: String {
      self == .access
        ? "Scoped to one repository, project, or workspace. Create it in that item's Bitbucket settings."
        : "Uses your Atlassian account, so it reaches every repository you can. Give it read and write access to repositories and pull requests, and read:user:bitbucket."
    }
    var link: (String, URL) {
      self == .access
        ? ("Learn more", URL(string: "https://support.atlassian.com/bitbucket-cloud/docs/access-tokens/")!)
        : ("Create an API token", URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
    }
  }

  var body: some View {
    let saved = settings(model, environmentId).bitbucket
    let current: Method? = !saved.accessToken.isEmpty ? .access : (!saved.email.isEmpty && !saved.apiToken.isEmpty ? .api : nil)
    let method = choice ?? current ?? .access
    let isSaved = current == method
    let emailValue = (email ?? saved.email).trimmingCharacters(in: .whitespaces)
    let newAccess = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let newAPI = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    // Saving one method clears the other, so a hidden credential never wins over the visible one. Resending the saved
    // token's redacted value keeps it.
    let patch: ServerSettingsPatchBitbucket? =
      method == .access
      ? (newAccess.isEmpty ? nil : ServerSettingsPatchBitbucket(email: "", accessToken: newAccess, apiToken: ""))
      : (!emailValue.isEmpty && (!newAPI.isEmpty || !saved.apiToken.isEmpty)
        ? ServerSettingsPatchBitbucket(email: emailValue, accessToken: "", apiToken: newAPI.isEmpty ? saved.apiToken : newAPI) : nil)
    let canSave = patch != nil && (method == .access || !isSaved || !newAPI.isEmpty || emailValue != saved.email)
    VStack(alignment: .leading, spacing: 10) {
      Picker("Sign-in method", selection: Binding(get: { method }, set: { choice = $0 })) {
        ForEach(Method.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      Text(method.help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Link(method.link.0, destination: method.link.1).font(.callout)
      if method == .access {
        SecureField("Access token", text: $accessToken, prompt: Text(isSaved ? "Stored secret, enter a new value to replace" : "Not set")).textFieldStyle(.roundedBorder)
      } else {
        TextField("Atlassian account email", text: Binding(get: { email ?? saved.email }, set: { email = $0 }), prompt: Text("you@example.com"))
          .textFieldStyle(.roundedBorder).autocorrectionDisabled()
        SecureField("API token", text: $apiToken, prompt: Text(isSaved ? "Stored secret, enter a new value to replace" : "Not set")).textFieldStyle(.roundedBorder)
      }
      HStack {
        Text(
          current == nil
            ? "Without a saved token, the server falls back to its T3CODE_BITBUCKET_* environment variables."
            : isSaved ? "" : "Saving replaces your \(current?.label.lowercased() ?? "credentials")."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if current != nil { Button("Remove") { save(ServerSettingsPatchBitbucket(email: "", accessToken: "", apiToken: "")) }.disabled(saving) }
        Button("Save") { if let patch { save(patch) } }.disabled(!canSave || saving)
      }
      .controlSize(.small)
    }
    .disabled(saving)
  }

  private func save(_ patch: ServerSettingsPatchBitbucket) {
    saving = true
    Task { @MainActor in
      defer { saving = false }
      if await saveCredentials(model, environmentId, ServerSettingsPatch(bitbucket: patch)) {
        accessToken = ""
        apiToken = ""
        email = nil
        onSaved()
      }
    }
  }
}
