import Foundation

extension ComposerModel {
  /// A wheel or trackpad event on the timeline. A deliberate scroll away from the end rests the
  /// composer to a single line; the next composer interaction lifts it. Losing focus never rests it.
  public func timelineDidScroll(
    now: Double, deltaPx: Double, canScrollInGestureDirection: Bool, scrollsTowardLogicalEnd: Bool, collapseThresholdPx: Double = 120
  ) {
    guard settings.collapseOnScroll else { return }
    let eligible = !isFocused || isScrollCollapsed == false
    if scrollGesture.record(
      now: now, deltaPx: deltaPx, collapseThresholdPx: collapseThresholdPx, collapseEligible: eligible, canScrollInGestureDirection: canScrollInGestureDirection,
      scrollsTowardLogicalEnd: scrollsTowardLogicalEnd)
    {
      isScrollCollapsed = true
    }
  }

  /// PageUp/Home/PageDown/End on the timeline.
  public func timelineDidPressScrollKey(_ key: String, scrollTop: Double, scrollHeight: Double, clientHeight: Double, isAtLogicalEnd: Bool) {
    guard settings.collapseOnScroll else { return }
    if ComposerScrollGesture.shouldCollapse(forKey: key, scrollTop: scrollTop, scrollHeight: scrollHeight, clientHeight: clientHeight, isAtLogicalEnd: isAtLogicalEnd) {
      isScrollCollapsed = true
    }
  }

  /// Any interaction with the composer lifts the resting layout and cancels the active gesture.
  public func composerWasUsed(now: Double = Date().timeIntervalSinceReferenceDate) {
    scrollGesture.suppressActive(now: now, gestureResetMs: 200)
    isScrollCollapsed = false
  }

  /// Whether the composer shows its single resting row.
  public func isResting(isExistingThread: Bool, timelineOverflows: Bool) -> Bool {
    ComposerFooterLayout.shouldUseRestingLayout(
      isExistingThread: isExistingThread, isScrollCollapsed: isScrollCollapsed, hasExpandedChrome: isMenuOpen || isModelPickerOpen || isStashMenuOpen
        || activeApproval != nil || activeUserInput != nil || !queuedMessages.isEmpty || thread.serverQueue?.items.isEmpty == false,
      hasMultilinePrompt: draft.prompt.contains("\n"), timelineOverflows: timelineOverflows)
  }
}
