import Foundation
import Testing
@testable import T3Contracts

enum Fixtures {
  static let root: URL = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
  static func data(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
  static func json(_ path: String) throws -> Any { try JSONCheck.parse(try data(path)) }
}

@Suite struct RecordedFixtureTests {
  @Test func everyRecordedFixtureDecodesAndRoundTrips() {
    let result = FixtureTree(root: Fixtures.root).verifyAll()
    for failure in result.failures.prefix(20) { Issue.record("\(failure)") }
    // shell + descriptor + session + 5+ threads + config/settings + stream chunks
    #expect(result.decoded >= 30, "only \(result.decoded) values decoded")
  }

  @Test func threadFixturesAreDiverse() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: Fixtures.root.appendingPathComponent("threads").path)
      .filter { $0.hasSuffix(".json") }
    #expect(names.count >= 5)
    var activityKinds = Set<String>()
    var hasCheckpoints = false
    for name in names {
      let snapshot = try JSONDecoder().decode(V1.OrchestrationThreadDetailSnapshot.self, from: Fixtures.data("threads/\(name)"))
      activityKinds.formUnion(snapshot.thread.activities.map { "\($0.kind)" })
      hasCheckpoints = hasCheckpoints || !snapshot.thread.checkpoints.isEmpty
    }
    #expect(activityKinds.count >= 5, "tool/task activities should be represented: \(activityKinds)")
    #expect(hasCheckpoints)
  }

  @Test func shellSnapshotExposesProjectsAndThreads() throws {
    let shell = try JSONDecoder().decode(V1.OrchestrationShellSnapshot.self, from: Fixtures.data("shell.json"))
    #expect(!shell.projects.isEmpty)
    #expect(!shell.threads.isEmpty)
    #expect(shell.threads.allSatisfy { thread in shell.projects.contains { $0.id == thread.projectId } })
  }

  @Test func serverConfigAndSettingsDecode() throws {
    let exits = try Fixtures.json("rpc/server.getConfig.json") as? [[String: Any]]
    let value = ((exits?.first?["exit"]) as? [String: Any])?["value"]
    let config = try JSONDecoder().decode(ServerConfig.self, from: JSONCheck.data(try #require(value)))
    #expect(!config.providers.isEmpty)
    #expect(!config.keybindings.isEmpty)
  }
}

@Suite struct ForwardCompatibilityTests {
  @Test func unknownUnionVariantSurvivesRoundTrip() throws {
    let raw = #"{"type":"thread.from-the-future","sequence":7,"payload":{"nested":[1,2.5,"x",null,true]}}"#
    // Commands are a tagged union on `type`; an unknown tag must not fail decoding.
    let value = try JSONDecoder().decode(V1.ClientOrchestrationCommand.self, from: Data(raw.utf8))
    guard case .unknown(let json) = value else { Issue.record("expected .unknown, got \(value)"); return }
    #expect(json["type"]?.stringValue == "thread.from-the-future")
    let again = try JSONEncoder().encode(value)
    #expect(JSONCheck.diff(try JSONCheck.parse(Data(raw.utf8)), try JSONCheck.parse(again)).isEmpty)
  }

  @Test func unknownLiteralKeepsItsStringAndEncodesBack() throws {
    let value = try JSONDecoder().decode(RuntimeMode.self, from: Data(#""warp-speed""#.utf8))
    #expect(value == .unknown("warp-speed"))
    #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == #""warp-speed""#)
    #expect(try JSONDecoder().decode(RuntimeMode.self, from: Data(#""full-access""#.utf8)) == .fullAccess)
  }

  @Test func forwardCompatibleArraySkipsUndecodableElements() throws {
    var config = try #require(((try Fixtures.json("rpc/server.getConfig.json") as? [[String: Any]])?.first?["exit"] as? [String: Any])?["value"] as? [String: Any])
    let valid = try #require((config["keybindings"] as? [Any])?.first)
    config["keybindings"] = [valid, 12345, ["command": ["not", "a", "command"]], valid]
    let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONCheck.data(config))
    #expect(decoded.keybindings.count == 2)
  }

  @Test func unknownFailureTagIsPreservedAndKnownTagDecodes() throws {
    let spec = V1.Rpc.orchestrationSubscribeShell
    let known = try Self.failure(of: spec, #"{"_tag":"OrchestrationGetSnapshotError","message":"boom"}"#)
    guard case .orchestrationGetSnapshotError(let error) = known else { Issue.record("wrong case \(known)"); return }
    #expect(error.message == "boom")

    let raw = #"{"_tag":"BrandNewError","code":42}"#
    let unknown = try Self.failure(of: spec, raw)
    guard case .unknown(let json) = unknown else { Issue.record("wrong case \(unknown)"); return }
    #expect(json["code"] == .int(42))
    let asError: any Error = unknown // the generated union is usable as a Swift Error
    #expect(asError is V1.OrchestrationGetArchivedShellSnapshotFailure)
  }

  private static func failure<P, S, F: Decodable>(of spec: RpcSpec<P, S, F>, _ json: String) throws -> F {
    try JSONDecoder().decode(F.self, from: Data(json.utf8))
  }
}

@Suite struct WireSemanticsTests {
  @Test func brandedIdsAreDistinctPlainStrings() throws {
    let thread: ThreadId = "t-1"
    let project: ProjectId = "t-1"
    #expect(String(decoding: try JSONEncoder().encode(thread), as: UTF8.self) == #""t-1""#)
    #expect(try JSONDecoder().decode(ProjectId.self, from: Data(#""p""#.utf8)) == project.with("p"))
    #expect(thread.rawValue == project.rawValue)
    // Different types: `thread == project` does not compile; hashing in one set is per type.
    #expect(Set([thread, thread]).count == 1)
  }

  @Test func isoDateTimeKeepsTheExactString() throws {
    for raw in ["2026-01-02T03:04:05.678Z", "2026-01-02T03:04:05Z", "2026-01-02T03:04:05.678901Z"] {
      let value = try JSONDecoder().decode(IsoDateTime.self, from: Data("\"\(raw)\"".utf8))
      #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == "\"\(raw)\"")
    }
    let parsed = try #require(IsoDateTime("2026-01-02T03:04:05.500Z").date)
    #expect(parsed.timeIntervalSince1970 == 1_767_323_045.5)
    #expect(IsoDateTime("not a date").date == nil)
  }

  @Test func integersAndFractionsStayDistinct() throws {
    let raw = #"{"id":"w","kind":"weekly","label":"l","usedPercent":42,"windowDurationMins":300}"#
    let window = try JSONDecoder().decode(ServerConfigProvidersItemUsageLimitsWindowsItem.self, from: Data(raw.utf8))
    #expect(window.usedPercent == 42.0) // Schema.Number: Double
    #expect(window.windowDurationMins == 300) // Schema.Int: Int
    let text = String(decoding: try JSONEncoder().encode(window), as: UTF8.self)
    #expect(text.contains(#""windowDurationMins":300"#))
    #expect(!text.contains("300.0"))
  }

  @Test func recursiveSchemaDecodes() throws {
    let raw = #"{"type":"and","left":{"type":"not","node":{"type":"identifier","name":"a"}},"right":{"type":"identifier","name":"b"}}"#
    let node = try JSONDecoder().decode(KeybindingWhenNode.self, from: Data(raw.utf8))
    guard case .and(let and) = node, case .not(let not) = and.left, case .identifier(let id) = not.node else {
      Issue.record("unexpected shape \(node)")
      return
    }
    #expect(id.name == "a")
    #expect(JSONCheck.diff(try JSONCheck.parse(Data(raw.utf8)), try JSONCheck.parse(try JSONEncoder().encode(node))).isEmpty)
  }

  @Test func triStateKeysDistinguishAbsentNullAndValue() throws {
    func encode(_ command: V1.ClientOrchestrationCommand) throws -> [String: Any] {
      try #require(try JSONCheck.parse(try JSONEncoder().encode(command)) as? [String: Any])
    }
    let absent = try encode(.threadMetaUpdate(.init(commandId: "c", threadId: "t")))
    #expect(absent["branch"] == nil)
    let null = try encode(.threadMetaUpdate(.init(commandId: "c", threadId: "t", branch: .some(nil))))
    #expect(null["branch"] is NSNull)
    let value = try encode(.threadMetaUpdate(.init(commandId: "c", threadId: "t", branch: .some("main"))))
    #expect(value["branch"] as? String == "main")
    let back = try JSONDecoder().decode(V1.ClientOrchestrationCommand.self, from: JSONSerialization.data(withJSONObject: null))
    guard case .threadMetaUpdate(let update) = back else { Issue.record("wrong case"); return }
    #expect(update.branch == .some(nil))
  }

  @Test func missingKeyUsesSchemaDefault() throws {
    // `interactionMode` has a decoding default of "default" on thread.create.
    let raw = #"{"type":"thread.create","commandId":"c","threadId":"t","projectId":"p","title":"x","modelSelection":{"instanceId":"codex","model":"m"},"runtimeMode":"full-access","createdAt":"2026-01-01T00:00:00.000Z"}"#
    guard case .threadCreate(let create) = try JSONDecoder().decode(V1.ClientOrchestrationCommand.self, from: Data(raw.utf8)) else {
      Issue.record("wrong case")
      return
    }
    #expect(create.interactionMode == .default)
  }

  @Test func rpcSpecsUseTheLiteralWireTags() {
    #expect(Rpc.subscribeServerConfig.tag == "subscribeServerConfig")
    #expect(Rpc.subscribeServerConfig.isStream)
    #expect(Rpc.serverGetConfig.tag == "server.getConfig")
    #expect(!Rpc.serverGetConfig.isStream)
    #expect(V1.Rpc.orchestrationSubscribeShell.tag == "orchestration.subscribeShell")
    #expect(V1.Rpc.orchestrationSubscribeShell.isStream)
    #expect(Rpc.allTags.count == 185 && V1.Rpc.allTags.count == 8)
    #expect(Set(Rpc.allTags).count == 185)
  }

  @Test func httpSpecsCarryMethodPathAndStatuses() {
    #expect(Http.authToken.method == "POST")
    #expect(Http.authToken.path == "/oauth/token")
    #expect(Http.authToken.bodyContentType == "application/x-www-form-urlencoded")
    #expect(Http.authToken.errorStatuses["EnvironmentAuthInvalidError"] == 401)
    #expect(V1.Http.orchestrationThreadSnapshot.path == "/api/orchestration/threads/:threadId")
  }
}

private extension ProjectId {
  func with(_ raw: String) -> ProjectId { ProjectId(rawValue: raw) }
}
