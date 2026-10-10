import SwiftUI
import T3ClientRuntime
import T3Connect

/// Settings › Connections › T3 Connect: sign in, the account's environments, and linking this Mac.
struct ConnectSettings: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.connect
    Section("T3 Connect") {
      if !model.isAvailable {
        Text(model.unavailableReason ?? "T3 Connect is not available in this build.").foregroundStyle(.secondary)
      } else if let account = model.account {
        SignedInView(model: model, account: account)
      } else {
        SignInView(model: model)
      }
      if let message = model.message {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
    }
    // Loads the account's environments (and this Mac's link) when the page opens or the account changes.
    .task(id: model.account?.id) { await model.refresh() }
  }
}

private struct SignInView: View {
  let model: ConnectModel
  @State private var email = ""
  @State private var code = ""

  var body: some View {
    Text("Sign in to reach the environments linked to your T3 account from this Mac, and to link this Mac for your other devices.")
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    if model.signInStep == .working { ProgressView().controlSize(.small) }
    switch model.signInStep {
    case .codeSent(let sent):
      Text("Enter the code sent to \(sent).").font(.callout)
      HStack {
        TextField("Code", text: $code).textFieldStyle(.roundedBorder).frame(maxWidth: 160).onSubmit { Task { await model.verifyEmailCode(code) } }
        Button("Verify") { Task { await model.verifyEmailCode(code) } }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        Button("Cancel", role: .cancel) { model.cancelEmailCode() }
      }
    default:
      HStack {
        ForEach(CloudSignInProvider.allCases) { provider in
          Button(provider.title) { Task { await model.signIn(with: provider) } }
        }
      }
      .disabled(model.signInStep == .working)
      HStack {
        TextField("Email address", text: $email).textFieldStyle(.roundedBorder).onSubmit { Task { await model.sendEmailCode(to: email) } }
        Button("Email me a code") { Task { await model.sendEmailCode(to: email) } }.disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || model.signInStep == .working)
      }
      Text("New to T3? Create your account at [app.t3.codes](https://app.t3.codes), then sign in here.").font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct SignedInView: View {
  let model: ConnectModel
  let account: CloudAccount

  var body: some View {
    HStack {
      Label(account.email ?? account.id, systemImage: "person.crop.circle")
      Spacer()
      Button("Sign out") { Task { await model.signOut() } }
    }
    thisMac
    HStack {
      Text("Environments").font(.headline)
      if model.loading { ProgressView().controlSize(.small) }
      Spacer()
      Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Refresh").disabled(model.loading)
    }
    if model.rows.isEmpty && !model.loading {
      Text("No environments are linked to this account yet. Link this Mac, or run `npx t3 connect` on another computer.").font(.callout).foregroundStyle(.secondary)
    }
    ForEach(model.rows) { row in EnvironmentLinkRow(model: model, row: row) }
  }

  @ViewBuilder private var thisMac: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("This Mac").font(.headline)
        Spacer()
        if let working = model.working {
          ProgressView().controlSize(.small)
          Text(working).font(.caption).foregroundStyle(.secondary)
        } else {
          switch model.link {
          case .linked: Button("Unlink this Mac") { Task { await model.unlinkThisMac() } }
          case .linkedToAnotherAccount: Text("Linked to another account").font(.caption).foregroundStyle(.secondary)
          case .notLinked, .unknown: Button("Link this Mac") { Task { await model.linkThisMac() } }.disabled(!model.canLinkThisMac)
          }
        }
      }
      Text(thisMacCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let version = model.installPrompt {
        HStack {
          Text("Linking needs the relay client (cloudflared \(version)). T3 Code downloads and verifies it once.").font(.callout)
          Spacer()
          Button("Download and link") { Task { await model.linkThisMac(installRelayClient: true) } }
          Button("Not now", role: .cancel) { model.declineRelayClientInstall() }
        }
      }
    }
  }

  private var thisMacCaption: String {
    switch model.link {
    case .linked: "This Mac is reachable from your other signed-in devices through a managed tunnel."
    case .linkedToAnotherAccount: "This Mac's server is linked to a different T3 account. Unlink it there first."
    case .notLinked, .unknown: "Make this Mac's server reachable from your other devices. Needs the local server."
    }
  }
}

private struct EnvironmentLinkRow: View {
  @Environment(AppModel.self) private var app
  let model: ConnectModel
  let row: ConnectModel.Row

  var body: some View {
    let saved = model.saved(row)
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 5)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.isThisMac(row) ? "\(row.record.label) (this Mac)" : row.record.label).lineLimit(1)
        Text(detail(saved)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 4)
      if saved == nil && !model.isThisMac(row) { Button("Connect") { Task { await model.connect(row) } } }
      Menu {
        if saved?.route == .relay { Button("Remove from this Mac") { Task { await model.removeFromThisMac(row) } } }
        Button("Unlink from account\u{2026}", role: .destructive) {
          app.confirm(
            "Unlink \u{201C}\(row.record.label)\u{201D}?",
            message: "It disappears from your other devices. The server keeps its data, and you can link it again.", confirmTitle: "Unlink"
          ) { await model.unlink(row) }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton).fixedSize()
    }
  }

  private var tint: Color {
    switch row.status {
    case .online: .green
    case .checking: .yellow
    case .offline: .gray
    case .unknown: .orange
    }
  }

  private func detail(_ saved: EnvironmentStatus?) -> String {
    var parts: [String] = []
    switch row.status {
    case .checking: parts.append("Checking\u{2026}")
    case .online: parts.append("Online")
    case .offline(let reason): parts.append(reason)
    case .unknown(let reason): parts.append(reason)
    }
    if let saved {
      parts.append(saved.route == .relay ? "Connected through T3 Connect on this Mac: \(saved.connection.phase.rawValue)" : "Also connected directly on this Mac")
    }
    return parts.joined(separator: " \u{00B7} ")
  }
}
