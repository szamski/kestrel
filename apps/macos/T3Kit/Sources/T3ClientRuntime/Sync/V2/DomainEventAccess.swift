import T3Contracts

extension OrchestrationV2DomainEvent {
  /// The thread an event belongs to; nil for a variant this build does not know.
  public var threadId: ThreadId? {
    switch self {
    case .threadCreated(let e): e.threadId
    case .threadArchived(let e): e.threadId
    case .runCreated(let e): e.threadId
    case .runUpdated(let e): e.threadId
    case .runBackgroundWorkCancelled(let e): e.threadId
    case .runAttemptCreated(let e): e.threadId
    case .runAttemptUpdated(let e): e.threadId
    case .nodeUpdated(let e): e.threadId
    case .subagentUpdated(let e): e.threadId
    case .providerSessionAttached(let e): e.threadId
    case .providerSessionDetached(let e): e.threadId
    case .providerThreadUpdated(let e): e.threadId
    case .providerTurnUpdated(let e): e.threadId
    case .runtimeRequestUpdated(let e): e.threadId
    case .messageUpdated(let e): e.threadId
    case .turnItemUpdated(let e): e.threadId
    case .planUpdated(let e): e.threadId
    case .checkpointScopeCreated(let e): e.threadId
    case .checkpointCaptured(let e): e.threadId
    case .checkpointRollbackRequested(let e): e.threadId
    case .contextHandoffUpdated(let e): e.threadId
    case .contextTransferCreated(let e): e.threadId
    case .contextTransferUpdated(let e): e.threadId
    case .unknown(let json): if case .object(let o) = json, case .string(let id)? = o["threadId"] { ThreadId(rawValue: id) } else { nil }
    }
  }

  public var occurredAt: IsoDateTime? {
    switch self {
    case .threadCreated(let e): e.occurredAt
    case .threadArchived(let e): e.occurredAt
    case .runCreated(let e): e.occurredAt
    case .runUpdated(let e): e.occurredAt
    case .runBackgroundWorkCancelled(let e): e.occurredAt
    case .runAttemptCreated(let e): e.occurredAt
    case .runAttemptUpdated(let e): e.occurredAt
    case .nodeUpdated(let e): e.occurredAt
    case .subagentUpdated(let e): e.occurredAt
    case .providerSessionAttached(let e): e.occurredAt
    case .providerSessionDetached(let e): e.occurredAt
    case .providerThreadUpdated(let e): e.occurredAt
    case .providerTurnUpdated(let e): e.occurredAt
    case .runtimeRequestUpdated(let e): e.occurredAt
    case .messageUpdated(let e): e.occurredAt
    case .turnItemUpdated(let e): e.occurredAt
    case .planUpdated(let e): e.occurredAt
    case .checkpointScopeCreated(let e): e.occurredAt
    case .checkpointCaptured(let e): e.occurredAt
    case .checkpointRollbackRequested(let e): e.occurredAt
    case .contextHandoffUpdated(let e): e.occurredAt
    case .contextTransferCreated(let e): e.occurredAt
    case .contextTransferUpdated(let e): e.occurredAt
    case .unknown(let json): if case .object(let o) = json, case .string(let at)? = o["occurredAt"] { IsoDateTime(rawValue: at) } else { nil }
    }
  }

  /// `thread.deleted` ends the thread: the stream consumer drops its data instead of reducing it.
  public var isThreadDeleted: Bool {
    if case .threadArchived(let e) = self, case .threadDeleted = e.type { return true }
    if case .unknown(let json) = self, case .object(let o) = json, case .string("thread.deleted")? = o["type"] { return true }
    return false
  }
}
