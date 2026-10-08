import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Differential tests: the Swift reducers must reach exactly the state the TypeScript reducers reach
/// on the same recorded or synthetic stream (see apps/macos/scripts/runtime-oracle).
@Suite struct ReducerOracleTests {
  static let rawEnabled = Oracle.rawDirectory != nil

  // MARK: Shell

  func runShell(_ directory: URL, _ name: String) throws -> Int {
    let scenario = try Oracle.load(directory, "scenarios", name)
    let expected = try Oracle.load(directory, "expected", name)
    var state = try decode(OrchestrationShellSnapshot.self, try #require(scenario["snapshot"]))
    let items = try #require(scenario["items"] as? [Any]).map { try decode(OrchestrationShellStreamItem.self, $0) }
    let perStep = expected["perStep"] as? Bool ?? false
    let steps = try #require(expected["steps"] as? [Any])
    #expect(steps.count == items.count, "\(name): step count")
    for (index, item) in items.enumerated() {
      if case .snapshot(let s) = item { state = s.snapshot } else if case .synchronized = item {} else { state = ShellReducer.apply(state, item) }
      let actual: Any = perStep
        ? try toAny(state)
        : ["sequence": state.snapshotSequence, "projects": state.projects.count, "threads": state.threads.count]
      let diff = jsonDiff(steps[index], actual, path: "\(name).steps[\(index)]")
      #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
      if !diff.isEmpty { break }
    }
    let diff = jsonDiff(try #require(expected["final"]), try toAny(state), path: "\(name).final")
    #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
    return items.count
  }

  @Test(arguments: Oracle.names(in: Oracle.directory(raw: false), prefix: "shell-"))
  func shellFixtures(_ name: String) throws { _ = try runShell(Oracle.directory(raw: false), name) }

  @Test(.enabled(if: rawEnabled), arguments: Oracle.names(in: Oracle.directory(raw: true), prefix: "shell-"))
  func shellRawCorpus(_ name: String) throws { _ = try runShell(Oracle.directory(raw: true), name) }

  // MARK: Thread

  func runThread(_ directory: URL, _ name: String) throws -> Int {
    let scenario = try Oracle.load(directory, "scenarios", name)
    let expected = try Oracle.load(directory, "expected", name)
    let snapshot = try decode(OrchestrationThreadDetailSnapshot.self, try #require(scenario["snapshot"]))
    let events = try #require(scenario["events"] as? [Any]).map { try decode(OrchestrationEvent.self, $0) }
    let perStep = expected["perStep"] as? Bool ?? false
    let steps = try #require(expected["steps"] as? [[String: Any]])
    #expect(steps.count == events.count, "\(name): step count")
    var thread: OrchestrationThread? = snapshot.thread
    for (index, event) in events.enumerated() {
      guard let current = thread else { break }
      var kind = "unchanged"
      var shown: Any = NSNull()
      switch ThreadReducer.apply(current, event) {
      case .updated(let next): thread = next; kind = "updated"; shown = perStep ? try toAny(next) : NSNull()
      case .deleted: thread = nil; kind = "deleted"
      case .unchanged: break
      }
      let step = steps[index]
      #expect(step["kind"] as? String == kind, "\(name)[\(index)] \(String(describing: event.sequence)): kind")
      if perStep, kind == "updated" {
        let diff = jsonDiff(try #require(step["thread"]), shown, path: "\(name).steps[\(index)].\(eventType(events[index]))")
        #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
        if !diff.isEmpty { break }
      }
    }
    if let thread {
      let diff = jsonDiff(try #require(expected["final"]), try toAny(thread), path: "\(name).final")
      #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
      let pendingDiff = jsonDiff(try #require(expected["pending"]), try toAny(PendingRequestDeriver.derive(thread.activities)), path: "\(name).pending")
      #expect(pendingDiff.isEmpty, "\(pendingDiff.joined(separator: "\n"))")
    } else {
      #expect(expected["final"] is NSNull, "\(name): thread deleted in Swift only")
    }
    return events.count
  }

  func eventType(_ event: OrchestrationEvent) -> String {
    ((try? toAny(event)) as? [String: Any])?["type"] as? String ?? "?"
  }

  @Test(arguments: Oracle.names(in: Oracle.directory(raw: false), prefix: "thread-"))
  func threadFixtures(_ name: String) throws { _ = try runThread(Oracle.directory(raw: false), name) }

  @Test(.enabled(if: rawEnabled), arguments: Oracle.names(in: Oracle.directory(raw: true), prefix: "thread-"))
  func threadRawCorpus(_ name: String) throws { _ = try runThread(Oracle.directory(raw: true), name) }
}
