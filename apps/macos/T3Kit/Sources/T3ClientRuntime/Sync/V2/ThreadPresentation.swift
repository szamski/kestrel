import Foundation
import T3Contracts

/// Read-side derivations of a protocol-2 thread projection that the UI needs next to the raw `projection`.
public enum ThreadPresentation {
  // MARK: Pending requests (`state/threadRequests.ts`)

  /// Open approvals and user-input questions, joined to the request items that carry their display data.
  public static func pendingRequests(_ projection: OrchestrationV2ThreadProjection) -> PendingRequests {
    var approvals: [PendingApproval] = []
    var userInputs: [PendingUserInput] = []
    for request in projection.runtimeRequests where request.status == .pending {
      let live: Bool = if case .message = request.responseCapability { true } else { false }
      if request.kind == .user_input {
        guard
          let item = projection.turnItems.last(where: { if case .userInputRequest(let r) = $0 { r.requestId == request.id } else { false } }),
          case .userInputRequest(let input) = item
        else { continue }
        let message = input.responseMode == "message" || live
        userInputs.append(
          PendingUserInput(
            requestId: V1.ApprovalRequestId(rawValue: request.id.rawValue), createdAt: request.createdAt,
            questions: input.questions.map { question in
              UserInputQuestion(
                id: question.id, header: question.header, question: question.question,
                options: question.options.map { UserInputQuestionOption(label: $0.label, description: $0.description, value: $0.value) },
                allowCustomAnswer: question.allowCustomAnswer, multiSelect: question.multiSelect ?? false)
            }, dismissible: message))
        continue
      }
      guard let kind = approvalKind(request.kind) else { continue }
      var detail: String?, appName: String?, options: [PendingApprovalOption]?
      if let item = projection.turnItems.last(where: { if case .approvalRequest(let r) = $0 { r.requestId == request.id } else { false } }),
        case .approvalRequest(let approval) = item
      {
        detail = approval.prompt.flatMap { $0.isEmpty ? nil : $0 }
        appName = approval.appName.flatMap { $0.isEmpty ? nil : $0 }
        options = approval.options?.map { PendingApprovalOption(decision: $0.decision, label: $0.label, warning: $0.warning) }
      }
      approvals.append(
        PendingApproval(
          requestId: V1.ApprovalRequestId(rawValue: request.id.rawValue), requestKind: kind, createdAt: request.createdAt, detail: detail,
          appName: appName, options: options))
    }
    return PendingRequests(approvals: approvals, userInputs: userInputs)
  }

  private static func approvalKind(_ kind: OrchestrationV2PendingRuntimeRequestSummaryKind) -> PendingRequestKind? {
    switch kind {
    case .command: .command
    case .fileRead: .fileRead
    case .fileChange: .fileChange
    case .mcpElicitation: .mcpElicitation
    case .permission: .permission
    default: nil  // user input has its own path; auth refresh and dynamic tool calls are not approvals
    }
  }

  // MARK: Queue (`state/threadWorkflows.ts`)

  /// The server-side queue of a thread: what is running, what waits behind it, and what the provider allows.
  public static func queue(_ projection: OrchestrationV2ThreadProjection) -> ThreadQueueState {
    let activeRun = projection.runs.last { ThreadQueueState.activeStatuses.contains($0.status) }
    let automatic = Set(projection.messages.filter { $0.delegatedCompletion != nil || $0.notification != nil }.map(\.id))
    let queued = projection.runs
      .filter { $0.status == .queued && !automatic.contains($0.userMessageId) }
      .sorted { left, right in
        let l = optionalValue(left.queuePosition) ?? left.ordinal, r = optionalValue(right.queuePosition) ?? right.ordinal
        return l != r ? l < r : left.ordinal < right.ordinal
      }
      .map { run -> QueuedMessage in
        let message = projection.messages.first { $0.id == run.userMessageId }
        return QueuedMessage(
          run: run, text: message?.text ?? "Queued message", attachments: message?.attachments ?? [], messageId: run.userMessageId, context: message?.context)
      }
    let capabilities = providerSession(projection, activeRun: activeRun)?.capabilities.turns
    let steerable =
      activeRun?.status == .running && activeRun?.activeAttemptId != nil
      && projection.providerTurns.contains { $0.runAttemptId == activeRun?.activeAttemptId && $0.status == .running }
    return ThreadQueueState(
      activeRun: activeRun, queued: queued, isHeld: projection.runs.contains { $0.status == .queued && $0.queueHeld == true },
      canReorder: capabilities?.supportsQueuedMessages == true,
      canPromoteToSteer: steerable && (capabilities?.supportsActiveSteering == true || capabilities?.supportsSteeringByInterruptRestart == true))
  }

  private static func providerSession(_ projection: OrchestrationV2ThreadProjection, activeRun: OrchestrationV2Run?) -> OrchestrationV2ProviderSession? {
    let providerThreadId = activeRun?.providerThreadId ?? projection.thread.activeProviderThreadId
    let attached =
      providerThreadId.flatMap { id in projection.providerThreads.first { $0.id == id } }
      ?? projection.providerThreads.first { $0.appThreadId == projection.thread.id && $0.providerSessionId != nil }
    if let sessionId = attached?.providerSessionId { return projection.providerSessions.first { $0.id == sessionId } }
    return projection.providerSessions.last { $0.status != .stopped && $0.status != .error }
  }

  // MARK: V1-shaped detail

  /// The projection as the thread detail the existing timeline renders: the shell's metadata, the conversation
  /// messages and the session. Tool activity, plans and checkpoints stay empty: the protocol-2 timeline reads the
  /// projection's turn items directly (stage 3), these are only enough for messages to appear and stream.
  public static func thread(_ projection: OrchestrationV2ThreadProjection, shell: V1.OrchestrationThreadShell) -> V1.OrchestrationThread {
    var thread = V1.OrchestrationThread(
      id: shell.id, projectId: shell.projectId, title: shell.title, modelSelection: shell.modelSelection, runtimeMode: shell.runtimeMode,
      interactionMode: shell.interactionMode, createdAt: shell.createdAt, updatedAt: shell.updatedAt, messages: projection.messages.map(message),
      activities: [], checkpoints: [])
    thread = thread.merged(with: shell)
    return thread
  }

  private static func message(_ message: OrchestrationV2ConversationMessage) -> V1.OrchestrationMessage {
    V1.OrchestrationMessage(
      id: message.id, role: V1.OrchestrationMessageRole(rawValue: message.role.rawValue), text: message.text,
      attachments: message.attachments.isEmpty ? nil : message.attachments, context: message.context,
      turnId: message.runId.map { V1.TurnId(rawValue: $0.rawValue) }, streaming: message.streaming, createdAt: message.createdAt, updatedAt: message.updatedAt)
  }
}

/// A user message waiting behind the active run (a queued run and the message it carries).
public struct QueuedMessage: Sendable, Equatable, Identifiable {
  public var run: OrchestrationV2Run
  public var text: String
  public var attachments: [ChatAttachment]
  /// Editing replaces this message's content, so its id and context travel with the row.
  public var messageId: MessageId
  public var context: OrchestrationMessageContext?
  public var id: RunId { run.id }
}

public struct ThreadQueueState: Sendable, Equatable {
  static let activeStatuses: Set<OrchestrationV2RunStatus> = [.preparing, .starting, .running, .waiting]
  public var activeRun: OrchestrationV2Run?
  public var queued: [QueuedMessage]
  /// Stop held the queue: queued messages wait for `resumeQueue`.
  public var isHeld: Bool
  public var canReorder: Bool
  public var canPromoteToSteer: Bool
  public static let empty = ThreadQueueState(activeRun: nil, queued: [], isHeld: false, canReorder: false, canPromoteToSteer: false)
}
