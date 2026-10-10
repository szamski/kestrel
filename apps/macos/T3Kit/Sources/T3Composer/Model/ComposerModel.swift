import Foundation
import Observation
import T3Contracts
import T3Timeline

/// A request for the editor to replace its content (draft switch, menu pick, history recall,
/// stash restore). The editor applies a request once, identified by `revision`.
public struct EditorSyncRequest: Equatable, Sendable {
  public var revision: Int
  public var markdown: String
  /// Caret in collapsed coordinates.
  public var cursor: Int
  /// Menu picks stay on the undo stack; a thread switch clears it.
  public var undoable: Bool
}

/// The composer for one thread. It reads and writes the shared `ComposerServices` (drafts, queue,
/// stash, uploads), follows the thread through the environment and owns everything the web
/// composer keeps in component state: the trigger menu, pickers, history position, the active
/// question's answers and the send in flight.
///
/// The model never touches AppKit. The editor reports edits through `editorDidChange`, and the
/// model asks it to reload through `editorSync`.
@MainActor
@Observable
public final class ComposerModel {
  public let target: ComposerTarget
  @ObservationIgnored public let services: ComposerServices

  public internal(set) var thread = ComposerThreadSnapshot()
  public internal(set) var editorSync = EditorSyncRequest(revision: 0, markdown: "", cursor: 0, undoable: false)
  /// Bumped to ask the editor to take keyboard focus.
  public internal(set) var focusRequest = 0
  /// Selection in Markdown offsets, as last reported by the editor.
  public internal(set) var selection: Range<Int> = 0..<0
  /// Caret in collapsed coordinates, as last reported by the editor.
  public internal(set) var cursor = 0
  public internal(set) var isFocused = false

  // Trigger menu
  public internal(set) var trigger: ComposerTrigger?
  public internal(set) var menuItems: [ComposerMenuItem] = []
  public internal(set) var menuIsLoading = false
  public internal(set) var menuHighlightedId: String?
  var pathEntries: [ProjectEntry] = []
  var recentPullRequests: [ComposerPullRequestCandidate] = []
  var exactPullRequest: ComposerPullRequestCandidate?
  @ObservationIgnored var menuSearchTask: Task<Void, Never>?
  @ObservationIgnored var menuSearchKey: String?

  // Pickers and panels
  public var isModelPickerOpen = false
  public var isStashMenuOpen = false
  public internal(set) var stashPulse = 0

  // Send state
  public internal(set) var isSending = false
  public internal(set) var errorMessage: String?
  public internal(set) var respondingRequestIds: Set<String> = []

  // Server queue (protocol 2)
  /// The queued message whose content the composer is editing; sending saves it in place.
  public internal(set) var editingQueued: EditingQueuedRun?
  /// The queued run a queue command is in flight for; its row's controls are disabled.
  public internal(set) var busyQueueRunId: RunId?

  // Prompt history
  var historyPosition: ComposerPromptHistoryPosition?

  // Pending questions
  public internal(set) var userInputAnswers: [String: [String: PendingUserInputDraftAnswer]] = [:]
  public internal(set) var userInputQuestionIndex: [String: Int] = [:]
  var questionAttachmentPreparation: [String: Int] = [:]

  // Resting layout
  public internal(set) var isScrollCollapsed = false
  @ObservationIgnored var scrollGesture = ComposerScrollGesture()

  @ObservationIgnored var dismissedTrigger: (kind: ComposerTriggerKind, rangeStart: Int)?
  @ObservationIgnored var highlightedSearchKey: String?
  @ObservationIgnored var selectLock = false
  @ObservationIgnored var questionAutoAdvance: Task<Void, Never>?
  @ObservationIgnored private var threadTask: Task<Void, Never>?
  @ObservationIgnored var revision = 0
  /// What the editor last reported, so a controlled update is not echoed back as an edit.
  @ObservationIgnored var lastEditorValue = ""
  @ObservationIgnored var attachmentIntakes = 0

  public init(target: ComposerTarget, services: ComposerServices) {
    self.target = target
    self.services = services
  }

  // MARK: Lifecycle

  /// Starts following the thread and loads the draft into the editor.
  public func start() async {
    await services.start()
    if services.drafts.draftsByKey[target.key] == nil && !services.drafts.stickyModelSelectionByProvider.isEmpty {
      services.editDrafts { $0.applyStickyState(target.key) }
    }
    reloadEditor(markdown: draft.prompt, cursor: ComposerLogic.collapseExpandedCursor(draft.prompt, draft.prompt.jsLength), undoable: false)
    threadTask?.cancel()
    let stream = services.environment.threadSnapshots(for: target)
    threadTask = Task { [weak self] in
      for await snapshot in stream {
        guard let self, !Task.isCancelled else { return }
        self.applyThread(snapshot)
      }
    }
    if !services.queue.queue(target.key).isEmpty { services.ensureDispatcher(for: target) }
  }

  public func stop() {
    // The edit text is not the user's draft: give the draft back before the model goes away.
    finishQueuedEdit()
    threadTask?.cancel()
    menuSearchTask?.cancel()
  }

  // MARK: Derived state

  public var catalog: ComposerCatalog { services.catalog }
  public var settings: ComposerSettings { services.catalog.settings }
  public var draft: ComposerThreadDraft { services.drafts.draft(target.key) }
  public var attachments: [ComposerAttachment] { draft.attachments }
  public var uploads: [String: AttachmentRules.UploadState] { services.uploads }
  public var queuedMessages: [QueuedComposerMessage] { services.queue.queue(target.key) }
  public var stashEntries: [PromptStashEntry] { services.stash.entries }

  public var activeApproval: ApprovalPrompt? { thread.pending.approvals.first }
  public var pendingApprovalCount: Int { thread.pending.approvals.count }
  public var activeUserInput: UserInputPrompt? { thread.pending.userInputs.first }

  /// Progress through the active question prompt, or nil when none is open.
  public var userInputProgress: PendingUserInputProgress? {
    guard let prompt = activeUserInput else { return nil }
    return derivePendingUserInputProgress(
      prompt.questions, userInputAnswers[prompt.id] ?? [:], questionIndex: userInputQuestionIndex[prompt.id] ?? 0)
  }

  public var isRunning: Bool { thread.phase == .running }
  public var isConnecting: Bool { thread.phase == .connecting }
  public var isApprovalState: Bool { activeApproval != nil }

  /// The text the editor shows: the thread draft, or the active question's own answer.
  public var activeText: String {
    if isApprovalState { return "" }
    if let progress = userInputProgress { return progress.customAnswer }
    return draft.prompt
  }

  public var isChoiceOnlyQuestion: Bool { userInputProgress?.activeQuestion?.allowCustomAnswer == false }

  public var richTextEnabled: Bool { settings.richTextEnabled }

  public var isEditorDisabled: Bool {
    isConnecting || isApprovalState || isChoiceOnlyQuestion || (userInputProgress != nil && respondingRequestIds.contains(activeUserInput?.id ?? ""))
  }

  public var placeholder: String {
    if isApprovalState { return "Resolve this approval request to continue" }
    if userInputProgress != nil { return isChoiceOnlyQuestion ? "Choose an option above" : "Type your own answer, or leave this blank to use the selected option" }
    if showProviderUnavailable { return "Enable a provider in Settings to send a message" }
    if thread.phase == .disconnected && thread.unavailableReason != nil { return DisconnectedPlaceholder.text }
    return "Ask anything, @tag files/folders, $use skills, or / for commands"
  }

  // MARK: Ids and snapshots

  /// Applies a change made through the model (menu pick, recall, restore): the editor reloads.
  func reloadEditor(markdown: String, cursor: Int, undoable: Bool, focus: Bool = false) {
    revision += 1
    lastEditorValue = markdown
    self.cursor = ComposerLogic.clampCollapsedCursor(markdown, cursor)
    editorSync = EditorSyncRequest(revision: revision, markdown: markdown, cursor: self.cursor, undoable: undoable)
    if focus { focusRequest += 1 }
    selection = ComposerLogic.expandCollapsedCursor(markdown, self.cursor)..<ComposerLogic.expandCollapsedCursor(markdown, self.cursor)
    updateTrigger(for: markdown, expandedCursor: ComposerLogic.expandCollapsedCursor(markdown, self.cursor))
  }

  public func requestFocus() { focusRequest += 1 }

  func fail(_ message: String?) { errorMessage = message }
}

enum DisconnectedPlaceholder {
  static let text = "Ask for changes, send follow-ups, or attach images"
}
