import Foundation
import T3Contracts

/// The composer's model and modes when a message was queued. The send uses these instead of the
/// live composer, so it can go out while the user is on another thread.
public struct QueuedMessageSendSettings: Sendable, Hashable, Codable {
  public var modelSelection: ModelSelection
  public var runtimeMode: RuntimeMode
  public var interactionMode: ProviderInteractionMode
  /// Effort written into the prompt text, for providers that read it there.
  public var promptEffort: String?

  public init(modelSelection: ModelSelection, runtimeMode: RuntimeMode, interactionMode: ProviderInteractionMode, promptEffort: String? = nil) {
    self.modelSelection = modelSelection
    self.runtimeMode = runtimeMode
    self.interactionMode = interactionMode
    self.promptEffort = promptEffort
  }
}

/// The thread as the composer saw it when a turn start went out (`LocalDispatchSnapshot`).
public struct ThreadDispatchSnapshot: Sendable, Hashable, Codable {
  public var startedAt: String
  public var preparingWorktree: Bool
  public var submissionIntent: ComposerSubmissionIntent
  public var latestUserMessageId: String?
  public var latestTurnTurnId: String?
  public var latestTurnRequestedAt: String?
  public var latestTurnStartedAt: String?
  public var latestTurnCompletedAt: String?
  public var sessionStatus: String?
  public var sessionUpdatedAt: String?
  public var latestTurnStartFailureId: String?

  public init(
    startedAt: String, preparingWorktree: Bool = false, submissionIntent: ComposerSubmissionIntent = .foreground,
    latestUserMessageId: String? = nil, latestTurnTurnId: String? = nil, latestTurnRequestedAt: String? = nil,
    latestTurnStartedAt: String? = nil, latestTurnCompletedAt: String? = nil, sessionStatus: String? = nil,
    sessionUpdatedAt: String? = nil, latestTurnStartFailureId: String? = nil
  ) {
    self.startedAt = startedAt
    self.preparingWorktree = preparingWorktree
    self.submissionIntent = submissionIntent
    self.latestUserMessageId = latestUserMessageId
    self.latestTurnTurnId = latestTurnTurnId
    self.latestTurnRequestedAt = latestTurnRequestedAt
    self.latestTurnStartedAt = latestTurnStartedAt
    self.latestTurnCompletedAt = latestTurnCompletedAt
    self.sessionStatus = sessionStatus
    self.sessionUpdatedAt = sessionUpdatedAt
    self.latestTurnStartFailureId = latestTurnStartFailureId
  }
}

/// A composer submission held back while the thread's turn is running. It carries the full draft
/// snapshot so it can be dispatched later with the same text, attachments and context.
public struct QueuedComposerMessage: Sendable, Hashable, Identifiable, Codable {
  public enum Sending: String, Sendable, Codable { case preparing, dispatching }

  public var id: String
  public var prompt: String
  public var attachments: [ComposerAttachment]
  public var records: [ComposerContextRecord]
  public var sendSettings: QueuedMessageSendSettings
  /// The newest completed tool activity at queue time; a different id later is the boundary the
  /// message goes out on.
  public var queuedAfterToolActivityId: String?
  /// Set when Stop or a failed restore created the message: it waits for Send now.
  public var holdUntilUserAction: Bool
  /// Set while a send is under way; Stop can take back a "preparing" message, not a "dispatching" one.
  public var sending: Sending?
  public var createdAt: String

  public init(
    id: String, prompt: String, attachments: [ComposerAttachment] = [], records: [ComposerContextRecord] = [],
    sendSettings: QueuedMessageSendSettings, queuedAfterToolActivityId: String? = nil, holdUntilUserAction: Bool = false,
    sending: Sending? = nil, createdAt: String
  ) {
    self.id = id
    self.prompt = prompt
    self.attachments = attachments
    self.records = records
    self.sendSettings = sendSettings
    self.queuedAfterToolActivityId = queuedAfterToolActivityId
    self.holdUntilUserAction = holdUntilUserAction
    self.sending = sending
    self.createdAt = createdAt
  }
}

/// The thread as it was when its last queued turn start went out. The next message waits until the
/// server has moved past it.
public struct QueuedDispatch: Sendable, Hashable {
  /// The message that went out, or nil for a dispatch restored after a failure.
  public var messageId: String?
  public var thread: ThreadDispatchSnapshot
  /// The dispatch this one replaced; if this send fails, that one still counts.
  public var previous: ThreadDispatchSnapshot?
}

/// Queued follow-ups per thread (`queuedMessageStore.ts`). In memory only: a queued message is a
/// live intent, not a draft worth persisting.
public struct QueuedMessageStore: Sendable {
  public private(set) var queuesByThreadKey: [String: [QueuedComposerMessage]] = [:]
  public private(set) var lastDispatchByThreadKey: [String: QueuedDispatch] = [:]

  public init() {}

  public func queue(_ threadKey: String) -> [QueuedComposerMessage] { queuesByThreadKey[threadKey] ?? [] }

  /// Replaces one thread's queue. `lastDispatch` `.forget` clears it, `.keep` leaves it; an empty
  /// queue always forgets it.
  private enum Dispatch {
    case keep
    case forget
    case set(QueuedDispatch)
  }

  private mutating func update(_ threadKey: String, _ queue: [QueuedComposerMessage], _ dispatch: Dispatch = .keep) {
    queuesByThreadKey[threadKey] = queue
    if case .set(let value) = dispatch { lastDispatchByThreadKey[threadKey] = value }
    if queue.isEmpty { queuesByThreadKey[threadKey] = nil }
    if queue.isEmpty { lastDispatchByThreadKey[threadKey] = nil }
    if case .forget = dispatch { lastDispatchByThreadKey[threadKey] = nil }
  }

  /// Appends a message behind the others.
  public mutating func enqueue(_ threadKey: String, _ message: QueuedComposerMessage) {
    update(threadKey, queue(threadKey) + [message])
  }

  /// Marks one message as sending and returns it, or nil when it is gone or the thread already has
  /// a send under way. The other messages are re-anchored to `toolActivityId` so only one leaves per
  /// tool boundary.
  public mutating func beginSend(_ threadKey: String, id: String, toolActivityId: String?) -> QueuedComposerMessage? {
    let current = queue(threadKey)
    guard let entry = current.first(where: { $0.id == id }), !current.contains(where: { $0.sending != nil }) else { return nil }
    update(
      threadKey,
      current.map { message in
        var next = message
        if message.id == id {
          next.sending = .preparing
        } else if message.queuedAfterToolActivityId != toolActivityId {
          next.queuedAfterToolActivityId = toolActivityId
        }
        return next
      })
    return entry
  }

  /// The turn start is going out. False when Stop took the message back first.
  public mutating func markDispatching(_ threadKey: String, id: String, thread: ThreadDispatchSnapshot) -> Bool {
    let current = queue(threadKey)
    guard current.contains(where: { $0.id == id && $0.sending != nil }) else { return false }
    let previous = lastDispatchByThreadKey[threadKey]?.thread
    update(
      threadKey,
      current.map { message in
        var next = message
        if message.id == id { next.sending = .dispatching }
        return next
      }, .set(QueuedDispatch(messageId: id, thread: thread, previous: previous)))
    return true
  }

  /// Drops a message whose send went out, or that had nothing left to send.
  public mutating func finishSend(_ threadKey: String, id: String) {
    let current = queue(threadKey)
    guard current.contains(where: { $0.id == id }) else { return }
    update(threadKey, current.filter { $0.id != id })
  }

  /// Moves a message whose send failed back to the head, held for user action. False when Stop
  /// already took the message back.
  public mutating func failSend(_ threadKey: String, id: String) -> Bool {
    let current = queue(threadKey)
    guard var entry = current.first(where: { $0.id == id }) else { return false }
    entry.sending = nil
    entry.holdUntilUserAction = true
    // This send never reached the server, so only an earlier one is worth waiting for.
    let dispatch = lastDispatchByThreadKey[threadKey]
    var next: Dispatch = .keep
    if let dispatch, dispatch.messageId == id {
      next = dispatch.previous.map { .set(QueuedDispatch(messageId: nil, thread: $0, previous: nil)) } ?? .forget
    }
    update(threadKey, [entry] + current.filter { $0.id != id }, next)
    return true
  }

  /// Removes one message without touching the others' anchors. Nil when gone or sending.
  public mutating func remove(_ threadKey: String, id: String) -> QueuedComposerMessage? {
    let current = queue(threadKey)
    guard let entry = current.first(where: { $0.id == id }), entry.sending == nil else { return nil }
    update(threadKey, current.filter { $0.id != id })
    return entry
  }

  /// Removes and returns every message that is not already on the wire.
  public mutating func drain(_ threadKey: String) -> [QueuedComposerMessage] {
    let current = queue(threadKey)
    let drained = current.filter { $0.sending != .dispatching }
    if drained.isEmpty { return [] }
    update(threadKey, current.filter { $0.sending == .dispatching })
    return drained
  }
}

public enum QueuedMessages {
  public enum Phase: String, Sendable, Codable { case connecting, running, ready, disconnected }

  public struct ToolActivity: Sendable, Hashable {
    public var id: String
    public var kind: String
    public var sequence: Int?
    public var createdAt: String

    public init(id: String, kind: String, sequence: Int? = nil, createdAt: String) {
      self.id = id
      self.kind = kind
      self.sequence = sequence
      self.createdAt = createdAt
    }
  }

  /// The newest finished tool call; its id changing is the boundary a queued message goes out on.
  /// Picks by sequence rather than position because a database snapshot is not sorted.
  public static func latestCompletedToolActivityId(_ activities: [ToolActivity]) -> String? {
    var latest: ToolActivity?
    for activity in activities where activity.kind == "tool.completed" {
      guard let current = latest else {
        latest = activity
        continue
      }
      let sequence = activity.sequence ?? -1
      let best = current.sequence ?? -1
      if sequence > best || (sequence == best && activity.createdAt > current.createdAt) { latest = activity }
    }
    return latest?.id
  }

  /// Due mid-turn once a tool call finished after it was queued, and as soon as the turn is over
  /// otherwise. "connecting" is the gap between a send and the provider picking it up.
  public static func isDue(holdUntilUserAction: Bool, queuedAfterToolActivityId: String?, phase: Phase, latestToolActivityId: String?) -> Bool {
    if holdUntilUserAction || phase == .connecting { return false }
    if phase != .running { return true }
    return latestToolActivityId != queuedAfterToolActivityId
  }

  public struct DispatchInput: Sendable {
    public var phase: Phase
    public var latestTurn: LatestTurn?
    public var latestUserMessageId: String?
    public var session: Session?
    public var hasPendingApproval: Bool
    public var hasPendingUserInput: Bool
    public var latestTurnStartFailureId: String?
    public var threadError: String?

    public struct LatestTurn: Sendable, Hashable {
      public var turnId: String
      public var requestedAt: String?
      public var startedAt: String?
      public var completedAt: String?

      public init(turnId: String, requestedAt: String? = nil, startedAt: String? = nil, completedAt: String? = nil) {
        self.turnId = turnId
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
      }
    }

    public struct Session: Sendable, Hashable {
      public var status: String
      public var updatedAt: String
      public var activeTurnId: String?

      public init(status: String, updatedAt: String, activeTurnId: String? = nil) {
        self.status = status
        self.updatedAt = updatedAt
        self.activeTurnId = activeTurnId
      }
    }

    public init(
      phase: Phase, latestTurn: LatestTurn? = nil, latestUserMessageId: String? = nil, session: Session? = nil,
      hasPendingApproval: Bool = false, hasPendingUserInput: Bool = false, latestTurnStartFailureId: String? = nil, threadError: String? = nil
    ) {
      self.phase = phase
      self.latestTurn = latestTurn
      self.latestUserMessageId = latestUserMessageId
      self.session = session
      self.hasPendingApproval = hasPendingApproval
      self.hasPendingUserInput = hasPendingUserInput
      self.latestTurnStartFailureId = latestTurnStartFailureId
      self.threadError = threadError
    }
  }

  /// `hasServerAcknowledgedLocalDispatch`: has the server moved past the turn start we sent?
  public static func hasServerAcknowledged(_ dispatch: ThreadDispatchSnapshot?, _ input: DispatchInput) -> Bool {
    guard let dispatch else { return false }
    if input.hasPendingApproval || input.hasPendingUserInput || !(input.threadError ?? "").isEmpty { return true }
    if let failure = input.latestTurnStartFailureId, failure != dispatch.latestTurnStartFailureId { return true }
    if input.phase == .connecting { return false }
    let turn = input.latestTurn
    let session = input.session
    let userMessageChanged = dispatch.latestUserMessageId != input.latestUserMessageId
    let turnChanged =
      dispatch.latestTurnTurnId != turn?.turnId || dispatch.latestTurnRequestedAt != turn?.requestedAt
      || dispatch.latestTurnStartedAt != turn?.startedAt || dispatch.latestTurnCompletedAt != turn?.completedAt
    if input.phase == .running {
      // Steering adds a user message to the running turn without necessarily changing any turn
      // timestamp, so that projected message is the acknowledgment.
      if userMessageChanged { return true }
      if !turnChanged { return false }
      guard let turn, turn.startedAt != nil else { return false }
      if let active = session?.activeTurnId, turn.turnId != active { return false }
      return true
    }
    return turnChanged || dispatch.sessionStatus != session?.status || dispatch.sessionUpdatedAt != session?.updatedAt
  }
}
