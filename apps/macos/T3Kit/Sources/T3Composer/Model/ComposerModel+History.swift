import Foundation

extension ComposerModel {
  /// ArrowUp in an empty composer recalls the last prompt sent in this thread, ArrowDown walks
  /// forward and empties the composer past the newest. The caret must sit on the first (up) or last
  /// (down) visual line so the arrows still move inside multi-line text.
  public func navigatePromptHistory(_ direction: ComposerPromptHistory.Direction, context: ComposerKeyContext) -> Bool {
    if context.shift || context.option || context.modifier || context.isComposing { return false }
    if isApprovalState || userInputProgress != nil { return false }
    // A composer holding an attachment or other context is not empty: recalling text into it would
    // send the old prompt with the new context.
    if !draft.attachments.isEmpty || !draft.records.isEmpty { return false }
    // A typed draft with no active recall can never step.
    if historyPosition == nil && !draft.prompt.isEmpty { return false }
    guard direction == .backward ? context.caretOnFirstLine : context.caretOnLastLine else { return false }
    let entries = ComposerPromptHistory.entries(from: thread.promptHistory)
    guard let step = ComposerPromptHistory.step(direction: direction, entries: entries, position: historyPosition, currentPrompt: draft.prompt) else { return false }
    historyPosition = step.position
    services.editDrafts { $0.setPrompt(target.key, step.prompt) }
    reloadEditor(markdown: step.prompt, cursor: ComposerLogic.collapseExpandedCursor(step.prompt, step.prompt.jsLength), undoable: false)
    return true
  }
}
