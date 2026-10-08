import Foundation
import T3Contracts

// A stable JSON projection of the derived rows. The differential oracle
// (apps/macos/scripts/timeline-oracle) writes the same projection from the TypeScript
// derivations; tests compare the two documents. Messages are reduced to ids and flags and
// wire structs to the fields a row renders, so the projection stays small and independent of
// how the generated Codable types spell optional or null values.

private func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var result: [String: JSONValue] = [:]
  for (key, value) in pairs { if let value { result[key] = value } }
  return .object(result)
}

private func string(_ value: String?) -> JSONValue? { value.map { .string($0) } }
private func orNull(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }

private func encoded<T: Encodable>(_ value: T) -> JSONValue {
  (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))) ?? .null
}

extension ToolActivityIcon {
  var projection: JSONValue {
    switch self {
    case .website(let pageUrl, let faviconUrl, let faviconUrlDark):
      object([("_tag", .string("website")), ("pageUrl", .string(pageUrl)), ("faviconUrl", string(faviconUrl)), ("faviconUrlDark", string(faviconUrlDark))])
    case .nativeApp(let app):
      switch app {
      case .appId(let id): object([("_tag", .string("native-app")), ("app", object([("_tag", .string("app-id")), ("appId", .string(id))]))])
      case .displayName(let name):
        object([("_tag", .string("native-app")), ("app", object([("_tag", .string("display-name")), ("displayName", .string(name))]))])
      }
    case .themedLogo(let logoUrl, let logoUrlDark):
      object([("_tag", .string("themed-logo")), ("logoUrl", .string(logoUrl)), ("logoUrlDark", string(logoUrlDark))])
    }
  }
}

extension ToolActivitySource {
  var projection: JSONValue {
    object([("key", .string(key)), ("name", .string(name)), ("kind", .string(kind.rawValue)), ("icon", icon?.projection)])
  }
}

extension WorkLogEntry {
  public var projection: JSONValue {
    object([
      ("id", .string(id)),
      ("createdAt", .string(createdAt)),
      ("turnId", orNull(turnId?.rawValue)),
      ("label", .string(label)),
      ("tone", .string(tone.rawValue)),
      ("questionAnswer", questionAnswer.map(encoded)),
      ("toolCallId", string(toolCallId)),
      ("detail", string(detail)),
      ("viewedImagePath", string(viewedImagePath)),
      ("command", string(command)),
      ("rawCommand", string(rawCommand)),
      ("changedFiles", changedFiles.map { .array($0.map { .string($0) }) }),
      ("toolTitle", string(toolTitle)),
      ("toolSurface", string(toolSurface?.rawValue)),
      ("toolIcon", toolIcon?.projection),
      ("toolSource", toolSource?.projection),
      ("toolData", toolData),
      ("itemType", string(itemType?.rawValue)),
      ("requestKind", string(requestKind?.rawValue)),
      ("toolLifecycleStatus", string(toolLifecycleStatus?.rawValue)),
      ("sourceActivityKind", string(sourceActivityKind)),
      ("taskId", string(taskId)),
      ("agentRole", string(agentRole)),
      (
        "agentSpawn",
        agentSpawn.map {
          object([("workflowId", orNull($0.workflowId)), ("agentTaskIds", .array($0.agentTaskIds.map { .string($0) }))])
        }
      ),
    ])
  }
}

extension OrchestrationCheckpointSummary {
  var projection: JSONValue {
    object([
      ("turnId", .string(turnId.rawValue)),
      ("checkpointTurnCount", .int(checkpointTurnCount)),
      ("status", .string(status.rawValue)),
      (
        "files",
        .array(
          files.map {
            object([("path", .string($0.path)), ("kind", .string($0.kind)), ("additions", .int($0.additions)), ("deletions", .int($0.deletions))])
          })
      ),
      ("assistantMessageId", orNull(assistantMessageId?.rawValue)),
      ("completedAt", .string(completedAt.rawValue)),
    ])
  }
}

extension ProposedPlan {
  var projection: JSONValue {
    object([
      ("id", .string(id)),
      ("turnId", orNull(turnId?.rawValue)),
      ("planMarkdown", .string(planMarkdown)),
      ("implementedAt", orNull(implementedAt?.rawValue)),
      ("implementationThreadId", orNull(implementationThreadId?.rawValue)),
      ("createdAt", .string(createdAt.rawValue)),
      ("updatedAt", .string(updatedAt.rawValue)),
    ])
  }
}

extension WorktreeSetupSnapshot {
  var projection: JSONValue {
    object([
      ("threadId", .string(threadId.rawValue)),
      ("phase", .string(phase.rawValue)),
      ("startedAt", .string(startedAt.rawValue)),
      ("sequence", .int(sequence)),
      ("stages", .array(stages.map { object([("id", .string($0.id.rawValue)), ("status", .string($0.status.rawValue))]) })),
    ])
  }
}

private func messageStub(_ message: OrchestrationMessage) -> JSONValue {
  object([("id", .string(message.id.rawValue)), ("role", .string(message.role.rawValue)), ("streaming", .bool(message.streaming))])
}

extension ActivityEntry {
  var projection: JSONValue {
    switch self {
    case .message(let message): object([("kind", .string("message")), ("message", messageStub(message))])
    case .work(let entry): object([("kind", .string("work")), ("entry", entry.projection)])
    }
  }
}

extension TimelineEntry {
  public var projection: JSONValue {
    switch self {
    case .message(let message): object([("kind", .string("message")), ("id", .string(id)), ("createdAt", .string(createdAt)), ("message", messageStub(message))])
    case .proposedPlan(let plan): object([("kind", .string("proposed-plan")), ("id", .string(id)), ("createdAt", .string(createdAt)), ("proposedPlan", plan.projection)])
    case .work(let entry): object([("kind", .string("work")), ("id", .string(id)), ("createdAt", .string(createdAt)), ("entry", entry.projection)])
    }
  }
}

extension TimelineRow {
  public var projection: JSONValue {
    func base(_ kind: String, _ id: String, _ createdAt: String?) -> [(String, JSONValue?)] {
      [("kind", .string(kind)), ("id", .string(id)), ("createdAt", orNull(createdAt))]
    }
    func entries(_ values: [WorkLogEntry]) -> JSONValue { .array(values.map(\.projection)) }
    switch self {
    case .activityGroup(let row):
      return object(
        base("activity-group", row.id, row.createdAt) + [
          ("turnId", .string(row.turnId.rawValue)), ("groupId", .string(row.groupId)),
          ("entries", .array(row.entries.map(\.projection))), ("expanded", .bool(row.expanded)), ("active", .bool(row.active)),
        ])
    case .work(let row):
      return object(
        base("work", row.id, row.createdAt) + [
          ("groupedEntries", entries(row.groupedEntries)), ("isExpandedToolGroup", .bool(row.isExpandedToolGroup)),
          ("displayLabel", string(row.displayLabel)),
        ])
    case .workLive(let row):
      return object(
        base("work-live", row.id, row.createdAt) + [
          ("entry", row.entry.projection), ("groupedEntries", entries(row.groupedEntries)), ("groupId", .string(row.groupId)),
          ("expanded", .bool(row.expanded)), ("active", .bool(row.active)),
        ])
    case .workToggle(let row):
      return object(
        base("work-toggle", row.id, row.createdAt) + [
          ("turnId", orNull(row.turnId?.rawValue)), ("groupId", .string(row.groupId)), ("hiddenCount", .int(row.hiddenCount)),
          ("expanded", .bool(row.expanded)), ("summary", .string(row.summary)), ("summaryKind", .string(row.summaryKind.rawValue)),
          ("toolSurface", string(row.toolSurface?.rawValue)), ("toolIcon", row.toolIcon?.projection),
          ("summaryToolIcon", string(row.summaryToolIcon?.rawValue)), ("hasFailure", .bool(row.hasFailure)),
        ])
    case .turnFold(let row):
      return object(
        base("turn-fold", row.id, row.createdAt) + [
          ("turnId", .string(row.turnId.rawValue)), ("label", .string(row.label)), ("expanded", .bool(row.expanded)),
        ])
    case .contextCompaction(let row):
      return object(base("context-compaction", row.id, row.createdAt) + [("label", .string(row.label))])
    case .message(let row):
      return object(
        base("message", row.id, row.createdAt) + [
          ("message", messageStub(row.message)), ("durationStart", .string(row.durationStart)),
          ("showAssistantMeta", .bool(row.showAssistantMeta)), ("showAssistantCopyButton", .bool(row.showAssistantCopyButton)),
          ("assistantCopyStreaming", .bool(row.assistantCopyStreaming)),
          ("assistantTurnDiffSummary", row.assistantTurnDiffSummary?.projection),
          ("revertTurnCount", row.revertTurnCount.map { .int($0) }),
        ])
    case .assistantMeta(let row):
      return object(
        base("assistant-meta", row.id, row.createdAt) + [
          ("message", messageStub(row.message)), ("showAssistantCopyButton", .bool(row.showAssistantCopyButton)),
          ("assistantCopyStreaming", .bool(row.assistantCopyStreaming)),
        ])
    case .proposedPlan(let row):
      return object(base("proposed-plan", row.id, row.createdAt) + [("proposedPlan", row.proposedPlan.projection)])
    case .working(let row): return object(base("working", row.id, row.createdAt))
    case .thinking(let row): return object(base("thinking", row.id, row.createdAt))
    case .worktreeSetup(let row):
      return object(base("worktree-setup", row.id, row.createdAt) + [("snapshot", row.snapshot.projection), ("embedded", .bool(row.embedded))])
    case .queuedMessage(let row):
      return object(
        base("queued-message", row.id, row.createdAt) + [("queuedMessageId", .string(row.queuedMessage.id)), ("isNext", .bool(row.isNext))])
    }
  }
}

extension ActivePlanState {
  public var projection: JSONValue {
    var pairs: [(String, JSONValue?)] = [
      ("createdAt", .string(createdAt)),
      ("turnId", orNull(turnId?.rawValue)),
      (
        "steps",
        .array(
          steps.map {
            object([("durationMs", $0.durationMs.map { .double($0) }), ("step", .string($0.step)), ("status", .string($0.status.rawValue))])
          })
      ),
    ]
    if let explanation { pairs.append(("explanation", orNull(explanation))) }
    return object(pairs)
  }
}

extension LatestProposedPlanState {
  public var projection: JSONValue {
    object([
      ("id", .string(id)), ("createdAt", .string(createdAt)), ("updatedAt", .string(updatedAt)), ("turnId", orNull(turnId?.rawValue)),
      ("planMarkdown", .string(planMarkdown)), ("implementedAt", orNull(implementedAt)),
      ("implementationThreadId", orNull(implementationThreadId?.rawValue)),
    ])
  }
}

extension ThreadTimeline {
  /// The document compared against the TypeScript oracle.
  public var projection: JSONValue {
    object([
      ("workEntries", .array(workEntries.map(\.projection))),
      ("timelineEntries", .array(entries.map(\.projection))),
      ("rows", .array(rows.map(\.projection))),
      ("phase", .string(phase.rawValue)),
      ("isWorking", .bool(isWorking)),
      ("activeTurnStartedAt", orNull(activeTurnStartedAt)),
      ("runningTurnId", orNull(runningTurnId?.rawValue)),
      ("activePlan", activePlan?.projection ?? .null),
      ("activeProposedPlan", activeProposedPlan?.projection ?? .null),
      (
        "minimap",
        .array(
          minimap.map {
            object([
              ("id", .string($0.id)), ("rowIndex", .int($0.rowIndex)), ("userText", orNull($0.userText)),
              ("assistantText", orNull($0.assistantText)),
            ])
          })
      ),
    ])
  }
}

extension PendingPrompts {
  /// JSON of `derivePendingRequests` in pendingRequests.ts.
  public var projection: JSONValue {
    object([
      (
        "approvals",
        .array(
          approvals.map { approval in
            object([
              ("requestId", .string(approval.requestId.rawValue)),
              ("requestKind", .string(approval.requestKind.rawValue)),
              ("createdAt", .string(approval.createdAt)),
              ("detail", string(approval.detail)),
              ("appName", string(approval.appName)),
              (
                "options",
                approval.options.map { options in
                  .array(
                    options.map {
                      object([("decision", .string($0.decision.rawValue)), ("label", .string($0.label)), ("warning", string($0.warning))])
                    })
                }
              ),
            ])
          })
      ),
      (
        "userInputs",
        .array(
          userInputs.map {
            object([
              ("requestId", .string($0.requestId.rawValue)), ("createdAt", .string($0.createdAt)),
              ("questions", encoded($0.questions)), ("dismissible", .bool($0.dismissible)),
            ])
          })
      ),
    ])
  }
}
