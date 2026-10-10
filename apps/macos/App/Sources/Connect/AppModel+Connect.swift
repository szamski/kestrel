import Foundation
import T3Contracts

extension AppModel {
  /// The environment of the server this app runs itself, once it has registered.
  static var storedLocalEnvironmentId: EnvironmentId? {
    UserDefaults.standard.string(forKey: localEnvironmentKey).map { EnvironmentId(rawValue: $0) }
  }
}
