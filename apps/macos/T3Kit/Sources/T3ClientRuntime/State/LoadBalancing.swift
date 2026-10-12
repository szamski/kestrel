import Foundation
import T3Contracts

/// Automatic machine choice for new threads (packages/client-runtime/src/load-balancing.ts), and the four per-machine
/// preferences of Settings › Connections › Load balancing.
public enum LoadBalancing {
  public struct Candidate: Sendable {
    public var environmentId: EnvironmentId
    public var resources: HostResourcesSnapshot?
    /// Client receipt time (ms): comparing the host's clock with this one would be meaningless.
    public var receivedAt: Int?
    public var weight: Double

    public init(environmentId: EnvironmentId, resources: HostResourcesSnapshot?, receivedAt: Int? = nil, weight: Double) {
      self.environmentId = environmentId
      self.resources = resources
      self.receivedAt = receivedAt
      self.weight = weight
    }
  }

  /// The machine with the best weighted share of free CPU and memory, or nil when none qualifies. Callers pass only
  /// connected machines that host the project and the selected provider. `now` is in milliseconds.
  public static func choose(_ candidates: [Candidate], now: Int) -> EnvironmentId? {
    var selected: EnvironmentId?
    var best = 0.0
    for candidate in candidates {
      guard let resources = candidate.resources, candidate.weight.isFinite, candidate.weight > 0 else { continue }
      let sampledAt = candidate.receivedAt ?? resources.sampledAt
      guard now - sampledAt <= 15_000, sampledAt <= now + 5_000, let cpu = resources.cpuUtilization, cpu < 0.95,
        resources.totalMemoryBytes > 0, resources.cpuCount > 0
      else { continue }
      let memoryAvailable = Double(resources.availableMemoryBytes) / Double(resources.totalMemoryBytes)
      if memoryAvailable <= 0.05 { continue }
      let score = candidate.weight * Double(resources.cpuCount) * (1 - cpu) * memoryAvailable
      if score > best {
        selected = candidate.environmentId
        best = score
      }
    }
    return selected
  }

  public enum Preference: Int, CaseIterable, Identifiable, Sendable {
    case prefer = 100, normal = 50, lessOften = 25, manualOnly = 0

    public var id: Int { rawValue }
    public var label: String {
      switch self {
      case .prefer: "Prefer"
      case .normal: "Normal"
      case .lessOften: "Less often"
      case .manualOnly: "Manual only"
      }
    }

    /// Snaps a saved weight (older builds stored a slider value) onto the four preferences.
    public init(weight: Int?) {
      guard let weight, weight != 50 else { self = .normal; return }
      self = weight == 0 ? .manualOnly : weight < 50 ? .lessOften : .prefer
    }
  }

  /// The machines not at Normal, so a folded section still says what is set; nil when all are at the default.
  public static func summary(_ labels: [(id: String, label: String)], weights: [String: Int]) -> String? {
    let parts = labels.compactMap { entry -> String? in
      let preference = Preference(weight: weights[entry.id])
      return preference == .normal ? nil : "\(entry.label) \(preference.label.lowercased())"
    }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
  }
}
