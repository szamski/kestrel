import Foundation
import T3Contracts

// The command, detail and changed-file extraction of session-logic.ts, working on the
// untyped activity payload exactly like the TypeScript.

/// `stripTrailingExitCode(value).output`: drops a trailing `<exited with exit code N>` marker.
func stripTrailingExitCode(_ value: String) -> String? {
  let trimmed = value.jsTrimmed
  var output = trimmed
  if trimmed.hasSuffix(">"), let marker = trimmed.range(of: "<exited with exit code ", options: [.caseInsensitive, .backwards]) {
    let digits = trimmed[marker.upperBound..<trimmed.index(before: trimmed.endIndex)]
    if !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
      output = String(trimmed[..<marker.lowerBound])
    }
  }
  let normalized = output.jsTrimmed
  return normalized.isEmpty ? nil : normalized
}

private func trimMatchingOuterQuotes(_ value: String) -> String {
  let trimmed = value.jsTrimmed
  if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
    let unquoted = trimmed.jsSlice(1, -1).jsTrimmed
    return unquoted.isEmpty ? trimmed : unquoted
  }
  return trimmed
}

private func executableBasename(_ value: String) -> String? {
  let trimmed = trimMatchingOuterQuotes(value)
  if trimmed.isEmpty { return nil }
  let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
  let last = (normalized.components(separatedBy: "/").last ?? "").jsTrimmed
  return last.isEmpty ? nil : last.lowercased()
}

private func splitExecutableAndRest(_ value: String) -> (executable: String, rest: String)? {
  let trimmed = value.jsTrimmed
  if trimmed.isEmpty { return nil }
  let units = Array(trimmed.utf16)
  if units[0] == 0x22 || units[0] == 0x27 {
    let quote = units[0]
    guard let close = units.dropFirst().firstIndex(of: quote) else { return nil }
    return (
      String(decoding: units[0...close], as: UTF16.self),
      String(decoding: units[(close + 1)...], as: UTF16.self).jsTrimmed
    )
  }
  guard let space = trimmed.unicodeScalars.firstIndex(where: isJSWhitespace) else { return (trimmed, "") }
  return (String(trimmed.unicodeScalars[..<space]), String(trimmed.unicodeScalars[space...]).jsTrimmed)
}

private let shellWrapperSpecs: [(executables: [String], pattern: String)] = [
  (["pwsh", "pwsh.exe", "powershell", "powershell.exe"], "(?:^|\\s)-command\\s+"),
  (["cmd", "cmd.exe"], "(?:^|\\s)/c\\s+"),
  (["bash", "sh", "zsh"], "(?:^|\\s)-(?:l)?c\\s+"),
]

private func unwrapCommandRemainder(_ value: String, pattern: String) -> String? {
  let regex = RegexCache.shared.regex(pattern, caseInsensitive: true)
  let ns = value as NSString
  guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
  let command = ns.substring(from: match.range.location + match.range.length).jsTrimmed
  if command.isEmpty { return nil }
  let opening = command.utf16.first!
  if (opening == 0x27 || opening == 0x22) && command.utf16.last! != opening { return nil }
  let unwrapped = trimMatchingOuterQuotes(command)
  return unwrapped.isEmpty ? nil : unwrapped
}

private func unwrapKnownShellCommandWrapper(_ value: String) -> String {
  guard let split = splitExecutableAndRest(value), !split.rest.isEmpty, let shell = executableBasename(split.executable),
    let spec = shellWrapperSpecs.first(where: { $0.executables.contains(shell) })
  else { return value }
  return unwrapCommandRemainder(split.rest, pattern: spec.pattern) ?? value
}

private func formatCommandArrayPart(_ value: String) -> String {
  let needsQuotes = value.unicodeScalars.contains { isJSWhitespace($0) || $0 == "\"" || $0 == "'" || $0 == "`" }
  return needsQuotes ? "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" : value
}

private func formatCommandValue(_ value: JSONValue?) -> String? {
  if let direct = value.trimmedString { return direct }
  guard let items = value.arrayOrNil else { return nil }
  let parts = items.compactMap { $0.trimmedString }
  return parts.isEmpty ? nil : parts.map(formatCommandArrayPart).joined(separator: " ")
}

private func normalizeCommandValue(_ value: JSONValue?) -> String? {
  formatCommandValue(value).map(unwrapKnownShellCommandWrapper).flatMap { $0.isEmpty ? nil : $0 }
}

struct ToolCommandPreview {
  var command: String?
  var rawCommand: String?
}

func extractToolCommand(_ payload: JSObject?) -> ToolCommandPreview {
  let data = payload?["data"].looseRecord
  let item = data?["item"].looseRecord
  let itemResult = item?["result"].looseRecord
  let itemInput = item?["input"].looseRecord
  let itemType = payload?["itemType"].trimmedString
  let detail = payload?["detail"].trimmedString
  var candidates: [JSONValue?] = [item?["command"], itemInput?["command"], itemResult?["command"], data?["command"]]
  if itemType == "command_execution", let detail, let output = stripTrailingExitCode(detail) {
    candidates.append(.string(output))
  } else {
    candidates.append(nil)
  }
  for candidate in candidates {
    guard let command = normalizeCommandValue(candidate) else { continue }
    let formatted = formatCommandValue(candidate)
    return ToolCommandPreview(command: command, rawCommand: formatted == command ? nil : formatted)
  }
  return ToolCommandPreview()
}

// MARK: - Detail

private func normalizeInlinePreview(_ value: String) -> String { value.jsCollapsedWhitespace }

private func truncateInlinePreview(_ value: String, maxLength: Int = 84) -> String {
  if value.utf16Length <= maxLength { return value }
  return "\(value.jsSlice(0, maxLength - 1).jsTrimmedEnd)…"
}

func normalizePreviewForComparison(_ value: String?) -> String? {
  guard let normalized = value.flatMap({ JSONValue.string($0).trimmedString }) else { return nil }
  return normalizeCompactToolLabel(normalizeInlinePreview(normalized)).lowercased()
}

private func summarizeToolTextOutput(_ value: String) -> String? {
  var lines: [String] = []
  var current = ""
  var pendingCR = false
  func flush() {
    let line = normalizeInlinePreview(current)
    if !line.isEmpty { lines.append(line) }
    current = ""
  }
  // Split on /\r?\n/u.
  for character in value.unicodeScalars {
    if character == "\n" {
      pendingCR = false
      flush()
    } else {
      if pendingCR { current.unicodeScalars.append("\r") }
      pendingCR = character == "\r"
      if !pendingCR { current.unicodeScalars.append(character) }
    }
  }
  if pendingCR { current.unicodeScalars.append("\r") }
  flush()
  if let first = lines.first(where: { $0 != "```" }) { return truncateInlinePreview(first) }
  if lines.count > 1 { return "\(jsLocaleNumber(lines.count)) lines" }
  return nil
}

private func summarizeToolRawOutput(_ payload: JSObject?) -> String? {
  let data = payload?["data"].looseRecord
  guard let rawOutput = data?["rawOutput"].looseRecord else { return nil }
  if let totalFiles = rawOutput["totalFiles"].finiteNumber {
    let suffix = rawOutput["truncated"]?.boolOrNil == true ? "+" : ""
    return "\(jsLocaleNumber(totalFiles)) file\(totalFiles == 1 ? "" : "s")\(suffix)"
  }
  if let content = rawOutput["content"].trimmedString { return summarizeToolTextOutput(content) }
  if let stdout = rawOutput["stdout"].trimmedString { return summarizeToolTextOutput(stdout) }
  return nil
}

private func extractToolOutput(_ payload: JSObject?) -> String? {
  guard let output = extractCommandOutputText(payload?["data"]) else { return nil }
  return stripTrailingExitCode(output)
}

func extractWorkLogItemType(_ payload: JSObject?) -> ToolLifecycleItemType? {
  payload?["itemType"]?.stringOrNil.flatMap { ToolLifecycleItemType(rawValue: $0) }
}

private func isCommandToolDetail(_ payload: JSObject?, heading: String) -> Bool {
  let data = payload?["data"].looseRecord
  let kind = data?["kind"].trimmedString?.lowercased()
  // `asTrimmedString(payload?.title ?? heading)`: a present title shadows the heading.
  let titleSource: JSONValue = payload?["title"].flatMap { $0.isNullish ? nil : $0 } ?? .string(heading)
  let title = titleSource.trimmedString?.lowercased()
  return extractWorkLogItemType(payload) == .commandExecution || kind == "execute" || title == "terminal"
    || title == "ran command"
}

func extractToolDetail(_ payload: JSObject?, heading: String) -> String? {
  let rawDetail = payload?["detail"].trimmedString
  let detail = rawDetail.flatMap { stripTrailingExitCode($0) }
  let normalizedHeading = normalizePreviewForComparison(heading)
  let normalizedDetail = normalizePreviewForComparison(detail)
  let commandTool = isCommandToolDetail(payload, heading: heading)
  let commandPreview = commandTool ? extractToolCommand(payload) : ToolCommandPreview()
  let command = commandPreview.command

  if commandTool, command != nil, let output = extractToolOutput(payload) { return output }

  let data = payload?["data"].looseRecord
  let repeatsCommand =
    detail != nil
    && commandDetailRepeatsCommand(
      detail: detail!,
      command: command,
      rawCommand: commandPreview.rawCommand,
      toolName: data?["toolName"],
      data: payload?["data"]
    )

  if let detail, normalizedHeading != normalizedDetail, !commandTool || !repeatsCommand { return detail }
  if commandTool { return nil }

  if let summary = summarizeToolRawOutput(payload), normalizePreviewForComparison(summary) != normalizedHeading {
    return summary
  }
  return nil
}

// MARK: - Changed files

private func pushChangedFile(_ target: inout [String], _ seen: inout Set<String>, _ value: JSONValue?) {
  guard let normalized = value.trimmedString, !seen.contains(normalized) else { return }
  seen.insert(normalized)
  target.append(normalized)
}

private func collectChangedFiles(_ value: JSONValue?, _ target: inout [String], _ seen: inout Set<String>, depth: Int) {
  if depth > 4 || target.count >= 12 { return }
  if let items = value.arrayOrNil {
    for entry in items {
      collectChangedFiles(entry, &target, &seen, depth: depth + 1)
      if target.count >= 12 { return }
    }
    return
  }
  guard let record = value.looseRecord else { return }
  for key in ["path", "filePath", "relativePath", "filename", "newPath", "oldPath"] {
    pushChangedFile(&target, &seen, record[key])
  }
  for nestedKey in ["item", "result", "input", "data", "changes", "files", "edits", "patch", "patches", "operations"] {
    guard let nested = record[nestedKey] else { continue }
    collectChangedFiles(nested, &target, &seen, depth: depth + 1)
    if target.count >= 12 { return }
  }
}

func extractChangedFiles(_ payload: JSObject?) -> [String] {
  var changedFiles: [String] = []
  var seen = Set<String>()
  collectChangedFiles(payload?["data"], &changedFiles, &seen, depth: 0)
  return changedFiles
}
