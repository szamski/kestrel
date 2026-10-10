import Foundation
import T3Contracts

// The stable JSON projection of a protocol-2 timeline. The V2 differential oracle
// (scripts/timeline-oracle/v2.ts) writes the same document from the web's TypeScript derivations;
// tests compare the two. Items are reduced to identity and the fields a row renders.

private func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var result: [String: JSONValue] = [:]
  for (key, value) in pairs { if let value { result[key] = value } }
  return .object(result)
}

private func string(_ value: String?) -> JSONValue? { value.map { .string($0) } }
private func orNull(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }

private func itemStub(_ item: TurnItem) -> JSONValue {
  object([
    ("id", string(item.fields?.id.rawValue)), ("type", .string(item.typeTag)), ("status", .string(item.statusValue)), ("runId", orNull(item.runIdValue)),
  ])
}

private func messageStub(_ message: V1.OrchestrationMessage, inputIntent: String? = nil) -> JSONValue {
  object([
    ("id", .string(message.id.rawValue)), ("role", .string(message.role.rawValue)), ("streaming", .bool(message.streaming)),
    ("runId", orNull(message.turnId?.rawValue)), ("inputIntent", string(inputIntent)),
  ])
}

extension WorkLogEntry {
  /// Protocol-2 entry document (`projectEntryV2` in the oracle).
  public var projectionV2: JSONValue {
    object([
      ("id", .string(id)), ("createdAt", .string(createdAt)), ("runId", orNull(turnId?.rawValue)), ("label", .string(label)),
      ("tone", .string(tone.rawValue)), ("detail", string(detail)), ("command", string(command)), ("rawCommand", string(rawCommand)),
      ("changedFiles", changedFiles.map { .array($0.map { .string($0) }) }), ("toolTitle", string(toolTitle)),
      ("viewedImagePath", string(viewedImagePath)), ("toolSurface", string(toolSurface?.rawValue)), ("toolIcon", toolIcon?.projection),
      ("toolSource", toolSource?.projection), ("itemType", string(v2Type)), ("toolLifecycleStatus", string(toolLifecycleStatus?.rawValue)),
      ("sourceActivityKind", string(sourceActivityKind)), ("questionAnswerRequestId", string(questionAnswer?.requestId.rawValue)),
    ])
  }
}

extension V2TimelineEntry {
  public var projectionV2: JSONValue {
    var pairs: [(String, JSONValue?)] = [("id", .string(id)), ("createdAt", .string(createdAt))]
    if let attempt {
      pairs.append(("attempt", object([("id", .string(attempt.id)), ("runId", .string(attempt.runId)), ("status", .string(attempt.status))])))
    }
    switch kind {
    case .message(let value):
      pairs += [("kind", .string("message")), ("message", messageStub(value.message, inputIntent: value.inputIntent))]
    case .proposedPlan(let plan):
      pairs += [("kind", .string("proposed-plan")), ("proposedPlan", plan.projectionV2)]
    case .htmlRender(let html):
      pairs += [("kind", .string("html-render")), ("htmlRender", html.projectionV2)]
    case .mcpApp(let app):
      pairs += [("kind", .string("mcp-app")), ("mcpApp", app.projectionV2)]
    case .work(let work):
      pairs += [("kind", .string("work")), ("entry", work.projectionV2)]
    case .event(let event):
      pairs += [("kind", .string("event")), ("item", itemStub(event.item))]
    }
    return object(pairs)
  }
}

extension V2Plan {
  var projectionV2: JSONValue {
    object([
      ("id", .string(id)), ("runId", orNull(runId)), ("planMarkdown", .string(planMarkdown)), ("status", .string(status)),
      ("createdAt", .string(createdAt)), ("updatedAt", .string(updatedAt)),
    ])
  }
}

extension HtmlRenderReference {
  var projectionV2: JSONValue { object([("attachmentId", .string(attachmentId)), ("title", .string(title)), ("height", .int(height))]) }
}

extension McpAppEntry {
  var projectionV2: JSONValue {
    object([
      ("sourceThreadId", .string(sourceThreadId)), ("itemId", .string(itemId)), ("revision", .string(revision)),
      ("mcpApp", object([("attachmentId", .string(app.attachmentId)), ("server", .string(app.server)), ("tool", .string(app.tool)), ("resourceUri", .string(app.resourceUri))])),
    ])
  }
}

private func summaryProjectionV2(_ summary: V1.OrchestrationCheckpointSummary) -> JSONValue {
  object([
    ("runId", .string(summary.turnId.rawValue)), ("checkpointTurnCount", .int(summary.checkpointTurnCount)), ("status", .string(summary.status.rawValue)),
    (
      "files",
      .array(
        summary.files.map {
          object([("path", .string($0.path)), ("kind", .string($0.kind)), ("additions", .int($0.additions)), ("deletions", .int($0.deletions))])
        })
    ),
    ("assistantMessageId", orNull(summary.assistantMessageId?.rawValue)), ("completedAt", .string(summary.completedAt.rawValue)),
  ])
}

extension TimelineRow {
  /// Protocol-2 row document (`projectRowV2` in the oracle).
  public var projectionV2: JSONValue {
    func base(_ kind: String, _ id: String, _ createdAt: String?) -> [(String, JSONValue?)] {
      [("kind", .string(kind)), ("id", .string(id)), ("createdAt", orNull(createdAt))]
    }
    func entries(_ values: [WorkLogEntry]) -> JSONValue { .array(values.map(\.projectionV2)) }
    func flag(_ value: Bool) -> JSONValue? { value ? .bool(true) : nil }
    switch self {
    case .work(let row):
      return object(
        base("work", row.id, row.createdAt) + [
          ("groupedEntries", entries(row.groupedEntries)), ("isExpandedToolGroup", .bool(row.isExpandedToolGroup)), ("displayLabel", string(row.displayLabel)),
          ("continuesWorkLog", flag(row.continuesWorkLog)),
        ])
    case .workLive(let row):
      return object(
        base("work-live", row.id, row.createdAt) + [
          ("entry", row.entry.projectionV2), ("groupedEntries", entries(row.groupedEntries)), ("groupId", .string(row.groupId)), ("expanded", .bool(row.expanded)),
          ("active", .bool(row.active)), ("thought", row.thought?.projectionV2), ("continuesWorkLog", flag(row.continuesWorkLog)),
        ])
    case .workToggle(let row):
      return object(
        base("work-toggle", row.id, row.createdAt) + [
          ("runId", orNull(row.turnId?.rawValue)), ("groupId", .string(row.groupId)), ("hiddenCount", .int(row.hiddenCount)), ("expanded", .bool(row.expanded)),
          ("summary", .string(row.summary)), ("summaryKind", .string(row.summaryKind.rawValue)), ("toolSurface", string(row.toolSurface?.rawValue)),
          ("toolIcon", row.toolIcon?.projection), ("summaryToolIcon", string(row.summaryToolIcon?.rawValue)), ("hasFailure", .bool(row.hasFailure)),
          ("continuesWorkLog", flag(row.continuesWorkLog)),
        ])
    case .turnFold(let row):
      return object(base("turn-fold", row.id, row.createdAt) + [("runId", .string(row.turnId.rawValue)), ("label", .string(row.label)), ("expanded", .bool(row.expanded))])
    case .attemptFold(let row):
      return object(
        base("attempt-fold", row.id, row.createdAt) + [
          ("runId", .string(row.runId)), ("attemptId", .string(row.attemptId)), ("label", .string(row.label)), ("expanded", .bool(row.expanded)),
        ])
    case .contextCompaction(let row):
      return object(base("context-compaction", row.id, row.createdAt) + [("label", .string(row.label)), ("active", .bool(row.active))])
    case .message(let row):
      return object(
        base("message", row.id, row.createdAt) + [
          ("message", messageStub(row.message, inputIntent: row.inputIntent)), ("durationStart", .string(row.durationStart)),
          ("showAssistantMeta", .bool(row.showAssistantMeta)), ("showAssistantCopyButton", .bool(row.showAssistantCopyButton)),
          ("assistantCopyStreaming", .bool(row.assistantCopyStreaming)), ("assistantTurnDiffSummary", row.assistantTurnDiffSummary.map(summaryProjectionV2)),
          ("revertTurnCount", row.revertTurnCount.map { .int($0) }),
        ])
    case .assistantMeta(let row):
      return object(
        base("assistant-meta", row.id, row.createdAt) + [
          ("message", messageStub(row.message)), ("showAssistantCopyButton", .bool(row.showAssistantCopyButton)),
          ("assistantCopyStreaming", .bool(row.assistantCopyStreaming)),
        ])
    case .event(let row):
      return object(
        base("event", row.id, row.createdAt) + [
          ("item", itemStub(row.item.item)), ("subagents", row.subagents.map { .array($0.map { itemStub($0.item) }) }),
          ("resourceSummary", flag(row.resourceSummary)),
        ])
    case .proposedPlan(let row):
      return object(
        base("proposed-plan", row.id, row.createdAt) + [
          ("proposedPlan", object([
            ("id", .string(row.proposedPlan.id)), ("runId", orNull(row.proposedPlan.turnId?.rawValue)), ("planMarkdown", .string(row.proposedPlan.planMarkdown)),
            ("status", string(row.status)), ("createdAt", .string(row.proposedPlan.createdAt.rawValue)), ("updatedAt", .string(row.proposedPlan.updatedAt.rawValue)),
          ]))
        ])
    case .htmlRender(let row):
      return object(base("html-render", row.id, row.createdAt) + [("htmlRender", row.htmlRender.projectionV2)])
    case .mcpApp(let row):
      return object(base("mcp-app", row.id, row.createdAt) + [("mcpApp", row.mcpApp.projectionV2)])
    case .working(let row): return object(base("working", row.id, row.createdAt))
    case .thinking(let row):
      return object(
        base("thinking", row.id, row.createdAt) + [
          ("groupId", string(row.groupId)), ("expanded", row.groupId == nil ? nil : .bool(row.expanded)), ("continuesWorkLog", flag(row.continuesWorkLog)),
        ])
    case .worktreeSetup(let row):
      return object(base("worktree-setup", row.id, row.createdAt) + [("snapshot", row.snapshot.projection), ("embedded", .bool(row.embedded))])
    case .activityGroup, .queuedMessage:
      return .null  // protocol 1 only
    }
  }
}

extension ThreadTimelineV2 {
  /// The document compared against the TypeScript oracle.
  public var projection: JSONValue {
    object([
      ("timelineEntries", .array(entries.map(\.projectionV2))), ("rows", .array(rows.map(\.projectionV2))), ("phase", .string(phase.rawValue)),
      ("isWorking", .bool(isWorking)), ("activeTurnStartedAt", orNull(activeTurnStartedAt)), ("runningRunId", orNull(runningRunId)),
      ("activePlan", activePlan.map(Self.planProjection) ?? .null),
      (
        "activeProposedPlan",
        activeProposedPlan.map { plan in
          object([
            ("id", .string(plan.id)), ("createdAt", .string(plan.createdAt)), ("updatedAt", .string(plan.updatedAt)), ("runId", orNull(plan.turnId?.rawValue)),
            ("planMarkdown", .string(plan.planMarkdown)), ("status", string(plan.status)),
          ])
        } ?? .null
      ),
      (
        "minimap",
        .array(
          minimap.map {
            object([("id", .string($0.id)), ("rowIndex", .int($0.rowIndex)), ("userText", orNull($0.userText)), ("assistantText", orNull($0.assistantText))])
          })
      ),
      ("checkpoints", .array(checkpoints.map(summaryProjectionV2))),
    ])
  }

  private static func planProjection(_ plan: ActivePlanState) -> JSONValue {
    object([
      ("createdAt", .string(plan.createdAt)), ("runId", orNull(plan.turnId?.rawValue)),
      ("explanation", plan.explanation.map { orNull($0) } ?? .null),
      (
        "steps",
        .array(
          plan.steps.map {
            object([("durationMs", $0.durationMs.map { .double($0) }), ("step", .string($0.step)), ("status", .string($0.status.rawValue))])
          })
      ),
    ])
  }
}
