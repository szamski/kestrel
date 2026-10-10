import Foundation
import T3Contracts

/// Port of `pendingRequests.ts`: derives the open approvals and user-input questions of a
/// thread from its activity log. Activity payloads are `unknown` on the wire, so these value
/// types are written by hand; their JSON shape matches the TypeScript result.
public enum PendingRequestKind: String, Sendable, Codable, Hashable {
  case command, fileRead = "file-read", fileChange = "file-change", mcpElicitation = "mcp-elicitation", permission
}

public struct PendingApprovalOption: Sendable, Codable, Hashable {
  public let decision: ProviderApprovalDecision
  public let label: String
  public let warning: String?
}

public struct PendingApproval: Sendable, Codable, Hashable {
  public let requestId: V1.ApprovalRequestId
  public let requestKind: PendingRequestKind
  public let createdAt: IsoDateTime
  public let detail: String?
  public let appName: String?
  public let options: [PendingApprovalOption]?
}

public struct UserInputQuestionOption: Sendable, Codable, Hashable {
  public let label: String
  public let description: String
  public let value: String?
}

public struct UserInputQuestion: Sendable, Codable, Hashable {
  public let id: String
  public let header: String
  public let question: String
  public let options: [UserInputQuestionOption]
  public let allowCustomAnswer: Bool?
  public let multiSelect: Bool
}

public struct PendingUserInput: Sendable, Codable, Hashable {
  public let requestId: V1.ApprovalRequestId
  public let createdAt: IsoDateTime
  public let questions: [UserInputQuestion]
  /// Async questions can be dismissed without a reply; native callbacks cannot.
  public let dismissible: Bool
}

public struct PendingRequests: Sendable, Codable, Hashable {
  public var approvals: [PendingApproval]
  public var userInputs: [PendingUserInput]
}

public enum PendingRequestDeriver {
  /// Older activities carry native request types instead of a request kind.
  public static func requestKind(fromRequestType type: String?) -> PendingRequestKind? {
    switch type {
    case "command_execution_approval", "exec_command_approval", "dynamic_tool_call": .command
    case "file_read_approval": .fileRead
    case "file_change_approval", "apply_patch_approval": .fileChange
    case "mcp_elicitation_approval": .mcpElicitation
    case "permission_approval": .permission
    default: nil
    }
  }

  private static let requestActivityKinds: Set<String> = [
    "approval.requested", "approval.resolved", "provider.approval.respond.failed",
    "user-input.requested", "user-input.resolved", "provider.user-input.respond.failed",
  ]

  // The server reports a stale or unknown request through the failure text.
  private static let staleApproval = [
    "stale pending approval request", "unknown pending approval request", "unknown pending permission request",
    "unknown pending codex approval request",
  ]
  private static let staleUserInput = [
    "stale pending user-input request", "unknown pending user-input request", "unknown pending user input request",
    "unknown pending codex user input request",
  ]

  private static func isStale(_ fragments: [String], _ payload: [String: JSONValue]) -> Bool {
    guard case .string(let detail)? = payload["detail"] else { return false }
    let lowered = detail.lowercased()
    return fragments.contains { lowered.contains($0) }
  }

  /// `TrimmedNonEmptyString`: the id must already be trimmed and non-empty.
  private static func requestId(_ value: JSONValue?) -> V1.ApprovalRequestId? {
    guard case .string(let s)? = value, !s.isEmpty, s == s.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return V1.ApprovalRequestId(s)
  }

  private static func trimmedNonEmpty(_ value: JSONValue?) -> String? {
    guard case .string(let s)? = value, !s.isEmpty, s == s.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return s
  }

  private static func options(_ value: JSONValue?) -> [PendingApprovalOption] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { item in
      guard case .object(let o) = item, case .string(let decision)? = o["decision"], let label = trimmedNonEmpty(o["label"]) else { return nil }
      let parsed = ProviderApprovalDecision(rawValue: decision)
      if case .unknown = parsed { return nil }
      if let warning = o["warning"], trimmedNonEmpty(warning) == nil { return nil }
      return PendingApprovalOption(decision: parsed, label: label, warning: trimmedNonEmpty(o["warning"]))
    }
  }

  private static func questions(_ value: JSONValue?) -> [UserInputQuestion] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { item in
      guard case .object(let q) = item, case .array(let rawOptions)? = q["options"] else { return nil }
      let options = rawOptions.compactMap { raw -> UserInputQuestionOption? in
        guard case .object(let o) = raw, case .string(let label)? = o["label"], case .string(let description)? = o["description"] else { return nil }
        switch o["value"] {
        case nil: return UserInputQuestionOption(label: label, description: description, value: nil)
        case .string(let v)?: return UserInputQuestionOption(label: label, description: description, value: v)
        default: return nil
        }
      }
      var allowCustom: Bool?
      if case .bool(let b)? = q["allowCustomAnswer"] { allowCustom = b }
      if options.isEmpty, allowCustom == false { return nil }
      guard case .string(let id)? = q["id"], case .string(let header)? = q["header"], case .string(let question)? = q["question"] else { return nil }
      var multi = false
      if case .bool(true)? = q["multiSelect"] { multi = true }
      return UserInputQuestion(id: id, header: header, question: question, options: options, allowCustomAnswer: allowCustom, multiSelect: multi)
    }
  }

  public static func derive(_ activities: [V1.OrchestrationThreadActivity]) -> PendingRequests {
    // Insertion-ordered maps, like the JS Maps they mirror.
    var approvals: [V1.ApprovalRequestId: PendingApproval] = [:], approvalOrder: [V1.ApprovalRequestId] = []
    var inputs: [V1.ApprovalRequestId: PendingUserInput] = [:], inputOrder: [V1.ApprovalRequestId] = []
    var closedApprovals = Set<V1.ApprovalRequestId>(), closedInputs = Set<V1.ApprovalRequestId>()

    for activity in activities where requestActivityKinds.contains(activity.kind) {
      guard case .object(let payload) = activity.payload, let id = requestId(payload["requestId"]) else { continue }
      switch activity.kind {
      case "approval.requested":
        var requestType: String?
        if case .string(let t)? = payload["requestType"] { requestType = t }
        if closedApprovals.contains(id) || requestType == "tool_user_input" || requestType == "auth_tokens_refresh" { continue }
        var kind: PendingRequestKind?
        if case .string(let k)? = payload["requestKind"] { kind = PendingRequestKind(rawValue: k) }
        kind = kind ?? requestKind(fromRequestType: requestType)
        let opts = options(payload["options"])
        var detail: String?, appName: String?
        if case .string(let d)? = payload["detail"], !d.isEmpty { detail = d }
        if case .string(let a)? = payload["appName"], !a.isEmpty { appName = a }
        if approvals[id] == nil { approvalOrder.append(id) }
        approvals[id] = PendingApproval(
          requestId: id, requestKind: kind ?? .command, createdAt: activity.createdAt, detail: detail, appName: appName,
          options: opts.isEmpty ? nil : opts)
      case "user-input.requested":
        if closedInputs.contains(id) { continue }
        let parsed = questions(payload["questions"])
        if parsed.isEmpty { continue }
        var dismissible = false
        if case .string("message")? = payload["responseMode"] { dismissible = true }
        if inputs[id] == nil { inputOrder.append(id) }
        inputs[id] = PendingUserInput(requestId: id, createdAt: activity.createdAt, questions: parsed, dismissible: dismissible)
      case "approval.resolved":
        closedApprovals.insert(id)
        approvals[id] = nil
        approvalOrder.removeAll { $0 == id }
      case "provider.approval.respond.failed" where isStale(staleApproval, payload):
        closedApprovals.insert(id)
        approvals[id] = nil
        approvalOrder.removeAll { $0 == id }
      case "user-input.resolved":
        closedInputs.insert(id)
        inputs[id] = nil
        inputOrder.removeAll { $0 == id }
      case "provider.user-input.respond.failed" where isStale(staleUserInput, payload):
        closedInputs.insert(id)
        inputs[id] = nil
        inputOrder.removeAll { $0 == id }
      default:
        break
      }
    }

    let openApprovals = approvalOrder.compactMap { approvals[$0] }
    let openInputs = inputOrder.compactMap { inputs[$0] }
    return PendingRequests(
      approvals: stableSorted(openApprovals) { JS.localeCompare($0.createdAt.rawValue, $1.createdAt.rawValue) },
      userInputs: stableSorted(openInputs) { JS.localeCompare($0.createdAt.rawValue, $1.createdAt.rawValue) })
  }
}
