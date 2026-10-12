import Foundation
import Observation
import T3ClientRuntime
import T3Contracts
import T3Protocol

/// Pairing links and authorized clients of one environment (this Mac's server), live from `subscribeAuthAccess`, with the
/// writes web's Connections page makes over HTTP: create a pairing link, revoke a link, revoke a client, revoke the others.
/// The server decides what this session may do; `session` only shapes what the page offers.
@MainActor @Observable
final class ConnectionsAccessModel {
  struct Failure: Error, LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  let runtime: ClientRuntime
  private(set) var environmentId: EnvironmentId?

  /// Nil until the first snapshot of the current connection.
  private(set) var access: AuthAccessSnapshot?
  /// This client's own grant on the environment.
  private(set) var session: AuthSessionState?
  private(set) var streamError: String?
  var failure: String?
  private(set) var creating = false
  private(set) var revokingOthers = false
  private(set) var revoking: Set<String> = []
  /// The raw credential of links created in this window. The server never lists it again, so it lives only while the page does.
  private(set) var credentials: [String: String] = [:]
  /// The link whose sheet (QR, URL, copy) is open.
  var sharing: String?
  /// T3 Connect state of this Mac's server, for "Publish agent activity". Nil when unknown or this session cannot read it.
  private(set) var cloudLink: EnvironmentCloudLinkStateResult?
  private(set) var updatingPublish = false

  @ObservationIgnored private var streamTask: Task<Void, Never>?
  #if DEBUG
  @ObservationIgnored var debugDone = false
  #endif

  init(runtime: ClientRuntime) { self.runtime = runtime }

  var canRead: Bool { session.map { AuthAccess.grants(.accessRead, in: $0) } ?? false }
  var canWrite: Bool { session.map { AuthAccess.grants(.accessWrite, in: $0) } ?? false }
  var canManageRelay: Bool { session.map { AuthAccess.grants(.relayWrite, in: $0) } ?? false }
  /// What this session may hand to a new client: its own grant.
  var heldScopes: [AuthEnvironmentScope] { session.map { $0.permissions ?? $0.scopes ?? [] } ?? [] }

  var links: [AuthPairingLink] { AuthAccess.sorted(access?.pairingLinks ?? []) }
  var clients: [AuthClientSession] { AuthAccess.sorted(access?.clientSessions ?? []) }

  // MARK: Live data

  /// Follows the environment's connection: reads this client's grant, then streams the access list on every session the
  /// supervisor opens. Returns when the page goes away (the task is cancelled).
  func run(environmentId: EnvironmentId?) async {
    self.environmentId = environmentId
    access = nil
    session = nil
    guard let environmentId else { return }
    defer { streamTask?.cancel() }
    for await ready in runtime.sessions(for: environmentId) {
      streamTask?.cancel()
      guard let ready else { continue }  // keep what is shown while the connection comes back
      streamTask = Task { await follow(ready, environmentId) }
    }
  }

  private func follow(_ ready: any EnvironmentSession, _ environmentId: EnvironmentId) async {
    do {
      session = try await authorized { client, auth in try await client.get(Http.authSession.path, auth: auth) }
    } catch {
      session = nil
      access = nil
      streamError = "Could not read this session's permissions: \(Self.message(error))"
      return
    }
    await loadCloudLink()
    guard canRead else {
      access = nil
      streamError = "This session cannot view pairing links or authorized clients."
      return
    }
    streamError = nil
    var current: AuthAccessSnapshot?
    do {
      for try await event in ready.subscribe(Rpc.subscribeAuthAccess, EmptyObject()) {
        // Updates before the first snapshot say nothing about the whole list.
        if current == nil { guard case .snapshot = event else { continue } }
        let next = AuthAccess.apply(event, to: current ?? AuthAccess.empty)
        current = next
        access = next
        #if DEBUG
        if !debugDone { debugDone = true; Task { await debugPairingLink() } }
        #endif
      }
    } catch is CancellationError {
    } catch {
      streamError = "Could not load the access list: \(Self.message(error))"
    }
  }

  // MARK: T3 Connect preference

  func loadCloudLink() async {
    guard let session, AuthAccess.grants(.relayRead, in: session) else { return cloudLink = nil }
    cloudLink = try? await authorized { client, auth in try await client.get(Http.connectLinkState.path, auth: auth) }
  }

  /// `POST /api/connect/preferences`: only meaningful while the server is linked to a T3 account (the link itself is made in T3 Connect).
  func setPublishAgentActivity(_ on: Bool) async {
    guard !updatingPublish else { return }
    updatingPublish = true
    failure = nil
    defer { updatingPublish = false }
    do {
      cloudLink = try await authorized { client, auth in
        try await client.post(Http.connectPreferences.path, body: EnvironmentCloudPreferencesRequest(publishAgentActivity: on), auth: auth)
      }
    } catch {
      failure = "Could not change agent activity publishing. \(Self.message(error))"
    }
  }

  // MARK: Writes

  /// A one-time link for another device. The credential comes back once and is kept for the sheet.
  @discardableResult
  func createLink(label: String, scopes: [AuthGrantScope]) async -> String? {
    guard !creating else { return nil }
    creating = true
    failure = nil
    defer { creating = false }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let result: AuthPairingCredentialResult = try await authorized { client, auth in
        try await client.post(Http.authPairingCredential.path, body: AuthCreatePairingCredentialInput(label: trimmed.isEmpty ? nil : trimmed, scopes: scopes), auth: auth)
      }
      credentials[result.id] = result.credential
      return result.id
    } catch {
      failure = "Could not create the pairing link. \(Self.message(error))"
      return nil
    }
  }

  func revokeLink(_ id: String) async {
    revoking.insert(id)
    defer { revoking.remove(id) }
    do {
      let _: AuthPairingLinkRevokeResult = try await authorized { client, auth in
        try await client.post(Http.authRevokePairingLink.path, body: AuthRevokePairingLinkInput(id: id), auth: auth)
      }
      credentials[id] = nil
      if sharing == id { sharing = nil }
    } catch {
      failure = "Could not revoke the pairing link. \(Self.message(error))"
    }
  }

  func revokeClient(_ sessionId: AuthSessionId) async {
    revoking.insert(sessionId.rawValue)
    defer { revoking.remove(sessionId.rawValue) }
    do {
      let _: AuthClientSessionRevokeResult = try await authorized { client, auth in
        try await client.post(Http.authRevokeClient.path, body: AuthRevokeClientSessionInput(sessionId: sessionId), auth: auth)
      }
    } catch {
      failure = "Could not revoke the client. \(Self.message(error))"
    }
  }

  func revokeOtherClients() async {
    guard !revokingOthers else { return }
    revokingOthers = true
    defer { revokingOthers = false }
    do {
      let _: AuthOtherClientSessionsRevokeResult = try await authorized { client, auth in try await client.postWithoutBody(Http.authRevokeOtherClients.path, auth: auth) }
    } catch {
      failure = "Could not revoke the other clients. \(Self.message(error))"
    }
  }

  // MARK: HTTP

  /// The environment's own bearer goes to that environment only.
  func authorized<T: Sendable>(_ call: (EnvironmentHTTPClient, RequestAuthorization) async throws -> T) async throws -> T {
    guard let environmentId, let local = await runtime.directAuthorization(for: environmentId) else { throw Failure("This Mac's server is not connected.") }
    return try await call(EnvironmentHTTPClient(baseURL: local.httpBaseURL), local.authorization)
  }

  static func message(_ error: any Error) -> String {
    switch error as? EnvironmentHTTPError {
    case .server(let status, _, let reason, let requiredScope, _)?:
      reason ?? requiredScope.map { "This session needs the \($0) permission." } ?? "The server answered with status \(status)."
    case .transport(let message)?, .invalidJSON(let message)?: message
    case .timeout?: "The server did not respond."
    case nil: error.localizedDescription
    }
  }
}
