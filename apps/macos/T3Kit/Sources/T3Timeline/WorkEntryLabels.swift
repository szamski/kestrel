import Foundation

// Labels of work rows (workEntryDisplayLabel / liveWorkEntryLabel in MessagesTimeline.logic.ts)
// and the path formatting they use (filePathDisplay.ts, markdownLinks.ts, shared/path.ts).

private let slashPrefixedWindowsDrive = try! NSRegularExpression(pattern: "^/[A-Za-z]:[\\\\/]")
private let positionSuffix = try! NSRegularExpression(pattern: ":(\\d+)(?::(\\d+))?\\z")

private func isWindowsDrivePath(_ value: String) -> Bool { value.matches("^[a-zA-Z]:([/\\\\]|\\z)") }
private func isWindowsAbsolutePath(_ value: String) -> Bool { value.hasPrefix("\\\\") || isWindowsDrivePath(value) }

private func stripSlashPrefixedWindowsDrive(_ path: String) -> String {
  let range = NSRange(location: 0, length: (path as NSString).length)
  return slashPrefixedWindowsDrive.firstMatch(in: path, range: range) != nil ? String(path.dropFirst()) : path
}

/// `fileBasename`: the last path segment, ignoring trailing separators.
func fileBasename(_ path: String) -> String {
  var trimmed = path
  while let last = trimmed.last, last == "/" || last == "\\" { trimmed.removeLast() }
  if trimmed.isEmpty { return path }
  if let separator = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) { return String(trimmed[trimmed.index(after: separator)...]) }
  return trimmed
}

struct FilePathPosition: Equatable {
  var path: String
  var line: Int?
  var column: Int?
}

/// `splitFilePathPosition(path)`: `file.ts:12:3` becomes the path with line and column.
func splitFilePathPosition(_ path: String) -> FilePathPosition {
  let ns = path as NSString
  guard let match = positionSuffix.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
    let line = Int(ns.substring(with: match.range(at: 1)))
  else { return FilePathPosition(path: path) }
  let column = match.range(at: 2).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: 2)))
  return FilePathPosition(
    path: ns.substring(to: match.range.location),
    line: line > 0 ? line : nil,
    column: column.flatMap { $0 > 0 ? $0 : nil }
  )
}

func formatFilePathPosition(_ position: FilePathPosition) -> String {
  guard let line = position.line, line != 0 else { return position.path }
  return "\(position.path):\(line)\(position.column.map { ":\($0)" } ?? "")"
}

/// A path as the chat shows it: relative to the workspace and prefixed with its folder name.
public func formatWorkspaceRelativePath(_ pathWithPosition: String, workspaceRoot: String?) -> String {
  let position = splitFilePathPosition(pathWithPosition)
  let normalizedPath = stripSlashPrefixedWindowsDrive(position.path.replacingOccurrences(of: "\\", with: "/"))
  var displayPath = normalizedPath
  if let workspaceRoot, !workspaceRoot.isEmpty {
    var trimmedRoot = workspaceRoot
    while let last = trimmedRoot.last, last == "/" || last == "\\" { trimmedRoot.removeLast() }
    let normalizedRoot = stripSlashPrefixedWindowsDrive(trimmedRoot.replacingOccurrences(of: "\\", with: "/"))
    let workspaceLabel = fileBasename(normalizedRoot)
    let caseInsensitive = isWindowsAbsolutePath(stripSlashPrefixedWindowsDrive(workspaceRoot))
    let pathForCompare = caseInsensitive ? normalizedPath.lowercased() : normalizedPath
    let rootForCompare = caseInsensitive ? normalizedRoot.lowercased() : normalizedRoot
    let rootWithSeparator = "\(rootForCompare)/"
    let labelWithSeparator = "\(caseInsensitive ? workspaceLabel.lowercased() : workspaceLabel)/"

    if pathForCompare == rootForCompare {
      displayPath = workspaceLabel
    } else if pathForCompare.hasPrefix(rootWithSeparator) {
      displayPath = "\(workspaceLabel)/\(normalizedPath.jsSlice(normalizedRoot.utf16Length + 1))"
    } else if !normalizedPath.hasPrefix("/") {
      // stripRelativePrefixes: one "./" run, then any leading slashes.
      var relative = normalizedPath
      if relative.hasPrefix("./") { relative = String(relative.dropFirst().drop { $0 == "/" }) }
      relative = String(relative.drop { $0 == "/" })
      displayPath = pathForCompare.hasPrefix(labelWithSeparator) ? normalizedPath : "\(workspaceLabel)/\(relative)"
    }
  }
  var formatted = position
  formatted.path = displayPath
  return formatFilePathPosition(formatted)
}

private func capitalizedHeading(_ entry: WorkLogEntry) -> String {
  normalizeCompactToolLabel(entry.toolTitle.flatMap { $0.isEmpty ? nil : $0 } ?? entry.label).jsCapitalizedFirst()
}

/// The label of one row inside an expanded group.
public func workEntryDisplayLabel(_ entry: WorkLogEntry, workspaceRoot: String?) -> String {
  if let presentation = resolveWorkEntryToolPresentation(entry) { return presentation.displayName }
  if let command = entry.command, !command.isEmpty { return command }
  if let detail = entry.detail, !detail.isEmpty { return detail }
  if let files = entry.changedFiles, let first = files.first, !first.isEmpty {
    let path = formatWorkspaceRelativePath(first, workspaceRoot: workspaceRoot)
    return files.count == 1 ? path : "\(path) +\(files.count - 1) more"
  }
  return capitalizedHeading(entry)
}

/// The label of the live activity row, in the present tense while the call runs.
public func liveWorkEntryLabel(_ entry: WorkLogEntry, workspaceRoot: String?, active: Bool) -> String {
  let status = liveActivityToolStatus(entry.toolLifecycleStatus, presentTense: active)
  var withStatus = entry
  withStatus.toolLifecycleStatus = status
  if let presentation = resolveWorkEntryToolPresentation(withStatus) { return presentation.displayName }
  if let command = entry.command?.jsTrimmed, !command.isEmpty {
    let verb: String =
      switch status {
      case .inProgress: "Running"
      case .failed: "Failed"
      case .declined: "Declined"
      case .stopped: "Stopped"
      case .completed: "Ran"
      }
    return "\(verb) \(commandProgramName(command) ?? "command")"
  }
  return workEntryDisplayLabel(entry, workspaceRoot: workspaceRoot)
}
