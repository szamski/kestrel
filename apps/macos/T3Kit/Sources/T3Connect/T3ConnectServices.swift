import Foundation
import T3ClientRuntime
import T3Protocol

/// Everything T3 Connect composes, built once per launch. `authorizer` plugs into `ClientRuntime.live(managed:)`;
/// the rest serves the settings page.
@MainActor
public struct T3ConnectServices {
  public let configuration: T3ConnectConfiguration
  public let session: any CloudSession
  public let relay: RelayClient
  public let authorizer: ManagedEnvironmentAuthorizer
  public let linker: LocalEnvironmentLinker

  public init(
    configuration: T3ConnectConfiguration, session: any CloudSession, signer: DPoPSigner, metadata: ClientMetadata,
    urlSession: URLSession = URLSession(configuration: .ephemeral)
  ) {
    self.configuration = configuration
    self.session = session
    relay = RelayClient(configuration: configuration, signer: signer, session: urlSession)
    authorizer = ManagedEnvironmentAuthorizer(relay: relay, session: session, signer: signer, metadata: metadata, urlSession: urlSession)
    linker = LocalEnvironmentLinker(relay: relay, relayURL: configuration.relayURL, urlSession: urlSession)
  }

  /// Production wiring: Clerk for the account, the device proof key in the Keychain (`<keychainService>.dpop`).
  public static func live(configuration: T3ConnectConfiguration, keychainService: String, appVersion: String?) -> T3ConnectServices {
    T3ConnectServices(
      configuration: configuration, session: ClerkCloudSession(configuration: configuration),
      signer: DPoPSigner(store: KeychainDPoPKeyStore(service: "\(keychainService).dpop")),
      metadata: ClientMetadata(label: EnvironmentRegistry.tokenExchangeLabel, appVersion: appVersion))
  }
}
