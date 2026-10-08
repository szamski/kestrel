import Foundation
import Testing

@testable import T3Composer

@Suite("Footer layout and scroll gesture oracle") struct LayoutOracleTests {
  private func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

  @Test func footer() throws {
    try Oracle.check("footerCounts") { input in
      let counts = ComposerFooterLayout.restingImagePreviewCounts(imageCount: input.int("imageCount"))
      return ["visibleCount": counts.visibleCount, "overflowCount": counts.overflowCount]
    }
    try Oracle.check("footerCompact") { input in
      let width = double(input["width"])
      let wide = input.bool("hasWideActions")
      return ["footer": ComposerFooterLayout.shouldUseCompactFooter(width: width, hasWideActions: wide), "actions": ComposerFooterLayout.shouldUseCompactPrimaryActions(width: width, hasWideActions: wide)]
    }
    try Oracle.check("footerResting") { input in
      ComposerFooterLayout.shouldUseRestingLayout(
        isExistingThread: input.bool("isExistingThread"), isMobileViewport: input.bool("isMobileViewport"), isScrollCollapsed: input.bool("isScrollCollapsed"),
        hasExpandedChrome: input.bool("hasExpandedChrome"), hasMultilinePrompt: input.bool("hasMultilinePrompt"), timelineOverflows: input.bool("timelineOverflows"))
    }
    try Oracle.check("footerInset") { input in
      ComposerFooterLayout.timelineInset(currentInset: double(input["currentInset"])!, overlayHeight: double(input["overlayHeight"])!, isResting: input.bool("isResting"))
    }
    try Oracle.check("footerAnimate") { input in
      ComposerFooterLayout.shouldAnimateRestingTransition(
        hasCompletedInitialLayout: input.bool("hasCompletedInitialLayout"), stateChanged: input.bool("stateChanged"), hasInterruptedAnimation: input.bool("hasInterruptedAnimation"))
    }
    func measurement(_ any: [String: Any]) -> ComposerFooterLayout.ControlsMeasurement {
      ComposerFooterLayout.ControlsMeasurement(
        gap: double(any["gap"])!, naturalFixedWidth: double(any["naturalFixedWidth"])!, minimumFixedWidth: double(any["minimumFixedWidth"])!,
        blockWidths: (any["blockWidths"] as! [NSNumber]).map(\.doubleValue), overflowWidth: double(any["overflowWidth"])!,
        iconOnlyBlockWidths: (any["iconOnlyBlockWidths"] as? [NSNumber])?.map(\.doubleValue))
    }
    try Oracle.check("footerControls") { input in
      let m = measurement(input["measurement"] as! [String: Any])
      let previous = (input["previous"] as? [String: Any]).map {
        ComposerFooterLayout.ControlsLayout(hiddenCount: $0.int("hiddenCount"), iconOnlyCount: ($0["iconOnlyCount"] as? NSNumber)?.intValue, visible: $0.bool("visible"))
      }
      let layout = ComposerFooterLayout.restingControlsLayout(m, hostWidth: double(input["hostWidth"])!, previous: previous)
      var out: [String: Any] = ["hiddenCount": layout.hiddenCount, "visible": layout.visible]
      if let iconOnly = layout.iconOnlyCount { out["iconOnlyCount"] = iconOnly }
      return ["natural": ComposerFooterLayout.restingControlsNaturalWidth(m), "layout": out]
    }
    try Oracle.check("scrollClearance") { input in
      let button = input["button"] as! [String: Any]
      let rects = (input["attachments"] as! [[String: Any]]).map { ComposerFooterLayout.Rect(top: double($0["top"])!, left: double($0["left"])!, right: double($0["right"])!) }
      return ComposerFooterLayout.scrollToEndClearance(
        overlayHeight: double(input["overlayHeight"])!, mainSurfaceTop: double(input["mainSurfaceTop"])!, buttonLeft: double(button["left"])!, buttonRight: double(button["right"])!, attachments: rects)
    }
  }

  @Test func scrollGestureAndMenuHighlight() throws {
    try Oracle.check("scrollKey") { input in
      ComposerScrollGesture.shouldCollapse(
        forKey: input.string("key"), scrollTop: double(input["scrollTop"])!, scrollHeight: double(input["scrollHeight"])!, clientHeight: double(input["clientHeight"])!,
        isAtLogicalEnd: input.bool("isAtLogicalEnd"))
    }
    try Oracle.check("scrollGesture") { input in
      var gesture = ComposerScrollGesture()
      var trace: [Any] = []
      for event in input["events"] as! [[String: Any]] {
        switch event.string("kind") {
        case "suppress": gesture.suppressActive(now: double(event["now"])!, gestureResetMs: 200)
        case "reset": gesture.reset()
        default:
          trace.append(["collapsed": gesture.record(
            now: double(event["now"])!, deltaPx: double(event["deltaPx"])!, collapseThresholdPx: double(event["collapseThresholdPx"])!, collapseEligible: event.bool("collapseEligible"),
            canScrollInGestureDirection: event.bool("canScrollInGestureDirection"), scrollsTowardLogicalEnd: event.bool("scrollsTowardLogicalEnd"))])
        }
        trace.append(["accumulated": gesture.accumulatedDeltaPx, "suppressed": gesture.collapseSuppressed])
      }
      return trace
    }
    try Oracle.check("menuHighlight") { input in
      ComposerMenuHighlight.activeItemId(
        itemIds: (input["items"] as! [[String: Any]]).map { $0.string("id") }, highlightedItemId: input["highlightedItemId"] as? String,
        currentSearchKey: input["currentSearchKey"] as? String, highlightedSearchKey: input["highlightedSearchKey"] as? String) as Any? ?? NSNull()
    }
  }
}
