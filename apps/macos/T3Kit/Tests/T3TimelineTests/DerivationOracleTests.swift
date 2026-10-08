import Foundation
import T3Contracts
import Testing

@testable import T3Timeline

/// Differential tests: the Swift derivation must project exactly what the TypeScript
/// derivations of the web chat view produce for the same thread (see scripts/timeline-oracle).
@Suite struct DerivationOracleTests {
  static let fixtureNames = Oracle.names(in: Oracle.directory(raw: false))

  /// Returns the differences for one scenario file, across all of its context variants.
  static func differences(directory: URL, name: String) throws -> [String] {
    let scenario = try Oracle.load(directory, "scenarios", name)
    let expected = try Oracle.load(directory, "expected", name)
    let thread = try decode(OrchestrationThread.self, try #require(scenario["thread"]))
    let variants = try #require(scenario["variants"] as? [[String: Any]])
    let expectedVariants = try #require(expected["variants"] as? [String: Any])
    var out: [String] = []
    for variant in variants {
      let variantName = try #require(variant["name"] as? String)
      let context = try decode(ScenarioContext.self, try #require(variant["context"]))
      let timeline = deriveThreadTimeline(thread, context: context.timelineContext)
      let actual = try toAny(timeline.projection)
      for line in jsonDiff(try #require(expectedVariants[variantName]), actual, path: "\(name)/\(variantName)") { out.append(line) }
    }
    let pending = try toAny(derivePendingPrompts(thread.activities).projection)
    out += jsonDiff(try #require(expected["pending"]), pending, path: "\(name)/pending")
    let diffs: [JSONValue] = thread.checkpoints.map { summary in
      .object([
        "turnId": .string(summary.turnId.rawValue),
        "stats": summarizeTurnDiffStats(summary.files).projection,
        "tree": .array(buildTurnDiffTree(summary.files).map(\.projection)),
      ])
    }
    out += jsonDiff(try #require(expected["turnDiffs"]), try toAny(diffs), path: "\(name)/turnDiffs")
    // The roots are the oracle's: a few synthetic ones plus the thread's own worktree.
    let expectedLabels = try #require(expected["labels"] as? [[String: Any]])
    let roots = (expectedLabels.first?["labels"] as? [[String: Any]])?.map { $0["root"] as? String } ?? []
    let labels: [JSONValue] = deriveWorkLogEntries(thread.activities).map { entry in
      .object([
        "id": .string(entry.id),
        "labels": .array(
          roots.map { workspace in
            .object([
              "root": workspace.map { .string($0) } ?? .null,
              "display": .string(workEntryDisplayLabel(entry, workspaceRoot: workspace)),
              "live": .string(liveWorkEntryLabel(entry, workspaceRoot: workspace, active: true)),
              "settled": .string(liveWorkEntryLabel(entry, workspaceRoot: workspace, active: false)),
            ])
          }),
      ])
    }
    out += jsonDiff(try #require(expected["labels"]), try toAny(labels), path: "\(name)/labels")
    out += try Self.answerDifferences(name: name, expected: expected, prompts: derivePendingPrompts(thread.activities).userInputs)
    let sessionLive = derivePhase(thread.session) != .disconnected
    let live = deriveLiveAgentTaskIds(activities: thread.activities, sessionLive: sessionLive).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    out += jsonDiff(try #require(expected["liveAgentTaskIds"]), live, path: "\(name)/liveAgentTaskIds")
    return out
  }

  @Test("sanitized fixtures and synthetic threads match the TypeScript oracle", arguments: fixtureNames)
  func scenarioMatchesOracle(name: String) throws {
    let differences = try Self.differences(directory: Oracle.directory(raw: false), name: name)
    #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
  }

  /// Opt-in: `T3_TIMELINE_RAW_ORACLE_DIR=<dir written by oracle.ts --raw>`. Private recordings
  /// never enter the repository; the directory lives under /private/tmp.
  @Test(.enabled(if: Oracle.rawDirectory != nil))
  func rawCorpusMatchesOracle() throws {
    let directory = Oracle.directory(raw: true)
    var failures: [String] = []
    let names = Oracle.names(in: directory)
    for name in names { failures += try Self.differences(directory: directory, name: name).prefix(6) }
    #expect(failures.isEmpty, "\(failures.count) differences over \(names.count) raw threads:\n\(failures.prefix(40).joined(separator: "\n"))")
  }
}

extension DerivationOracleTests {
  static func commandLabelDifferences(directory: URL) throws -> (count: Int, differences: [String]) {
    let expected = try Oracle.load(directory, "expected", "_commandLabels")
    let cases = try #require(expected["cases"] as? [[String: Any]])
    var out: [String] = []
    for item in cases {
      let command = try #require(item["command"] as? String)
      let actual = commandProgramName(command)
      let want = item["program"] as? String
      if actual != want { out.append("\(command.prefix(80).debugDescription): TS \(want ?? "nil") != Swift \(actual ?? "nil")") }
    }
    return (cases.count, out)
  }

  @Test func commandProgramNamesMatchOracle() throws {
    let result = try Self.commandLabelDifferences(directory: Oracle.directory(raw: false))
    #expect(result.count > 50)
    #expect(result.differences.isEmpty, "\(result.differences.prefix(20).joined(separator: "\n"))")
  }

  @Test(.enabled(if: Oracle.rawDirectory != nil))
  func rawCommandProgramNamesMatchOracle() throws {
    let result = try Self.commandLabelDifferences(directory: Oracle.directory(raw: true))
    #expect(result.differences.isEmpty, "\(result.differences.count) of \(result.count): \(result.differences.prefix(20).joined(separator: "\n"))")
  }
}

extension DerivationOracleTests {
  /// Replays the oracle's draft answers against the Swift answer builders.
  static func answerDifferences(name: String, expected: [String: Any], prompts: [UserInputPrompt]) throws -> [String] {
    let cases = try #require(expected["answerCases"] as? [[String: Any]])
    var out: [String] = []
    for (index, item) in cases.enumerated() {
      let requestId = try #require(item["requestId"] as? String)
      let prompt = try #require(prompts.first { $0.requestId.rawValue == requestId })
      let rawDrafts = try #require(item["drafts"] as? [String: [String: Any]])
      let drafts = rawDrafts.mapValues { raw in
        PendingUserInputDraftAnswer(
          selectedOptionValues: raw["selectedOptionValues"] as? [String],
          customAnswer: raw["customAnswer"] as? String,
          attachmentCount: raw["attachmentCount"] as? Int,
          attachmentsBlocked: raw["attachmentsBlocked"] as? Bool
        )
      }
      let progress = derivePendingUserInputProgress(prompt.questions, drafts, questionIndex: try #require(item["questionIndex"] as? Int))
      func answerJSON(_ answer: PendingUserInputAnswer?) -> JSONValue {
        switch answer {
        case nil: .null
        case .text(let text)?: .string(text)
        case .values(let values)?: .array(values.map { .string($0) })
        }
      }
      func draftJSON(_ draft: PendingUserInputDraftAnswer) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let values = draft.selectedOptionValues { object["selectedOptionValues"] = .array(values.map { .string($0) }) }
        if let custom = draft.customAnswer { object["customAnswer"] = .string(custom) }
        return .object(object)
      }
      let first = prompt.questions[0]
      let firstValue = first.options.first.map { first.answerValue(of: $0) } ?? "none"
      let actual: JSONValue = .object([
        "progress": .object([
          "questionIndex": .int(progress.questionIndex),
          "activeQuestionId": progress.activeQuestion.map { .string($0.id) } ?? .null,
          "selectedOptionValues": .array(progress.selectedOptionValues.map { .string($0) }),
          "customAnswer": .string(progress.customAnswer),
          "resolvedAnswer": answerJSON(progress.resolvedAnswer),
          "usingCustomAnswer": .bool(progress.usingCustomAnswer),
          "answeredQuestionCount": .int(progress.answeredQuestionCount),
          "isLastQuestion": .bool(progress.isLastQuestion),
          "isComplete": .bool(progress.isComplete),
          "canAdvance": .bool(progress.canAdvance),
        ]),
        "answers": buildPendingUserInputAnswers(prompt.questions, drafts).map { .object($0.mapValues { answerJSON($0) }) } ?? .null,
        "toggled": draftJSON(togglePendingUserInputOptionSelection(first, drafts[first.id], optionValue: firstValue)),
        "customSet": draftJSON(setPendingUserInputCustomAnswer(drafts[first.id], (item["questionIndex"] as? Int ?? 0) < 0 ? "" : " custom ")),
        "carried": .string(carryDisplacedCustomAnswerIntoPrompt((item["questionIndex"] as? Int) == 0 ? "" : "draft  ", customAnswer: drafts[first.id]?.customAnswer)),
      ])
      var wanted = item
      for key in ["requestId", "shapeIndex", "questionIndex", "drafts"] { wanted[key] = nil }
      out += jsonDiff(wanted, try toAny(actual), path: "\(name)/answerCases[\(index)]")
    }
    return out
  }
}
