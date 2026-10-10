import AuthenticationServices
import Foundation
import Observation
import T3ClientRuntime
import T3Connect
import T3Contracts
import T3Protocol

/// State and actions behind Settings › Connections › T3 Connect: the account, the environments linked to it, and linking this Mac.
/// Thin on purpose: the protocol lives in T3Connect, connections in `ClientRuntime`.
@MainActor @Observable
final class ConnectModel {
  struct Row: Identifiable, Equatable {
    enum Status: Equatable {
      case checking
      case online
      case offline(String)
      case unknown(String)
    }
    var record: RelayClientEnvironmentRecord
    var status: Status
    var id: EnvironmentId { record.environmentId }
  }

  enum SignIn: Equatable {
    case idle
    case working
    case codeSent(email: String)
  }

  enum LinkState: Equatable {
    case unknown
    case notLinked
    case linked
    case linkedToAnotherAccount
  }

  let runtime: ClientRuntime
  /// Why this build has no T3 Connect (nil when it has).
  let unavailableReason: String?
  var isAvailable: Bool { services != nil }

  private(set) var account: CloudAccount?
  private(set) var rows: [Row] = []
  private(set) var loading = false
  private(set) var signInStep: SignIn = .idle
  private(set) var link: LinkState = .unknown
  /// A running multi-step action ("Linking this Mac…").
  private(set) var working: String?
  /// Set when linking needs the relay client (cloudflared) and the user has not agreed to download it yet.
  private(set) var installPrompt: String?
  var message: String?

  @ObservationIgnored private let services: T3ConnectServices?
  @ObservationIgnored private let localEnvironmentId: @MainActor () -> EnvironmentId?
  @ObservationIgnored private var observer: Task<Void, Never>?
  @ObservationIgnored private var refreshGeneration = 0

  init(runtime: ClientRuntime, setup: ConnectSetup.Result, localEnvironmentId: @escaping @MainActor () -> EnvironmentId?) {
    self.runtime = runtime
    services = setup.services
    unavailableReason = setup.unavailableReason
    self.localEnvironmentId = localEnvironmentId
  }

  // MARK: Lifecycle

  func start() async {
    guard let services, observer == nil else { return }
    observer = Task { [weak self] in
      for await next in services.session.accountChanges { await self?.accountChanged(next) }
    }
    await services.session.refresh()
    await accountChanged(services.session.account)
  }

  func stop() {
    observer?.cancel()
    observer = nil
  }

  private func accountChanged(_ next: CloudAccount?) async {
    guard let services else { return }
    let previous = account
    account = next
    guard next?.id != previous?.id else { return }
    // Tokens belong to the account that obtained them.
    await services.authorizer.reset()
    if next != nil {
      // Environments that waited for a sign-in connect now. The list itself loads when the settings page asks for it.
      await runtime.wake(.credentialsChanged)
    } else {
      rows = []
      link = .unknown
      installPrompt = nil
    }
  }

  // MARK: Sign-in

  func signIn(with provider: CloudSignInProvider) async {
    guard let services, signInStep == .idle else { return }
    signInStep = .working
    message = nil
    defer { signInStep = .idle }
    do {
      try await services.session.signIn(with: provider)
      await accountChanged(services.session.account)
      await refresh()
    } catch {
      report(error)
    }
  }

  func sendEmailCode(to email: String) async {
    guard let services, signInStep == .idle else { return }
    signInStep = .working
    message = nil
    do {
      try await services.session.startEmailCode(email: email)
      signInStep = .codeSent(email: email)
    } catch {
      signInStep = .idle
      report(error)
    }
  }

  func verifyEmailCode(_ code: String) async {
    guard let services, case .codeSent(let email) = signInStep else { return }
    signInStep = .working
    message = nil
    do {
      try await services.session.verifyEmailCode(code)
      signInStep = .idle
      await accountChanged(services.session.account)
      await refresh()
    } catch {
      signInStep = .codeSent(email: email)
      report(error)
    }
  }

  func cancelEmailCode() { if case .codeSent = signInStep { signInStep = .idle } }

  func signOut() async {
    guard let services else { return }
    message = nil
    do {
      try await services.session.signOut()
      await accountChanged(services.session.account)
    } catch {
      report(error)
    }
  }

  // MARK: Environments

  func refresh() async {
    guard let services, let account else { return }
    refreshGeneration += 1
    let generation = refreshGeneration
    loading = true
    defer { if generation == refreshGeneration { loading = false } }
    do {
      let token = try await services.session.relayToken()
      let records = try await services.relay.listEnvironments(clerkToken: token)
      guard generation == refreshGeneration, self.account?.id == account.id else { return }
      let known = Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
      rows = records.map { Row(record: $0, status: known[$0.environmentId] ?? .checking) }
      for record in records {
        let status = await status(of: record, token: token)
        guard generation == refreshGeneration, let index = rows.firstIndex(where: { $0.id == record.environmentId }) else { return }
        rows[index].status = status
      }
      await refreshLinkState()
    } catch {
      report(error)
    }
  }

  private func status(of record: RelayClientEnvironmentRecord, token: String) async -> Row.Status {
    guard let services else { return .unknown("T3 Connect is not available.") }
    do {
      let status = try await services.relay.status(of: record, clerkToken: token)
      if status.status == .online { return .online }
      if status.offlineReason == "tunnel_released" { return .offline("Start T3 Code on that computer and update it to reconnect its tunnel.") }
      return .offline(status.error ?? "Offline")
    } catch {
      return .unknown(Self.describe(error))
    }
  }

  /// The saved connection of a relay row on this Mac, if any.
  func saved(_ row: Row) -> EnvironmentStatus? { runtime.environments.first { $0.environmentId == row.id } }

  func isThisMac(_ row: Row) -> Bool { row.id == localEnvironmentId() }

  func connect(_ row: Row) async {
    message = nil
    guard let http = URL(string: row.record.endpoint.httpBaseUrl), let ws = URL(string: row.record.endpoint.wsBaseUrl) else {
      message = "The relay returned an invalid endpoint for \(row.record.label)."
      return
    }
    do {
      try await runtime.addManagedEnvironment(environmentId: row.id, label: row.record.label, httpBaseURL: http, wsBaseURL: ws)
    } catch {
      report(error)
    }
  }

  /// Forgets the saved connection on this Mac. The environment stays linked to the account.
  func removeFromThisMac(_ row: Row) async {
    guard saved(row)?.route == .relay else { return }
    await runtime.removeEnvironment(row.id)
  }

  /// Removes the environment from the account (its other devices lose it). This Mac's own link is undone on the server first.
  func unlink(_ row: Row) async {
    guard let services, account != nil else { return }
    message = nil
    if isThisMac(row) { return await unlinkThisMac() }
    working = "Unlinking \(row.record.label)…"
    defer { working = nil }
    do {
      try await services.relay.unlinkEnvironment(clerkToken: try await services.session.relayToken(), environmentId: row.id)
      if saved(row)?.route == .relay { await runtime.removeEnvironment(row.id) }
      await refresh()
    } catch {
      report(error)
    }
  }

  // MARK: This Mac

  private func linkTarget() async -> LinkTarget? {
    guard let id = localEnvironmentId(), let local = await runtime.directAuthorization(for: id) else { return nil }
    return LinkTarget(environmentId: id, httpBaseURL: local.httpBaseURL, authorization: local.authorization)
  }

  var canLinkThisMac: Bool { account != nil && localEnvironmentId() != nil && working == nil }

  func refreshLinkState() async {
    guard let services, let account, let target = await linkTarget() else { return link = .unknown }
    guard let state = try? await services.linker.linkState(target) else { return link = .unknown }
    link = !state.linked ? .notLinked : state.cloudUserId == account.id ? .linked : .linkedToAnotherAccount
  }

  /// Makes this Mac's server reachable from the account's other devices. A missing relay client (cloudflared) needs a yes first.
  func linkThisMac(installRelayClient: Bool = false) async {
    guard let services, let account, working == nil else { return }
    guard let target = await linkTarget() else {
      message = "This Mac's server is not running."
      return
    }
    message = nil
    installPrompt = nil
    working = "Linking this Mac…"
    defer { working = nil }
    do {
      guard try await ensureRelayClient(target.environmentId, install: installRelayClient) else { return }
      let token = try await services.session.relayToken()
      let session = services.session
      try await services.linker.link(target, clerkToken: token, accountId: account.id, accountStillCurrent: { await session.account?.id == account.id })
      await refresh()
    } catch {
      report(error)
    }
  }

  func declineRelayClientInstall() { installPrompt = nil }

  /// True when the relay client is ready. When it is missing and `install` is false, asks (sets `installPrompt`) and returns false.
  private func ensureRelayClient(_ environmentId: EnvironmentId, install: Bool) async throws -> Bool {
    guard let session = await runtime.runtime(for: environmentId)?.supervisor.session.value else { throw ConnectError("This Mac's server is not connected yet.") }
    switch try await session.call(Rpc.cloudGetRelayClientStatus, EmptyObject()) {
    case .available: return true
    case .unsupported(let status): throw ConnectError("T3 Code cannot install the relay client automatically on \(status.platform)-\(status.arch).")
    case .unknown: throw ConnectError("This Mac's server reported an unknown relay client state. Update T3 Code and try again.")
    case .missing(let status):
      guard install else {
        installPrompt = status.version
        return false
      }
      var installed: RelayClientStatusSchema?
      for try await event in session.subscribe(Rpc.cloudInstallRelayClient, EmptyObject()) {
        switch event {
        case .progress(let progress): working = "Installing the relay client (\(progress.stage.rawValue.replacingOccurrences(of: "_", with: " ")))…"
        case .complete(let complete): installed = complete.status
        case .unknown: break
        }
      }
      guard case .available? = installed else { throw ConnectError("The relay client is still unavailable after installation.") }
      return true
    }
  }

  func unlinkThisMac() async {
    guard let services, account != nil, let target = await linkTarget() else { return }
    working = "Unlinking this Mac…"
    defer { working = nil }
    do {
      // The relay call is best effort once the server is unlinked: the token may have lapsed with the session.
      let token = try? await services.session.relayToken()
      try await services.linker.unlink(target, clerkToken: token)
      await refresh()
    } catch {
      report(error)
      await refreshLinkState()
    }
  }

  // MARK: Errors

  struct ConnectError: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  private func report(_ error: any Error) {
    guard !Self.isCancellation(error) else { return }
    message = Self.describe(error)
  }

  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == ASWebAuthenticationSessionError.errorDomain && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
  }

  static func describe(_ error: any Error) -> String {
    switch error {
    case let error as AddEnvironmentError: error.message
    case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
    default: error.localizedDescription
    }
  }
}
