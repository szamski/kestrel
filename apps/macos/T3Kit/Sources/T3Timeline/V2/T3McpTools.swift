import Foundation
import T3Contracts

// Ports of the shared helpers the protocol-2 work log leans on: the T3 MCP tool inventory
// (packages/shared t3McpToolPresentation.ts), tool classification and labels (toolActivity.ts),
// compact tool output (toolOutput.ts) and the grouped-call summaries (client-runtime
// t3ToolSummary.ts). The inventory table is generated from the TypeScript so it cannot drift by
// hand; regenerate it with scripts/timeline-oracle/gen-t3-tools.ts.

// MARK: - T3 MCP tool inventory

struct T3McpToolDefinition: Sendable {
  var displayName: String
  var labels: (action: String, running: String, completed: String, detail: String)
  var icon: ToolPresentation.Icon
  var summaryAction: String
}

private let t3McpTools: [String: T3McpToolDefinition] = [
  "link_pull_request": T3McpToolDefinition(displayName: "Link a pull request", labels: ("Link", "Linking", "Linked", "a pull request"), icon: .pullRequest, summaryAction: "link-pr"),
  "unlink_pull_request": T3McpToolDefinition(displayName: "Unlink a pull request", labels: ("Unlink", "Unlinking", "Unlinked", "a pull request"), icon: .pullRequest, summaryAction: "unlink-pr"),
  "list_thread_pull_requests": T3McpToolDefinition(displayName: "Check linked pull requests", labels: ("Check", "Checking", "Checked", "linked pull requests"), icon: .pullRequest, summaryAction: "list-prs"),
  "watch_pull_request": T3McpToolDefinition(displayName: "Watch a pull request", labels: ("Watch", "Watching", "Watching", "a pull request"), icon: .pullRequest, summaryAction: "watch-pr"),
  "unwatch_pull_request": T3McpToolDefinition(displayName: "Stop watching a pull request", labels: ("Stop watching", "Stopping watching", "Stopped watching", "a pull request"), icon: .pullRequest, summaryAction: "unwatch-pr"),
  "orchestrator_capabilities": T3McpToolDefinition(displayName: "Get orchestration capabilities", labels: ("Get", "Getting", "Got", "orchestration capabilities"), icon: .t3Code, summaryAction: "capabilities"),
  "delegate_task": T3McpToolDefinition(displayName: "Delegate a child task", labels: ("Delegate", "Delegating", "Delegated", "a child task"), icon: .t3Code, summaryAction: "delegate"),
  "task_status": T3McpToolDefinition(displayName: "Get delegated task status", labels: ("Get", "Getting", "Got", "delegated task status"), icon: .t3Code, summaryAction: "task-status"),
  "task_cancel": T3McpToolDefinition(displayName: "Cancel delegated task", labels: ("Cancel", "Canceling", "Requested cancellation of", "delegated task"), icon: .t3Code, summaryAction: "task-cancel"),
  "schedule_task": T3McpToolDefinition(displayName: "Schedule a recurring task", labels: ("Schedule", "Scheduling", "Scheduled", "a recurring task"), icon: .t3Code, summaryAction: "schedule-create"),
  "list_scheduled_tasks": T3McpToolDefinition(displayName: "List scheduled tasks", labels: ("List", "Listing", "Listed", "scheduled tasks"), icon: .t3Code, summaryAction: "schedule-list"),
  "update_scheduled_task": T3McpToolDefinition(displayName: "Update a scheduled task", labels: ("Update", "Updating", "Updated", "a scheduled task"), icon: .t3Code, summaryAction: "schedule-update"),
  "delete_scheduled_task": T3McpToolDefinition(displayName: "Delete a scheduled task", labels: ("Delete", "Deleting", "Requested deletion of", "a scheduled task"), icon: .t3Code, summaryAction: "schedule-delete"),
  "request_secret": T3McpToolDefinition(displayName: "Ask for a secret", labels: ("Ask for", "Asking for", "Asked for", "a secret"), icon: .t3Code, summaryAction: "secret-request"),
  "create_threads": T3McpToolDefinition(displayName: "Create T3 threads", labels: ("Create", "Creating", "Created", "T3 threads"), icon: .t3Code, summaryAction: "thread-create"),
  "t3_thread_start": T3McpToolDefinition(displayName: "Start a T3 thread", labels: ("Start", "Starting", "Started", "a T3 thread"), icon: .t3Code, summaryAction: "thread-create"),
  "t3_thread_list": T3McpToolDefinition(displayName: "List T3 threads", labels: ("List", "Listing", "Listed", "T3 threads"), icon: .t3Code, summaryAction: "thread-list"),
  "t3_thread_read": T3McpToolDefinition(displayName: "Read a T3 thread", labels: ("Read", "Reading", "Read", "a T3 thread"), icon: .t3Code, summaryAction: "thread-read"),
  "t3_thread_send": T3McpToolDefinition(displayName: "Send to a T3 thread", labels: ("Send", "Sending", "Sent", "to a T3 thread"), icon: .t3Code, summaryAction: "thread-send"),
  "t3_thread_wait": T3McpToolDefinition(displayName: "Wait for a T3 thread", labels: ("Wait", "Waiting", "Waited", "for a T3 thread"), icon: .t3Code, summaryAction: "thread-wait"),
  "t3_thread_interrupt": T3McpToolDefinition(displayName: "Interrupt a T3 thread", labels: ("Interrupt", "Interrupting", "Requested an interrupt of", "a T3 thread"), icon: .t3Code, summaryAction: "thread-interrupt"),
  "t3_worktree_handoff": T3McpToolDefinition(displayName: "Hand off thread to a git worktree", labels: ("Hand off", "Handing off", "Handed off", "thread to a git worktree"), icon: .t3Code, summaryAction: "worktree-handoff"),
  "t3_worktree_status": T3McpToolDefinition(displayName: "Get thread worktree status", labels: ("Get", "Getting", "Got", "thread worktree status"), icon: .t3Code, summaryAction: "worktree-status"),
  "preview_status": T3McpToolDefinition(displayName: "Get preview browser status", labels: ("Get", "Getting", "Got", "preview browser status"), icon: .browser, summaryAction: "browser"),
  "preview_open": T3McpToolDefinition(displayName: "Open a page in the preview browser", labels: ("Open", "Opening", "Opened", "a page in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_navigate": T3McpToolDefinition(displayName: "Navigate the preview browser", labels: ("Navigate", "Navigating", "Navigated", "the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_dialog": T3McpToolDefinition(displayName: "Respond to a preview browser dialog", labels: ("Respond", "Responding", "Responded", "to a preview browser dialog"), icon: .browser, summaryAction: "browser"),
  "preview_snapshot": T3McpToolDefinition(displayName: "Snapshot the preview page", labels: ("Take a snapshot of", "Taking a snapshot of", "Took a snapshot of", "the preview page"), icon: .browser, summaryAction: "browser"),
  "preview_click": T3McpToolDefinition(displayName: "Click in the preview browser", labels: ("Click", "Clicking", "Clicked", "in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_press": T3McpToolDefinition(displayName: "Press a key in the preview browser", labels: ("Press", "Pressing", "Pressed", "a key in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_type": T3McpToolDefinition(displayName: "Type in the preview browser", labels: ("Type", "Typing", "Typed", "in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_hover": T3McpToolDefinition(displayName: "Hover in the preview browser", labels: ("Hover", "Hovering", "Hovered", "in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_select": T3McpToolDefinition(displayName: "Choose an option in the preview browser", labels: ("Choose", "Choosing", "Chose", "an option in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_drag": T3McpToolDefinition(displayName: "Drag in the preview browser", labels: ("Drag", "Dragging", "Dragged", "in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_upload": T3McpToolDefinition(displayName: "Upload files to the preview browser", labels: ("Upload", "Uploading", "Uploaded", "files to the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_scroll": T3McpToolDefinition(displayName: "Scroll the preview browser", labels: ("Scroll", "Scrolling", "Scrolled", "the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_resize": T3McpToolDefinition(displayName: "Resize the preview browser", labels: ("Resize", "Resizing", "Resized", "the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_evaluate": T3McpToolDefinition(displayName: "Evaluate script in the preview browser", labels: ("Evaluate", "Evaluating", "Evaluated", "script in the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_wait_for": T3McpToolDefinition(displayName: "Wait for the preview page", labels: ("Wait", "Waiting", "Waited", "for the preview page"), icon: .browser, summaryAction: "browser"),
  "preview_set_appearance": T3McpToolDefinition(displayName: "Set preview browser appearance", labels: ("Set", "Setting", "Set", "preview browser appearance"), icon: .browser, summaryAction: "browser"),
  "preview_recording_start": T3McpToolDefinition(displayName: "Start recording the preview browser", labels: ("Start", "Starting", "Started", "recording the preview browser"), icon: .browser, summaryAction: "browser"),
  "preview_recording_stop": T3McpToolDefinition(displayName: "Stop recording the preview browser", labels: ("Stop", "Stopping", "Stopped", "recording the preview browser"), icon: .browser, summaryAction: "browser"),
  "device_list": T3McpToolDefinition(displayName: "List simulators and emulators", labels: ("List", "Listing", "Listed", "simulators and emulators"), icon: .device, summaryAction: "device"),
  "device_open": T3McpToolDefinition(displayName: "Open a device in the Device panel", labels: ("Open", "Opening", "Opened", "a device in the Device panel"), icon: .device, summaryAction: "device"),
  "device_screenshot": T3McpToolDefinition(displayName: "Take a screenshot of the device", labels: ("Take a screenshot of", "Taking a screenshot of", "Took a screenshot of", "the device"), icon: .device, summaryAction: "device"),
  "device_close": T3McpToolDefinition(displayName: "Close a device", labels: ("Close", "Closing", "Closed", "a device"), icon: .device, summaryAction: "device"),
  "run_scheduled_task_now": T3McpToolDefinition(displayName: "Run a scheduled task", labels: ("Run", "Running", "Requested a run of", "a scheduled task"), icon: .t3Code, summaryAction: "schedule-run"),
  "t3_queue_list": T3McpToolDefinition(displayName: "List queued messages", labels: ("List", "Listing", "Listed", "queued messages"), icon: .t3Code, summaryAction: "queue-list"),
  "t3_queue_read": T3McpToolDefinition(displayName: "Read a queued message", labels: ("Read", "Reading", "Read", "a queued message"), icon: .t3Code, summaryAction: "queue-read"),
  "t3_queue_edit": T3McpToolDefinition(displayName: "Edit a queued message", labels: ("Edit", "Editing", "Edited", "a queued message"), icon: .t3Code, summaryAction: "queue-edit"),
  "t3_queue_cancel": T3McpToolDefinition(displayName: "Cancel a queued run", labels: ("Cancel", "Canceling", "Requested cancellation of", "a queued run"), icon: .t3Code, summaryAction: "queue-cancel"),
  "t3_queue_reorder": T3McpToolDefinition(displayName: "Reorder a queued run", labels: ("Reorder", "Reordering", "Reordered", "a queued run"), icon: .t3Code, summaryAction: "queue-reorder"),
  "t3_queue_promote_to_steer": T3McpToolDefinition(displayName: "Steer with a queued message", labels: ("Steer with", "Steering with", "Requested steering with", "a queued message"), icon: .t3Code, summaryAction: "queue-steer"),
  "t3_pending_request_list": T3McpToolDefinition(displayName: "List pending questions", labels: ("List", "Listing", "Listed", "pending questions"), icon: .t3Code, summaryAction: "question-list"),
  "t3_pending_request_read": T3McpToolDefinition(displayName: "Read pending questions", labels: ("Read", "Reading", "Read", "pending questions"), icon: .t3Code, summaryAction: "question-read"),
  "t3_pending_request_respond": T3McpToolDefinition(displayName: "Answer pending questions", labels: ("Answer", "Answering", "Answered", "pending questions"), icon: .t3Code, summaryAction: "question-respond"),
  "t3_thread_configuration": T3McpToolDefinition(displayName: "Read thread configuration", labels: ("Read", "Reading", "Read", "thread configuration"), icon: .t3Code, summaryAction: "thread-configuration"),
  "t3_thread_configure": T3McpToolDefinition(displayName: "Set thread model", labels: ("Set", "Setting", "Set", "thread model"), icon: .t3Code, summaryAction: "thread-configure"),
  "t3_thread_fork": T3McpToolDefinition(displayName: "Fork this thread", labels: ("Fork", "Forking", "Requested a fork of", "this thread"), icon: .t3Code, summaryAction: "thread-fork"),
  "t3_thread_merge_back": T3McpToolDefinition(displayName: "Merge thread context", labels: ("Merge", "Merging", "Requested a merge of", "thread context"), icon: .t3Code, summaryAction: "thread-merge"),
  "t3_thread_search": T3McpToolDefinition(displayName: "Search thread content", labels: ("Search", "Searching", "Searched", "thread content"), icon: .t3Code, summaryAction: "thread-search"),
  "t3_thread_transfers": T3McpToolDefinition(displayName: "Read thread transfers", labels: ("Read", "Reading", "Read", "thread transfers"), icon: .t3Code, summaryAction: "thread-transfers"),
  "t3_thread_organize": T3McpToolDefinition(displayName: "Organize a thread", labels: ("Organize", "Organizing", "Organized", "a thread"), icon: .t3Code, summaryAction: "thread-organize"),
  "t3_thread_update": T3McpToolDefinition(displayName: "Update T3 thread metadata", labels: ("Update", "Updating", "Updated", "T3 thread metadata"), icon: .t3Code, summaryAction: "thread-update"),
  "t3_worktree_list": T3McpToolDefinition(displayName: "List workspace branches", labels: ("List", "Listing", "Listed", "workspace branches"), icon: .t3Code, summaryAction: "worktree-list"),
  "t3_preview_list": T3McpToolDefinition(displayName: "List preview tabs", labels: ("List", "Listing", "Listed", "preview tabs"), icon: .browser, summaryAction: "browser"),
  "t3_preview_close": T3McpToolDefinition(displayName: "Close a preview tab", labels: ("Close", "Closing", "Closed", "a preview tab"), icon: .browser, summaryAction: "browser"),
  "t3_environment_read": T3McpToolDefinition(displayName: "Read environment preferences", labels: ("Read", "Reading", "Read", "environment preferences"), icon: .t3Code, summaryAction: "environment-read"),
  "t3_environment_preferences_update": T3McpToolDefinition(displayName: "Update environment preferences", labels: ("Update", "Updating", "Updated", "environment preferences"), icon: .t3Code, summaryAction: "environment-update"),
  "t3_thread_launch": T3McpToolDefinition(displayName: "Launch a project thread", labels: ("Launch", "Launching", "Launched", "a project thread"), icon: .t3Code, summaryAction: "thread-create"),
  "t3_project_list": T3McpToolDefinition(displayName: "List projects", labels: ("List", "Listing", "Listed", "projects"), icon: .t3Code, summaryAction: "project-list"),
  "t3_project_read": T3McpToolDefinition(displayName: "Read a project", labels: ("Read", "Reading", "Read", "a project"), icon: .t3Code, summaryAction: "project-read"),
  "t3_project_create": T3McpToolDefinition(displayName: "Register a project", labels: ("Register", "Registering", "Registered", "a project"), icon: .t3Code, summaryAction: "project-create"),
  "t3_project_update": T3McpToolDefinition(displayName: "Update a project", labels: ("Update", "Updating", "Updated", "a project"), icon: .t3Code, summaryAction: "project-update"),
  "t3_project_delete": T3McpToolDefinition(displayName: "Delete a project", labels: ("Delete", "Deleting", "Deleted", "a project"), icon: .t3Code, summaryAction: "project-delete"),
  "t3_project_clone": T3McpToolDefinition(displayName: "Clone a repository", labels: ("Clone", "Cloning", "Cloned", "a repository"), icon: .t3Code, summaryAction: "project-clone"),
  "t3_attachment_prepare_upload": T3McpToolDefinition(displayName: "Prepare an attachment upload", labels: ("Prepare", "Preparing", "Prepared", "an attachment upload"), icon: .t3Code, summaryAction: "attachment-prepare"),
  "t3_attachment_discard": T3McpToolDefinition(displayName: "Discard a pending attachment", labels: ("Discard", "Discarding", "Discarded", "a pending attachment"), icon: .t3Code, summaryAction: "attachment-discard"),
  "t3_thread_send_attachments": T3McpToolDefinition(displayName: "Send attachments", labels: ("Send", "Sending", "Sent", "attachments"), icon: .t3Code, summaryAction: "attachment-send"),
  "html_preview": T3McpToolDefinition(displayName: "Preview an HTML page", labels: ("Preview", "Previewing", "Previewed", "an HTML page"), icon: .t3Code, summaryAction: "html-preview"),
  "html_render": T3McpToolDefinition(displayName: "Render an HTML page", labels: ("Render", "Rendering", "Rendered", "an HTML page"), icon: .t3Code, summaryAction: "html-render"),
]

private let t3McpServerAliases: Set<String> = ["t3-code", "t3_code", "t3code"]

private func regexGroups(_ pattern: String, in text: String, caseInsensitive: Bool = true) -> [String]? {
  let regex = RegexCache.shared.regex(pattern, caseInsensitive: caseInsensitive)
  let ns = text as NSString
  guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
  return (1..<match.numberOfRanges).map { index in
    let range = match.range(at: index)
    return range.location == NSNotFound ? "" : ns.substring(with: range)
  }
}

/// `resolveT3McpToolName`: ACP agents spell the injected server's prefix many ways.
private func resolveT3McpToolName(_ value: String) -> String? {
  let label = normalizeCompactToolLabel(value)
  if let groups = regexGroups("^mcp__(.+?)__(.+)$", in: label) {
    return t3McpServerAliases.contains(groups[0].lowercased()) ? groups[1] : nil
  }
  if let groups = regexGroups("^(t3-code|t3_code|t3code)(?:[./:]|\\s*\u{00B7}\\s*)(.+)$", in: label) { return groups[1] }
  let prefixed = regexGroups("^(?:mcp[-_]{1,2})?t3[-_ ]?code(?:__|[-_.:/ ])(.+)$", in: label)?[0]
  let candidate = prefixed ?? label
  if t3McpTools[candidate] != nil { return candidate }
  guard label.matches("^t3-code-", caseInsensitive: true) else { return nil }
  var longest: String?
  for tool in t3McpTools.keys where label.hasSuffix("_\(tool)") && tool.utf16Length > (longest?.utf16Length ?? 0) { longest = tool }
  return longest
}

func resolveT3McpToolDefinition(_ toolName: String?) -> T3McpToolDefinition? {
  guard let toolName, let name = resolveT3McpToolName(toolName) else { return nil }
  return t3McpTools[name]
}

/// The bare T3 tool name for any provider's spelling of it.
func resolveT3McpToolId(_ toolName: String?) -> String? {
  guard let toolName, let name = resolveT3McpToolName(toolName), t3McpTools[name] != nil else { return nil }
  return name
}
