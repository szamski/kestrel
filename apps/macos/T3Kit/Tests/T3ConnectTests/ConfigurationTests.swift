import Foundation
import Testing
@testable import T3Connect

@Suite struct ConfigurationTests {
  @Test func requiresAllPublicValues() {
    #expect(T3ConnectConfiguration.resolve(infoDictionary: [:]) == .unavailable(reason: "This build is missing the Clerk publishable key, Clerk JWT template, relay host."))
    // An unexpanded build variable counts as missing.
    #expect(
      T3ConnectConfiguration.resolve(infoDictionary: [
        "T3ConnectClerkPublishableKey": "$(T3_CONNECT_CLERK_PUBLISHABLE_KEY)", "T3ConnectClerkJWTTemplate": "t3-relay", "T3ConnectRelayHost": "relay.t3.codes",
      ]) == .unavailable(reason: "This build is missing the Clerk publishable key."))
  }

  @Test func productionValuesFromEnvExample() throws {
    // The values in .env.example (public identifiers).
    let resolution = T3ConnectConfiguration.resolve(infoDictionary: [
      "T3ConnectClerkPublishableKey": "pk_live_Y2xlcmsudDMuY29kZXMk", "T3ConnectClerkJWTTemplate": "t3-relay", "T3ConnectRelayHost": "relay.t3.codes",
    ])
    let configuration = try #require(resolution.configuration)
    #expect(configuration.relayURL.absoluteString == "https://relay.t3.codes")
    #expect(configuration.clerkJWTTemplate == "t3-relay")
    #expect(T3ConnectConfiguration.clerkFrontendAPIHost(publishableKey: configuration.clerkPublishableKey) == "clerk.t3.codes")
  }

  @Test func rejectsMalformedValues() {
    func resolve(key: String = "pk_live_Y2xlcmsudDMuY29kZXMk", host: String = "relay.t3.codes") -> T3ConnectConfiguration.Resolution {
      T3ConnectConfiguration.resolve(infoDictionary: ["T3ConnectClerkPublishableKey": key, "T3ConnectClerkJWTTemplate": "t", "T3ConnectRelayHost": host])
    }
    #expect(resolve(key: "sk_live_secret") == .unavailable(reason: "The Clerk publishable key of this build is not valid."))
    #expect(resolve(key: "pk_live_!!!") == .unavailable(reason: "The Clerk publishable key of this build is not valid."))
    #expect(resolve(host: "relay.example/path") == .unavailable(reason: "The relay host of this build is not valid."))
    #expect(resolve(host: "user@relay.example") == .unavailable(reason: "The relay host of this build is not valid."))
    #expect(resolve(host: "relay.example?x=1") == .unavailable(reason: "The relay host of this build is not valid."))
  }

  @Test func secureOriginKeepsOnlyAnHTTPSOrigin() {
    #expect(T3ConnectConfiguration.secureOrigin("https://Relay.Example:443/")?.absoluteString == "https://relay.example")
    #expect(T3ConnectConfiguration.secureOrigin("https://relay.example:8443")?.absoluteString == "https://relay.example:8443")
    #expect(T3ConnectConfiguration.secureOrigin("http://relay.example") == nil)
    #expect(T3ConnectConfiguration.secureOrigin("https://relay.example/v1") == nil)
  }
}
