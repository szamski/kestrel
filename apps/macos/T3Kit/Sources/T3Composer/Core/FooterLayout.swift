import Foundation

/// Layout decisions of the composer footer (`components/composerFooterLayout.ts`) and the scroll
/// gesture that rests the composer (`components/chat/composerScrollGesture.ts`). Pure geometry, so
/// the SwiftUI view only has to measure and apply.
public enum ComposerFooterLayout {
  public static let compactBreakpoint = 620.0
  public static let wideActionsCompactBreakpoint = 780.0
  static let restingImageThumbnailLimit = 3
  /// How much taller the empty expanded composer is than its resting row.
  public static let restingExpansionMin = 94.0
  private static let restingControlsSlack = 1.0

  public static func restingImagePreviewCounts(imageCount: Int) -> (visibleCount: Int, overflowCount: Int) {
    let visible = min(imageCount, restingImageThumbnailLimit)
    return (visible, max(0, imageCount - visible))
  }

  public static func shouldUseCompactFooter(width: Double?, hasWideActions: Bool = false) -> Bool {
    guard let width else { return false }
    return width < (hasWideActions ? wideActionsCompactBreakpoint : compactBreakpoint)
  }

  /// Only a timeline scroll rests the composer; it lifts on the next composer interaction.
  public static func shouldUseRestingLayout(
    isExistingThread: Bool, isMobileViewport: Bool = false, isScrollCollapsed: Bool, hasExpandedChrome: Bool, hasMultilinePrompt: Bool, timelineOverflows: Bool
  ) -> Bool {
    isExistingThread && !isMobileViewport && timelineOverflows && isScrollCollapsed && !hasMultilinePrompt && !hasExpandedChrome
  }

  /// The space the timeline reserves at its end for the composer overlay. While resting it keeps the
  /// measured expanded height; the empty-expansion estimate only applies before that measurement
  /// exists (`currentInset == 0`).
  public static func timelineInset(currentInset: Double, overlayHeight: Double, isResting: Bool, restingOnlyHeight: Double = 0) -> Double {
    guard isResting else { return overlayHeight }
    return max(currentInset, overlayHeight + (currentInset == 0 ? restingExpansionMin - restingOnlyHeight : 0))
  }

  public static func shouldAnimateRestingTransition(hasCompletedInitialLayout: Bool, stateChanged: Bool, hasInterruptedAnimation: Bool) -> Bool {
    hasCompletedInitialLayout && (stateChanged || hasInterruptedAnimation)
  }

  public static func shouldUseCompactPrimaryActions(width: Double?, hasWideActions: Bool = false) -> Bool {
    guard hasWideActions, let width else { return false }
    return width < wideActionsCompactBreakpoint
  }

  public struct ControlsMeasurement: Sendable, Hashable {
    public var gap: Double
    public var naturalFixedWidth: Double
    public var minimumFixedWidth: Double
    public var blockWidths: [Double]
    public var overflowWidth: Double
    public var iconOnlyBlockWidths: [Double]?

    public init(gap: Double, naturalFixedWidth: Double, minimumFixedWidth: Double, blockWidths: [Double], overflowWidth: Double, iconOnlyBlockWidths: [Double]? = nil) {
      self.gap = gap
      self.naturalFixedWidth = naturalFixedWidth
      self.minimumFixedWidth = minimumFixedWidth
      self.blockWidths = blockWidths
      self.overflowWidth = overflowWidth
      self.iconOnlyBlockWidths = iconOnlyBlockWidths
    }
  }

  public struct ControlsLayout: Sendable, Hashable {
    public var hiddenCount: Int
    public var iconOnlyCount: Int?
    public var visible: Bool

    public init(hiddenCount: Int, iconOnlyCount: Int? = nil, visible: Bool) {
      self.hiddenCount = hiddenCount
      self.iconOnlyCount = iconOnlyCount
      self.visible = visible
    }
  }

  private static func controlsWidth(_ input: ControlsMeasurement, hiddenCount: Int, fixedWidth: Double? = nil, iconOnlyCount: Int = 0) -> Double {
    let fixed = fixedWidth ?? input.naturalFixedWidth
    let visibleCount = input.blockWidths.count - hiddenCount
    var total = fixed
    for (index, width) in input.blockWidths.prefix(max(0, visibleCount)).enumerated() {
      total += index >= input.blockWidths.count - iconOnlyCount ? (input.iconOnlyBlockWidths.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? width) : width
    }
    total += hiddenCount > 0 ? input.overflowWidth : 0
    total += input.gap * Double(visibleCount + (hiddenCount > 0 ? 1 : 0))
    return total
  }

  /// The width the resting controls take with nothing moved into overflow.
  public static func restingControlsNaturalWidth(_ input: ControlsMeasurement) -> Double { controlsWidth(input, hiddenCount: 0) }

  /// Fit footer controls using natural widths: remove trailing labels first, then move trailing
  /// blocks into overflow; below the minimum the whole cluster hides rather than clipping.
  public static func restingControlsLayout(_ input: ControlsMeasurement, hostWidth: Double, previous: ControlsLayout? = nil) -> ControlsLayout {
    let count = input.blockWidths.count
    let iconSteps = input.iconOnlyBlockWidths != nil ? count : 0
    let previousStep: Int
    if let previous {
      previousStep = previous.hiddenCount > 0 ? iconSteps + min(previous.hiddenCount, count) : min(previous.iconOnlyCount ?? 0, iconSteps)
    } else {
      previousStep = 0
    }
    var step = 0
    func width(at candidate: Int, fixed: Double? = nil) -> Double {
      controlsWidth(input, hiddenCount: max(0, candidate - iconSteps), fixedWidth: fixed, iconOnlyCount: min(candidate, iconSteps))
    }
    // Promotions need a pixel of slack; demotions are immediate so a threshold cannot clip.
    while step < iconSteps + count && width(at: step) > hostWidth - (step < previousStep ? restingControlsSlack : 0) { step += 1 }
    let hidden = max(0, step - iconSteps)
    let iconOnly = min(step, iconSteps)
    let minimum = width(at: step, fixed: input.minimumFixedWidth)
    let visible = (previous.map { !$0.visible } ?? false) ? minimum <= hostWidth - restingControlsSlack : minimum <= hostWidth
    return ControlsLayout(hiddenCount: hidden, iconOnlyCount: input.iconOnlyBlockWidths != nil ? iconOnly : nil, visible: visible)
  }

  public struct Rect: Sendable, Hashable {
    public var top: Double
    public var left: Double
    public var right: Double

    public init(top: Double, left: Double, right: Double) {
      self.top = top
      self.left = left
      self.right = right
    }
  }

  public static func scrollToEndClearance(overlayHeight: Double, mainSurfaceTop: Double, buttonLeft: Double, buttonRight: Double, attachments: [Rect]) -> Int {
    var contentTop = mainSurfaceTop
    var top = contentTop
    for attachment in attachments {
      contentTop = min(contentTop, attachment.top)
      if attachment.left < buttonRight && attachment.right > buttonLeft { top = min(top, attachment.top) }
    }
    return Int((overlayHeight - (top - contentTop)).rounded(.up))
  }
}

/// Collapse-on-scroll gesture accumulation: a deliberate scroll away from the end of the timeline
/// rests the composer.
public struct ComposerScrollGesture: Sendable, Hashable {
  public var accumulatedDeltaPx = 0.0
  public var collapseSuppressed = false
  public var lastEventAt = -Double.infinity

  public init() {}

  public static func shouldCollapse(forKey key: String, scrollTop: Double, scrollHeight: Double, clientHeight: Double, isAtLogicalEnd: Bool) -> Bool {
    switch key {
    case "PageUp", "Home": scrollTop > 1
    case "PageDown", "End": !isAtLogicalEnd && scrollTop < scrollHeight - clientHeight - 1
    default: false
    }
  }

  public mutating func reset() {
    accumulatedDeltaPx = 0
    collapseSuppressed = false
    lastEventAt = -Double.infinity
  }

  public mutating func suppressActive(now: Double, gestureResetMs: Double) {
    if now - lastEventAt <= gestureResetMs { collapseSuppressed = true }
  }

  /// True when this event completes a collapsing gesture.
  public mutating func record(
    now: Double, deltaPx: Double, collapseThresholdPx: Double, collapseEligible: Bool, canScrollInGestureDirection: Bool, scrollsTowardLogicalEnd: Bool
  ) -> Bool {
    lastEventAt = now
    if collapseSuppressed || !collapseEligible || !canScrollInGestureDirection || scrollsTowardLogicalEnd {
      accumulatedDeltaPx = 0
      return false
    }
    accumulatedDeltaPx += deltaPx
    if accumulatedDeltaPx < collapseThresholdPx { return false }
    accumulatedDeltaPx = 0
    return true
  }
}

public enum ComposerMenuHighlight {
  /// The highlighted row survives while the query is unchanged and the row still exists.
  public static func activeItemId(itemIds: [String], highlightedItemId: String?, currentSearchKey: String?, highlightedSearchKey: String?) -> String? {
    if itemIds.isEmpty { return nil }
    if currentSearchKey == highlightedSearchKey, let highlightedItemId, itemIds.contains(highlightedItemId) { return highlightedItemId }
    return itemIds.first
  }
}
