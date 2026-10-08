import Foundation
import Testing
@testable import T3Contracts

/// Oracle tests: Effect's own codec encoded these (see scripts/encode-reference.ts).
@Suite struct ReferenceTests {
  private struct Sample: Decodable {
    let type: String
    let mode: String
    let idx: Int
    let input: JSONValue
    let canonical: JSONValue
    /// False when Effect's codec rewrites the input (legacy/normalising shapes): only the canonical form is replayed.
    let exact: Bool
  }

  @Test func everySampleRoundTripsLikeEffect() throws {
    let samples = try JSONDecoder().decode([Sample].self, from: Fixtures.data("reference/samples.json"))
    #expect(samples.count > 1000)
    var failures: [String] = []
    var covered = Set<String>()
    var exactCount = samples.count
    for s in samples {
      guard let check = referenceCases[s.type] else {
        failures.append("\(s.type): no generated case")
        continue
      }
      covered.insert(s.type)
      do {
        let canonical = try JSONEncoder().encode(s.canonical)
        // Effect's own output must survive Swift unchanged; the raw input too unless Effect normalises it.
        var diffs = try check(canonical, canonical)
        if s.exact { diffs += try check(JSONEncoder().encode(s.input), canonical) }
        else { exactCount -= 1 }
        if !diffs.isEmpty { failures.append("\(s.type) [\(s.mode)#\(s.idx)]: \(diffs.joined(separator: "; "))") }
      } catch {
        failures.append("\(s.type) [\(s.mode)#\(s.idx)]: decode failed: \(error)")
      }
    }
    for f in failures.prefix(25) { Issue.record("\(f)") }
    #expect(failures.isEmpty, "\(failures.count) of \(samples.count) samples differ over \(covered.count) types")
    #expect(covered.contains("OrchestrationEvent") && covered.contains("ClientOrchestrationCommand"))
    #expect(exactCount > samples.count * 9 / 10, "too many samples are normalised by Effect: \(samples.count - exactCount)")
  }

  private struct Command: Decodable {
    let name: String
    let canonical: JSONValue
  }

  /// The same commands built from typed Swift values must encode exactly as Effect encodes them.
  @Test func constructedCommandsEncodeLikeEffect() throws {
    let at = IsoDateTime("2026-01-01T00:00:00.000Z")
    let typed: [String: ClientOrchestrationCommand] = [
      "projectCreate": .projectCreate(.init(
        commandId: "cmd-1", projectId: "proj-1", title: "Project", workspaceRoot: "/tmp/project",
        createWorkspaceRootIfMissing: true,
        defaultModelSelection: .some(ModelSelection(instanceId: "codex", model: "gpt-5", options: [.init(id: "effort", value: .string("high"))])),
        createdAt: at)),
      "projectMetaUpdateClearsModel": .projectMetaUpdate(.init(
        commandId: "cmd-2", projectId: "proj-1", title: "Renamed", defaultModelSelection: .some(nil), faviconPath: .some(nil))),
      "threadCreate": .threadCreate(.init(
        commandId: "cmd-3", threadId: "thread-1", projectId: "proj-1", title: "Thread",
        modelSelection: ModelSelection(instanceId: "claudeAgent", model: "opus"), runtimeMode: .approvalRequired, createdAt: at)),
      "threadTurnStart": .threadTurnStart(.init(
        commandId: "cmd-4", threadId: "thread-1",
        message: .init(messageId: "msg-1", text: "Hello", attachments: [
          .option1(.init(name: "a.png", mimeType: "image/png", sizeBytes: 3, dataUrl: "data:image/png;base64,AAAA")),
        ]),
        runtimeMode: .fullAccess, interactionMode: .plan, createdAt: at)),
      "threadMetaUpdateTriState": .threadMetaUpdate(.init(
        commandId: "cmd-5", threadId: "thread-1", title: "New title", branch: .some(nil), worktreePath: .some("/tmp/wt"))),
      "threadApprovalRespond": .threadApprovalRespond(.init(
        commandId: "cmd-6", threadId: "thread-1", requestId: "req-1", decision: .acceptForSession, createdAt: at)),
      "threadSnooze": .threadSnooze(.init(commandId: "cmd-7", threadId: "thread-1", snoozedUntil: at)),
    ]
    let reference = try JSONDecoder().decode([Command].self, from: Fixtures.data("reference/commands.json"))
    #expect(Set(reference.map(\.name)) == Set(typed.keys))
    for item in reference {
      let command = try #require(typed[item.name])
      let encoded = try JSONEncoder().encode(command)
      let diffs = JSONCheck.diff(try JSONCheck.parse(JSONEncoder().encode(item.canonical)), try JSONCheck.parse(encoded))
      #expect(diffs.isEmpty, "\(item.name): \(diffs.joined(separator: "; "))")
    }
  }
}
