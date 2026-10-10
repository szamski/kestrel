import Foundation
import T3Contracts
import T3Timeline

// MARK: - Settings and capabilities

public enum FollowUpBehavior: String, Sendable, Hashable, Codable, CaseIterable {
  /// A message sent during a running turn waits and goes out on its own.
  case queue
  /// A message sent during a running turn goes out immediately.
  case steer
}

/// The settings that shape the composer (`ClientSettings` plus the model preferences).
public struct ComposerSettings: Sendable, Hashable {
  public var sendShortcut: SendShortcut
  public var followUpBehavior: FollowUpBehavior
  public var showSkillsInSlashMenu: Bool
  /// Rich-text editing. Off keeps formatting markers literal ("plain" mode).
  public var richTextEnabled: Bool
  public var collapseOnScroll: Bool
  public var contextWindowMeterEnabled: Bool
  public var models: ComposerModelSettings

  public init(
    sendShortcut: SendShortcut = .enter, followUpBehavior: FollowUpBehavior = .queue, showSkillsInSlashMenu: Bool = true, richTextEnabled: Bool = true,
    collapseOnScroll: Bool = true, contextWindowMeterEnabled: Bool = false, models: ComposerModelSettings = ComposerModelSettings()
  ) {
    self.sendShortcut = sendShortcut
    self.followUpBehavior = followUpBehavior
    self.showSkillsInSlashMenu = showSkillsInSlashMenu
    self.richTextEnabled = richTextEnabled
    self.collapseOnScroll = collapseOnScroll
    self.contextWindowMeterEnabled = contextWindowMeterEnabled
    self.models = models
  }
}

/// What the connected environment accepts.
public struct ComposerCapabilities: Sendable, Hashable {
  public var attachments: AttachmentRules.Capabilities
  /// Servers from before inline context drop `message.context`, so their turns carry the payload
  /// in the text instead.
  public var inlineMessageContext: Bool

  public init(attachments: AttachmentRules.Capabilities = .init(), inlineMessageContext: Bool = true) {
    self.attachments = attachments
    self.inlineMessageContext = inlineMessageContext
  }
}

/// Server configuration as the composer consumes it: provider instances (models, skills, slash
/// commands), settings and capabilities. The host builds it from `ServerConfig` and client settings.
public struct ComposerCatalog: Sendable {
  public var providers: [ProviderSnapshot]
  public var settings: ComposerSettings
  public var capabilities: ComposerCapabilities
  /// Model selection new threads start with (server default or the user's sticky pick).
  public var defaultModelSelection: ModelSelection?
  public var defaultRuntimeMode: RuntimeMode

  public init(
    providers: [ProviderSnapshot] = [], settings: ComposerSettings = ComposerSettings(), capabilities: ComposerCapabilities = ComposerCapabilities(),
    defaultModelSelection: ModelSelection? = nil, defaultRuntimeMode: RuntimeMode = .fullAccess
  ) {
    self.providers = providers
    self.settings = settings
    self.capabilities = capabilities
    self.defaultModelSelection = defaultModelSelection
    self.defaultRuntimeMode = defaultRuntimeMode
  }

  /// Provider instances with the settings overlay applied, default instances first.
  public var instanceEntries: [ProviderInstanceEntry] {
    ModelCatalog.sortEntries(ModelCatalog.applySettings(ModelCatalog.deriveEntries(providers), settings.models))
  }
}

// MARK: - Thread state

/// Token usage of the thread's context window (`lib/contextWindow.ts`).
public struct ContextWindowSnapshot: Sendable, Hashable {
  public var usedTokens: Double
  public var maxTokens: Double?
  public var usedPercentage: Double?
  public var remainingTokens: Double?
  public var remainingPercentage: Double?
  public var compactsAutomatically: Bool
  public var autoCompactThreshold: Double?
  public var updatedAt: String

  public init(usedTokens: Double, maxTokens: Double? = nil, compactsAutomatically: Bool = false, autoCompactThreshold: Double? = nil, updatedAt: String = "") {
    self.usedTokens = usedTokens
    self.maxTokens = maxTokens
    let percentage = maxTokens.flatMap { $0 > 0 ? min(100, usedTokens / $0 * 100) : nil }
    self.usedPercentage = percentage
    self.remainingTokens = maxTokens.map { max(0, (($0 - usedTokens)).rounded()) }
    self.remainingPercentage = percentage.map { max(0, 100 - $0) }
    self.compactsAutomatically = compactsAutomatically
    self.autoCompactThreshold = autoCompactThreshold
    self.updatedAt = updatedAt
  }

  /// The newest `context-window.updated` activity with a usable `usedTokens`.
  public static func latest(in activities: [V1.OrchestrationThreadActivity]) -> ContextWindowSnapshot? {
    for activity in activities.reversed() where activity.kind == "context-window.updated" {
      func number(_ key: String) -> Double? {
        switch activity.payload[key] {
        case .int(let value)?: Double(value)
        case .double(let value)? where value.isFinite: value
        default: nil
        }
      }
      guard let used = number("usedTokens"), used >= 0 else { continue }
      var flag = false
      if case .bool(let value)? = activity.payload["compactsAutomatically"] { flag = value }
      return ContextWindowSnapshot(
        usedTokens: used, maxTokens: number("maxTokens"), compactsAutomatically: flag, autoCompactThreshold: number("autoCompactThreshold"),
        updatedAt: activity.createdAt.rawValue)
    }
    return nil
  }

  /// `1.2k`, `35k`, `1.5m`.
  public static func formatTokens(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "0" }
    func trimmed(_ number: Double) -> String {
      let text = String(format: "%.1f", number)
      return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    if value < 1_000 { return "\(Int(value.rounded()))" }
    if value < 10_000 { return "\(trimmed(value / 1_000))k" }
    if value < 1_000_000 { return "\(Int((value / 1_000).rounded()))k" }
    return "\(trimmed(value / 1_000_000))m"
  }
}

/// The server-side queue of a protocol-2 thread: user messages waiting behind the active run. Protocol-1 threads have
/// none (`ComposerThreadSnapshot.serverQueue == nil`) and keep the composer's own queue.
public struct ComposerServerQueue: Sendable, Equatable {
  public struct Item: Sendable, Equatable, Identifiable {
    public var runId: RunId
    public var messageId: MessageId
    public var text: String
    public var attachments: [ChatAttachment]
    public var context: OrchestrationMessageContext?
    public var id: RunId { runId }

    public init(runId: RunId, messageId: MessageId, text: String, attachments: [ChatAttachment] = [], context: OrchestrationMessageContext? = nil) {
      self.runId = runId
      self.messageId = messageId
      self.text = text
      self.attachments = attachments
      self.context = context
    }
  }

  public var items: [Item]
  /// The run a queued message can be steered into.
  public var activeRunId: RunId?
  /// Stop held the queue: it waits for `resumeQueue`.
  public var isHeld: Bool
  public var canReorder: Bool
  public var canPromoteToSteer: Bool

  public init(items: [Item] = [], activeRunId: RunId? = nil, isHeld: Bool = false, canReorder: Bool = false, canPromoteToSteer: Bool = false) {
    self.items = items
    self.activeRunId = activeRunId
    self.isHeld = isHeld
    self.canReorder = canReorder
    self.canPromoteToSteer = canPromoteToSteer
  }
}

/// What a send does while a run is active on a protocol-2 thread (`dispatchMode` of the web composer); without
/// an active run every delivery starts one.
public enum ComposerDelivery: Sendable, Hashable {
  case auto
  case queue
  case steer
}

/// What the composer needs to know about its thread, pushed by the host as it changes.
public struct ComposerThreadSnapshot: Sendable {
  public var phase: QueuedMessages.Phase
  /// Newest finished tool call: the boundary a queued message goes out on.
  public var latestToolActivityId: String?
  public var pending: PendingPrompts
  public var promptHistory: [ComposerPromptHistoryMessage]
  public var dispatch: QueuedMessages.DispatchInput
  public var threadModelSelection: ModelSelection?
  public var projectModelSelection: ModelSelection?
  public var runtimeMode: RuntimeMode?
  public var interactionMode: ProviderInteractionMode?
  public var contextWindow: ContextWindowSnapshot?
  /// The provider instance running the thread's session, once it has started.
  public var sessionProviderInstanceId: String?
  /// A thread without messages sends its first message (title seeding).
  public var isFirstMessage: Bool
  public var isDetailLoaded: Bool
  /// Set when the environment cannot take a send (disconnected, no project).
  public var unavailableReason: String?
  /// A revert is rewriting the thread.
  public var isRewinding: Bool
  /// Protocol 2: the server's queue and run state. Nil on protocol 1.
  public var serverQueue: ComposerServerQueue?

  public init(
    phase: QueuedMessages.Phase = .ready, latestToolActivityId: String? = nil, pending: PendingPrompts = derivePendingPrompts([]),
    promptHistory: [ComposerPromptHistoryMessage] = [], dispatch: QueuedMessages.DispatchInput? = nil, threadModelSelection: ModelSelection? = nil,
    projectModelSelection: ModelSelection? = nil, runtimeMode: RuntimeMode? = nil, interactionMode: ProviderInteractionMode? = nil,
    contextWindow: ContextWindowSnapshot? = nil, sessionProviderInstanceId: String? = nil, isFirstMessage: Bool = true, isDetailLoaded: Bool = true,
    unavailableReason: String? = nil, isRewinding: Bool = false, serverQueue: ComposerServerQueue? = nil
  ) {
    self.serverQueue = serverQueue
    self.phase = phase
    self.latestToolActivityId = latestToolActivityId
    self.pending = pending
    self.promptHistory = promptHistory
    self.dispatch = dispatch ?? QueuedMessages.DispatchInput(phase: phase, hasPendingApproval: !pending.approvals.isEmpty, hasPendingUserInput: !pending.userInputs.isEmpty)
    self.threadModelSelection = threadModelSelection
    self.projectModelSelection = projectModelSelection
    self.runtimeMode = runtimeMode
    self.interactionMode = interactionMode
    self.contextWindow = contextWindow
    self.sessionProviderInstanceId = sessionProviderInstanceId
    self.isFirstMessage = isFirstMessage
    self.isDetailLoaded = isDetailLoaded
    self.unavailableReason = unavailableReason
    self.isRewinding = isRewinding
  }

  /// Derives everything from the thread read model with the same helpers the timeline uses.
  public init(thread: V1.OrchestrationThread, unavailableReason: String? = nil, isRewinding: Bool = false) {
    func phase(_ value: SessionPhase) -> QueuedMessages.Phase { QueuedMessages.Phase(rawValue: value.rawValue) ?? .ready }
    let phase = phase(derivePhase(thread.session))
    let pending = derivePendingPrompts(thread.activities)
    let latestUser = thread.messages.last { $0.role == .user }
    let turn = thread.latestTurn
    self.init(
      phase: phase,
      latestToolActivityId: QueuedMessages.latestCompletedToolActivityId(
        thread.activities.map { QueuedMessages.ToolActivity(id: $0.id.rawValue, kind: $0.kind, sequence: $0.sequence, createdAt: $0.createdAt.rawValue) }),
      pending: pending,
      promptHistory: thread.messages.map { ComposerPromptHistoryMessage(id: $0.id.rawValue, role: $0.role.rawValue, text: $0.text) },
      dispatch: QueuedMessages.DispatchInput(
        phase: phase,
        latestTurn: turn.map { .init(turnId: $0.turnId.rawValue, requestedAt: $0.requestedAt.rawValue, startedAt: $0.startedAt?.rawValue, completedAt: $0.completedAt?.rawValue) },
        latestUserMessageId: latestUser?.id.rawValue,
        session: thread.session.map { .init(status: $0.status.rawValue, updatedAt: $0.updatedAt.rawValue, activeTurnId: $0.activeTurnId?.rawValue) },
        hasPendingApproval: !pending.approvals.isEmpty, hasPendingUserInput: !pending.userInputs.isEmpty,
        latestTurnStartFailureId: latestUser.flatMap { user in
          thread.activities.last { activity in
            guard activity.kind == "provider.turn.start.failed", case .string(let id)? = activity.payload["requestId"] else { return false }
            return id == user.id.rawValue
          }?.id.rawValue
        }),
      threadModelSelection: thread.modelSelection, runtimeMode: thread.runtimeMode,
      interactionMode: ProviderInteractionMode(rawValue: thread.interactionMode.rawValue), contextWindow: ContextWindowSnapshot.latest(in: thread.activities),
      sessionProviderInstanceId: thread.session?.providerInstanceId?.rawValue, isFirstMessage: thread.messages.isEmpty, unavailableReason: unavailableReason, isRewinding: isRewinding)
  }

  public var isRunning: Bool { phase == .running }
}

// MARK: - Requests

/// One attachment on the wire once its upload settled (or its bytes as a data URL for servers
/// without uploads).
public enum ComposerWireAttachment: Sendable, Hashable {
  case uploaded(V1.ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem)
  case userInput(V1.ClientOrchestrationCommandThreadUserInputRespondAttachmentsByQuestionIdValueItem)
}

/// A file the composer wants stored on the environment before a send.
public struct ComposerUploadRequest: Sendable {
  public var attachmentId: String
  public var kind: ComposerAttachment.Kind
  public var name: String
  public var mimeType: String
  public var sizeBytes: Int
  /// The staged bytes inside the app's attachment cache.
  public var fileURL: URL

  public init(attachmentId: String, kind: ComposerAttachment.Kind, name: String, mimeType: String, sizeBytes: Int, fileURL: URL) {
    self.attachmentId = attachmentId
    self.kind = kind
    self.name = name
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.fileURL = fileURL
  }
}

public enum UploadVerification: Sendable, Hashable {
  case verified
  /// The server no longer has it (uploads expire after 24 hours).
  case missing
  case failed
}

/// How the composer reaches the outside world. The app implements it on top of T3ClientRuntime;
/// `FakeComposerEnvironment` serves previews and tests. Every operation is async and may throw;
/// the composer shows the failure and keeps the draft.
public protocol ComposerEnvironment: Sendable {
  // MARK: Server configuration and live thread state

  func catalog() async -> ComposerCatalog
  /// Emits whenever providers, settings or capabilities change.
  func catalogUpdates() -> AsyncStream<ComposerCatalog>
  /// Emits the thread's state whenever it changes, starting with the current one. Also used by
  /// the queue dispatcher for threads that are not on screen.
  func threadSnapshots(for target: ComposerTarget) -> AsyncStream<ComposerThreadSnapshot>

  // MARK: Context sources

  /// `projects.searchEntries` for `@`.
  func searchWorkspaceEntries(cwd: String, query: String, limit: Int) async throws -> ProjectSearchEntriesResult
  /// Recent (or text-searched) pull requests of the project's repository for `#`.
  func listPullRequests(projectId: String, query: String?, limit: Int) async throws -> [ComposerPullRequestCandidate]
  /// One pull request by number when it is older than the recent list.
  func resolvePullRequest(projectId: String, repository: String, number: Int) async throws -> ComposerPullRequestCandidate?

  // MARK: Attachments

  /// Stores the bytes on the environment and returns the attachment id. `progress` is 0...1.
  func uploadAttachment(_ upload: ComposerUploadRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> String
  func deleteUploadedAttachment(id: String) async
  func verifyUploadedAttachment(id: String) async -> UploadVerification
  /// Fetches an attachment of another message (clipboard paste across threads) into a local file.
  func downloadAttachment(id: String, sourceEnvironmentId: String, to url: URL) async throws

  // MARK: Turn actions

  /// Sends `thread.turn.start`. The implementation also applies the thread-level side effects the
  /// web composer performs around a send (title seeding, model / mode persistence).
  func sendTurn(_ command: V1.ClientOrchestrationCommandThreadTurnStart, target: ComposerTarget, titleSeed: String?, isFirstMessage: Bool) async throws
  /// Same as `sendTurn`, with the delivery protocol 2 applies while a run is active. Protocol 1 ignores it.
  func sendTurn(
    _ command: V1.ClientOrchestrationCommandThreadTurnStart, target: ComposerTarget, titleSeed: String?, isFirstMessage: Bool, delivery: ComposerDelivery
  ) async throws
  func interruptTurn(_ command: V1.ClientOrchestrationCommandThreadTurnInterrupt, target: ComposerTarget) async throws
  func respondToApproval(_ command: V1.ClientOrchestrationCommandThreadApprovalRespond, target: ComposerTarget) async throws
  func respondToUserInput(_ command: V1.ClientOrchestrationCommandThreadUserInputRespond, target: ComposerTarget) async throws
  /// Closes an async question without messaging the agent.
  func dismissUserInput(requestId: V1.ApprovalRequestId, target: ComposerTarget) async throws

  // MARK: Server queue (protocol 2)

  /// Hands a queued message to the active run.
  func steerQueued(runId: RunId, into targetRunId: RunId, target: ComposerTarget) async throws
  /// Replaces a queued message; `attachments` and `context` are the complete new set.
  func editQueued(runId: RunId, text: String, attachments: [ChatAttachment], context: OrchestrationMessageContext?, target: ComposerTarget) async throws
  /// Moves a queued message in front of `beforeRunId` (nil: to the end).
  func reorderQueued(runId: RunId, before beforeRunId: RunId?, target: ComposerTarget) async throws
  func cancelQueued(runId: RunId, target: ComposerTarget) async throws
  /// Releases a queue that Stop held.
  func resumeQueue(target: ComposerTarget) async throws

  // MARK: Client settings

  /// Favorites live in the host's client settings; the picker asks it to flip one.
  func setFavoriteModel(instanceId: String, slug: String, isFavorite: Bool) async

  // MARK: Persistence

  /// Opaque storage for drafts and the stash (`composer-drafts`, `prompt-stash`).
  func loadStorage(key: String) async -> Data?
  func saveStorage(key: String, data: Data) async throws
}

/// Defaults so hosts implement only what they support; unsupported operations fail loudly.
public struct ComposerEnvironmentError: Error, LocalizedError, Sendable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

extension ComposerEnvironment {
  public func sendTurn(
    _ command: V1.ClientOrchestrationCommandThreadTurnStart, target: ComposerTarget, titleSeed: String?, isFirstMessage: Bool, delivery: ComposerDelivery
  ) async throws {
    try await sendTurn(command, target: target, titleSeed: titleSeed, isFirstMessage: isFirstMessage)
  }

  public func steerQueued(runId: RunId, into targetRunId: RunId, target: ComposerTarget) async throws { throw Self.noServerQueue }
  public func editQueued(runId: RunId, text: String, attachments: [ChatAttachment], context: OrchestrationMessageContext?, target: ComposerTarget) async throws {
    throw Self.noServerQueue
  }
  public func reorderQueued(runId: RunId, before beforeRunId: RunId?, target: ComposerTarget) async throws { throw Self.noServerQueue }
  public func cancelQueued(runId: RunId, target: ComposerTarget) async throws { throw Self.noServerQueue }
  public func resumeQueue(target: ComposerTarget) async throws { throw Self.noServerQueue }

  private static var noServerQueue: ComposerEnvironmentError { ComposerEnvironmentError("This environment has no server-side queue.") }

  public func downloadAttachment(id: String, sourceEnvironmentId: String, to url: URL) async throws {
    throw ComposerEnvironmentError("Attachments cannot be copied between environments here.")
  }

  public func resolvePullRequest(projectId: String, repository: String, number: Int) async throws -> ComposerPullRequestCandidate? { nil }

  /// Favorites live in the host's client settings; the picker asks it to flip one.
  public func setFavoriteModel(instanceId: String, slug: String, isFavorite: Bool) async {}
}
