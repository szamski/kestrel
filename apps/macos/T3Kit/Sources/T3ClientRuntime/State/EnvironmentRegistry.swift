import Foundation
import T3Contracts
import T3Protocol

public enum AddEnvironmentError: Error, Sendable, Equatable {
  case invalidPairing(String)
  case unreachable(String)
  /// The server speaks another orchestration protocol version than this client.
  case incompatible(String)
  /// The pairing code was refused, expired or already used.
  case pairingRejected(String)
  case unsupportedToken(String)
  case storage(String)
  /// The environment is already saved with a direct credential; a second route would replace it.
  case alreadyConnected(String)

  public var message: String {
    switch self {
    case .invalidPairing(let m), .unreachable(let m), .incompatible(let m), .pairingRejected(let m), .unsupportedToken(let m), .storage(let m),
      .alreadyConnected(let m):
      m
    }
  }
}

/// One saved environment and its connection, as the UI lists it.
public struct EnvironmentStatus: Sendable, Equatable, Identifiable {
  public var environmentId: EnvironmentId
  public var label: String
  public var enabled: Bool
  public var connection: SupervisorConnectionState
  public var route: ConnectionRoute = .direct
  public var id: EnvironmentId { environmentId }
}

/// Scopes connections by environment (port of connection/registry.ts for direct, bearer-paired
/// environments). An involuntary disconnect keeps the registration and cached data; explicit removal
/// closes the scope and clears credentials, caches and client-owned state.
public actor EnvironmentRegistry {
  public static let tokenExchangeLabel = "T3 Code macOS"

  public nonisolated let runtimes = ValueHub<[EnvironmentRuntime]>([])
  private let catalog: EnvironmentCatalogFile
  private let credentials: any CredentialStore
  private let cache: any SnapshotCache
  private let clientState: ClientStateStore?
  private let loader: any SnapshotLoading
  private let clock: any RuntimeClock
  private let metadata: ClientMetadata
  private let makeDriver: @Sendable (any CredentialStore, ClientMetadata) -> any ConnectionDriving
  private let keepRunningThreadsMounted: Bool
  private let httpSession: URLSession
  private var network: NetworkStatus = .unknown
  private var started: [EnvironmentId: EnvironmentRuntime] = [:]
  private var order: [EnvironmentId] = []

  public init(
    catalog: EnvironmentCatalogFile, credentials: any CredentialStore, cache: any SnapshotCache,
    clientState: ClientStateStore? = nil, loader: any SnapshotLoading = HTTPSnapshotLoader(), clock: any RuntimeClock = SystemClock(),
    metadata: ClientMetadata = ClientMetadata(label: EnvironmentRegistry.tokenExchangeLabel),
    keepRunningThreadsMounted: Bool = true, httpSession: URLSession = URLSession(configuration: .ephemeral),
    makeDriver: (@Sendable (any CredentialStore, ClientMetadata) -> any ConnectionDriving)? = nil
  ) {
    self.catalog = catalog
    self.credentials = credentials
    self.cache = cache
    self.clientState = clientState
    self.loader = loader
    self.clock = clock
    self.metadata = metadata
    self.keepRunningThreadsMounted = keepRunningThreadsMounted
    self.httpSession = httpSession
    self.makeDriver = makeDriver ?? { BearerConnectionDriver(credentials: $0, metadata: $1) }
  }

  // MARK: Lifecycle

  /// Starts every saved environment (enabled ones connect).
  public func start() async {
    for entry in catalog.load() where started[entry.environmentId] == nil { await launch(entry) }
  }

  public func stop() async {
    for runtime in started.values { await runtime.stop() }
    started = [:]
    order = []
    publish()
  }

  private func launch(_ entry: EnvironmentConnectionEntry) async {
    let runtime = EnvironmentRuntime(
      entry: entry, driver: makeDriver(credentials, metadata), cache: cache, loader: loader, clock: clock, network: network,
      keepRunningThreadsMounted: keepRunningThreadsMounted)
    started[entry.environmentId] = runtime
    order.append(entry.environmentId)
    publish()
    await runtime.start()
  }

  private func publish() { runtimes.set(order.compactMap { started[$0] }) }

  public func runtime(for environmentId: EnvironmentId) -> EnvironmentRuntime? { started[environmentId] }

  // MARK: Catalog

  /// Pairs with an environment from a pairing link (`https://host/pair#token=...`).
  @discardableResult
  public func add(pairingURL: String) async throws(AddEnvironmentError) -> EnvironmentConnectionEntry {
    do { return try await add(target: try PairingTarget.parse(pairingURL: pairingURL)) } catch let error as PairingError {
      throw .invalidPairing(Self.describe(error))
    } catch let error as AddEnvironmentError { throw error } catch { throw .unreachable("\(error)") }
  }

  /// Pairs with a host (scheme optional, https assumed) and a pairing code.
  @discardableResult
  public func add(host: String, pairingCode: String) async throws(AddEnvironmentError) -> EnvironmentConnectionEntry {
    do { return try await add(target: try PairingTarget.resolve(host: host, pairingCode: pairingCode)) } catch let error as PairingError {
      throw .invalidPairing(Self.describe(error))
    } catch let error as AddEnvironmentError { throw error } catch { throw .unreachable("\(error)") }
  }

  /// Registers the environment with an already-resolved target: descriptor, token exchange, credential
  /// into the Keychain, catalog entry, connect. Pairing the same environment again replaces its credential.
  @discardableResult
  public func add(target: PairingTarget) async throws(AddEnvironmentError) -> EnvironmentConnectionEntry {
    try await register(target: target, label: target.label, metadata: metadata)
  }

  /// Registers the server this app started itself: the desktop bootstrap credential is exchanged for a bearer
  /// like a pairing code, under `label` in the catalog and `clientLabel` on the server's client list.
  @discardableResult
  public func addLocal(baseURL: URL, bootstrapToken: String, label: String, clientLabel: String) async throws(AddEnvironmentError)
    -> EnvironmentConnectionEntry
  {
    let target: PairingTarget
    do { target = try PairingTarget.resolve(host: baseURL.absoluteString, pairingCode: bootstrapToken) } catch {
      throw .invalidPairing(Self.describe(error))
    }
    var local = metadata
    local.label = clientLabel
    return try await register(target: target, label: label, metadata: local)
  }

  private func register(target: PairingTarget, label requestedLabel: String?, metadata: ClientMetadata) async throws(AddEnvironmentError)
    -> EnvironmentConnectionEntry
  {
    let http = EnvironmentHTTPClient(baseURL: target.httpBaseURL, session: httpSession)
    let descriptor: EnvironmentDescriptorInfo
    let token: AccessTokenResponse
    do {
      descriptor = try await http.descriptor()
      if let incompatible = ProtocolCompatibility.check(descriptor) {
        throw AddEnvironmentError.incompatible(incompatible.message(environmentLabel: descriptor.label))
      }
      token = try await http.exchangeToken(credential: target.credential, clientMetadata: metadata)
    } catch let error as AddEnvironmentError {
      throw error
    } catch let error as EnvironmentHTTPError {
      switch error {
      case .server(let status, _, let reason, _, _) where [400, 401, 403].contains(status):
        throw .pairingRejected(reason ?? "The pairing code was rejected. It may have expired or been used already.")
      case .server(let status, _, _, _, _): throw .unreachable("The environment answered with status \(status).")
      case .transport(let message), .invalidJSON(let message): throw .unreachable(message)
      case .timeout: throw .unreachable("The environment did not respond.")
      }
    } catch {
      throw .unreachable("\(error)")
    }
    guard token.tokenType.lowercased() == "bearer" else {
      throw .unsupportedToken("The environment issued a \(token.tokenType) token, which this client cannot use yet.")
    }
    let environmentId = EnvironmentId(rawValue: descriptor.environmentId)
    let label = requestedLabel ?? descriptor.label
    do {
      try credentials.save(
        EnvironmentCredential(
          environmentId: descriptor.environmentId, label: label, httpBaseURL: target.httpBaseURL, wsBaseURL: target.wsBaseURL,
          accessToken: token.accessToken, tokenType: token.tokenType))
    } catch {
      throw .storage("Could not store the credential in the Keychain.")
    }
    let entry = EnvironmentConnectionEntry(environmentId: environmentId, label: label, httpBaseURL: target.httpBaseURL, wsBaseURL: target.wsBaseURL)
    try await install(entry)
    return entry
  }

  /// Saves a T3 Connect environment. Nothing secret is stored: the driver asks the signed-in account for access on every connect.
  /// Saving the same relay environment again only updates its label and last known endpoint.
  @discardableResult
  public func addManaged(environmentId: EnvironmentId, label: String, httpBaseURL: URL, wsBaseURL: URL) async throws(AddEnvironmentError)
    -> EnvironmentConnectionEntry
  {
    let entry = EnvironmentConnectionEntry(environmentId: environmentId, label: label, httpBaseURL: httpBaseURL, wsBaseURL: wsBaseURL, route: .relay)
    if let existing = catalog.load().first(where: { $0.environmentId == environmentId }) {
      // Installing over a direct entry would drop its bearer scope: the user pairs and unpairs those explicitly.
      guard existing.route == .relay else { throw .alreadyConnected("\(existing.label) is already connected directly on this Mac.") }
      var same = existing
      same.label = label
      same.httpBaseURL = httpBaseURL
      same.wsBaseURL = wsBaseURL
      if same == existing, started[environmentId] != nil { return existing }
      var kept = entry
      kept.enabled = existing.enabled
      try await install(kept)
      return kept
    }
    try await install(entry)
    return entry
  }

  /// Replaces the environment's scope with one for `entry`, saves the catalog and connects.
  private func install(_ entry: EnvironmentConnectionEntry) async throws(AddEnvironmentError) {
    let environmentId = entry.environmentId
    if let existing = started[environmentId] {
      // Pairing again: replace the old scope so it connects with the new credential.
      await existing.stop()
      started[environmentId] = nil
      order.removeAll { $0 == environmentId }
    }
    var entries = catalog.load().filter { $0.environmentId != environmentId }
    entries.append(entry)
    do { try catalog.save(entries) } catch { throw .storage("Could not save the environment list.") }
    await launch(entry)
  }

  /// Removes the environment: closes its scope and clears credentials, caches and client-owned state.
  public func remove(_ environmentId: EnvironmentId) async {
    if let runtime = started.removeValue(forKey: environmentId) { await runtime.stop() }
    order.removeAll { $0 == environmentId }
    try? credentials.remove(environmentId: environmentId.rawValue)
    await cache.clearEnvironment(environmentId)
    await clientState?.update { $0.removeEnvironment(environmentId) }
    try? catalog.save(catalog.load().filter { $0.environmentId != environmentId })
    publish()
  }

  /// The saved bearer credential of a direct environment, for calls to that same server (T3 Connect linking). Relay environments have none.
  public func directAuthorization(for environmentId: EnvironmentId) -> (httpBaseURL: URL, authorization: RequestAuthorization)? {
    guard let entry = catalog.load().first(where: { $0.environmentId == environmentId }), entry.route == .direct,
      let credential = try? credentials.load(environmentId: environmentId.rawValue), credential.tokenType.lowercased() == "bearer"
    else { return nil }
    return (entry.httpBaseURL, .bearer(credential.accessToken))
  }

  /// Switches a saved environment on or off. Off drops the socket and stops the retry ladder;
  /// registration, credentials and cache stay.
  public func setEnabled(_ environmentId: EnvironmentId, _ enabled: Bool) async {
    var entries = catalog.load()
    guard let index = entries.firstIndex(where: { $0.environmentId == environmentId }) else { return }
    entries[index].enabled = enabled
    try? catalog.save(entries)
    guard let runtime = started[environmentId] else { return }
    if enabled { await runtime.connect() } else { await runtime.disconnect() }
  }

  public func retryNow(_ environmentId: EnvironmentId) async { await started[environmentId]?.retryNow() }

  // MARK: Platform signals

  public func networkChanged(_ status: NetworkStatus) async {
    network = status
    for runtime in started.values { await runtime.networkChanged(status) }
  }

  public func wake(_ reason: ConnectionWakeup) async {
    for runtime in started.values { await runtime.wake(reason) }
  }

  private static func describe(_ error: PairingError) -> String {
    switch error {
    case .missingBackendURL: "Enter the address of the T3 Code server."
    case .invalidPairingURL: "That is not a valid pairing link."
    case .invalidBackendURL: "That is not a valid server address."
    case .missingToken, .missingCode: "The pairing link or code is missing."
    }
  }
}
