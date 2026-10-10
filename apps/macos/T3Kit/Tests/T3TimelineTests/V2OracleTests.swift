import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

/// Differential tests for protocol 2: the Swift derivation must project exactly what the web's
/// TypeScript derivations produce for the same thread projection (scripts/timeline-oracle/v2.ts).
@Suite struct V2OracleTests {
  static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/oracle-v2")
  static let names: [String] = {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("scenarios").path)) ?? []
    return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
  }()

  struct Context: Decodable {
    var isWorking: Bool?
    var sendStartedAt: String?
    var expandedRunIds: [String]
    var expandedAttemptIds: [String]
    var expandedWorkGroupIds: [String]
    var supportsConversationRollback: Bool
    var worktreeSetup: WorktreeSetupSnapshot?

    var timelineContext: TimelineContextV2 {
      TimelineContextV2(
        isWorking: isWorking, sendStartedAt: sendStartedAt, expandedRunIds: Set(expandedRunIds), expandedAttemptIds: Set(expandedAttemptIds),
        expandedWorkGroupIds: Set(expandedWorkGroupIds), supportsConversationRollback: supportsConversationRollback, worktreeSetup: worktreeSetup)
    }
  }

  static func load(_ kind: String, _ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: directory.appendingPathComponent("\(kind)/\(name).json"))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func differences(name: String) throws -> [String] {
    let scenario = try load("scenarios", name)
    let expected = try load("expected", name)
    let projection = try decode(OrchestrationV2ThreadProjection.self, try #require(scenario["projection"]))
    let variants = try #require(scenario["variants"] as? [[String: Any]])
    let expectedVariants = try #require(expected["variants"] as? [String: Any])
    var out: [String] = []
    for variant in variants {
      let variantName = try #require(variant["name"] as? String)
      let context = try decode(Context.self, try #require(variant["context"]))
      let timeline = deriveThreadTimeline(projection: projection, context: context.timelineContext)
      out += jsonDiff(try #require(expectedVariants[variantName]), try toAny(timeline.projection), path: "\(name)/\(variantName)")
    }
    // Display labels of every work entry, for the oracle's workspace roots.
    let expectedLabels = try #require(expected["labels"] as? [[String: Any]])
    let roots = (expectedLabels.first?["labels"] as? [[String: Any]])?.map { $0["root"] as? String } ?? []
    let entries = deriveThreadTimeline(projection: projection).entries.compactMap(\.workEntry)
    let labels: [JSONValue] = entries.map { entry in
      .object([
        "id": .string(entry.id),
        "labels": .array(
          roots.map { root in
            .object([
              "root": root.map { .string($0) } ?? .null,
              "display": .string(workEntryDisplayLabel(entry, workspaceRoot: root)),
              "live": .string(liveWorkEntryLabel(entry, workspaceRoot: root, active: true)),
              "settled": .string(liveWorkEntryLabel(entry, workspaceRoot: root, active: false)),
            ])
          }),
      ])
    }
    out += jsonDiff(try #require(expected["labels"]), try toAny(labels), path: "\(name)/labels")
    return out
  }

  @Test("protocol-2 scenarios match the TypeScript oracle", arguments: names)
  func scenarioMatchesOracle(name: String) throws {
    let differences = try Self.differences(name: name)
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
  }
}
