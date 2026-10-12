import Foundation
import T3Contracts
import T3Timeline

/// A key press as the keybinding table sees it (`NSEvent` without AppKit).
public struct ComposerKeyPress: Sendable {
  public var keyCode: UInt16
  public var characters: String?
  public var command: Bool
  public var control: Bool
  public var shift: Bool
  public var option: Bool

  public init(keyCode: UInt16, characters: String?, command: Bool, control: Bool, shift: Bool, option: Bool) {
    self.keyCode = keyCode
    self.characters = characters
    self.command = command
    self.control = control
    self.shift = shift
    self.option = option
  }
}

/// Modifier and caret facts the editor passes with a command key.
public struct ComposerKeyContext: Sendable {
  public var shift: Bool
  /// Command or Control: the "modifier" of the send shortcut.
  public var modifier: Bool
  public var option: Bool
  public var isComposing: Bool
  public var caretOnFirstLine: Bool
  public var caretOnLastLine: Bool
  /// The keybinding the key press resolves to (server rules incl. user overrides); nil when unbound.
  public var command: KeybindingCommand?

  public init(
    shift: Bool = false, modifier: Bool = false, option: Bool = false, isComposing: Bool = false, caretOnFirstLine: Bool = false, caretOnLastLine: Bool = false,
    command: KeybindingCommand? = nil
  ) {
    self.shift = shift
    self.modifier = modifier
    self.option = option
    self.isComposing = isComposing
    self.caretOnFirstLine = caretOnFirstLine
    self.caretOnLastLine = caretOnLastLine
    self.command = command
  }
}

extension ComposerModel {
  // MARK: Edits from the editor

  /// Writes the active text: the thread draft, or the custom answer of the open question.
  func setActiveText(_ text: String) {
    if let prompt = activeUserInput, let progress = userInputProgress, let question = progress.activeQuestion {
      guard question.allowCustomAnswer != false else { return }
      var answers = userInputAnswers[prompt.id] ?? [:]
      answers[question.id] = setPendingUserInputCustomAnswer(answers[question.id], text)
      userInputAnswers[prompt.id] = answers
      return
    }
    let before = draft.attachments
    services.editDrafts {
      $0.setPrompt(target.key, text)
      $0.syncWithPrompt(target.key)
    }
    releaseDroppedAttachments(before: before)
  }

  /// A file whose last chip left the text goes away with its upload.
  func releaseDroppedAttachments(before: [ComposerAttachment]) {
    let remaining = Set(draft.attachments.map(\.id))
    for attachment in before where !remaining.contains(attachment.id) {
      services.cancelUpload(attachment.id)
      if let path = attachment.localPath { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    }
  }

  /// The editor reports an edit.
  public func editorDidChange(_ snapshot: EditorSnapshot) {
    cursor = snapshot.cursor
    selection = snapshot.selection
    if snapshot.value != activeText {
      lastEditorValue = snapshot.value
      setActiveText(snapshot.value)
      // Editing a recalled prompt turns it into a normal draft.
      if let position = historyPosition, position.recalled != snapshot.value { historyPosition = nil }
    }
    updateTrigger(for: snapshot.value, expandedCursor: snapshot.expandedCursor)
  }

  public func editorSelectionDidChange(_ snapshot: EditorSnapshot) {
    cursor = snapshot.cursor
    selection = snapshot.selection
    updateTrigger(for: snapshot.value, expandedCursor: snapshot.expandedCursor)
  }

  public func editorFocusDidChange(_ focused: Bool) {
    isFocused = focused
    if focused { isScrollCollapsed = false }
  }

  // MARK: Triggers

  func updateTrigger(for text: String, expandedCursor: Int) {
    var next = isEditorDisabled ? nil : ComposerLogic.detectTrigger(text, expandedCursor)
    if let found = next, let dismissed = dismissedTrigger, dismissed.kind == found.kind, dismissed.rangeStart == found.rangeStart {
      next = nil
    } else if next == nil || dismissedTrigger?.rangeStart != next?.rangeStart {
      dismissedTrigger = nil
    }
    if next == trigger { return }
    let previousKey = triggerSearchKey(trigger)
    trigger = next
    if triggerSearchKey(next) != previousKey { menuHighlightedId = nil }
    startMenuSearch()
    recomputeMenu()
  }

  func triggerSearchKey(_ trigger: ComposerTrigger?) -> String? {
    trigger.map { "\($0.kind.rawValue):\($0.query.jsTrim().lowercased())" }
  }

  public var isMenuOpen: Bool { trigger != nil }

  /// Esc closes the menu for this trigger until it changes.
  public func dismissMenu() {
    if let trigger { dismissedTrigger = (trigger.kind, trigger.rangeStart) }
    self.trigger = nil
    menuItems = []
    menuSearchTask?.cancel()
    menuIsLoading = false
  }

  // MARK: Menu content

  var selectedProviderSkills: [ProviderSkill] { selectedEntry?.snapshot.skills ?? [] }

  var compactCommandAvailable: Bool {
    guard let trigger, trigger.kind == .slashCommand else { return false }
    let prompt = draft.prompt
    return prompt.jsSlice(0, trigger.rangeStart).jsTrim().isEmpty && prompt.jsSlice(trigger.rangeEnd).jsTrim().isEmpty && draft.attachments.isEmpty && draft.records.isEmpty
      && !thread.isFirstMessage
  }

  func recomputeMenu() {
    guard let trigger else {
      menuItems = []
      return
    }
    let entry = selectedEntry
    menuItems = ComposerMenu.items(
      ComposerMenu.Inputs(
        trigger: trigger, prompt: activeText, driver: entry?.driverKind ?? "codex", skills: entry?.snapshot.skills ?? [],
        slashCommands: entry?.snapshot.slashCommands ?? [], showSkillsInSlashMenu: settings.showSkillsInSlashMenu, planModeEnabled: planModeUiEnabled,
        compactAvailable: compactCommandAvailable, pathEntries: pathEntries, pullRequests: recentPullRequests, exactPullRequest: exactPullRequest,
        projectId: target.projectId, repository: target.repository))
    // Keep the highlight while the query is unchanged and the row still exists.
    menuHighlightedId = ComposerMenuHighlight.activeItemId(
      itemIds: menuItems.map(\.id), highlightedItemId: menuHighlightedId, currentSearchKey: triggerSearchKey(trigger),
      highlightedSearchKey: highlightedSearchKey)
    highlightedSearchKey = triggerSearchKey(trigger)
  }

  public var highlightedMenuItem: ComposerMenuItem? { menuItems.first { $0.id == menuHighlightedId } }

  public func highlightMenuItem(_ id: String?) {
    menuHighlightedId = id
    highlightedSearchKey = triggerSearchKey(trigger)
  }

  public enum MenuDirection: Sendable { case up, down }

  public func nudgeMenu(_ direction: MenuDirection) {
    guard !menuItems.isEmpty else { return }
    let index = menuItems.firstIndex { $0.id == menuHighlightedId }
    let normalized = index ?? (direction == .down ? -1 : 0)
    let next = (normalized + (direction == .down ? 1 : -1) + menuItems.count) % menuItems.count
    menuHighlightedId = menuItems[next].id
  }

  /// Debounced searches behind the menu: workspace paths for `@`, pull requests for `#`.
  func startMenuSearch() {
    menuSearchTask?.cancel()
    pathEntries = trigger?.kind == .path ? pathEntries : []
    guard let trigger else {
      menuIsLoading = false
      return
    }
    switch trigger.kind {
    case .path:
      let query = trigger.query.jsTrim()
      guard !query.isEmpty, let cwd = target.cwd else {
        pathEntries = []
        menuIsLoading = false
        return
      }
      menuIsLoading = true
      let environment = services.environment
      menuSearchTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        do {
          let result = try await environment.searchWorkspaceEntries(cwd: cwd, query: query, limit: 80)
          guard !Task.isCancelled, let self else { return }
          self.pathEntries = result.entries
        } catch {
          guard !Task.isCancelled, let self else { return }
          self.pathEntries = []
        }
        guard !Task.isCancelled else { return }
        self?.menuIsLoading = false
        self?.recomputeMenu()
      }
    case .pullRequest:
      guard let projectId = target.projectId else { return }
      let query = trigger.query
      let isNumeric = query.isEmpty || query.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
      let number = isNumeric ? Int(query) : nil
      menuIsLoading = true
      let environment = services.environment
      menuSearchTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(isNumeric && query.isEmpty ? 0 : 180))
        guard !Task.isCancelled else { return }
        do {
          let recent = try await environment.listPullRequests(projectId: projectId, query: isNumeric ? nil : query, limit: PullRequestMatching.listLimit)
          guard !Task.isCancelled, let self else { return }
          self.recentPullRequests = recent
          // A complete number older than the recent list is resolved directly.
          if let number, number > 0, let repository = self.target.repository, !recent.contains(where: { $0.number == number }) {
            self.exactPullRequest = try await environment.resolvePullRequest(projectId: projectId, repository: repository, number: number)
          } else {
            self.exactPullRequest = nil
          }
        } catch {
          guard !Task.isCancelled, let self else { return }
          self.recentPullRequests = []
        }
        guard !Task.isCancelled else { return }
        self?.menuIsLoading = false
        self?.recomputeMenu()
      }
    default:
      menuIsLoading = false
    }
  }

  // MARK: Picking

  /// Applies the menu row for the active trigger.
  public func pick(_ item: ComposerMenuItem) {
    guard let trigger, !selectLock else { return }
    selectLock = true
    defer { Task { @MainActor [weak self] in self?.selectLock = false } }
    guard let edit = ComposerMenu.edit(for: item, trigger: trigger, prompt: activeText, planModeEnabled: planModeUiEnabled) else { return }
    if applyReplacement(
      rangeStart: edit.rangeStart, rangeEnd: edit.rangeEnd, replacement: edit.replacement, expectedText: edit.expectedText, focus: edit.refocusEditor)
    {
      menuHighlightedId = nil
      for effect in edit.effects {
        switch effect {
        case .openModelPicker: isModelPickerOpen = true
        case .setInteractionMode(let mode): setInteractionMode(mode)
        case .addRecord(let record):
          services.editDrafts { $0.addRecord(target.key, record) }
        }
      }
    }
  }

  /// Replaces a range of the Markdown (expanded offsets) and puts the caret after it. False when the
  /// text moved on or the editor takes no input.
  @discardableResult
  public func applyReplacement(
    rangeStart: Int, rangeEnd: Int, replacement: String, expectedText: String? = nil, expandedCursorAfter: Int? = nil, focus: Bool = true
  ) -> Bool {
    if isChoiceOnlyQuestion { return false }
    let current = activeText
    let length = current.jsLength
    let safeStart = max(0, min(length, rangeStart))
    let safeEnd = max(safeStart, min(length, rangeEnd))
    if let expectedText, current.jsSlice(safeStart, safeEnd) != expectedText { return false }
    let next = ComposerLogic.replaceTextRange(current, rangeStart: rangeStart, rangeEnd: rangeEnd, replacement: replacement)
    let nextCursor = ComposerLogic.collapseExpandedCursor(next.text, expandedCursorAfterOr(next.cursor, expandedCursorAfter))
    setActiveText(next.text)
    reloadEditor(markdown: next.text, cursor: nextCursor, undoable: true, focus: focus)
    return true
  }

  private func expandedCursorAfterOr(_ cursor: Int, _ override: Int?) -> Int { override ?? cursor }

  /// Inserts text at the caret or the end, padding a boundary space; used for context that other
  /// panels produce (terminal excerpts, review comments, dropped paths).
  @discardableResult
  public func insertText(_ text: String, at position: InsertPosition, ensureLeadingBoundary: Bool = false) -> Bool {
    if text.isEmpty || isConnecting || isApprovalState || userInputProgress != nil { return false }
    let prompt = activeText
    let caret = position == .cursor ? min(selection.lowerBound, prompt.jsLength) : prompt.jsLength
    let needsSpace = ensureLeadingBoundary && caret > 0 && !(prompt.jsUnit(at: caret - 1).map(JS.isSpace) ?? true)
    let end = prompt.jsUnit(at: caret) == 0x20 && text.hasSuffix(" ") ? caret + 1 : caret
    return applyReplacement(rangeStart: caret, rangeEnd: end, replacement: needsSpace ? " \(text)" : text)
  }

  public enum InsertPosition: Sendable { case cursor, end }

  /// Context from another panel lands at the caret as chips, with its records in the draft.
  @discardableResult
  public func insertContext(_ records: [ComposerContextRecord]) -> Bool {
    guard !records.isEmpty else { return false }
    let references = records.map(ContextRecords.reference(for:))
    let prompt = draft.prompt
    let edit = ComposerContextReferences.inlineReplacement(prompt: prompt, start: selection.lowerBound, end: selection.upperBound, references: references)
    guard applyReplacement(rangeStart: edit.start, rangeEnd: edit.end, replacement: edit.text) else {
      setActiveText(ComposerContextReferences.ensure(prompt: prompt, references: references))
      services.editDrafts { state in records.forEach { state.addRecord(target.key, $0) } }
      reloadEditor(markdown: draft.prompt, cursor: ComposerLogic.collapseExpandedCursor(draft.prompt, draft.prompt.jsLength), undoable: true)
      return true
    }
    services.editDrafts { state in records.forEach { state.addRecord(target.key, $0) } }
    return true
  }

  /// Quote of an assistant response with an optional comment, at the caret.
  @discardableResult
  public func insertCitation(_ citation: AssistantCitation, comment: String = "") -> Bool {
    insertText(ComposerLogic.formatAssistantCitation(citation, comment: comment), at: .cursor, ensureLeadingBoundary: true)
  }

  // MARK: Command keys

  /// A command key from the editor; true when the model handled it.
  public func handleCommandKey(_ key: ComposerCommandKey, context: ComposerKeyContext, isTaskItem: Bool) -> Bool {
    if key == .tab && context.shift {
      guard planModeUiEnabled else { return false }
      toggleInteractionMode()
      return true
    }
    let menuIsActive = trigger != nil
    if key == .escape {
      guard menuIsActive, !context.isComposing else { return false }
      dismissMenu()
      return true
    }
    if menuIsActive {
      let selected = highlightedMenuItem ?? menuItems.first
      if key == .arrowDown, !menuItems.isEmpty {
        nudgeMenu(.down)
        return true
      }
      if key == .arrowUp, !menuItems.isEmpty {
        nudgeMenu(.up)
        return true
      }
      if key == .enter || key == .tab, let selected {
        pick(selected)
        return true
      }
    }
    if key == .arrowUp || key == .arrowDown {
      return navigatePromptHistory(key == .arrowUp ? .backward : .forward, context: context)
    }
    if key == .enter {
      if let intent = ComposerLogic.submissionIntent(
        command: context.command, shift: context.shift, option: context.option, modifier: context.modifier, isDraftThread: target.isDraftThread,
        isRunning: isRunning, sendShortcut: settings.sendShortcut, prompt: activeText)
      {
        Task { await submit(intent: intent) }
        return true
      }
      // A key bound to another command (⌘⇧↩ steers the queue, run by the app) is not typed as a newline.
      if context.command != nil { return true }
      // Native task splitting preserves marks and chips on both sides of the caret.
      if isTaskItem { return false }
    }
    if !context.isComposing, key == .enter || (key == .tab && !context.shift), selection.isEmpty, lastEditorValue == activeText {
      let edit =
        key == .enter
        ? ComposerListContinuation.forEnter(activeText, selection.lowerBound)
        : ComposerListContinuation.indentForTab(activeText, start: selection.lowerBound, end: selection.upperBound)
      if let edit,
        applyReplacement(
          rangeStart: edit.start, rangeEnd: edit.end, replacement: edit.replacement,
          expandedCursorAfter: key == .tab ? selection.lowerBound + edit.replacement.jsLength : nil)
      {
        return true
      }
    }
    return false
  }
}
