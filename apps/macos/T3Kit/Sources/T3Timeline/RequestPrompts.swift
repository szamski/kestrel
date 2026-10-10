import Foundation
import T3Contracts

// What the composer shows while the agent waits for the user: approvals and user-input
// questions, derived from the activity log.
//
// `derivePendingPrompts` duplicates packages/client-runtime/src/pendingRequests.ts on purpose
// (T3ClientRuntime owns the sidebar copy; this module must not depend on it). Both are checked
// against the same TypeScript oracle, so they cannot drift silently.

public struct ApprovalOption: Sendable, Hashable {
  public var decision: ProviderApprovalDecision
  public var label: String
  /// Provider-supplied caution shown next to the option, such as a prompt injection warning.
  public var warning: String?

  public init(decision: ProviderApprovalDecision, label: String, warning: String? = nil) {
    self.decision = decision
    self.label = label
    self.warning = warning
  }
}

public struct ApprovalPrompt: Sendable, Hashable, Identifiable {
  public var requestId: V1.ApprovalRequestId
  public var requestKind: ProviderRequestKind
  public var createdAt: String
  public var detail: String?
  public var appName: String?
  /// Provider-specific choices; nil means the standard four (`defaultOptions`).
  public var options: [ApprovalOption]?

  public var id: String { requestId.rawValue }

  public init(
    requestId: V1.ApprovalRequestId, requestKind: ProviderRequestKind, createdAt: String, detail: String? = nil, appName: String? = nil,
    options: [ApprovalOption]? = nil
  ) {
    self.requestId = requestId
    self.requestKind = requestKind
    self.createdAt = createdAt
    self.detail = detail
    self.appName = appName
    self.options = options
  }

  /// ComposerPendingApprovalActions: used when the provider sent no options.
  public static let defaultOptions: [ApprovalOption] = [
    ApprovalOption(decision: .cancel, label: "Cancel"),
    ApprovalOption(decision: .decline, label: "Decline"),
    ApprovalOption(decision: .acceptForSession, label: "Always allow this session"),
    ApprovalOption(decision: .accept, label: "Approve"),
  ]

  public var resolvedOptions: [ApprovalOption] { options ?? Self.defaultOptions }
  /// Buttons: Decline and Approve.
  public var primaryOptions: [ApprovalOption] { resolvedOptions.filter { $0.decision == .decline || $0.decision == .accept } }
  /// Overflow menu: everything else.
  public var moreOptions: [ApprovalOption] { resolvedOptions.filter { $0.decision != .decline && $0.decision != .accept } }

  /// ComposerPendingApprovalPanel heading.
  public var panelLabel: String {
    switch requestKind {
    case .mcpElicitation: "App access approval"
    case .command: "Command approval"
    case .fileRead: "File read approval"
    case .permission: "App permission approval"
    case .fileChange: "File change approval"
    }
  }

  /// Accessibility label of the detail field.
  public var detailLabel: String {
    switch requestKind {
    case .mcpElicitation: "App access request"
    case .command: "Command"
    case .fileRead: "File to read"
    case .permission: "Permission request"
    case .fileChange: "File change"
    }
  }

  /// Commands and paths read as code; app access requests are prose.
  public var detailIsCode: Bool { requestKind != .mcpElicitation }

  public var displayDetail: String { (detail ?? "").isEmpty ? panelLabel : detail! }
}

public struct UserInputQuestionOption: Sendable, Hashable, Codable {
  public var label: String
  public var description: String
  public var value: String?

  public init(label: String, description: String, value: String? = nil) {
    self.label = label
    self.description = description
    self.value = value
  }
}

public struct UserInputQuestion: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var header: String
  public var question: String
  public var options: [UserInputQuestionOption]
  public var allowCustomAnswer: Bool?
  public var multiSelect: Bool

  public init(
    id: String, header: String, question: String, options: [UserInputQuestionOption], allowCustomAnswer: Bool? = nil, multiSelect: Bool = false
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.options = options
    self.allowCustomAnswer = allowCustomAnswer
    self.multiSelect = multiSelect
  }

  /// The value an option answers with (`option.value ?? option.label`).
  public func answerValue(of option: UserInputQuestionOption) -> String { option.value ?? option.label }
}

public struct UserInputPrompt: Sendable, Hashable, Identifiable {
  public var requestId: V1.ApprovalRequestId
  public var createdAt: String
  public var questions: [UserInputQuestion]
  /// Async questions can be dismissed without a reply; native callbacks cannot.
  public var dismissible: Bool

  public var id: String { requestId.rawValue }

  public init(requestId: V1.ApprovalRequestId, createdAt: String, questions: [UserInputQuestion], dismissible: Bool) {
    self.requestId = requestId
    self.createdAt = createdAt
    self.questions = questions
    self.dismissible = dismissible
  }
}

public struct PendingPrompts: Sendable, Hashable {
  public var approvals: [ApprovalPrompt]
  public var userInputs: [UserInputPrompt]

  public init(approvals: [ApprovalPrompt], userInputs: [UserInputPrompt]) {
    self.approvals = approvals
    self.userInputs = userInputs
  }
}

private let requestActivityKinds: Set<String> = [
  "approval.requested", "approval.resolved", "provider.approval.respond.failed",
  "user-input.requested", "user-input.resolved", "provider.user-input.respond.failed",
]

// The server reports a stale or unknown request through the failure text. A failed reply with
// any other text stays open so the user can retry.
private let staleApprovalFailures = [
  "stale pending approval request", "unknown pending approval request", "unknown pending permission request",
  "unknown pending codex approval request",
]
private let staleUserInputFailures = [
  "stale pending user-input request", "unknown pending user-input request", "unknown pending user input request",
  "unknown pending codex user input request",
]

private func isStaleFailure(_ fragments: [String], _ payload: JSObject) -> Bool {
  let detail = payload["detail"]?.stringOrNil?.lowercased() ?? ""
  return fragments.contains { detail.contains($0) }
}

private func parseApprovalOptions(_ value: JSONValue?) -> [ApprovalOption] {
  (value?.arrayOrNil ?? []).compactMap { item in
    guard let record = item.strictRecord, let decision = record["decision"]?.stringOrNil, let label = record["label"]?.stringOrNil,
      !label.isEmpty,
      ["accept", "acceptForSession", "acceptAlways", "decline", "cancel"].contains(decision)
    else { return nil }
    var warning: String?
    if let raw = record["warning"] {
      guard let text = raw.stringOrNil, !text.isEmpty else { return nil }
      warning = text
    }
    return ApprovalOption(decision: ProviderApprovalDecision(rawValue: decision), label: label, warning: warning)
  }
}

/// Native question ids and option labels can be answer keys; they are never trimmed.
private func parseQuestions(_ value: JSONValue?) -> [UserInputQuestion] {
  (value?.arrayOrNil ?? []).compactMap { item in
    guard let record = item.strictRecord, let rawOptions = record["options"]?.arrayOrNil else { return nil }
    let options: [UserInputQuestionOption] = rawOptions.compactMap { optionValue in
      guard let option = optionValue.strictRecord, let label = option["label"]?.stringOrNil,
        let description = option["description"]?.stringOrNil
      else { return nil }
      var answerValue: String?
      if let raw = option["value"] {
        guard let text = raw.stringOrNil else { return nil }
        answerValue = text
      }
      return UserInputQuestionOption(label: label, description: description, value: answerValue)
    }
    // The guard keeps non-conforming option shapes out; they are dropped, not fatal.
    if options.isEmpty && record["allowCustomAnswer"]?.boolOrNil == false { return nil }
    guard let id = record["id"]?.stringOrNil, let header = record["header"]?.stringOrNil, let question = record["question"]?.stringOrNil
    else { return nil }
    return UserInputQuestion(
      id: id,
      header: header,
      question: question,
      options: options,
      allowCustomAnswer: record["allowCustomAnswer"]?.boolOrNil,
      multiSelect: record["multiSelect"]?.boolOrNil == true
    )
  }
}

/// Reduces request state once: a terminal event stays final even when provider sequences and
/// server-generated activities arrive in a different order.
public func derivePendingPrompts(_ activities: [V1.OrchestrationThreadActivity]) -> PendingPrompts {
  var approvals: [String: ApprovalPrompt] = [:]
  var approvalOrder: [String] = []
  var userInputs: [String: UserInputPrompt] = [:]
  var userInputOrder: [String] = []
  var closedApprovals = Set<String>()
  var closedUserInputs = Set<String>()

  for activity in activities where requestActivityKinds.contains(activity.kind) {
    guard let payload = activity.payload.strictRecord, let requestId = payload["requestId"]?.stringOrNil, !requestId.isEmpty else { continue }
    switch activity.kind {
    case "approval.requested":
      let requestType = payload["requestType"]?.stringOrNil
      if closedApprovals.contains(requestId) || requestType == "tool_user_input" || requestType == "auth_tokens_refresh" { continue }
      let explicitKind = payload["requestKind"]?.stringOrNil.flatMap { ProviderRequestKind(rawValue: $0) }
      let kind = explicitKind ?? requestKindFromRequestType(payload["requestType"])
      let options = parseApprovalOptions(payload["options"])
      if approvals[requestId] == nil { approvalOrder.append(requestId) }
      approvals[requestId] = ApprovalPrompt(
        requestId: V1.ApprovalRequestId(requestId),
        // Older OpenCode approvals do not always include a recognized kind.
        requestKind: kind ?? .command,
        createdAt: activity.createdAt.rawValue,
        detail: payload["detail"]?.stringOrNil.flatMap { $0.isEmpty ? nil : $0 },
        appName: payload["appName"]?.stringOrNil.flatMap { $0.isEmpty ? nil : $0 },
        options: options.isEmpty ? nil : options
      )
    case "user-input.requested":
      if closedUserInputs.contains(requestId) { continue }
      let questions = parseQuestions(payload["questions"])
      if questions.isEmpty { continue }
      if userInputs[requestId] == nil { userInputOrder.append(requestId) }
      userInputs[requestId] = UserInputPrompt(
        requestId: V1.ApprovalRequestId(requestId),
        createdAt: activity.createdAt.rawValue,
        questions: questions,
        dismissible: payload["responseMode"]?.stringOrNil == "message"
      )
    case "approval.resolved", "provider.approval.respond.failed":
      if activity.kind == "approval.resolved" || isStaleFailure(staleApprovalFailures, payload) {
        closedApprovals.insert(requestId)
        approvals[requestId] = nil
        approvalOrder.removeAll { $0 == requestId }
      }
    default:  // user-input.resolved, provider.user-input.respond.failed
      if activity.kind == "user-input.resolved" || isStaleFailure(staleUserInputFailures, payload) {
        closedUserInputs.insert(requestId)
        userInputs[requestId] = nil
        userInputOrder.removeAll { $0 == requestId }
      }
    }
  }
  return PendingPrompts(
    approvals: approvalOrder.compactMap { approvals[$0] }.stableSorted { jsLocaleCompare($0.createdAt, $1.createdAt) },
    userInputs: userInputOrder.compactMap { userInputs[$0] }.stableSorted { jsLocaleCompare($0.createdAt, $1.createdAt) }
  )
}

// MARK: - Answering (apps/web/src/pendingUserInput.ts)

/// What the reader has entered for one question so far.
public struct PendingUserInputDraftAnswer: Sendable, Hashable {
  public var selectedOptionValues: [String]?
  public var customAnswer: String?
  public var attachmentCount: Int?
  public var attachmentsBlocked: Bool?

  public init(
    selectedOptionValues: [String]? = nil,
    customAnswer: String? = nil,
    attachmentCount: Int? = nil,
    attachmentsBlocked: Bool? = nil
  ) {
    self.selectedOptionValues = selectedOptionValues
    self.customAnswer = customAnswer
    self.attachmentCount = attachmentCount
    self.attachmentsBlocked = attachmentsBlocked
  }
}

/// A resolved answer: one text, or the chosen values of a multi-select question.
public enum PendingUserInputAnswer: Sendable, Hashable {
  case text(String)
  case values([String])
}

private func normalizeDraftAnswer(_ value: String?) -> String? {
  guard let trimmed = value?.jsTrimmed, !trimmed.isEmpty else { return nil }
  return trimmed
}

/// Provider option ids stay unchanged, including whitespace; duplicates collapse.
private func normalizeSelectedOptionValues(_ value: [String]?) -> [String] {
  var seen = Set<String>()
  return (value ?? []).filter { seen.insert($0).inserted }
}

public func resolvePendingUserInputAnswer(_ question: UserInputQuestion, _ draft: PendingUserInputDraftAnswer?) -> PendingUserInputAnswer? {
  if draft?.attachmentsBlocked == true { return nil }
  let allowsCustom = question.allowCustomAnswer != false
  if allowsCustom, let custom = normalizeDraftAnswer(draft?.customAnswer) { return .text(custom) }
  let selected = normalizeSelectedOptionValues(draft?.selectedOptionValues).filter { value in
    question.options.contains { question.answerValue(of: $0) == value }
  }
  let hasAttachmentOnlyAnswer = allowsCustom && (draft?.attachmentCount ?? 0) > 0
  if question.multiSelect { return !selected.isEmpty ? .values(selected) : hasAttachmentOnlyAnswer ? .text("") : nil }
  if let first = selected.first { return .text(first) }
  return hasAttachmentOnlyAnswer ? .text("") : nil
}

public func setPendingUserInputCustomAnswer(_ draft: PendingUserInputDraftAnswer?, _ customAnswer: String) -> PendingUserInputDraftAnswer {
  let selected = customAnswer.jsTrimmed.isEmpty ? normalizeSelectedOptionValues(draft?.selectedOptionValues) : []
  return PendingUserInputDraftAnswer(selectedOptionValues: selected.isEmpty ? nil : selected, customAnswer: customAnswer)
}

/// Selecting an option replaces the custom answer, so the typed text moves back into the
/// thread draft instead of vanishing.
public func carryDisplacedCustomAnswerIntoPrompt(_ prompt: String, customAnswer: String?) -> String {
  let displaced = customAnswer?.jsTrimmed ?? ""
  if displaced.isEmpty { return prompt }
  if prompt.jsTrimmed.isEmpty { return displaced }
  return "\(prompt.jsTrimmedEnd)\n\n\(displaced)"
}

public func togglePendingUserInputOptionSelection(
  _ question: UserInputQuestion,
  _ draft: PendingUserInputDraftAnswer?,
  optionValue: String
) -> PendingUserInputDraftAnswer {
  if question.multiSelect {
    let selected = normalizeSelectedOptionValues(draft?.selectedOptionValues)
    let next = selected.contains(optionValue) ? selected.filter { $0 != optionValue } : selected + [optionValue]
    return PendingUserInputDraftAnswer(selectedOptionValues: next.isEmpty ? nil : next, customAnswer: "")
  }
  return PendingUserInputDraftAnswer(selectedOptionValues: [optionValue], customAnswer: "")
}

/// Answers keyed by question id, or nil while any question is unanswered.
public func buildPendingUserInputAnswers(
  _ questions: [UserInputQuestion],
  _ draftAnswers: [String: PendingUserInputDraftAnswer]
) -> [String: PendingUserInputAnswer]? {
  var answers: [String: PendingUserInputAnswer] = [:]
  for question in questions {
    guard let answer = resolvePendingUserInputAnswer(question, draftAnswers[question.id]) else { return nil }
    answers[question.id] = answer
  }
  return answers
}

public func countAnsweredPendingUserInputQuestions(_ questions: [UserInputQuestion], _ draftAnswers: [String: PendingUserInputDraftAnswer]) -> Int {
  questions.filter { resolvePendingUserInputAnswer($0, draftAnswers[$0.id]) != nil }.count
}

public struct PendingUserInputProgress: Sendable, Hashable {
  public var questionIndex: Int
  public var activeQuestion: UserInputQuestion?
  public var activeDraft: PendingUserInputDraftAnswer?
  public var selectedOptionValues: [String]
  public var customAnswer: String
  public var resolvedAnswer: PendingUserInputAnswer?
  public var usingCustomAnswer: Bool
  public var answeredQuestionCount: Int
  public var isLastQuestion: Bool
  public var isComplete: Bool
  public var canAdvance: Bool
}

public func derivePendingUserInputProgress(
  _ questions: [UserInputQuestion],
  _ draftAnswers: [String: PendingUserInputDraftAnswer],
  questionIndex: Int
) -> PendingUserInputProgress {
  let normalizedIndex = questions.isEmpty ? 0 : max(0, min(questionIndex, questions.count - 1))
  let activeQuestion = questions.indices.contains(normalizedIndex) ? questions[normalizedIndex] : nil
  let activeDraft = activeQuestion.flatMap { draftAnswers[$0.id] }
  let resolved = activeQuestion.flatMap { resolvePendingUserInputAnswer($0, activeDraft) }
  let customAnswer = activeQuestion?.allowCustomAnswer == false ? "" : (activeDraft?.customAnswer ?? "")
  return PendingUserInputProgress(
    questionIndex: normalizedIndex,
    activeQuestion: activeQuestion,
    activeDraft: activeDraft,
    selectedOptionValues: normalizeSelectedOptionValues(activeDraft?.selectedOptionValues),
    customAnswer: customAnswer,
    resolvedAnswer: resolved,
    usingCustomAnswer: !customAnswer.jsTrimmed.isEmpty,
    answeredQuestionCount: countAnsweredPendingUserInputQuestions(questions, draftAnswers),
    isLastQuestion: questions.isEmpty ? true : normalizedIndex >= questions.count - 1,
    isComplete: buildPendingUserInputAnswers(questions, draftAnswers) != nil,
    canAdvance: resolved != nil
  )
}
