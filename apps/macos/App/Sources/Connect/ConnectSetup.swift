import Foundation
import T3ClientRuntime
import T3Connect

/// Reads T3 Connect's public configuration (Info.plist, filled from App/Support/Connect.xcconfig, the values web and desktop get from
/// `.env`) and builds the services once per launch. A build without a valid configuration simply has no T3 Connect.
@MainActor
enum ConnectSetup {
  struct Result {
    var services: T3ConnectServices? = nil
    var unavailableReason: String? = nil
  }

  static func make(keychainService: String, appVersion: String?) -> Result {
    switch T3ConnectConfiguration.resolve() {
    case .available(let configuration):
      Result(services: .live(configuration: configuration, keychainService: keychainService, appVersion: appVersion))
    case .unavailable(let reason):
      Result(services: nil, unavailableReason: reason)
    }
  }
}
