import Foundation
import T3Contracts

// toolActivity.ts, toolOutput.ts and t3ToolSummary.ts of the web, over `JSONValue`.

// MARK: - Classification and labels (toolActivity.ts)

private func trimmed(_ value: JSONValue?) -> String? { value.trimmedString }

enum ToolActivityAction: String {
  case command, read, fileChange = "file_change", search, other
}

private func toolNameToken(_ value: String?) -> String? {
  guard let trimmed = value?.jsTrimmed, !trimmed.isEmpty else { return nil }
  // Server-prefixed MCP names (`github.read_file`, `mcp__db__find`) are not local reads or searches.
  if trimmed.matches("__|[./]") { return nil }
  let regex = RegexCache.shared.regex("[_\\s-]")
  return regex.stringByReplacingMatches(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length), withTemplate: "").lowercased()
}

/// `classifyToolActivity`. `kind` and the tool name come from the entry's structured data, which
/// protocol-2 items never carry as `kind`; only the tool name path is live.
func classifyToolActivity(itemType: String?, requestKind: String? = nil, kind: String? = nil, toolName rawToolName: String?) -> ToolActivityAction {
  let requestKind = requestKind?.jsTrimmed.lowercased().nilIfEmpty
  let kind = kind?.jsTrimmed.lowercased().nilIfEmpty
  let toolName = toolNameToken(rawToolName.flatMap { $0.jsTrimmed.isEmpty ? nil : $0.jsTrimmed })
  switch itemType {
  case "command_execution": return .command
  case "image_view": return .read
  case "file_change": return .fileChange
  case "web_search": return .search
  default: break
  }
  if requestKind == "command" || kind == "execute" { return .command }
  if requestKind == "file-change" || ["edit", "move", "delete", "write"].contains(kind ?? "") { return .fileChange }
  if kind == "search" || ["find", "grep", "glob", "rg", "ls"].contains(toolName ?? "") { return .search }
  if requestKind == "file-read" || kind == "read" { return .read }
  if ["terminal", "bash", "shell"].contains(toolName ?? "") { return .command }
  if ["read", "readfile"].contains(toolName ?? "") { return .read }
  return .other
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

private let pathKeys = ["path", "filePath", "file_path", "relativePath", "filename", "fileName", "newPath", "oldPath"]

private func collectPaths(_ value: JSONValue?, _ paths: inout [String], _ seen: inout Set<String>, _ depth: Int) {
  if depth > 4 || paths.count >= 8 { return }
  if case .array(let entries)? = value {
    for entry in entries {
      collectPaths(entry, &paths, &seen, depth + 1)
      if paths.count >= 8 { return }
    }
    return
  }
  guard let record = value.strictRecord else { return }
  for key in pathKeys {
    guard let candidate = trimmed(record[key]), !seen.contains(candidate) else { continue }
    seen.insert(candidate)
    paths.append(candidate)
    if paths.count >= 8 { return }
  }
  for nested in ["locations", "item", "input", "result", "rawInput", "data", "changes"] {
    guard let child = record[nested] else { continue }
    collectPaths(child, &paths, &seen, depth + 1)
    if paths.count >= 8 { return }
  }
}

/// Structured paths from tool input, never file-body text.
func collectToolFilePaths(_ data: JSONValue?) -> [String] {
  var paths: [String] = []
  var seen = Set<String>()
  collectPaths(data, &paths, &seen, 0)
  return paths
}

private let searchQueryKeys = ["pattern", "query", "searchTerm", "regex", "grep", "needle"]
private let searchGlobKeys = ["glob", "globPattern", "glob_pattern", "include", "filePattern", "file_pattern"]
private let searchTargetKeys = ["path", "target_directory", "targetDirectory", "directory", "cwd", "root"]

private func firstInputString(_ record: JSObject?, _ keys: [String]) -> String? {
  guard let record else { return nil }
  for key in keys { if let value = trimmed(record[key]) { return value } }
  return nil
}

private func searchInputRecord(_ data: JSObject?) -> JSObject? {
  let candidates = [data?["rawInput"], data?["input"], data?["item"].strictRecord?["input"]]
  for candidate in candidates {
    if let record = candidate.strictRecord, !record.isEmpty { return record }
  }
  return data
}

/// Cursor-style row: "Searched files *.{ts,tsx} in t3chat-new".
func formatSearchToolLabel(_ data: JSObject?) -> String? {
  let input = searchInputRecord(data)
  let query = firstInputString(input, searchQueryKeys)
  let glob = firstInputString(input, searchGlobKeys)
  let target = firstInputString(input, searchTargetKeys).flatMap { value -> String? in
    value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { !$0.isEmpty && $0 != "." }.map(String.init)
  }
  if let query, let target { return "Searched \(query) in \(target)" }
  if let glob, let target { return "Searched files \(glob) in \(target)" }
  if let glob { return "Searched files \(glob)" }
  if let query { return "Searched \(query)" }
  if let target { return "Searched in \(target)" }
  return nil
}

/// Work-log heading for a file read: verb plus the structured path, never the path alone.
func formatReadToolLabel(_ path: String, extraCount: Int = 0) -> String {
  let trimmedPath = path.jsTrimmed
  let suffix = extraCount > 0 ? " +\(extraCount) more" : ""
  return trimmedPath.isEmpty ? "Read file\(suffix)" : "Read \(trimmedPath)\(suffix)"
}

/// Activity heading a dynamic tool derives from its input: CUA's `title`, or the skill a Claude
/// `Skill` call loads.
func dynamicToolTitle(_ toolName: String?, _ input: JSONValue?) -> String? {
  if toolName == "cua_repl.js" { return trimmed(input.strictRecord?["title"]) }
  if toolName == "Skill", let skill = trimmed(input.strictRecord?["skill"]) { return "Skill: \(skill)" }
  return nil
}

// MARK: - Failure text (toolOutput.ts)

func toolOutputIndicatesFailure(_ text: String) -> Bool {
  text.matches(
    "file not found|no files found|enoent|no such file|commandnotfoundexception|command not found|is not recognized as the name of a cmdlet|a parameter cannot be found that matches parameter name",
    caseInsensitive: true)
    || (text.matches("cannot find path", caseInsensitive: true) && text.matches("because it does not exist", caseInsensitive: true))
    || (text.matches("is not recognized", caseInsensitive: true) && text.matches("the term '", caseInsensitive: true))
    || text.matches("<exited with exit code\\s+[1-9]\\d*\\s*>", caseInsensitive: true)
    || text.matches("exit(?:ed)? with exit code\\s+[1-9]\\d*", caseInsensitive: true)
    || text.matches("exit code\\s*[:\\s]\\s*[1-9]\\d*\\b", caseInsensitive: true)
}

// MARK: - Compact dynamic tool output (toolOutput.ts)

/// The page a completed `html_render` call published (`HtmlRenderReference`).
public struct HtmlRenderReference: Sendable, Hashable {
  public var attachmentId: String
  public var title: String
  public var height: Int
}

/// An MCP App a completed tool call captured (`McpAppReference`, without its CSP details).
public struct McpAppReference: Sendable, Hashable {
  public var attachmentId: String
  public var server: String
  public var tool: String
  public var resourceUri: String
  public var prefersBorder: Bool?
}

struct CompactToolOutput {
  var isError = false
  var taskId: String?
  var htmlRender: HtmlRenderReference?
  var mcpApp: McpAppReference?
}

private final class ResultBudget {
  var remainingBytes = 16_384
  var remainingNodes = 128
  var exceeded = false
}

private struct ResultEnvelope {
  var data: JSObject?
  var failed: Bool
}

/// `value ?? fallback` treats null like undefined.
private func nn(_ value: JSONValue?) -> JSONValue? { value.flatMap { $0.isNullish ? nil : $0 } }

private func parseJSON(_ text: String) -> JSONValue? {
  guard let data = text.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(JSONValue.self, from: data)
}

private func readEnvelope(_ value: JSONValue?, _ budget: ResultBudget, _ depth: Int = 0) -> ResultEnvelope {
  budget.remainingNodes -= 1
  if depth > 4 || budget.remainingNodes < 0 {
    budget.exceeded = true
    return ResultEnvelope(data: nil, failed: false)
  }
  switch value {
  case .string(let text)?:
    let bytes = text.utf8.count
    if text.utf16Length > budget.remainingBytes || bytes > budget.remainingBytes {
      budget.exceeded = true
      return ResultEnvelope(data: nil, failed: false)
    }
    budget.remainingBytes -= bytes
    guard let parsed = parseJSON(text) else { return ResultEnvelope(data: nil, failed: false) }
    return readEnvelope(parsed, budget, depth + 1)
  case .array(let blocks)?:
    if blocks.count > 32 {
      budget.exceeded = true
      return ResultEnvelope(data: nil, failed: false)
    }
    var data: JSObject?
    var failed = false
    for block in blocks {
      // `Predicate.isObject` is true for arrays too, whose `.text` is undefined.
      let text: JSONValue? = block.looseRecord?["text"]
      let inner: JSONValue? = text.looseRecord.map { nn($0["text"]) ?? text } ?? text
      let result = readEnvelope(inner, budget, depth + 1)
      if data == nil { data = result.data }
      failed = failed || result.failed
      if budget.exceeded { break }
    }
    return ResultEnvelope(data: data, failed: failed)
  case .object(let record)?:
    let failed =
      record["isError"] == .bool(true) || record["is_error"] == .bool(true)
      || record["_tag"]?.stringOrNil == "OrchestratorMcpFailure" || (record["error"].map { !$0.isNullish } ?? false)
    let content = record["structuredContent"] ?? record["content"]
    if let content {
      let nested = readEnvelope(content, budget, depth + 1)
      return ResultEnvelope(data: nested.data, failed: failed || nested.failed)
    }
    return ResultEnvelope(data: record, failed: failed)
  default:
    return ResultEnvelope(data: nil, failed: false)
  }
}

private func boundedName(_ value: JSONValue?) -> String? {
  guard let text = value.stringOrNil, !text.jsTrimmed.isEmpty, text.utf16Length <= 256 else { return nil }
  return text
}

private func readHtmlRenderReference(_ value: JSONValue?) -> HtmlRenderReference? {
  guard let record = value.strictRecord, let attachmentId = record["attachmentId"]?.stringOrNil, !attachmentId.isEmpty, attachmentId.utf16Length <= 256,
    let title = record["title"]?.stringOrNil, let height = record["height"].finiteNumber
  else { return nil }
  let clamped = Int(min(2000, max(80, jsRound(height))))
  return HtmlRenderReference(attachmentId: attachmentId, title: String(title.jsTrimmed.jsSlice(0, 200)).nonEmpty ?? "HTML", height: clamped)
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

private func readMcpAppReference(_ value: JSONValue?) -> McpAppReference? {
  guard let record = value.strictRecord, let attachmentId = boundedName(record["attachmentId"]), let server = boundedName(record["server"]),
    let tool = boundedName(record["tool"]), let uri = record["resourceUri"]?.stringOrNil, uri.utf16Length <= 4096, uri.hasPrefix("ui://")
  else { return nil }
  return McpAppReference(attachmentId: attachmentId, server: server, tool: tool, resourceUri: uri, prefersBorder: record["prefersBorder"]?.boolOrNil)
}

/// Keeps only IDs and failure metadata used by T3's grouped summaries and published pages.
// ponytail: the wire compaction also drops oversized thread lists and CSP details to stay under 8 KB;
// none of that is read here, so the size guard is not ported.
func compactDynamicToolOutput(_ value: JSONValue?) -> CompactToolOutput? {
  let budget = ResultBudget()
  let result = readEnvelope(value, budget)
  var output = CompactToolOutput(isError: result.failed)
  if !budget.exceeded, let data = result.data {
    output.taskId = data["taskId"].flatMap { v -> String? in
      guard let id = v.stringOrNil, id.utf16Length <= 256, !id.jsTrimmed.isEmpty else { return nil }
      return id
    }
    output.htmlRender = readHtmlRenderReference(data["htmlRender"])
    output.mcpApp = readMcpAppReference(data["t3McpApp"])
  }
  if !output.isError && output.taskId == nil && output.htmlRender == nil && output.mcpApp == nil { return nil }
  return output
}

/// The page a completed `html_render` tool call published, if this item is one.
func htmlRenderFromToolItem(toolName: String?, output: JSONValue?) -> HtmlRenderReference? {
  guard resolveT3McpToolId(toolName) == "html_render" else { return nil }
  let compact = compactDynamicToolOutput(output)
  return compact?.isError == true ? nil : compact?.htmlRender
}

/// The MCP App a completed tool call carries. The reference only counts when it names the very
/// server and tool the item records.
func mcpAppFromToolItem(toolName: String?, output: JSONValue?) -> McpAppReference? {
  guard let app = compactDynamicToolOutput(output)?.mcpApp, toolName == "\(app.server).\(app.tool)" else { return nil }
  return app
}

// MARK: - Grouped T3 tool summaries (t3ToolSummary.ts)

struct T3ToolSummaryCall {
  enum Outcome { case completed, failed, unfinished }
  var input: JSONValue?
  var output: JSONValue?
  var outcome: Outcome
}

private struct SummaryResult {
  var data: JSObject?
  var failed: Bool
}

private func readSummaryResult(_ value: JSONValue?, _ depth: Int = 0) -> SummaryResult {
  if depth > 4 { return SummaryResult(data: nil, failed: false) }
  switch value {
  case .string(let text)?:
    guard let parsed = parseJSON(text) else { return SummaryResult(data: nil, failed: false) }
    return readSummaryResult(parsed, depth + 1)
  case .array(let blocks)?:
    var data: JSObject?
    var failed = false
    for block in blocks {
      let record = block.strictRecord
      let text: JSONValue? = nn(record?["text"]) ?? record?["content"].strictRecord?["text"]
      let inner: JSONValue? = nn(text.strictRecord?["text"]) ?? text
      let result = readSummaryResult(inner, depth + 1)
      if data == nil { data = result.data }
      failed = failed || result.failed
    }
    return SummaryResult(data: data, failed: failed)
  case .object(let record)?:
    var failed = record["isError"] == .bool(true) || record["is_error"] == .bool(true) || (record["error"].map { !$0.isNullish } ?? false)
    if let tag = record["_tag"]?.stringOrNil, tag.matches("(?:Error|Failure)$") { failed = true }
    let content = record["structuredContent"] ?? record["content"]
    if let content {
      let result = readSummaryResult(content, depth + 1)
      return SummaryResult(data: result.data, failed: failed || result.failed)
    }
    return SummaryResult(data: record, failed: failed)
  default:
    return SummaryResult(data: nil, failed: false)
  }
}

private func readSummaryInput(_ value: JSONValue?) -> JSObject? {
  let input = readSummaryResult(value).data
  // Cursor retains its MCP args envelope; other adapters retain the arguments directly.
  if let input, input["toolName"]?.stringOrNil != nil { return input["args"].strictRecord }
  return input
}

/// MCP errors can be returned as data even when the provider completed the tool call.
func t3ToolResultIndicatesFailure(_ output: JSONValue?) -> Bool { readSummaryResult(output).failed }

private func entityId(_ value: JSONValue?) -> String? {
  guard let text = value.stringOrNil, text.jsTrimmed != "" else { return nil }
  return text
}

private func countEntities(_ ids: [String?]) -> Int { Set(ids.compactMap { $0 }).count + ids.filter { $0 == nil }.count }

private func quantity(_ count: Int, _ noun: String, plural: String? = nil) -> String {
  "\(count) \(count == 1 ? noun : (plural ?? "\(noun)s"))"
}

/// Counts successful effects separately from failed or unfinished tool calls.
func summarizeT3ToolCalls(_ action: String, _ calls: [T3ToolSummaryCall]) -> (label: String, failedCount: Int) {
  struct Resolved {
    var input: JSObject?
    var output: JSObject?
    var outcome: T3ToolSummaryCall.Outcome
  }
  let results = calls.map { call -> Resolved in
    let result = readSummaryResult(call.output)
    return Resolved(input: readSummaryInput(call.input), output: result.data, outcome: result.failed ? .failed : call.outcome)
  }
  let completed = results.filter { $0.outcome == .completed }
  let failedCount = results.filter { $0.outcome == .failed }.count
  let selected = completed.isEmpty ? results : completed
  let times = quantity(selected.count, "time")
  func phrase(_ past: String, _ infinitive: String, _ object: String) -> String {
    "\(completed.isEmpty ? "Tried to \(infinitive)" : past) \(object)"
  }
  func entityIds(_ key: String) -> [String?] { selected.map { entityId($0.output?[key]) ?? entityId($0.input?[key]) } }
  let projectIds: [String?] = selected.map { entityId($0.output?["id"]) ?? entityId($0.output?["projectId"]) ?? entityId($0.input?["projectId"]) }
  let threadIds: [String?] = selected.map {
    entityId($0.output?["threadId"]) ?? entityId($0.output?["thread"].strictRecord?["threadId"]) ?? entityId($0.input?["threadId"])
  }
  let label: String
  switch action {
  case "thread-send":
    let messages = countEntities(selected.map { entityId($0.output?["messageId"]) })
    let targetsKnown = threadIds.allSatisfy { $0 != nil }
    let threads = Set(threadIds.map { $0 ?? "" }).count
    let object: String =
      targetsKnown
      ? (messages == threads && messages > 1 ? "messages to \(quantity(threads, "thread"))" : "\(quantity(messages, "message")) to \(quantity(threads, "thread"))")
      : quantity(messages, "message")
    label = phrase("Sent", "send", object)
  case "thread-create":
    var createdIds: [String] = []
    let resultsKnown =
      !completed.isEmpty
      && completed.allSatisfy { call in
        let threads: [JSONValue] = call.output?["threads"].arrayOrNil ?? [call.output.map { .object($0) } ?? .null]
        return threads.allSatisfy { thread in
          let record = thread.strictRecord
          if record?["status"]?.stringOrNil == "rolled_back" { return true }
          guard let threadId = entityId(record?["threadId"]) else { return false }
          createdIds.append(threadId)
          return true
        }
      }
    label = resultsKnown ? "Created \(quantity(Set(createdIds).count, "thread"))" : "Requested thread creation \(times)"
  case "delegate": label = phrase("Delegated", "delegate", quantity(countEntities(entityIds("taskId")), "task"))
  case "thread-read", "thread-wait":
    let targets = threadIds.allSatisfy { $0 != nil } ? quantity(Set(threadIds.map { $0 ?? "" }).count, "thread") : "threads \(times)"
    label = action == "thread-read" ? phrase("Read", "read", targets) : phrase("Waited on", "wait on", targets)
  case "thread-list": label = phrase("Listed", "list", "threads \(times)")
  case "thread-interrupt": label = phrase("Requested interrupts for", "interrupt", quantity(countEntities(threadIds), "thread"))
  case "task-status": label = phrase("Checked", "check", "task status \(times)")
  case "task-cancel": label = phrase("Requested cancellation of", "cancel", quantity(countEntities(entityIds("taskId")), "task"))
  case "schedule-create": label = phrase("Scheduled", "schedule", quantity(countEntities(entityIds("scheduledTaskId")), "task"))
  case "schedule-list": label = phrase("Listed", "list", "scheduled tasks \(times)")
  case "schedule-update": label = phrase("Updated", "update", quantity(countEntities(entityIds("scheduledTaskId")), "scheduled task"))
  case "schedule-delete": label = phrase("Requested deletion of", "delete", quantity(countEntities(entityIds("scheduledTaskId")), "scheduled task"))
  case "schedule-run": label = phrase("Requested", "request", quantity(selected.count, "scheduled task run"))
  case "thread-configuration": label = phrase("Checked", "check", "thread configuration \(times)")
  case "thread-configure": label = phrase("Set", "set", "thread model \(times)")
  case "thread-fork": label = phrase("Requested", "request", quantity(selected.count, "thread fork"))
  case "thread-merge": label = phrase("Requested", "request", quantity(selected.count, "context merge"))
  case "thread-search": label = phrase("Searched", "search", "threads \(times)")
  case "thread-transfers": label = phrase("Checked", "check", "thread transfers \(times)")
  case "thread-organize": label = phrase("Organized", "organize", "threads \(times)")
  case "thread-update": label = phrase("Updated", "update", quantity(countEntities(threadIds), "thread"))
  case "queue-list": label = phrase("Listed", "list", "queued messages \(times)")
  case "queue-read": label = phrase("Read", "read", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
  case "queue-edit": label = phrase("Edited", "edit", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
  case "queue-cancel": label = phrase("Requested cancellation of", "cancel", quantity(countEntities(entityIds("queuedRunId")), "queued run"))
  case "queue-reorder": label = phrase("Reordered", "reorder", quantity(countEntities(entityIds("queuedRunId")), "queued run"))
  case "queue-steer": label = phrase("Requested steering with", "steer with", quantity(countEntities(entityIds("queuedRunId")), "queued message"))
  case "question-list": label = phrase("Listed", "list", "pending questions \(times)")
  case "question-read": label = phrase("Read", "read", quantity(countEntities(entityIds("requestId")), "pending question request"))
  case "question-respond": label = phrase("Answered", "answer", quantity(countEntities(entityIds("requestId")), "pending question request"))
  case "secret-request": label = phrase("Asked for", "ask for", quantity(selected.count, "secret"))
  case "worktree-handoff": label = phrase("Handed off to", "hand off to", quantity(countEntities(entityIds("worktreePath")), "worktree"))
  case "worktree-list": label = phrase("Listed", "list", "workspace branches \(times)")
  case "worktree-status": label = phrase("Checked", "check", "worktree status \(times)")
  case "project-list": label = phrase("Listed", "list", "projects \(times)")
  case "project-read": label = phrase("Read", "read", quantity(countEntities(projectIds), "project"))
  case "project-create": label = phrase("Registered", "register", quantity(countEntities(projectIds), "project"))
  case "project-update": label = phrase("Updated", "update", quantity(countEntities(projectIds), "project"))
  case "project-delete": label = phrase("Deleted", "delete", quantity(countEntities(projectIds), "project"))
  case "project-clone": label = phrase("Cloned", "clone", quantity(countEntities(entityIds("cwd")), "repository", plural: "repositories"))
  case "environment-read": label = phrase("Checked", "check", "environment preferences \(times)")
  case "environment-update": label = phrase("Updated", "update", "environment preferences \(times)")
  case "attachment-prepare": label = phrase("Prepared", "prepare", quantity(countEntities(entityIds("attachmentId")), "attachment upload"))
  case "attachment-discard": label = phrase("Discarded", "discard", quantity(countEntities(entityIds("attachmentId")), "pending attachment"))
  case "attachment-send":
    // A message can contain several attachments. Count retries by message identity.
    var messages: [String: Resolved] = [:]
    for (index, call) in selected.enumerated() { messages[entityId(call.output?["messageId"]) ?? "call-\(index)"] = call }
    func attachmentCount(_ call: Resolved) -> Int? { call.input?["attachments"].arrayOrNil?.count }
    let total = messages.values.reduce(0) { $0 + (attachmentCount($1) ?? 0) }
    let countsKnown = messages.values.allSatisfy { (attachmentCount($0) ?? 0) > 0 }
    let targets = threadIds.allSatisfy { $0 != nil } ? " to \(quantity(Set(threadIds.map { $0 ?? "" }).count, "thread"))" : ""
    label = phrase("Sent", "send", countsKnown ? "\(quantity(total, "attachment"))\(targets)" : "attachments\(targets) \(times)")
  case "link-pr": label = phrase("Linked", "link", quantity(selected.count, "pull request"))
  case "unlink-pr": label = phrase("Unlinked", "unlink", quantity(selected.count, "pull request"))
  case "watch-pr": label = phrase("Watching", "watch", quantity(selected.count, "pull request"))
  case "unwatch-pr": label = phrase("Stopped watching", "stop watching", quantity(selected.count, "pull request"))
  case "list-prs": label = phrase("Checked", "check", "linked pull requests\(selected.count == 1 ? "" : " \(times)")")
  case "browser": label = phrase("Used", "use", "browser \(times)")
  case "device": label = phrase("Used", "use", "device controls \(times)")
  case "html-preview": label = phrase("Previewed", "preview", quantity(selected.count, "HTML page"))
  case "html-render": label = phrase("Rendered", "render", quantity(selected.count, "HTML page"))
  case "capabilities": label = phrase("Checked", "check", "orchestration capabilities \(times)")
  default: label = ""
  }
  return (label, failedCount)
}
