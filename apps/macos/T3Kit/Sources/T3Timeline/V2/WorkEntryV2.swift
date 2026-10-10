import Foundation
import T3Contracts

// Protocol-2 work-log entries: `projectedWorkEntry` of session-logic.ts, plus the entry judgements
// and labels of work-log/presentation.ts and MessagesTimeline.logic.ts that read them.
// `V2Work` is dispatched to from the protocol-1 functions (`entry.v2 != nil`), so rows and views
// call one set of names for both protocols.

func jsonEncoded<T: Encodable>(_ value: T) -> JSONValue? {
  guard let data = try? JSONEncoder().encode(value) else { return nil }
  return try? JSONDecoder().decode(JSONValue.self, from: data)
}

/// `bridge`: re-reads a value through its wire form where the generator declared structurally
/// identical types twice.
func jsonBridge<Source: Encodable, Target: Decodable>(_ value: Source) -> Target? {
  guard let data = try? JSONEncoder().encode(value) else { return nil }
  return try? JSONDecoder().decode(Target.self, from: data)
}

func formatTokens(_ value: Int) -> String {
  func trim(_ number: Double) -> String {
    let abs = Swift.abs(number)
    let digits = abs >= 100 ? 0 : abs >= 10 ? 1 : 2
    var text = String(format: "%.\(digits)f", number)
    if let dot = text.firstIndex(of: "."), text[dot...].dropFirst().allSatisfy({ $0 == "0" }) { text = String(text[..<dot]) }
    return text
  }
  let number = Double(value)
  let abs = Swift.abs(number)
  if abs >= 1e12 { return "\(trim(number / 1e12))T" }
  if abs >= 1e9 { return "\(trim(number / 1e9))B" }
  if abs >= 1e6 { return "\(trim(number / 1e6))M" }
  if abs >= 1e3 { return "\(trim(number / 1e3))K" }
  return jsLocaleNumber(Int(jsRound(number)))
}

func contextCompactionLabel(_ item: OrchestrationV2ThreadProjectionTurnItemsItemCompaction) -> String {
  if item.status.rawValue == "running" { return "Compacting context" }
  if let before = item.beforeTokenCount, let after = item.afterTokenCount {
    return "Context compacted \(formatTokens(before)) \u{2192} \(formatTokens(after)) tokens"
  }
  return "Context compacted"
}

/// `providerErrorPresentation`.
func providerErrorPresentation(_ item: OrchestrationV2ThreadProjectionTurnItemsItemError) -> (label: String, detail: String) {
  let usageLimit = item.failure.class.rawValue == "usage_limit"
  guard let retry = item.retry else {
    let title = item.title?.jsTrimmed ?? ""
    return (usageLimit ? "Usage limit reached" : (title.isEmpty ? "Provider error" : title), item.failure.message)
  }
  let progress = retry.maxAttempts.map { "\(retry.attempt)/\($0)" } ?? "\(retry.attempt)"
  let status = item.status.rawValue
  let label: String =
    switch status {
    case "running": "Retrying provider (\(progress))"
    case "completed": "Provider recovered (\(progress) retries)"
    case "failed": "\(usageLimit ? "Usage limit reached" : "Provider error") after \(progress) retries"
    default: "Provider retry stopped (\(progress))"
    }
  var retryDelay = ""
  if status == "running", let ms = retry.retryDelayMs, ms > 0 {
    if ms < 1_000 {
      retryDelay = " Retrying in \(ms)ms."
    } else {
      var seconds = String(format: "%.1f", Double(ms) / 1_000)
      if seconds.hasSuffix(".0") { seconds.removeLast(2) }
      retryDelay = " Retrying in \(seconds)s."
    }
  }
  return (label, "\(item.failure.message)\(retryDelay)")
}

private func workEntryStatus(_ status: String) -> ToolLifecycleStatus {
  switch status {
  case "pending", "running", "waiting": .inProgress
  case "completed": .completed
  case "idle": .idle
  case "failed": .failed
  default: .stopped  // cancelled, interrupted (and a status this build does not know)
  }
}

private func workEntryTone(_ item: TurnItem) -> WorkLogTone {
  switch item {
  case .error: .info
  case .reasoning: .thinking
  case .commandExecution, .fileChange, .fileSearch, .webSearch, .dynamicTool, .subagent, .threadCreated, .userInputRequest, .approvalRequest: .tool
  default: .info
  }
}

private func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

/// `projectedWorkEntry`: one projected turn item as a work-log entry.
func projectedWorkEntry(_ row: ProjectedItem) -> WorkLogEntry {
  let item = row.item
  guard let fields = item.fields else {
    return WorkLogEntry(id: row.sourceItemId.rawValue, createdAt: "", label: "", tone: .info)
  }
  let title = fields.title.flatMap { nonEmpty($0.jsTrimmed) }
  var entry = WorkLogEntry(
    id: fields.id.rawValue, createdAt: (fields.startedAt ?? fields.updatedAt).rawValue,
    turnId: fields.runId.map { V1.TurnId(rawValue: $0.rawValue) }, label: "", tone: workEntryTone(item))
  entry.v2 = V2WorkItem(row: row)
  entry.toolLifecycleStatus = workEntryStatus(fields.status.rawValue)

  var payload: JSObject = [:]
  if let surface = fields.toolSurface { payload["toolSurface"] = .string(surface.rawValue) }
  if let icon = fields.toolIcon, let value = jsonEncoded(icon) { payload["toolIcon"] = value }
  if let source = fields.toolSource, let value = jsonEncoded(source) { payload["toolSource"] = value }
  let extracted = extractToolActivityPresentation(.object(payload))
  entry.toolSurface = extracted.toolSurface
  entry.toolIcon = extracted.toolIcon
  entry.toolSource = extracted.toolSource
  if case .dynamicTool(let tool) = item, let path = tool.viewedImagePath?.jsTrimmed, !path.isEmpty, path.utf16Length <= 4096,
    !path.contains(where: { $0 == "\n" || $0 == "\r" }), isWorkspaceImagePreviewPath(path)
  {
    entry.viewedImagePath = path
  }

  switch item {
  case .threadCreated:
    entry.label = "Created thread"
  case .compaction(let value):
    entry.label = contextCompactionLabel(value)
    entry.sourceActivityKind = "context-compaction"
    if let summary = nonEmpty(value.summary) { entry.detail = summary }
  case .reasoning(let value):
    entry.label = title ?? "Thinking"
    if !value.text.isEmpty { entry.detail = value.text }
  case .commandExecution(let value):
    entry.label = title ?? "Ran command"
    entry.command = value.input
    entry.rawCommand = value.input
    entry.toolTitle = title ?? "Command"
  case .fileChange(let value):
    entry.label = title ?? ((value.changes?.count ?? 0) > 1 ? "Changed \(value.changes!.count) files" : "Changed \(value.fileName)")
    entry.changedFiles = value.changes?.map(\.path) ?? [value.fileName]
    entry.toolTitle = title ?? "File change"
  case .fileSearch(let value):
    let searchLabel = value.pattern.flatMap { formatSearchToolLabel(["pattern": .string($0)]) }
    entry.label = title ?? searchLabel ?? "Searched files"
    if let pattern = nonEmpty(value.pattern) { entry.detail = pattern }
    entry.toolTitle = title ?? "File search"
  case .webSearch(let value):
    entry.label = title ?? "Searched the web"
    if let patterns = value.patterns, !patterns.isEmpty { entry.detail = patterns.joined(separator: ", ") }
    entry.toolTitle = title ?? "Web search"
  case .checkpoint(let value):
    entry.label = title ?? "Checkpoint captured"
    entry.changedFiles = value.files.map(\.path)
  case .systemNotice(let value):
    entry.label = value.message
    entry.sourceActivityKind = "runtime.warning"
  case .error(let value):
    let presentation = providerErrorPresentation(value)
    entry.label = presentation.label
    entry.detail = presentation.detail
    if value.failure.class.rawValue == "usage_limit" && value.status.rawValue != "completed" {
      entry.sourceActivityKind = "runtime.warning"
    } else if value.retry == nil {
      entry.sourceActivityKind = "runtime.error"
    }
  case .dynamicTool(let value):
    let classified = classifyToolActivity(itemType: "dynamic_tool_call", toolName: value.toolName)
    let readPath = collectToolFilePaths(.object(["input": value.input])).first
    let label: String
    switch classified {
    case .read: label = formatReadToolLabel(readPath ?? "")
    case .search:
      label = formatSearchToolLabel(value.input.strictRecord.map { ["input": .object($0)] }) ?? value.toolName ?? "Tool call"
    default: label = value.toolName ?? "Tool call"
    }
    entry.label = title ?? label
    entry.toolTitle = title ?? value.toolName ?? "Tool"
  case .approvalRequest(let value):
    entry.label = title ?? "Approval requested"
    entry.detail = value.prompt ?? value.requestKind.rawValue
  case .userInputRequest(let value):
    entry.label = title ?? (value.questionAnswer != nil ? "Answered questions" : "Input requested")
    if let answer = value.questionAnswer { entry.questionAnswer = jsonBridge(answer) }
  default:
    entry.label = title ?? item.typeTag.replacingOccurrences(of: "_", with: " ")
  }
  return entry
}

// MARK: - Judgements and labels

enum V2Work {
  // MARK: Item accessors

  static func dynamicTool(_ entry: WorkLogEntry) -> OrchestrationV2ThreadProjectionTurnItemsItemDynamicTool? {
    if case .dynamicTool(let tool)? = entry.v2?.item { return tool }
    return nil
  }

  /// `workEntryToolName`: structured identity is authoritative.
  static func toolName(_ entry: WorkLogEntry) -> String? {
    if let name = dynamicTool(entry)?.toolName, !name.isEmpty { return name }
    if let title = entry.toolTitle, resolveT3McpToolDefinition(title) != nil { return title }
    return entry.label
  }

  static func toolOutput(_ entry: WorkLogEntry) -> JSONValue? {
    if let tool = dynamicTool(entry) { return tool.output }
    if case .commandExecution(let command)? = entry.v2?.item { return command.output.map { .string($0) } }
    return nil
  }

  /// The `input` a dynamic tool call carries (the web's `toolData.input`).
  static func toolInput(_ entry: WorkLogEntry) -> JSONValue? { dynamicTool(entry)?.input }

  // MARK: Tool-likeness

  /// session-logic `workLogEntryIsToolLike`.
  static func isToolLike(_ entry: WorkLogEntry) -> Bool {
    entry.tone == .tool || entry.tone == .thinking || entry.tone == .error || entry.command != nil || entry.requestKind != nil
  }

  /// presentation.ts `workLogEntryIsToolLike`.
  static func presentationIsToolLike(_ entry: WorkLogEntry) -> Bool {
    if entry.tone == .tool || entry.tone == .thinking || entry.tone == .error { return true }
    if let command = entry.command, !command.jsTrimmed.isEmpty { return true }
    if entry.requestKind != nil { return true }
    return ["command_execution", "file_change", "web_search"].contains(entry.v2Type ?? "")
  }

  // MARK: Failure and success

  static func indicatesToolFailure(_ entry: WorkLogEntry, includeCommand: Bool) -> Bool {
    if entry.tone == .error || entry.toolLifecycleStatus == .failed || entry.toolLifecycleStatus == .declined { return true }
    if !presentationIsToolLike(entry) { return false }
    if resolveT3McpToolDefinition(toolName(entry)) != nil && t3ToolResultIndicatesFailure(toolOutput(entry)) { return true }
    if case .commandExecution(let command)? = entry.v2?.item {
      if command.outputIndicatesFailure == true || (command.exitCode != nil && command.exitCode != 0) { return true }
      // Older servers/caches can still carry output; read only the preview-sized prefix for status.
      if let output = command.output, !output.isEmpty, toolOutputIndicatesFailure(output.jsSlice(0, 32_768)) { return true }
    }
    let output =
      includeCommand
      ? [entry.detail, entry.command].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
      : (entry.detail ?? "")
    return !output.isEmpty && toolOutputIndicatesFailure(output)
  }

  /// session-logic `workEntryIndicatesToolSuccess`.
  static func indicatesToolSuccess(_ entry: WorkLogEntry) -> Bool {
    if !isToolLike(entry) || indicatesToolFailure(entry, includeCommand: true) || (entry.tone == .thinking && entry.v2Type != "reasoning") { return false }
    switch entry.toolLifecycleStatus {
    case .failed?, .declined?, .inProgress?, .stopped?, .idle?: return false
    default: return true
    }
  }

  /// session-logic `workEntryIndicatesToolNeutralStatus`.
  static func indicatesNeutralStatus(_ entry: WorkLogEntry) -> Bool {
    isToolLike(entry) && !indicatesToolFailure(entry, includeCommand: true) && !indicatesToolSuccess(entry)
  }

  static func isVisibleInGroup(_ entry: WorkLogEntry, expandedToolGroupEntry: Bool) -> Bool {
    if entry.v2Type == "reasoning" { return !(entry.detail?.jsTrimmed ?? "").isEmpty }
    return (expandedToolGroupEntry && (entry.toolLifecycleStatus == .inProgress || entry.sourceActivityKind == "task.progress"))
      // A stopped call is an outcome ("Stopped sleep"), not an empty row.
      || entry.toolLifecycleStatus == .stopped || !indicatesNeutralStatus(entry)
  }

  // MARK: T3 tool presentation

  static func toolPresentation(_ entry: WorkLogEntry, fallbackStatus: ToolLifecycleStatus? = nil) -> ToolPresentation? {
    guard let definition = resolveT3McpToolDefinition(toolName(entry)) else { return nil }
    let status = t3ToolResultIndicatesFailure(toolOutput(entry)) ? "failed" : (entry.toolLifecycleStatus ?? fallbackStatus)?.rawValue
    let verb: String =
      switch status {
      case "inProgress": definition.labels.running
      case "completed": definition.labels.completed
      case "failed": "Failed to \(definition.labels.action.lowercased())"
      case "declined": "Declined to \(definition.labels.action.lowercased())"
      case "stopped": "Stopped \(definition.labels.running.lowercased())"
      default: definition.labels.running
      }
    let prActions: Set<String> = ["link-pr", "unlink-pr", "list-prs", "watch-pr", "unwatch-pr"]
    let action = prActions.contains(definition.summaryAction) ? ToolGroupAction(rawValue: definition.summaryAction) : nil
    let input = toolInput(entry).strictRecord
    let urlNumber = input?["url"]?.stringOrNil.flatMap { parseChangeRequestNumber($0) }
    let number: Int? =
      urlNumber
      ?? input?["number"].flatMap { value -> Int? in
        guard let double = value.finiteNumber, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
      }
    let target: String
    if let action, action != .listPRs, let number, number > 0 { target = "PR #\(number)" } else { target = definition.labels.detail }
    return ToolPresentation(displayName: "\(verb) \(target)", icon: definition.icon, action: action)
  }

  // MARK: Grouping

  private static func isLocalCodeSearch(_ entry: WorkLogEntry) -> Bool {
    entry.v2Type == "file_search"
      || (entry.v2Type == "web_search" && normalizeCompactToolLabel(entry.toolTitle ?? entry.label).matches("\\bgrep\\b", caseInsensitive: true))
  }

  static func toolGroupAction(_ entry: WorkLogEntry) -> ToolGroupAction {
    let type = entry.v2Type
    if type == "thread_created" { return .threadCreate }
    let presentation = toolPresentation(entry)
    if let action = presentation?.action { return action }
    if presentation?.icon == .browser { return .browser }
    if presentation?.icon == .device { return .device }
    if entry.requestKind == .fileRead || entry.viewedImagePath != nil { return .read }
    // Approvals and questions describe requested work, not work that ran.
    if type == "approval_request" || type == "user_input_request" { return presentationIsToolLike(entry) ? .other : .update }
    let toolName: String? = dynamicTool(entry) != nil ? dynamicTool(entry)!.toolName : entry.toolTitle
    let classifyType: String? =
      switch type {
      case "command_execution", "file_change", "web_search": type
      case "dynamic_tool": "dynamic_tool_call"
      default: nil
      }
    let classified = classifyToolActivity(itemType: classifyType, toolName: toolName.flatMap { $0.isEmpty ? nil : $0 })
    if classified == .read { return .read }
    if classified == .fileChange || type == "file_change" { return .edit }
    if classified == .command || type == "command_execution" || !(entry.command ?? "").isEmpty { return .command }
    if classified == .search { return type == "web_search" && !isLocalCodeSearch(entry) ? .search : .codeSearch }
    if isLocalCodeSearch(entry) { return .codeSearch }
    if type == "web_search" { return .search }
    if (entry.changedFiles?.count ?? 0) > 0 { return .edit }
    return presentationIsToolLike(entry) ? .other : .update
  }

  private static func summaryActionPriority(_ action: String) -> Int {
    switch action {
    case "command", "edit", "delegate", "task-cancel", "thread-create", "thread-send", "thread-interrupt", "schedule-create", "schedule-update",
      "schedule-delete", "schedule-run", "thread-configure", "thread-fork", "thread-merge", "thread-organize", "thread-update", "queue-edit",
      "queue-cancel", "queue-reorder", "queue-steer", "question-respond", "worktree-handoff", "project-create", "project-update", "project-delete",
      "project-clone", "environment-update", "attachment-prepare", "attachment-discard", "attachment-send":
      0
    case "other", "update": 2
    default: 1
    }
  }

  private static func t3SummaryCall(_ entry: WorkLogEntry) -> T3ToolSummaryCall {
    let outcome: T3ToolSummaryCall.Outcome =
      entry.toolLifecycleStatus == .failed || entry.toolLifecycleStatus == .declined || entry.tone == .error
      ? .failed : (entry.toolLifecycleStatus == .completed ? .completed : .unfinished)
    return T3ToolSummaryCall(input: toolInput(entry), output: toolOutput(entry), outcome: outcome)
  }

  /// Summarizes at most two action categories; every omitted call still counts in the remainder.
  static func summarizeToolGroup(_ allEntries: [WorkLogEntry]) -> (summary: String, hasFailure: Bool) {
    let toolEntries = allEntries.filter { $0.v2Type != "reasoning" }
    if !allEntries.isEmpty && toolEntries.isEmpty {
      return (allEntries.count == 1 ? "Thought" : "Thought (\u{00D7}\(allEntries.count))", false)
    }
    struct Group {
      var action: ToolGroupAction
      var t3Action: String?
      var entries: [WorkLogEntry]
    }
    var order: [String] = []
    var groups: [String: Group] = [:]
    var sources: [(key: String, source: ToolActivitySource)] = []
    for entry in toolEntries {
      let t3Action = resolveT3McpToolDefinition(toolName(entry))?.summaryAction
      if let source = entry.toolSource, t3Action == nil {
        if let index = sources.firstIndex(where: { $0.key == source.key }) { sources[index] = (source.key, source) } else { sources.append((source.key, source)) }
        continue
      }
      let action = toolGroupAction(entry)
      let key = t3Action ?? action.rawValue
      if groups[key] != nil {
        groups[key]!.entries.append(entry)
      } else {
        groups[key] = Group(action: action, t3Action: t3Action, entries: [entry])
        order.append(key)
      }
    }
    struct Summary {
      var index: Int
      var count: Int
      var priority: Int
      var label: String
      var failedCount: Int
    }
    let summaries = order.enumerated().map { index, key -> Summary in
      let group = groups[key]!
      if let t3 = group.t3Action {
        let result = summarizeT3ToolCalls(t3, group.entries.map(t3SummaryCall))
        return Summary(index: index, count: group.entries.count, priority: summaryActionPriority(key), label: result.label, failedCount: result.failedCount)
      }
      return Summary(
        index: index, count: group.entries.count, priority: summaryActionPriority(key),
        label: toolGroupActionLabel(group.action, toolGroupActionCount(group.action, group.entries)),
        failedCount: group.entries.filter(workEntryDisplayIndicatesToolFailure).count)
    }
    let selected = summaries.stableSorted { $0.priority != $1.priority ? $0.priority - $1.priority : $0.index - $1.index }
      .prefix(2).sorted { $0.index < $1.index }
    var labels = selected.map(\.label)
    if !sources.isEmpty {
      let values = sources.map(\.source)
      let names = values.map(\.name)
      let formatted =
        names.count < 2 ? names[0] : names.count == 2 ? names.joined(separator: " and ") : "\(names.dropLast().joined(separator: ", ")), and \(names.last!)"
      let allIntegrations = values.allSatisfy { $0.kind == .integration }
      labels.insert("Used \(formatted)\(allIntegrations ? " \(sources.count == 1 ? "integration" : "integrations")" : "")", at: 0)
    }
    let sourcedCount = toolEntries.filter { $0.toolSource != nil && resolveT3McpToolDefinition(toolName($0)) == nil }.count
    let remaining = toolEntries.count - sourcedCount - selected.reduce(0) { $0 + $1.count }
    if remaining > 0 { labels.append("Performed \(remaining) other \(remaining == 1 ? "action" : "actions")") }
    let sentence = labels.enumerated().map { index, label in index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst() }
    let summary: String =
      sentence.count < 3 ? sentence.joined(separator: " and ") : "\(sentence.dropLast().joined(separator: ", ")), and \(sentence.last!)"
    return (summary, summaries.contains { $0.failedCount > 0 })
  }

  static func toolGroupSummaryKind(_ allEntries: [WorkLogEntry]) -> ToolGroupSummaryKind {
    let entries = allEntries.filter { $0.v2Type != "reasoning" }
    if !allEntries.isEmpty && entries.isEmpty { return .reasoning }
    if !entries.isEmpty && entries.allSatisfy({ toolPresentation($0)?.icon == .pullRequest }) { return .pullRequest }
    let actions = Set(entries.map(toolGroupAction))
    if actions.count != 1 { return .mixed }
    let action = actions.first!
    if action != .other { return ToolGroupSummaryKind(action) }
    let fallback = Set(
      entries.map { entry -> ToolGroupSummaryKind in
        if entry.v2Type == "dynamic_tool" { return .dynamicTool }
        if entry.v2Type == "subagent" { return .agentTool }
        if entry.tone == .thinking { return .agentTool }
        if entry.tone == .tool { return .toneTool }
        return .other
      })
    return fallback.count == 1 ? fallback.first! : .mixed
  }

  // MARK: Labels (MessagesTimeline.logic.ts)

  private static func toolDataRecord(_ entry: WorkLogEntry) -> JSObject? {
    // Only a dynamic call keeps a record the label code reads (`{ input, output }`).
    guard let tool = dynamicTool(entry) else { return nil }
    var record: JSObject = ["input": tool.input]
    if let output = tool.output { record["output"] = output }
    return record
  }

  private static func readRawPaths(_ entry: WorkLogEntry) -> [String] {
    if let changed = entry.changedFiles, !changed.isEmpty { return changed }
    if let tool = dynamicTool(entry) {
      let paths = collectToolFilePaths(.object(["input": tool.input]))
      if !paths.isEmpty { return paths }
    }
    if case .fileChange(let change)? = entry.v2?.item {
      var record: JSObject = ["fileName": .string(change.fileName)]
      if let changes = change.changes { record["changes"] = .array(changes.map { .object(["path": .string($0.path)]) }) }
      return collectToolFilePaths(.object(record))
    }
    return collectToolFilePaths(toolDataRecord(entry).map { .object($0) })
  }

  static func displayLabel(_ entry: WorkLogEntry, workspaceRoot: String?) -> String {
    if entry.v2Type == "system_notice" { return entry.label }
    if entry.v2Type == "reasoning" || entry.tone == .thinking {
      let thought = entry.detail?.jsCollapsedWhitespace ?? ""
      return thought.isEmpty ? entry.label : thought
    }
    if let presentation = toolPresentation(entry) { return presentation.displayName }
    if let command = entry.command, !command.jsTrimmed.isEmpty { return commandDisplayText(command) }
    let action = toolGroupAction(entry)
    if action == .codeSearch || action == .search {
      // Adapters title file searches with their target; the item keeps only the pattern.
      let searchLabel = entry.v2Type == "file_search" ? entry.label : formatSearchToolLabel(toolDataRecord(entry))
      if let searchLabel, !searchLabel.isEmpty { return searchLabel }
    }
    let readPaths = action == .read ? readRawPaths(entry).map { formatWorkspaceRelativePath($0, workspaceRoot: workspaceRoot) } : []
    if action == .read, let first = readPaths.first { return formatReadToolLabel(first, extraCount: readPaths.count - 1) }
    // Retrying providers keep their progress label; other diagnostics expose the retained message.
    var providerRetry = false
    if case .error(let error)? = entry.v2?.item, error.retry != nil { providerRetry = true }
    if let tool = dynamicTool(entry), let title = dynamicToolTitle(tool.toolName, tool.input), !title.isEmpty { return title }
    let compactDetail = entry.detail?.jsTrimmed
    let detailIsSearchOutput = (action == .codeSearch || action == .search) && (compactDetail ?? "").contains { $0 == "\n" || $0 == "\r" }
    if let compactDetail, !compactDetail.isEmpty, !providerRetry, action != .read, !detailIsSearchOutput { return compactDetail }
    if let files = entry.changedFiles, let first = files.first, !first.isEmpty {
      let path = formatWorkspaceRelativePath(first, workspaceRoot: workspaceRoot)
      return files.count == 1 ? path : "\(path) +\(files.count - 1) more"
    }
    if action == .read && entry.viewedImagePath == nil { return "Read file" }
    let heading = normalizeCompactToolLabel(nonEmpty(entry.toolTitle) ?? entry.label)
    return heading.jsCapitalizedFirst()
  }

  static func liveLabel(_ entry: WorkLogEntry, workspaceRoot: String?, active: Bool) -> String {
    let status = liveActivityToolStatus(entry.toolLifecycleStatus, presentTense: active)
    if entry.v2Type == "reasoning" {
      let thought = entry.detail?.jsCollapsedWhitespace ?? ""
      return thought.isEmpty ? (status == .inProgress ? "Thinking" : "Thought") : thought
    }
    var withStatus = entry
    withStatus.toolLifecycleStatus = status
    if let presentation = toolPresentation(withStatus) { return presentation.displayName }
    if let command = entry.command?.jsTrimmed, !command.isEmpty {
      let verb: String =
        switch status {
        case .inProgress: "Running"
        case .failed: "Failed"
        case .declined: "Declined"
        case .stopped: "Stopped"
        case .completed, .idle: "Ran"
        }
      return "\(verb) \(commandProgramName(command) ?? "command")"
    }
    return displayLabel(entry, workspaceRoot: workspaceRoot)
  }

  /// `singleToolCallLabel`.
  static func singleToolCallLabel(_ entry: WorkLogEntry) -> String {
    if entry.v2Type == "reasoning" {
      let thought = entry.detail?.jsCollapsedWhitespace ?? ""
      return thought.isEmpty ? "Thought" : thought
    }
    if let presentation = toolPresentation(entry, fallbackStatus: .completed) { return presentation.displayName }
    if let tool = dynamicTool(entry), let title = dynamicToolTitle(tool.toolName, tool.input), !title.isEmpty { return title }
    // A lone web search keeps its heading; the query stays in its detail.
    if entry.v2Type == "web_search" { return entry.toolTitle ?? "Web search" }
    return displayLabel(entry, workspaceRoot: nil)
  }
}


/// Plain-text line for the latest thought in the live activity row (`liveThoughtLine`): a
/// bold-only opening line (the Codex summary heading) wins; otherwise the first sentence.
public func liveThoughtLine(_ markdown: String) -> String {
  func regex(_ pattern: String, multiline: Bool = false) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: multiline ? [.anchorsMatchLines] : [])
  }
  func replace(_ pattern: String, _ template: String, in text: String, multiline: Bool = false) -> String {
    regex(pattern, multiline: multiline).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
  }
  let ns = markdown as NSString
  var heading: String?
  if let match = regex("^\\s*\\*\\*([^*\\r\\n]+)\\*\\*[ \\t]*\\r?(?:\\n|$)").firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)) {
    heading = ns.substring(with: match.range(at: 1))
  }
  var text = heading ?? markdown
  text = replace("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1", in: text)
  text = replace("^[ \\t]*(?:#{1,6}|[-*+]|\\d+\\.)[ \\t]+", "", in: text, multiline: true)
  text = replace("`+|\\*\\*|~~", "", in: text)
  text = replace("(^|[^A-Za-z0-9_*])[*_]([^*_\\n]+)[*_](?![A-Za-z0-9_*])", "$1$2", in: text)
  text = text.jsCollapsedWhitespace
  if heading != nil { return text }
  // Cut after the first . ? or ! (plus a closing quote or paren) that a space follows.
  let tail = text as NSString
  if let end = regex("[.?!][\"'\u{201D}\u{2019})]?(?=\\s)").firstMatch(in: text, range: NSRange(location: 0, length: tail.length)) {
    return tail.substring(to: end.range.location + end.range.length)
  }
  return text
}

// MARK: - On-demand item detail (`turnItemNeedsDetailFetch`, `turnItemDetailRevision`, `turnItemHasDetail`)

extension V2WorkItem {
  /// `{ summary, truncated: true }`: what the wire projection leaves of a large dynamic input.
  private static func isSummarized(_ value: JSONValue) -> Bool {
    value["truncated"] == .bool(true) && value["summary"]?.stringValue != nil
  }

  /// True when the timeline withholds content that `orchestration.getTurnItem` returns.
  public var needsDetailFetch: Bool {
    switch item {
    case .commandExecution(let value): value.outputOmitted == true
    case .dynamicTool(let value): value.outputOmitted == true || Self.isSummarized(value.input)
    default: false
    }
  }

  /// Cache key of a fetched item: a running item keeps one key, so an open entry fetches once
  /// while it streams and again when it finishes.
  public var detailRevision: String { item.fields.map(turnItemDetailRevision) ?? "" }

  /// Whether expanding the entry shows anything. Entries without content must not offer a disclosure.
  public var hasDetail: Bool {
    switch item {
    case .commandExecution(let value):
      !value.input.jsTrimmed.isEmpty || value.outputOmitted == true || (value.exitCode ?? 0) != 0
    case .fileChange: true
    case .dynamicTool(let value):
      value.outputOmitted == true || Self.isSummarized(value.input) || value.input != .null && value.input != .object([:])
    default: false
    }
  }
}
