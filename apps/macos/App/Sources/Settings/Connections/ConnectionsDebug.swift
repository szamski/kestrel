#if DEBUG
import Foundation
import T3ClientRuntime

extension ConnectionsAccessModel {
  /// `-T3DebugPairingLink create|revoke`: verification of the access list against the Debug server without clicking.
  /// `create` makes one standard pairing link labelled "Kestrel debug"; `revoke` removes every link with that label.
  func debugPairingLink() async {
    guard let mode = UserDefaults.standard.string(forKey: "T3DebugPairingLink") else { return }
    let label = "Kestrel debug"
    switch mode {
    case "create": if !links.contains(where: { $0.label == label }) { await createLink(label: label, scopes: PairingScopes.standard) }
    case "revoke": for link in links where link.label == label { await revokeLink(link.id) }
    default: break
    }
  }
}
#endif
