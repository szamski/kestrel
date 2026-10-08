import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

/// Locates and compares oracle files written by apps/macos/scripts/timeline-oracle/oracle.ts.
enum Oracle {
  /// `T3_TIMELINE_RAW_ORACLE_DIR` points at a private corpus produced by `oracle.ts --raw`.
  static var rawDirectory: URL? {
    ProcessInfo.processInfo.environment["T3_TIMELINE_RAW_ORACLE_DIR"].map { URL(fileURLWithPath: $0) }
  }

  static func directory(raw: Bool) -> URL {
    if raw, let rawDirectory { return rawDirectory }
    return Bundle.module.resourceURL!.appendingPathComponent("Fixtures/oracle")
  }

  /// Scenario base names (`_`-prefixed files are auxiliary corpora).
  static func names(in directory: URL, prefix: String = "") -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("scenarios").path)) ?? []
    return files.filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") && $0.hasPrefix(prefix) }.map { String($0.dropLast(5)) }.sorted()
  }

  static func load(_ directory: URL, _ kind: String, _ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: directory.appendingPathComponent("\(kind)/\(name).json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

func decode<T: Decodable>(_ type: T.Type, _ any: Any) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed]))
}

func toAny<T: Encodable>(_ value: T) throws -> Any {
  try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}

/// Structural differences between two JSON documents (at most `limit`). `null` and a missing key
/// are different on purpose: the projection preserves the distinction.
func jsonDiff(_ expected: Any, _ actual: Any, path: String = "$", limit: Int = 8) -> [String] {
  var out: [String] = []
  func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
  func walk(_ a: Any, _ b: Any, _ path: String) {
    if out.count >= limit { return }
    switch (a, b) {
    case (let a as [String: Any], let b as [String: Any]):
      for key in Set(a.keys).union(b.keys).sorted() {
        switch (a[key], b[key]) {
        case (let x?, let y?): walk(x, y, "\(path).\(key)")
        case (let x?, nil): out.append("\(path).\(key): missing in Swift (TS has \(String(describing: x).prefix(80)))")
        case (nil, let y?): out.append("\(path).\(key): extra in Swift (\(String(describing: y).prefix(80)))")
        default: break
        }
      }
    case (let a as [Any], let b as [Any]):
      if a.count != b.count {
        out.append("\(path): array length TS \(a.count) != Swift \(b.count)")
        // Show the first element that differs to make length mismatches actionable.
        for (i, pair) in zip(a, b).enumerated() where !jsonDiff(pair.0, pair.1, limit: 1).isEmpty {
          walk(pair.0, pair.1, "\(path)[\(i)]")
          return
        }
        return
      }
      for (i, pair) in zip(a, b).enumerated() { walk(pair.0, pair.1, "\(path)[\(i)]") }
    case (is NSNull, is NSNull): break
    default:
      if isBool(a) != isBool(b) || !(a as AnyObject).isEqual(b as AnyObject) {
        out.append("\(path): TS \(String(describing: a).prefix(100)) != Swift \(String(describing: b).prefix(100))")
      }
    }
  }
  walk(expected, actual, path)
  return out
}

/// Wire form of the client-side context a scenario was derived with.
struct ScenarioContext: Decodable {
  struct Queued: Decodable {
    var id: String
    var createdAt: String
    var text: String
  }
  var isWorking: Bool?
  var sendStartedAt: String?
  var expandedTurnIds: [String]
  var expandedWorkGroupIds: [String]
  var supportsConversationRollback: Bool
  var liveAgentTaskIds: [String]?
  var worktreeSetup: WorktreeSetupSnapshot?
  var queuedMessages: [Queued]

  var timelineContext: TimelineContext {
    TimelineContext(
      isWorking: isWorking,
      sendStartedAt: sendStartedAt,
      expandedTurnIds: Set(expandedTurnIds.map { TurnId($0) }),
      expandedWorkGroupIds: Set(expandedWorkGroupIds),
      supportsConversationRollback: supportsConversationRollback,
      liveAgentTaskIds: liveAgentTaskIds.map(Set.init),
      worktreeSetup: worktreeSetup,
      queuedMessages: queuedMessages.map { QueuedMessagePlaceholder(id: $0.id, createdAt: $0.createdAt, text: $0.text) }
    )
  }
}
