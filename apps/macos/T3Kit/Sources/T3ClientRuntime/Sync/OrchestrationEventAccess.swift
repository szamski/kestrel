import T3Contracts

extension V1.OrchestrationEvent {
  /// Global event sequence; nil for a variant this build does not know.
  public var sequence: Int? {
    switch self {
    case .projectCreated(let e): e.sequence
    case .projectMetaUpdated(let e): e.sequence
    case .projectDeleted(let e): e.sequence
    case .threadCreated(let e): e.sequence
    case .threadDeleted(let e): e.sequence
    case .threadArchived(let e): e.sequence
    case .threadUnarchived(let e): e.sequence
    case .threadSettled(let e): e.sequence
    case .threadUnsettled(let e): e.sequence
    case .threadSnoozed(let e): e.sequence
    case .threadUnsnoozed(let e): e.sequence
    case .threadPinned(let e): e.sequence
    case .threadUnpinned(let e): e.sequence
    case .threadPinReordered(let e): e.sequence
    case .threadAutoSettleSet(let e): e.sequence
    case .threadMetaUpdated(let e): e.sequence
    case .threadPullRequestLinked(let e): e.sequence
    case .threadPullRequestUnlinked(let e): e.sequence
    case .threadPullRequestSynced(let e): e.sequence
    case .threadRuntimeModeSet(let e): e.sequence
    case .threadInteractionModeSet(let e): e.sequence
    case .threadMessageSent(let e): e.sequence
    case .threadTurnStartRequested(let e): e.sequence
    case .threadTurnInterruptRequested(let e): e.sequence
    case .threadApprovalResponseRequested(let e): e.sequence
    case .threadUserInputResponseRequested(let e): e.sequence
    case .threadCheckpointRevertRequested(let e): e.sequence
    case .threadReverted(let e): e.sequence
    case .threadSessionStopRequested(let e): e.sequence
    case .threadSessionSet(let e): e.sequence
    case .threadProposedPlanUpserted(let e): e.sequence
    case .threadTurnDiffCompleted(let e): e.sequence
    case .threadActivityAppended(let e): e.sequence
    case .unknown(let raw): if case .int(let v)? = raw["sequence"] { v } else { nil }
    }
  }

  public var occurredAt: IsoDateTime? {
    switch self {
    case .projectCreated(let e): e.occurredAt
    case .projectMetaUpdated(let e): e.occurredAt
    case .projectDeleted(let e): e.occurredAt
    case .threadCreated(let e): e.occurredAt
    case .threadDeleted(let e): e.occurredAt
    case .threadArchived(let e): e.occurredAt
    case .threadUnarchived(let e): e.occurredAt
    case .threadSettled(let e): e.occurredAt
    case .threadUnsettled(let e): e.occurredAt
    case .threadSnoozed(let e): e.occurredAt
    case .threadUnsnoozed(let e): e.occurredAt
    case .threadPinned(let e): e.occurredAt
    case .threadUnpinned(let e): e.occurredAt
    case .threadPinReordered(let e): e.occurredAt
    case .threadAutoSettleSet(let e): e.occurredAt
    case .threadMetaUpdated(let e): e.occurredAt
    case .threadPullRequestLinked(let e): e.occurredAt
    case .threadPullRequestUnlinked(let e): e.occurredAt
    case .threadPullRequestSynced(let e): e.occurredAt
    case .threadRuntimeModeSet(let e): e.occurredAt
    case .threadInteractionModeSet(let e): e.occurredAt
    case .threadMessageSent(let e): e.occurredAt
    case .threadTurnStartRequested(let e): e.occurredAt
    case .threadTurnInterruptRequested(let e): e.occurredAt
    case .threadApprovalResponseRequested(let e): e.occurredAt
    case .threadUserInputResponseRequested(let e): e.occurredAt
    case .threadCheckpointRevertRequested(let e): e.occurredAt
    case .threadReverted(let e): e.occurredAt
    case .threadSessionStopRequested(let e): e.occurredAt
    case .threadSessionSet(let e): e.occurredAt
    case .threadProposedPlanUpserted(let e): e.occurredAt
    case .threadTurnDiffCompleted(let e): e.occurredAt
    case .threadActivityAppended(let e): e.occurredAt
    case .unknown: nil
    }
  }

  public var isThreadDeleted: Bool { if case .threadDeleted = self { true } else { false } }
  public var isThreadReverted: Bool { if case .threadReverted = self { true } else { false } }
}
