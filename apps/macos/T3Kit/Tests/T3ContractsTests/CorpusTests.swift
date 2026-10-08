import Foundation
import Testing
@testable import T3Contracts

/// Opt-in: decodes and round-trips a full raw recording.
/// `T3_CONTRACTS_CORPUS=<dir> swift test --filter CorpusTests` (dir layout: see `FixtureTree`).
@Suite struct CorpusTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["T3_CONTRACTS_CORPUS"] != nil))
  func fullCorpusDecodesAndRoundTrips() {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["T3_CONTRACTS_CORPUS"] ?? "")
    let result = FixtureTree(root: root).verifyAll()
    for failure in result.failures.prefix(40) { Issue.record("\(failure)") }
    #expect(result.decoded > 0, "corpus contained nothing to decode")
    print("corpus: decoded \(result.decoded) values, \(result.failures.count) failures")
  }
}
