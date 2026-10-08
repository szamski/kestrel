import Foundation
import T3Contracts

// Port of packages/client-runtime/src/work-log/presentation.ts: how a work-log row is named,
// judged (success/failure) and summarised when several rows fold into one group.

public enum ToolGroupAction: String, Sendable, Hashable {
  case linkPR = "link-pr"
  case unlinkPR = "unlink-pr"
  case listPRs = "list-prs"
  case read
  case edit
  case command
  case browser
  case device
  case codeSearch = "code-search"
  case search
  case other
  case update
}

public enum ToolGroupSummaryKind: String, Sendable, Hashable {
  case pullRequest = "pull-request"
  case linkPR = "link-pr"
  case unlinkPR = "unlink-pr"
  case listPRs = "list-prs"
  case read
  case edit
  case command
  case browser
  case device
  case codeSearch = "code-search"
  case search
  case other
  case update
  case dynamicTool = "dynamic-tool"
  case agentTool = "agent-tool"
  case toneTool = "tone-tool"
  case mixed

  init(_ action: ToolGroupAction) { self = ToolGroupSummaryKind(rawValue: action.rawValue)! }
}

/// A T3 MCP tool call (`link_pull_request`, `preview_open`, ...) rendered as a sentence.
public struct ToolPresentation: Sendable, Hashable {
  public enum Icon: String, Sendable, Hashable {
    case pullRequest = "pull-request"
    case browser
    case device
    case t3Code = "t3-code"
  }

  public var displayName: String
  public var icon: Icon
  public var action: ToolGroupAction?
}

/// Activities the worktree setup card already represents; they never appear as work rows.
func isWorktreeSetupActivity(_ kind: String) -> Bool {
  kind == "setup-script.requested" || kind == "setup-script.started" || kind == "worktree-setup"
}

public func normalizeCompactToolLabel(_ value: String) -> String {
  // value.replace(/\s+(?:complete|completed)\s*$/i, "").trim(): drop a final "complete(d)" word
  // that follows whitespace, together with that whitespace.
  let trimmedEnd = value.jsTrimmedEnd
  let lower = trimmedEnd.lowercased()
  for word in ["completed", "complete"] where lower.hasSuffix(word) {
    let stem = trimmedEnd.unicodeScalars.dropLast(word.unicodeScalars.count)
    if let last = stem.last, isJSWhitespace(last) { return String(String.UnicodeScalarView(stem)).jsTrimmed }
    break
  }
  return value.jsTrimmed
}

private let t3McpToolLabels: [String: (action: String, running: String, completed: String, detail: String)] = [
  "link_pull_request": ("Link", "Linking", "Linked", "a pull request"),
  "unlink_pull_request": ("Unlink", "Unlinking", "Unlinked", "a pull request"),
  "list_thread_pull_requests": ("Check", "Checking", "Checked", "linked pull requests"),
  "orchestrator_capabilities": ("Get", "Getting", "Got", "orchestration capabilities"),
  "delegate_task": ("Delegate", "Delegating", "Delegated", "a child task"),
  "task_status": ("Get", "Getting", "Got", "delegated task status"),
  "task_cancel": ("Cancel", "Canceling", "Canceled", "delegated task"),
  "schedule_task": ("Schedule", "Scheduling", "Scheduled", "a recurring task"),
  "list_scheduled_tasks": ("List", "Listing", "Listed", "scheduled tasks"),
  "update_scheduled_task": ("Update", "Updating", "Updated", "a scheduled task"),
  "delete_scheduled_task": ("Delete", "Deleting", "Deleted", "a scheduled task"),
  "create_threads": ("Create", "Creating", "Created", "T3 threads"),
  "t3_thread_start": ("Start", "Starting", "Started", "a T3 thread"),
  "t3_thread_list": ("List", "Listing", "Listed", "T3 threads"),
  "t3_thread_read": ("Read", "Reading", "Read", "a T3 thread"),
  "t3_thread_send": ("Send", "Sending", "Sent", "to a T3 thread"),
  "t3_thread_wait": ("Wait", "Waiting", "Waited", "for a T3 thread"),
  "t3_thread_interrupt": ("Interrupt", "Interrupting", "Interrupted", "a T3 thread"),
  "t3_worktree_handoff": ("Hand off", "Handing off", "Handed off", "thread to a git worktree"),
  "t3_worktree_status": ("Get", "Getting", "Got", "thread worktree status"),
  "preview_status": ("Get", "Getting", "Got", "preview browser status"),
  "preview_open": ("Open", "Opening", "Opened", "a page in the preview browser"),
  "preview_navigate": ("Navigate", "Navigating", "Navigated", "the preview browser"),
  "preview_snapshot": ("Take a snapshot of", "Taking a snapshot of", "Took a snapshot of", "the preview page"),
  "preview_click": ("Click", "Clicking", "Clicked", "in the preview browser"),
  "preview_press": ("Press", "Pressing", "Pressed", "a key in the preview browser"),
  "preview_type": ("Type", "Typing", "Typed", "in the preview browser"),
  "preview_scroll": ("Scroll", "Scrolling", "Scrolled", "the preview browser"),
  "preview_resize": ("Resize", "Resizing", "Resized", "the preview browser"),
  "preview_evaluate": ("Evaluate", "Evaluating", "Evaluated", "script in the preview browser"),
  "preview_wait_for": ("Wait", "Waiting", "Waited", "for the preview page"),
  "preview_set_appearance": ("Set", "Setting", "Set", "preview browser appearance"),
  "preview_recording_start": ("Start", "Starting", "Started", "recording the preview browser"),
  "preview_recording_stop": ("Stop", "Stopping", "Stopped", "recording the preview browser"),
  "device_list": ("List", "Listing", "Listed", "simulators and emulators"),
  "device_open": ("Open", "Opening", "Opened", "a device in the Device panel"),
  "device_screenshot": ("Take a screenshot of", "Taking a screenshot of", "Took a screenshot of", "the device"),
  "device_close": ("Close", "Closing", "Closed", "a device"),
]

private let prToolActions: [String: ToolGroupAction] = [
  "link_pull_request": .linkPR,
  "unlink_pull_request": .unlinkPR,
  "list_thread_pull_requests": .listPRs,
]

private func resolveT3McpToolPresentation(_ value: String?, status: String?, data: JSONValue?) -> ToolPresentation? {
  guard let value, value.contains("_") else { return nil }  // every T3 tool name has an underscore
  let normalized = normalizeCompactToolLabel(value)
  let regex = RegexCache.shared.regex(
    "^(?:mcp__(?:t3-code|t3_code|t3code)__|(?:t3-code|t3_code|t3code)(?:[.:/]|[\\s\\x{FEFF}]*·[\\s\\x{FEFF}]*))", caseInsensitive: true)
  let name = regex.stringByReplacingMatches(
    in: normalized, range: NSRange(location: 0, length: (normalized as NSString).length), withTemplate: "")
  guard let labels = t3McpToolLabels[name] else { return nil }
  let verb: String =
    switch status {
    case "inProgress": labels.running
    case "completed": labels.completed
    case "failed": "Failed to \(labels.action.lowercased())"
    case "declined": "Declined to \(labels.action.lowercased())"
    case "stopped": "Stopped \(labels.running.lowercased())"
    default: labels.running
    }
  let actionKind = prToolActions[name]
  let payload = data.strictRecord
  let input = payload?["arguments"].strictRecord ?? payload?["input"].strictRecord ?? payload?["rawInput"].strictRecord
  let urlNumber = input?["url"]?.stringOrNil.flatMap { parseChangeRequestNumber($0) }
  let number: Int? = urlNumber ?? input?["number"].flatMap { value in
    guard let double = value.finiteNumber, double == double.rounded(), abs(double) <= 9_007_199_254_740_991 else { return nil }
    return Int(double)
  }
  let target: String
  if let actionKind, actionKind != .listPRs, let number, number > 0 {
    target = "PR #\(number)"
  } else {
    target = labels.detail
  }
  let icon: ToolPresentation.Icon =
    actionKind != nil ? .pullRequest : name.hasPrefix("preview_") ? .browser : name.hasPrefix("device_") ? .device : .t3Code
  return ToolPresentation(displayName: "\(verb) \(target)", icon: icon, action: actionKind)
}

/// Latest live activity stays present-tense unless the call itself failed, declined, or stopped.
public func liveActivityToolStatus(_ status: ToolLifecycleStatus?, presentTense: Bool) -> ToolLifecycleStatus {
  if status == .failed || status == .declined || status == .stopped { return status! }
  if presentTense || status == .inProgress { return .inProgress }
  return .completed
}

/// Resolves tool identity before choosing labels or icons.
public func resolveWorkEntryToolPresentation(
  _ entry: WorkLogEntry,
  fallbackStatus: ToolLifecycleStatus? = nil
) -> ToolPresentation? {
  let status = (entry.toolLifecycleStatus ?? fallbackStatus)?.rawValue
  let data = entry.toolData
  if let data, case .object(let object) = data {
    if let server = object["server"]?.stringOrNil, let tool = object["tool"]?.stringOrNil {
      return resolveT3McpToolPresentation("\(server).\(tool)", status: status, data: data)
    }
    if let toolName = object["toolName"]?.stringOrNil {
      return resolveT3McpToolPresentation(toolName, status: status, data: data)
    }
  }
  return resolveT3McpToolPresentation(entry.toolTitle, status: status, data: data)
    ?? resolveT3McpToolPresentation(entry.label, status: status, data: data)
}

// MARK: - Command output

private func nonEmptyString(_ value: JSONValue?) -> String? {
  guard case .string(let text)? = value, !text.jsTrimmed.isEmpty else { return nil }
  return text
}

private func commandResultContent(_ value: JSONValue?) -> String? {
  if let direct = nonEmptyString(value) { return direct }
  let directContent = value.arrayOrNil
  let record = value.strictRecord
  let content = record?["content"]
  if let contentText = nonEmptyString(content) { return contentText }
  guard let blocks = directContent ?? content.arrayOrNil else { return nil }
  let chunks = blocks.compactMap { entry in nonEmptyString(entry) ?? nonEmptyString(entry.strictRecord?["text"]) }
  return chunks.isEmpty ? nil : chunks.joined(separator: "\n")
}

/// Returns provider command output before it is formatted for a work-log row.
public func extractCommandOutputText(_ dataValue: JSONValue?) -> String? {
  let data = dataValue.strictRecord
  let item = data?["item"].strictRecord
  let itemResult = item?["result"].strictRecord
  let rawOutput = data?["rawOutput"].strictRecord
  let outputStreams = [nonEmptyString(rawOutput?["stdout"]), nonEmptyString(rawOutput?["stderr"])].compactMap { $0 }
  var acpContent: String?
  if let content = data?["content"].arrayOrNil {
    acpContent = content.compactMap { entryValue -> String? in
      let entry = entryValue.strictRecord
      let content = entry?["content"].strictRecord
      return entry?["type"]?.stringOrNil == "content" ? nonEmptyString(content?["text"]) : nil
    }.joined(separator: "\n")
  }
  let candidates: [JSONValue?] = [
    item?["aggregatedOutput"],
    itemResult?["content"],
    data?["rawOutput"],
    rawOutput?["content"],
    outputStreams.isEmpty ? nil : .string(outputStreams.joined(separator: "\n")),
    rawOutput?["output"],
    acpContent.map { .string($0) },
    data?["result"],
  ]
  for candidate in candidates {
    if let text = commandResultContent(candidate) { return text }
  }
  return nil
}

/// Ingestion caps tool details at 180 chars and appends "...", so a long command echo no
/// longer equals the command it repeats. A truncated prefix of the command is the same echo.
private func textRepeatsCommand(_ text: String, _ commands: [String?]) -> Bool {
  let truncated: String? =
    text.hasSuffix("...") ? String(text.dropLast(3)) : text.hasSuffix("\u{2026}") ? String(text.dropLast(1)) : nil
  return commands.contains { candidate in
    guard let command = candidate?.jsTrimmed, !command.isEmpty else { return false }
    if command == text { return true }
    return truncated != nil && !truncated!.isEmpty && command.utf16Length > truncated!.utf16Length
      && command.hasPrefix(truncated!)
  }
}

/// Whether a command row's `detail` is a synthetic echo of the command rather than real output.
public func commandDetailRepeatsCommand(
  detail: String,
  command: String?,
  rawCommand: String?,
  toolName: JSONValue?,
  data: JSONValue?
) -> Bool {
  let toolName = nonEmptyString(toolName)?.jsTrimmed
  let detail = detail.jsTrimmed
  let commands = [command, rawCommand]
  if let toolName {
    let prefix = "\(toolName):"
    if detail.lowercased().hasPrefix(prefix.lowercased()) {
      let unprefixed = detail.jsSlice(prefix.utf16Length).jsTrimmed
      if textRepeatsCommand(unprefixed, commands) { return true }
    }
  }
  if !textRepeatsCommand(detail, commands) { return false }

  let data = data.strictRecord
  let item = data?["item"].strictRecord
  let itemInput = item?["input"].strictRecord
  let itemResult = item?["result"].strictRecord
  let hasStructuredCommand = [item?["command"], itemInput?["command"], itemResult?["command"], data?["command"]].contains {
    value in
    if let parts = value.arrayOrNil { return parts.contains { nonEmptyString($0) != nil } }
    return nonEmptyString(value) != nil
  }
  return !hasStructuredCommand || item != nil || data?["toolCallId"] != nil
    || nonEmptyString(data?["kind"])?.lowercased() == "execute"
}

// MARK: - Status judgement

public func workLogEntryIsToolLike(_ entry: WorkLogEntry) -> Bool {
  if entry.tone == .tool || entry.tone == .thinking || entry.tone == .error { return true }
  if let command = entry.command, !command.jsTrimmed.isEmpty { return true }
  if entry.requestKind != nil { return true }
  return entry.itemType != nil
}

/// Maps item and task status to the status shown on a work-log row.
func extractWorkLogToolLifecycleStatus(_ payload: JSONValue?) -> ToolLifecycleStatus? {
  guard let record = payload.strictRecord, let status = record["status"]?.stringOrNil else { return nil }
  switch status {
  case "pending", "running", "waiting": return .inProgress
  case "cancelled", "interrupted": return .stopped
  case "idle": return record["taskType"]?.stringOrNil == "subagent_batch" ? .stopped : nil
  case "inProgress", "completed", "failed", "declined", "stopped": return ToolLifecycleStatus(rawValue: status)
  default: return nil
  }
}

// Some providers report completion even when the output describes a failure.
private func toolDetailTextLooksLikeFailure(_ text: String) -> Bool {
  let normalized = text.lowercased()
  return normalized.contains("file not found")
    || normalized.contains("no files found")
    || normalized.contains("enoent")
    || normalized.contains("no such file or directory")
    || normalized.contains("no such file")
    || normalized.contains("commandnotfoundexception")
    || normalized.contains("command not found")
    || (normalized.contains("cannot find path") && normalized.contains("because it does not exist"))
    || (normalized.contains("is not recognized") && normalized.contains("the term '"))
    || normalized.contains("is not recognized as the name of a cmdlet")
    || normalized.contains("a parameter cannot be found that matches parameter name")
    // All three exit-code patterns need the word "exit".
    || (normalized.contains("exit")
      && (text.matches("<exited with exit code[\\s]+[1-9][0-9]*[\\s]*>", caseInsensitive: true)
        || text.matches("exit(?:ed)? with exit code[\\s]+[1-9][0-9]*", caseInsensitive: true)
        || text.matches("exit code[\\s]*[:\\s][\\s]*[1-9][0-9]*\\b", caseInsensitive: true)))
}

private func workEntryIndicatesToolFailureFromOutput(_ entry: WorkLogEntry, includeCommand: Bool) -> Bool {
  if entry.tone == .error || entry.toolLifecycleStatus == .failed || entry.toolLifecycleStatus == .declined {
    return true
  }
  if !workLogEntryIsToolLike(entry) { return false }
  let output =
    includeCommand
    ? [entry.detail, entry.command].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    : (entry.detail ?? "")
  return !output.isEmpty && toolDetailTextLooksLikeFailure(output)
}

/// Includes legacy activities that stored error output in the command field.
public func workEntryIndicatesToolFailure(_ entry: WorkLogEntry) -> Bool {
  workEntryIndicatesToolFailureFromOutput(entry, includeCommand: true)
}

/// Checks rendered output without treating the user's command as an error.
public func workEntryDisplayIndicatesToolFailure(_ entry: WorkLogEntry) -> Bool {
  workEntryIndicatesToolFailureFromOutput(entry, includeCommand: false)
}

/// Decides whether the row can show a success marker.
public func workEntryIndicatesToolSuccess(_ entry: WorkLogEntry) -> Bool {
  workLogEntryIsToolLike(entry) && !workEntryIndicatesToolFailure(entry) && entry.tone != .thinking
    && entry.toolLifecycleStatus != .inProgress && entry.toolLifecycleStatus != .stopped
}

/// Tool-like row with neither clear success nor failure (empty, incomplete, in progress, etc.).
public func workEntryIndicatesToolNeutralStatus(_ entry: WorkLogEntry) -> Bool {
  // Spawn CTA rows are never neutral-hidden: mid-run they derive from task.progress (tone
  // "thinking") and the neutral filter would swallow them exactly while the fleet runs.
  if entry.agentSpawn != nil { return false }
  if !workLogEntryIsToolLike(entry) { return false }
  if workEntryIndicatesToolFailure(entry) { return false }
  if workEntryIndicatesToolSuccess(entry) { return false }
  return true
}

/// Severe failures keep the red treatment ordinary tool failures lose: runtime errors and
/// orchestration `*.failed` activities.
public func workEntrySignalsSevereFailure(_ entry: WorkLogEntry) -> Bool {
  entry.sourceActivityKind == "runtime.error" || entry.sourceActivityKind?.hasSuffix(".failed") == true
}

private func workLogEntryIsLocalCodeSearch(_ entry: WorkLogEntry) -> Bool {
  entry.itemType == .webSearch
    && normalizeCompactToolLabel(entry.toolTitle ?? entry.label).matches("\\bgrep\\b", caseInsensitive: true)
}

public func toolGroupAction(_ entry: WorkLogEntry) -> ToolGroupAction {
  switch entry.sourceActivityKind {
  case "approval.requested", "approval.resolved", "provider.approval.respond.failed": return .update
  default: break
  }
  let presentation = resolveWorkEntryToolPresentation(entry)
  if let action = presentation?.action { return action }
  if presentation?.icon == .browser { return .browser }
  if presentation?.icon == .device { return .device }
  if entry.requestKind == .fileRead || entry.itemType == .imageView || entry.viewedImagePath != nil
    || (entry.itemType == .dynamicToolCall && entry.toolTitle?.jsTrimmed.lowercased() == "read file")
  {
    return .read
  }
  if entry.requestKind == .fileChange || entry.itemType == .fileChange || (entry.changedFiles?.count ?? 0) > 0 {
    return .edit
  }
  // `entry.command` is truthy for any non-empty string.
  if entry.requestKind == .command || entry.itemType == .commandExecution || !(entry.command ?? "").isEmpty {
    return .command
  }
  if workLogEntryIsLocalCodeSearch(entry) { return .codeSearch }
  if entry.itemType == .webSearch { return .search }
  return workLogEntryIsToolLike(entry) ? .other : .update
}

private let imagePreviewExtensions = [".avif", ".gif", ".ico", ".jpeg", ".jpg", ".png", ".svg", ".webp"]

func isWorkspaceImagePreviewPath(_ path: String) -> Bool {
  let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? path.endIndex
  let withoutQuery = path[..<end].lowercased()
  return imagePreviewExtensions.contains { withoutQuery.hasSuffix($0) }
}

/// The workspace image a row viewed, if any.
public func workEntryViewedImagePath(_ entry: WorkLogEntry) -> String? {
  func hasLineBreak(_ value: String) -> Bool { value.contains { $0 == "\n" || $0 == "\r" } }
  if let viewed = entry.viewedImagePath?.jsTrimmed, !hasLineBreak(viewed), isWorkspaceImagePreviewPath(viewed) {
    return viewed
  }
  if let detail = entry.detail?.jsTrimmed, toolGroupAction(entry) == .read, !hasLineBreak(detail),
    isWorkspaceImagePreviewPath(detail)
  {
    return detail
  }
  return nil
}

// MARK: - Group summaries

private func toolGroupActionCount(_ action: ToolGroupAction, _ entries: [WorkLogEntry]) -> Int {
  if action != .edit { return entries.count }
  var changedFiles = Set<String>()
  var editsWithoutFileDetails = 0
  for entry in entries {
    guard let files = entry.changedFiles, !files.isEmpty else {
      editsWithoutFileDetails += 1
      continue
    }
    changedFiles.formUnion(files)
  }
  return changedFiles.count + editsWithoutFileDetails
}

private func toolGroupActionLabel(_ action: ToolGroupAction, _ count: Int) -> String {
  func plural(_ one: String, _ many: String) -> String { count == 1 ? one : many }
  switch action {
  case .linkPR: return "Linked \(count) \(plural("pull request", "pull requests"))"
  case .unlinkPR: return "Unlinked \(count) \(plural("pull request", "pull requests"))"
  case .listPRs: return count == 1 ? "Checked linked pull requests" : "Checked linked pull requests \(count) times"
  case .read: return "Read \(count) \(plural("file", "files"))"
  case .edit: return "Changed \(count) \(plural("file", "files"))"
  case .command: return "Ran \(count) \(plural("command", "commands"))"
  case .device: return "Used device controls \(count) \(plural("time", "times"))"
  case .browser: return "Used browser \(count) \(plural("time", "times"))"
  case .search: return "Searched the web \(count) \(plural("time", "times"))"
  case .codeSearch: return "Searched code \(count) \(plural("time", "times"))"
  case .other: return "Used \(count) \(plural("tool", "tools"))"
  case .update: return "Received \(count) \(plural("update", "updates"))"
  }
}

private func joinSentence(_ labels: [String]) -> String {
  switch labels.count {
  case 0: ""
  case 1: labels[0]
  case 2: labels.joined(separator: " and ")
  default: "\(labels.dropLast().joined(separator: ", ")), and \(labels.last!)"
  }
}

public func summarizeToolGroup(_ entries: [WorkLogEntry]) -> String {
  let summaryEntries = omitSupersededLifecycleMarkers(entries) { $0 }
  var sources: [(key: String, source: ToolActivitySource)] = []
  var actionOrder: [ToolGroupAction] = []
  var grouped: [ToolGroupAction: [WorkLogEntry]] = [:]
  for entry in summaryEntries {
    if let source = entry.toolSource, resolveWorkEntryToolPresentation(entry)?.icon != .pullRequest {
      if let index = sources.firstIndex(where: { $0.key == source.key }) {
        sources[index] = (source.key, source)
      } else {
        sources.append((source.key, source))
      }
      continue
    }
    let action = toolGroupAction(entry)
    if grouped[action] == nil { actionOrder.append(action) }
    grouped[action, default: []].append(entry)
  }
  var labels = actionOrder.map { toolGroupActionLabel($0, toolGroupActionCount($0, grouped[$0]!)) }
  if !sources.isEmpty {
    let values = sources.map(\.source)
    let names = values.map(\.name)
    let formattedNames =
      names.count < 2
      ? names[0]
      : names.count == 2 ? names.joined(separator: " and ") : "\(names.dropLast().joined(separator: ", ")), and \(names.last!)"
    let allIntegrations = values.allSatisfy { $0.kind == .integration }
    labels.insert(
      "Used \(formattedNames)\(allIntegrations ? " \(sources.count == 1 ? "integration" : "integrations")" : "")",
      at: 0
    )
  }
  let sentenceLabels = labels.enumerated().map { index, label in
    index == 0 ? label : label.prefix(1).lowercased() + label.dropFirst()
  }
  return joinSentence(sentenceLabels)
}

/// Drops statusless, id-less `tool.started`/`tool.updated` markers once a later terminal row
/// for the same tool exists.
public func omitSupersededLifecycleMarkers<T>(_ entries: [T], workEntryFor: (T) -> WorkLogEntry) -> [T] {
  var laterTerminalIdentities = Set<String>()
  var reversed: [T] = []
  for entry in entries.reversed() {
    let workEntry = workEntryFor(entry)
    let normalizedLabel = normalizeCompactToolLabel(workEntry.toolTitle ?? workEntry.label)
    let identity = [workEntry.turnId?.rawValue ?? "no-turn", workEntry.itemType?.rawValue ?? "", normalizedLabel]
      .joined(separator: "\u{1F}")
    let activityKind = workEntry.sourceActivityKind
    let isStatuslessIdlessMarker =
      workEntry.toolCallId == nil && workEntry.toolLifecycleStatus == nil
      && (activityKind == "tool.started" || activityKind == "tool.updated")
    if isStatuslessIdlessMarker && laterTerminalIdentities.contains(identity) { continue }
    reversed.append(entry)
    if activityKind == "tool.completed" || (workEntry.toolLifecycleStatus != nil && workEntry.toolLifecycleStatus != .inProgress) {
      laterTerminalIdentities.insert(identity)
    }
  }
  return reversed.reversed()
}

public func toolGroupSummaryKind(_ entries: [WorkLogEntry]) -> ToolGroupSummaryKind {
  if !entries.isEmpty && entries.allSatisfy({ resolveWorkEntryToolPresentation($0)?.icon == .pullRequest }) {
    return .pullRequest
  }
  let actions = Set(entries.map(toolGroupAction))
  if actions.count != 1 { return .mixed }
  let action = actions.first!
  if action != .other { return ToolGroupSummaryKind(action) }

  let fallbackKinds = Set(
    entries.map { entry -> ToolGroupSummaryKind in
      if entry.itemType == .mcpToolCall { return .other }
      if entry.itemType == .dynamicToolCall { return .dynamicTool }
      if entry.itemType == .collabAgentToolCall || !(entry.taskId ?? "").isEmpty { return .agentTool }
      if entry.tone == .thinking { return .agentTool }
      if entry.tone == .tool { return .toneTool }
      return .other
    })
  return fallbackKinds.count == 1 ? fallbackKinds.first! : .mixed
}

// MARK: - Change request URLs

/// The pull request number behind a change request URL (`parseChangeRequestUrl().number`).
func parseChangeRequestNumber(_ target: String) -> Int? {
  guard let components = URLComponents(string: target), let scheme = components.scheme?.lowercased(),
    scheme == "https" || scheme == "http", let rawHost = components.host
  else { return nil }
  let host = rawHost.lowercased()
  let path = components.percentEncodedPath

  func isHostOf(_ apex: String, label: String? = nil) -> Bool {
    if host == apex || host.hasSuffix(".\(apex)") { return true }
    return label.map { host.split(separator: ".").contains(Substring($0)) } ?? false
  }
  func number(_ pattern: String) -> Int? {
    let regex = RegexCache.shared.regex(pattern)
    guard let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
      let range = Range(match.range(at: 2), in: path), let value = Int(path[range]), value > 0
    else { return nil }
    return value
  }
  if isHostOf("github.com", label: "github"), let value = number("^/([^/]+/[^/]+)/pull/(\\d+)(?:/|$)") { return value }
  if let value = number("^/([^/]+(?:/[^/]+)+)/pulls/(\\d+)(?:/|$)") { return value }
  if let value = number("^/([^/]+(?:/[^/]+)+)/-/merge_requests/(\\d+)(?:/|$)") { return value }
  if isHostOf("bitbucket.org", label: "bitbucket") { return number("^/([^/]+/[^/]+)/pull-requests/(\\d+)(?:/|$)") }
  if isHostOf("dev.azure.com") || host.hasSuffix(".visualstudio.com") {
    return number("^/((?:[^/]+/)*_git/[^/]+)/pullrequest/(\\d+)(?:/|$)")
  }
  return nil
}
