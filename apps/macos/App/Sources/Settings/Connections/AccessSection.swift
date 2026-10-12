import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Connections › Authorized clients: the one-time pairing links and the clients that paired, live from the server.
struct AccessSection: View {
  let model: ConnectionsAccessModel
  /// Addresses a pairing link can name; empty while the server is not running.
  let endpoints: [PairingEndpoint]
  let connected: Bool

  @State private var creating = false
  @State private var revokingOthers = false
  @State private var revokingClient: AuthClientSession?

  var body: some View {
    Section {
      if let error = model.streamError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary).font(.callout) }
      if model.access == nil, model.streamError == nil {
        if connected {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading\u{2026}").foregroundStyle(.secondary) }
        } else {
          Text("Connect to this Mac's server to see its pairing links and clients.").font(.callout).foregroundStyle(.secondary)
        }
      }
      if model.access != nil {
        pairingLinks
        clients
      }
    } header: {
      HStack {
        Text("Authorized clients").id("authorized-clients")
        Spacer()
        if model.canWrite {
          Button("Revoke others") { revokingOthers = true }
            .disabled(model.revokingOthers || !AuthAccess.canRevokeOthers(model.access?.clientSessions))
          Button("Create link", systemImage: "plus") { creating = true }.disabled(endpoints.isEmpty)
        }
      }
    } footer: {
      Text("A pairing link is a one-time credential for another device. Keep it private until it is used, and revoke any you did not share.")
    }
    .sheet(isPresented: $creating) { CreatePairingLinkSheet(model: model) }
    .sheet(isPresented: Binding(get: { model.sharing != nil }, set: { if !$0 { model.sharing = nil } })) {
      if let id = model.sharing { PairingShareSheet(model: model, linkId: id, endpoints: endpoints) }
    }
    .confirmationDialog("Revoke all other clients?", isPresented: $revokingOthers) {
      Button("Revoke others", role: .destructive) { Task { await model.revokeOtherClients() } }
    } message: {
      Text("Every device except this one is signed out and must pair again.")
    }
    .confirmationDialog(
      "Revoke \u{201C}\(revokingClient.map(ClientRow.title) ?? "")\u{201D}?", isPresented: Binding(get: { revokingClient != nil }, set: { if !$0 { revokingClient = nil } })
    ) {
      Button("Revoke", role: .destructive) { if let client = revokingClient { Task { await model.revokeClient(client.sessionId) } } }
    } message: {
      Text("That device is signed out and must pair again.")
    }
  }

  @ViewBuilder private var pairingLinks: some View {
    Text("Pairing links").font(.subheadline.weight(.medium))
    if model.links.isEmpty {
      Text("No pending pairing links.").font(.callout).foregroundStyle(.secondary)
    }
    ForEach(model.links, id: \.id) { link in
      PairingLinkRow(model: model, link: link, endpoints: endpoints)
    }
  }

  @ViewBuilder private var clients: some View {
    Text("Clients").font(.subheadline.weight(.medium))
    if model.clients.isEmpty {
      Text("No clients have paired yet.").font(.callout).foregroundStyle(.secondary)
    }
    ForEach(model.clients, id: \.sessionId) { client in
      ClientRow(model: model, client: client) { revokingClient = client }
    }
  }
}

// MARK: Rows

private struct PairingLinkRow: View {
  let model: ConnectionsAccessModel
  let link: AuthPairingLink
  let endpoints: [PairingEndpoint]

  var body: some View {
    let credential = model.credentials[link.id]
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "link").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(link.label ?? "Pairing link")
        HStack(spacing: 4) {
          TimelineView(.periodic(from: .now, by: 15)) { context in Text(Self.expiry(link.expiresAt, now: context.date)) }
          Text("\u{00B7}")
          ScopeSummary(scopes: AuthAccess.scopes(of: link))
        }
        .font(.caption).foregroundStyle(.secondary)
        if credential == nil {
          Text("Created in another window or session, so the link itself is not available here.").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if let credential, let endpoint = PairingEndpoint.preferred(endpoints), let url = endpoint.pairingURL(credential: credential) {
        Button { Self.copy(url.absoluteString) } label: { Label("Copy link", systemImage: "doc.on.doc") }.labelStyle(.iconOnly).help("Copy link")
        Button { model.sharing = link.id } label: { Label("Show QR code", systemImage: "qrcode") }.labelStyle(.iconOnly).help("Show QR code")
      }
      if model.canWrite {
        Button("Revoke", role: .destructive) { Task { await model.revokeLink(link.id) } }.disabled(model.revoking.contains(link.id))
      }
    }
    .buttonStyle(.borderless)
  }

  static func expiry(_ expiresAt: IsoDateTime, now: Date) -> String {
    guard let date = expiresAt.date else { return "Expires \(expiresAt.rawValue)" }
    return date <= now ? "Expired" : "Expires \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct ClientRow: View {
  let model: ConnectionsAccessModel
  let client: AuthClientSession
  let revoke: () -> Void

  var body: some View {
    let live = client.current || client.connected
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Circle().fill(live ? .green : .gray.opacity(0.4)).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(Self.title(client))
          if client.current {
            Text("This device").font(.caption2).foregroundStyle(.secondary)
              .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
          }
        }
        HStack(spacing: 4) {
          if !details.isEmpty { Text(details.joined(separator: " \u{00B7} ")); Text("\u{00B7}") }
          ScopeSummary(scopes: AuthAccess.scopes(of: client))
        }
        .font(.caption).foregroundStyle(.secondary)
        Text(seen(live: live)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if !client.current, model.canWrite {
        Button("Revoke", role: .destructive, action: revoke).buttonStyle(.borderless).disabled(model.revoking.contains(client.sessionId.rawValue))
      }
    }
  }

  static func title(_ client: AuthClientSession) -> String {
    let device = client.client
    if let label = device.label, !label.isEmpty { return label }
    let platform = [device.os, device.browser].compactMap { $0 }.joined(separator: " \u{00B7} ")
    return platform.isEmpty ? client.subject : platform
  }

  private var details: [String] {
    let device = client.client
    let type = device.deviceType == .unknownValue ? nil : device.deviceType.rawValue.capitalized
    return [type, device.os, device.browser, device.ipAddress].compactMap { $0 }
  }

  private func seen(live: Bool) -> String {
    if live { return "Connected" }
    guard let last = client.lastConnectedAt else { return "Not connected yet" }
    return "Last seen \(last.date?.formatted(.relative(presentation: .named)) ?? last.rawValue)"
  }
}

/// "13 scopes", opening the list of what was granted.
private struct ScopeSummary: View {
  let scopes: [AuthEnvironmentScope]
  @State private var shown = false

  var body: some View {
    Button("\(scopes.count) \(scopes.count == 1 ? "scope" : "scopes")") { shown.toggle() }
      .buttonStyle(.link)
      .popover(isPresented: $shown) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Granted scopes").font(.headline)
          if scopes.isEmpty { Text("None").foregroundStyle(.secondary) }
          ForEach(scopes, id: \.rawValue) { Text($0.rawValue).font(.caption.monospaced()) }
        }
        .padding(12)
      }
  }
}

// MARK: Sheets

/// Label and permissions of a new pairing link. A client can only be given what this session holds, as the server enforces.
private struct CreatePairingLinkSheet: View {
  let model: ConnectionsAccessModel
  @Environment(\.dismiss) private var dismiss
  @State private var label = ""
  @State private var selected: [AuthGrantScope] = []
  @State private var seeded = false

  var body: some View {
    let offered = PairingScopes.options.filter { option in model.heldScopes.contains { $0.rawValue == option.scope.rawValue } }
    let chosen = selected.filter { scope in offered.contains { $0.scope == scope } }
    VStack(alignment: .leading, spacing: 14) {
      Text("Create pairing link").font(.headline)
      Text("Generate a one-time link that another device can use to pair with this Mac as an authorized client.")
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField("Client label (optional)", text: $label, prompt: Text("e.g. Living room iPad")).textFieldStyle(.roundedBorder)
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Permissions").font(.subheadline.weight(.medium))
          Text("Limit what the paired client can do.").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Read only") { selected = PairingScopes.delegatable(PairingScopes.readOnly, by: model.heldScopes) }
        Button("Standard") { selected = PairingScopes.delegatable(PairingScopes.standard, by: model.heldScopes) }
        Button("Administrative") { selected = PairingScopes.delegatable(PairingScopes.administrative, by: model.heldScopes) }
      }
      .controlSize(.small)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(offered) { option in
            Toggle(isOn: Binding(get: { selected.contains(option.scope) }, set: { selected = PairingScopes.toggled(selected, option.scope, on: $0) })) {
              VStack(alignment: .leading, spacing: 1) {
                Text(option.title)
                Text(option.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 5).padding(.horizontal, 10)
            Divider()
          }
        }
      }
      .frame(height: 230)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      if chosen.isEmpty {
        Text("Select at least one permission.").font(.caption).foregroundStyle(.red)
      } else if chosen.contains(.accessWrite) {
        Text("This client can create or revoke access for other devices.").font(.caption).foregroundStyle(.orange)
      }
      HStack {
        if model.creating { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Create link") {
          Task {
            if let id = await model.createLink(label: label, scopes: chosen) {
              model.sharing = id
              dismiss()
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(chosen.isEmpty || model.creating)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      guard !seeded else { return }
      seeded = true
      selected = PairingScopes.delegatable(PairingScopes.standard, by: model.heldScopes)
    }
  }
}

/// QR code, address and copy buttons for a link created in this window.
private struct PairingShareSheet: View {
  let model: ConnectionsAccessModel
  let linkId: String
  let endpoints: [PairingEndpoint]
  @Environment(\.dismiss) private var dismiss
  @State private var endpointId: String?

  var body: some View {
    let credential = model.credentials[linkId]
    let endpoint = endpoints.first { $0.id == endpointId } ?? PairingEndpoint.preferred(endpoints)
    let url = credential.flatMap { endpoint?.pairingURL(credential: $0) }
    VStack(alignment: .leading, spacing: 12) {
      Text(model.links.first { $0.id == linkId }?.label ?? "Pairing link").font(.headline)
      if let url, let endpoint {
        Text("Scan the code on the other device, or paste the link into Add environment.").font(.callout).foregroundStyle(.secondary)
        if endpoints.count > 1 {
          Picker("Address", selection: Binding(get: { endpoint.id }, set: { endpointId = $0 })) {
            ForEach(endpoints) { Text("\($0.label) \u{00B7} \($0.baseURL.host() ?? "")").tag($0.id) }
          }
        }
        Text(endpoint.hint).font(.caption).foregroundStyle(.secondary)
        if endpoint.qrShareable {
          QRCodeView(text: url.absoluteString).frame(maxWidth: .infinity)
        } else {
          Label("An address on this Mac does not work from another device. Turn on Network access for a link to scan.", systemImage: "info.circle")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Copy link") { PairingLinkRow.copy(url.absoluteString) }
          if let credential { Button("Copy code") { PairingLinkRow.copy(credential) } }
        }
      } else {
        Text("This link is no longer available here.").foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 380)
  }
}
