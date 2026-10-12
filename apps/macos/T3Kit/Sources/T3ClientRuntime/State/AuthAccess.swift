import Foundation
import T3Contracts

/// The access list of an environment (`subscribeAuthAccess`): pairing links and authorized clients. Ports
/// `applyAuthAccessStreamEvent` (packages/client-runtime/src/state/auth.ts) and the list rules of web's Connections page.
public enum AuthAccess {
  public static let empty = AuthAccessSnapshot(pairingLinks: [], clientSessions: [])

  /// The snapshot after one stream event. A snapshot event replaces everything; upserts replace by id.
  public static func apply(_ event: AuthAccessStreamEvent, to current: AuthAccessSnapshot) -> AuthAccessSnapshot {
    var next = current
    switch event {
    case .snapshot(let e): next = e.payload
    case .pairingLinkUpserted(let e):
      next.pairingLinks.removeAll { $0.id == e.payload.id }
      next.pairingLinks.append(e.payload)
    case .pairingLinkRemoved(let e): next.pairingLinks.removeAll { $0.id == e.payload.id }
    case .clientUpserted(let e):
      next.clientSessions.removeAll { $0.sessionId == e.payload.sessionId }
      next.clientSessions.append(e.payload)
    case .clientRemoved(let e): next.clientSessions.removeAll { $0.sessionId == e.payload.sessionId }
    case .unknown: break
    }
    return next
  }

  /// Newest first.
  public static func sorted(_ links: [AuthPairingLink]) -> [AuthPairingLink] {
    links.sorted { (IsoTimestamp.parse($0.createdAt) ?? 0) > (IsoTimestamp.parse($1.createdAt) ?? 0) }
  }

  /// This client first, then connected ones, then newest.
  public static func sorted(_ sessions: [AuthClientSession]) -> [AuthClientSession] {
    sessions.sorted { left, right in
      if left.current != right.current { return left.current }
      if left.connected != right.connected { return left.connected }
      return (IsoTimestamp.parse(left.issuedAt) ?? 0) > (IsoTimestamp.parse(right.issuedAt) ?? 0)
    }
  }

  /// The exact grant: `permissions` when the server sends it (even empty), else the wire `scopes`.
  public static func scopes(of link: AuthPairingLink) -> [AuthEnvironmentScope] { link.permissions ?? link.scopes }
  public static func scopes(of session: AuthClientSession) -> [AuthEnvironmentScope] { session.permissions ?? session.scopes }

  /// A missing list says nothing about whether other clients exist.
  public static func canRevokeOthers(_ sessions: [AuthClientSession]?) -> Bool { sessions?.contains { !$0.current } ?? true }

  /// Whether a session holds `scope`. These client checks only shape the UI; the server authorizes every call.
  public static func grants(_ scope: AuthEnvironmentScope, in session: AuthSessionState) -> Bool {
    guard session.authenticated else { return false }
    return (session.permissions ?? session.scopes ?? []).contains(scope)
  }
}

public struct PairingScopeOption: Sendable, Identifiable, Equatable {
  public var scope: AuthGrantScope
  public var title: String
  public var detail: String
  public var id: String { scope.rawValue }
}

/// What a pairing link can delegate (packages/shared/src/authScopeOptions.ts, AuthStandardClientScopes).
public enum PairingScopes {
  public static let options: [PairingScopeOption] = [
    PairingScopeOption(scope: .orchestrationRead, title: "View environment", detail: "Read threads, status, checkpoints, and configuration."),
    PairingScopeOption(scope: .orchestrationOperate, title: "Operate tasks", detail: "Start, update, and stop tasks."),
    PairingScopeOption(scope: .settingsWrite, title: "Change environment settings", detail: "Edit environment preferences and keybindings."),
    PairingScopeOption(scope: .providersManage, title: "Manage providers", detail: "Configure, install, sign in to, and update providers and usage sources."),
    PairingScopeOption(scope: .environmentMaintain, title: "Maintain environment", detail: "Update the server and control environment processes."),
    PairingScopeOption(scope: .previewOperate, title: "Control previews", detail: "Open browser previews and host browser automation."),
    PairingScopeOption(scope: .diagnosticsRead, title: "View diagnostics and usage", detail: "Read process diagnostics, resource history, and usage totals."),
    PairingScopeOption(scope: .terminalRead, title: "View terminals", detail: "Read existing terminal output and status."),
    PairingScopeOption(scope: .terminalOperate, title: "Use terminals", detail: "Create terminals and send input to running shells."),
    PairingScopeOption(scope: .sourceControlWrite, title: "Change source control", detail: "Commit, push, manage branches and repositories, and change pull requests."),
    PairingScopeOption(scope: .filesystemRead, title: "Read files", detail: "Browse host files, search workspaces, and inspect local changes."),
    PairingScopeOption(scope: .filesystemWrite, title: "Write files", detail: "Edit workspace files and save plans to disk."),
    PairingScopeOption(scope: .accessRead, title: "View access", detail: "Inspect pairing links and authorized clients."),
    PairingScopeOption(scope: .accessWrite, title: "Manage access", detail: "Issue and revoke credentials for other clients."),
    PairingScopeOption(scope: .relayRead, title: "View relay", detail: "Inspect managed relay connectivity."),
    PairingScopeOption(scope: .relayWrite, title: "Manage relay", detail: "Change managed tunnel connectivity."),
  ]

  public static let standard: [AuthGrantScope] = [
    .orchestrationRead, .orchestrationOperate, .settingsWrite, .providersManage, .environmentMaintain, .previewOperate, .diagnosticsRead,
    .terminalRead, .terminalOperate, .sourceControlWrite, .filesystemRead, .filesystemWrite, .relayRead,
  ]
  public static let administrative: [AuthGrantScope] = standard + [.accessRead, .accessWrite, .relayWrite]
  public static let readOnly: [AuthGrantScope] = [.orchestrationRead, .filesystemRead, .diagnosticsRead, .terminalRead]

  /// The part of `scopes` the holder of `held` may delegate.
  public static func delegatable(_ scopes: [AuthGrantScope], by held: [AuthEnvironmentScope]) -> [AuthGrantScope] {
    let held = Set(held.map(\.rawValue))
    return scopes.filter { held.contains($0.rawValue) }
  }

  /// Operating terminals without being able to list them leaves a client allocating a fresh shell it cannot see, so
  /// `terminal:operate` keeps `terminal:read`, and dropping `terminal:read` drops `terminal:operate`.
  public static func toggled(_ current: [AuthGrantScope], _ scope: AuthGrantScope, on: Bool) -> [AuthGrantScope] {
    var next = current.filter { $0 != scope }
    if !on { return scope == .terminalRead ? next.filter { $0 != .terminalOperate } : next }
    next.append(scope)
    if scope == .terminalOperate, !next.contains(.terminalRead) { next.append(.terminalRead) }
    return next
  }
}

/// A way to reach the server that a pairing link can name.
public struct PairingEndpoint: Identifiable, Hashable, Sendable {
  public enum Reach: Sendable { case loopback, lan, tailnet, tailnetHTTPS }

  public var reach: Reach
  public var baseURL: URL
  public var id: String { baseURL.absoluteString }

  public var label: String {
    switch reach {
    case .loopback: "This Mac"
    case .lan: "Local network"
    case .tailnet: "Tailscale"
    case .tailnetHTTPS: "Tailscale HTTPS"
    }
  }

  public var hint: String {
    switch reach {
    case .loopback: "Clients on this Mac only"
    case .lan: "Devices on the same network"
    case .tailnet, .tailnetHTTPS: "Devices on your tailnet"
    }
  }

  /// A QR code of a loopback address makes the scanning device dial itself.
  public var qrShareable: Bool { reach != .loopback }

  /// Loopback first when the server listens locally, then what the server reports binding to (`ServerConfig.directEndpoints`).
  public static func endpoints(loopbackPort: Int?, direct: [ServerConfigDirectEndpointsItem]) -> [PairingEndpoint] {
    var result: [PairingEndpoint] = []
    if let loopbackPort, let url = URL(string: "http://127.0.0.1:\(loopbackPort)") { result.append(PairingEndpoint(reach: .loopback, baseURL: url)) }
    for item in direct {
      guard let url = URL(string: item.httpBaseUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
      let reach: Reach = item.kind == .lan ? .lan : scheme == "https" ? .tailnetHTTPS : .tailnet
      if !result.contains(where: { $0.baseURL == url }) { result.append(PairingEndpoint(reach: reach, baseURL: url)) }
    }
    return result
  }

  /// The first address another device can use; loopback only when there is nothing else.
  public static func preferred(_ endpoints: [PairingEndpoint]) -> PairingEndpoint? { endpoints.first { $0.qrShareable } ?? endpoints.first }

  /// `<endpoint>/pair#token=<credential>`: the fragment keeps the secret out of any request line.
  public func pairingURL(credential: String) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
    components.path = "/pair"
    components.query = nil
    components.percentEncodedFragment = "token=" + (credential.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? credential)
    return components.url
  }

  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
