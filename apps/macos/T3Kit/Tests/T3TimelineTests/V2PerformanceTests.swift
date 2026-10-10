import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

/// A 300-turn protocol-2 thread (about 4500 items) built from the oracle's tool-heavy scenario. Debug
/// builds are far slower than release, so the limit only guards against accidental quadratic behavior.
@Suite struct V2PerformanceTests {
  static func largeProjection(turns: Int) throws -> OrchestrationV2ThreadProjection {
    let scenario = try V2OracleTests.load("scenarios", "syn-settled-turn")
    var wire = try #require(scenario["projection"] as? [String: Any])
    let runs = try #require(wire["runs"] as? [[String: Any]])
    let attempts = try #require(wire["attempts"] as? [[String: Any]])
    let nodes = try #require(wire["nodes"] as? [[String: Any]])
    let items = try #require(wire["turnItems"] as? [[String: Any]])
    var allRuns: [[String: Any]] = [], allAttempts: [[String: Any]] = [], allNodes: [[String: Any]] = [], allItems: [[String: Any]] = []
    func suffixed(_ value: Any, _ suffix: String) -> Any {
      // Rewrites every id-like string field that names one of this copy's entities.
      if let object = value as? [String: Any] { return object.mapValues { suffixed($0, suffix) } }
      if let array = value as? [Any] { return array.map { suffixed($0, suffix) } }
      if let text = value as? String, text.hasPrefix("run-") || text.hasPrefix("node-") || text.hasPrefix("attempt-") || text.hasPrefix("item-") || text.hasPrefix("message-") {
        return text + suffix
      }
      return value
    }
    for turn in 0..<turns {
      let suffix = "-\(turn)"
      allRuns += runs.map { suffixed($0, suffix) as! [String: Any] }
      allAttempts += attempts.map { suffixed($0, suffix) as! [String: Any] }
      allNodes += nodes.map { suffixed($0, suffix) as! [String: Any] }
      allItems += items.map { suffixed($0, suffix) as! [String: Any] }
    }
    wire["runs"] = allRuns
    wire["attempts"] = allAttempts
    wire["nodes"] = allNodes
    wire["turnItems"] = allItems
    wire["messages"] = []
    wire["checkpoints"] = []
    wire["checkpointScopes"] = []
    wire["visibleTurnItems"] = allItems.enumerated().map { index, item in
      ["position": index, "visibility": "local", "sourceThreadId": "thread-syn", "sourceItemId": item["id"] as Any, "item": item]
    }
    return try decode(OrchestrationV2ThreadProjection.self, wire)
  }

  @Test func derivesA300TurnThreadWithoutBlowingUp() throws {
    let projection = try Self.largeProjection(turns: 300)
    let clock = ContinuousClock()
    var timeline: ThreadTimelineV2?
    let elapsed = clock.measure { timeline = deriveThreadTimeline(projection: projection) }
    #expect(timeline?.rows.isEmpty == false)
    print("T3Timeline: derived \(projection.visibleTurnItems.count) V2 items into \(timeline?.rows.count ?? 0) rows in \(elapsed)")
    #expect(elapsed < .seconds(5))
  }
}
