import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Differential tests for the derived sidebar state: partition, sorts, grouping, lifecycle
/// predicates, order keys and snooze presets, against the TypeScript implementations.
@Suite struct DerivedOracleTests {
  static let rawEnabled = Oracle.rawDirectory != nil

  struct Case { let op: String; let name: String; let input: [String: Any]; let expected: Any }

  static func load(raw: Bool) -> ([Case], [String: Any]) {
    let directory = Oracle.directory(raw: raw)
    let scenario = try! Oracle.load(directory, "scenarios", "derived")
    let expected = try! Oracle.load(directory, "expected", "derived")
    let cases = scenario["cases"] as! [[String: Any]], expectedCases = expected["cases"] as! [[String: Any]]
    let merged = zip(cases, expectedCases).map { c, e in
      Case(op: c["op"] as! String, name: c["name"] as! String, input: c["input"] as! [String: Any], expected: e["expected"]!)
    }
    return (merged, scenario["shared"] as! [String: Any])
  }

  static func caseNames(raw: Bool) -> [String] { load(raw: raw).0.map(\.name) }

  func threads(_ any: Any) throws -> [EnvironmentThreadShell] {
    try (any as! [[String: Any]]).map { row in
      EnvironmentThreadShell(environmentId: EnvironmentId(rawValue: row["environmentId"] as! String), shell: try decode(OrchestrationThreadShell.self, row))
    }
  }

  func projects(_ any: Any) throws -> [EnvironmentProject] {
    try (any as! [[String: Any]]).map { row in
      EnvironmentProject(environmentId: EnvironmentId(rawValue: row["environmentId"] as! String), project: try decode(OrchestrationProjectShell.self, row))
    }
  }

  func run(_ c: Case, shared: [String: Any]) throws -> Any {
    let input = c.input
    func now() -> IsoDateTime { IsoDateTime(rawValue: input["now"] as! String) }
    switch c.op {
    case "list":
      let rows = try threads(shared[input["threadsRef"] as! String]!)
      let o = input["options"] as! [String: Any]
      func set(_ key: String) -> Set<String>? { (o[key] as? [String]).map(Set.init) }
      func envSet(_ key: String) -> Set<EnvironmentId>? { (o[key] as? [String]).map { Set($0.map { EnvironmentId(rawValue: $0) }) } }
      let refs = (o["projectRefs"] as? [[String: String]])?.map { ScopedProjectRef(environmentId: EnvironmentId(rawValue: $0["environmentId"]!), projectId: ProjectId(rawValue: $0["projectId"]!)) }
      let layout = ThreadList.build(
        ThreadListInput(
          threads: rows, environmentId: (o["environmentId"] as? String).map { EnvironmentId(rawValue: $0) }, projectRefs: refs,
          searchQuery: o["searchQuery"] as? String ?? "", matchedThreadKeys: set("matchedThreadKeys"),
          settlementEnvironmentIds: envSet("settlementEnvironmentIds"), snoozeEnvironmentIds: envSet("snoozeEnvironmentIds"),
          settledLimit: o["settledLimit"] as? Int, now: now(), snoozedShelfExpanded: o["snoozedShelfExpanded"] as? Bool ?? false,
          settledShelfExpanded: o["settledShelfExpanded"] as? Bool ?? true, selectedThreadKey: o["selectedThreadKey"] as? String,
          queuedThreadKeys: set("queuedThreadKeys")))
      var result: [String: Any] = [:]
      result["items"] = layout.items.map { item -> [Any] in [item.thread.id, item.variant.rawValue, item.snoozed, item.pinned, item.isLast] }
      result["hiddenSettledCount"] = layout.hiddenSettledCount
      result["snoozedCount"] = layout.snoozedCount
      result["snoozedShelfHeaderIndex"] = layout.snoozedShelfHeaderIndex.map { $0 as Any } ?? NSNull()
      result["settledCount"] = layout.settledCount
      result["settledShelfHeaderIndex"] = layout.settledShelfHeaderIndex.map { $0 as Any } ?? NSNull()
      result["nextSnoozeWakeAt"] = layout.nextSnoozeWakeAt.map { $0.rawValue as Any } ?? NSNull()
      return result
    case "lifecycle":
      return try threads(shared[input["threadsRef"] as! String]!).map { t -> [Any] in
        [
          t.id, ThreadSettled.effectiveSnoozed(t.shell, now: now()), ThreadSettled.threadWokeAt(t.shell, now: now())?.rawValue as Any? ?? NSNull(),
          ThreadSettled.canSnooze(t.shell, now: now()), ThreadSettled.hasQueuedTurnStart(t.shell, now: now()),
          ThreadSettled.threadRaisedHandWhileSnoozed(t.shell),
        ]
      }
    case "sorts":
      let rows = try threads(shared[input["threadsRef"] as! String]!)
      return [
        "settled": ThreadSort.sortSettled(rows).map(\.id), "pinned": ThreadSort.sortPinned(rows).map(\.id),
        "active": ThreadSort.sortActive(rows).map(\.id), "updatedAt": ThreadSort.sortThreads(rows, order: .updatedAt).map(\.id),
        "createdAt": ThreadSort.sortThreads(rows, order: .createdAt).map(\.id),
        "settledTimestamps": rows.map { ThreadSort.resolveSettledThreadTimestamp($0.shell)?.rawValue as Any? ?? NSNull() },
      ] as [String: Any]
    case "groups":
      let settings = input["settings"] as! [String: Any]
      let overrides = (settings["sidebarProjectGroupingOverrides"] as! [String: String]).mapValues { ProjectGroupingMode(rawValue: $0)! }
      let groups = ProjectGrouping.buildGroups(
        projects: try projects(shared[input["projectsRef"] as! String]!),
        settings: ProjectGroupingSettings(mode: ProjectGroupingMode(rawValue: settings["sidebarProjectGroupingMode"] as! String)!, overrides: overrides),
        preferredEnvironmentId: (input["preferredEnvironmentId"] as? String).map { EnvironmentId(rawValue: $0) })
      return groups.map { g -> [String: Any] in
        [
          "key": g.key, "label": g.label, "representative": g.representative.id,
          "members": g.members.map { [$0.physicalProjectKey, $0.project.id] },
          "memberProjectRefs": g.memberProjectRefs.map { "\($0.environmentId.rawValue):\($0.projectId.rawValue)" },
        ]
      }
    case "pending":
      let activities = try decode([OrchestrationThreadActivity].self, input["activities"]!)
      return try toAny(PendingRequestDeriver.derive(activities))
    case "pinKeys":
      return try runPinKeys(input)
    case "commands":
      return try runCommands(input)
    case "snooze":
      return try runSnooze(input)
    default:
      Issue.record("unknown op \(c.op)")
      return NSNull()
    }
  }

  func runCommands(_ input: [String: Any]) throws -> Any {
    let metaJSON = input["meta"] as! [String: String]
    let meta = CommandMeta(commandId: CommandId(rawValue: metaJSON["commandId"]!), createdAt: IsoDateTime(rawValue: metaJSON["createdAt"]!))
    return try (input["specs"] as! [[String: Any]]).map { spec -> [Any] in
      let a = spec["args"] as! [String: Any]
      let name = spec["name"] as! String
      let thread = ThreadId(rawValue: a["threadId"] as! String)
      let model = try (a["model"]).map { try decode(ModelSelection.self, $0) }
      func runtime(_ key: String) -> RuntimeMode { RuntimeMode(rawValue: a[key] as! String) }
      let command: ClientOrchestrationCommand
      switch name {
      case "create", "create-minimal":
        command = ThreadCommand.create(
          threadId: thread, projectId: ProjectId(rawValue: a["projectId"] as! String), title: a["title"] as! String, modelSelection: model!,
          runtimeMode: runtime("runtimeMode"), interactionMode: (a["interactionMode"] as? String).map { ProviderInteractionMode(rawValue: $0) } ?? .default,
          branch: a["branch"] as? String, worktreePath: a["worktreePath"] as? String, meta: meta)
      case "delete": command = ThreadCommand.delete(thread, meta: meta)
      case "archive": command = ThreadCommand.archive(thread, meta: meta)
      case "unarchive": command = ThreadCommand.unarchive(thread, meta: meta)
      case "settle": command = ThreadCommand.settle(thread, meta: meta)
      case "unsettle": command = ThreadCommand.unsettle(thread, meta: meta)
      case "snooze": command = ThreadCommand.snooze(thread, until: IsoDateTime(rawValue: a["until"] as! String), meta: meta)
      case "unsnooze": command = ThreadCommand.unsnooze(thread, meta: meta)
      case "pin", "pin-key": command = ThreadCommand.pin(thread, orderKey: a["orderKey"] as? String, meta: meta)
      case "unpin": command = ThreadCommand.unpin(thread, meta: meta)
      case "reorderPinned": command = ThreadCommand.reorderPinned(thread, orderKey: a["orderKey"] as! String, meta: meta)
      case "reorderActive": command = ThreadCommand.reorderActive(thread, orderKey: a["orderKey"] as! String, meta: meta)
      case "autoSettleOn", "autoSettleOff": command = ThreadCommand.setAutoSettle(thread, enabled: a["enabled"] as! Bool, meta: meta)
      case "rename": command = ThreadCommand.updateMetadata(thread, title: a["title"] as? String, meta: meta)
      case "regenerateTitle": command = ThreadCommand.updateMetadata(thread, regenerateTitle: a["regenerateTitle"] as? Bool, meta: meta)
      case "runtimeMode": command = ThreadCommand.setRuntimeMode(thread, RuntimeMode(rawValue: a["mode"] as! String), meta: meta)
      case "interactionMode": command = ThreadCommand.setInteractionMode(thread, ProviderInteractionMode(rawValue: a["mode"] as! String), meta: meta)
      case "startTurn", "startTurnAttachments":
        let attachments = ((a["attachments"] as? [[String: Any]]) ?? []).map { att -> ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem in
          UploadedAttachment(
            attachmentId: att["id"] as! String, name: att["name"] as! String, mimeType: att["mimeType"] as! String, sizeBytes: att["sizeBytes"] as! Int,
            kind: att["kind"] as! String == "image" ? .image : .file
          ).messageAttachment
        }
        command = ThreadCommand.startTurn(
          thread, message: ClientOrchestrationCommandThreadTurnStartMessage(messageId: MessageId(rawValue: a["messageId"] as! String), text: a["text"] as! String, attachments: attachments),
          runtimeMode: runtime("runtimeMode"), interactionMode: ProviderInteractionMode(rawValue: a["interactionMode"] as! String), modelSelection: model,
          titleSeed: a["titleSeed"] as? String, meta: meta)
      case "interrupt", "interruptTurn": command = ThreadCommand.interruptTurn(thread, turnId: (a["turnId"] as? String).map { TurnId(rawValue: $0) }, meta: meta)
      case "approval":
        command = ThreadCommand.respondToApproval(thread, requestId: ApprovalRequestId(rawValue: a["requestId"] as! String), decision: ProviderApprovalDecision(rawValue: a["decision"] as! String), meta: meta)
      case "userInput":
        command = ThreadCommand.respondToUserInput(
          thread, requestId: ApprovalRequestId(rawValue: a["requestId"] as! String), answers: try decode([String: JSONValue].self, a["answers"]!), meta: meta)
      case "dismissUserInput": command = ThreadCommand.dismissUserInput(thread, requestId: ApprovalRequestId(rawValue: a["requestId"] as! String), meta: meta)
      case "revertFiles", "revertConversation":
        command = ThreadCommand.revert(thread, toTurnCount: a["turnCount"] as! Int, restoreFiles: a["restoreFiles"] as! Bool, meta: meta)
      case "stopSession": command = ThreadCommand.stopSession(thread, meta: meta)
      default: fatalError("unknown command spec \(name)")
      }
      return [name, try toAny(command)]
    }
  }

  func runPinKeys(_ input: [String: Any]) throws -> Any {
    let keys = (input["keys"] as! [Any]).map { $0 as? String }
    var between: [[Any]] = []
    for a in keys { for b in keys { between.append([a as Any? ?? NSNull(), b as Any? ?? NSNull(), ThreadSort.pinOrderKeyBetween(a, b) as Any? ?? NSNull()]) } }
    let spread = [1, 2, 3, 5, 10, 25, 26, 27, 100, 700, 1400].map { [$0, ThreadSort.generateSpreadPinOrderKeys($0)] as [Any] }
    var plans: [[Any]] = []
    func assignments(_ list: [ThreadSort.KeyAssignment]?) -> Any {
      guard let list else { return NSNull() }
      return list.map { ["id": $0.id, "orderKey": $0.orderKey] as [String: Any] }
    }
    for c in input["planCases"] as! [[String: Any]] {
      let ordered = c["ordered"] as! [String]
      var keys: [String: String?] = [:]
      for pair in c["keys"] as! [[Any]] { keys[pair[0] as! String] = .some(pair[1] as? String) }
      let moved = c["moved"] as! String, name = c["name"] as! String
      plans.append([name, assignments(ThreadSort.planPinnedReorder(orderedIds: ordered, keysById: keys, movedId: moved))])
      for up in [true, false] {
        plans.append(["\(name)/move-\(up ? "up" : "down")", assignments(ThreadSort.planPinnedMove(orderedIds: ordered, keysById: keys, movedId: moved, up: up))])
      }
    }
    return ["between": between, "spread": spread, "plans": plans] as [String: Any]
  }

  func runSnooze(_ input: [String: Any]) throws -> Any {
    var presets: [[Any]] = [], custom: [[Any]] = [], wake: [Any] = []
    for zone in input["zones"] as! [String] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: zone)!
      calendar.locale = Locale(identifier: "en_US_POSIX")
      for instant in input["instants"] as! [String] {
        let now = Date(timeIntervalSince1970: IsoTimestamp.parse(instant)! / 1000)
        presets.append([zone, instant, ThreadSettled.resolveSnoozePresets(now: now, calendar: calendar).map { [$0.id.rawValue, $0.label, $0.snoozedUntil.rawValue] as [Any] }])
        custom.append([
          zone, instant,
          (input["custom"] as! [[String: String]]).map { c -> Any in
            let parsed: ThreadSettled.CustomSnoozeInput =
              c["mode"] == "date"
              ? .date(date: c["date"]!, time: c["time"]!)
              : .duration(amount: c["amount"]!, unit: .init(rawValue: c["unit"]!)!)
            return ThreadSettled.resolveCustomSnooze(parsed, now: now, calendar: calendar)?.rawValue as Any? ?? NSNull()
          },
        ])
      }
    }
    for pair in input["wake"] as! [[String]] { wake.append(ThreadSettled.snoozeWakeLabel(IsoDateTime(rawValue: pair[0]), now: IsoDateTime(rawValue: pair[1]))) }
    return ["presets": presets, "custom": custom, "wake": wake] as [String: Any]
  }

  func check(raw: Bool, name: String) throws {
    let (cases, shared) = Self.load(raw: raw)
    let c = try #require(cases.first { $0.name == name })
    let diff = jsonDiff(c.expected, try run(c, shared: shared), path: name)
    #expect(diff.isEmpty, "\(diff.joined(separator: "\n"))")
  }

  @Test(arguments: DerivedOracleTests.caseNames(raw: false))
  func derivedCases(_ name: String) throws { try check(raw: false, name: name) }

  @Test(.enabled(if: rawEnabled), arguments: rawEnabled ? DerivedOracleTests.caseNames(raw: true) : [])
  func derivedRawCorpus(_ name: String) throws { try check(raw: true, name: name) }
}
