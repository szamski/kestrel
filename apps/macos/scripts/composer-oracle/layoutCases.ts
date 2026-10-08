// Footer layout, scroll gesture and menu highlight.
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";

type Case = { group: string; input: unknown; output: unknown };
const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export async function layoutCases(): Promise<Case[]> {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  const footer = await imp("apps/web/src/components/composerFooterLayout.ts");
  const scroll = await imp("apps/web/src/components/chat/composerScrollGesture.ts");
  const highlight = await imp("apps/web/src/components/chat/composerMenuHighlight.ts");

  for (const imageCount of [0, 1, 3, 4, 10])
    add("footerCounts", { imageCount }, footer.getRestingComposerImagePreviewCounts(imageCount));
  for (const width of [null, 100, 619, 620, 621, 779, 780, 1200])
    for (const hasWideActions of [false, true]) {
      add(
        "footerCompact",
        { width, hasWideActions },
        {
          footer: footer.shouldUseCompactComposerFooter(width, { hasWideActions }),
          actions: footer.shouldUseCompactComposerPrimaryActions(width, { hasWideActions }),
        },
      );
    }
  for (const isExistingThread of [false, true])
    for (const isMobileViewport of [false, true])
      for (const isScrollCollapsed of [false, true])
        for (const hasExpandedChrome of [false, true])
          for (const hasMultilinePrompt of [false, true])
            for (const timelineOverflows of [false, true]) {
              const input = {
                isExistingThread,
                isMobileViewport,
                isScrollCollapsed,
                hasExpandedChrome,
                hasMultilinePrompt,
                timelineOverflows,
              };
              add("footerResting", input, footer.shouldUseRestingComposerLayout(input));
            }
  for (const currentInset of [0, 100, 500])
    for (const overlayHeight of [60, 300])
      for (const isResting of [false, true]) {
        add(
          "footerInset",
          { currentInset, overlayHeight, isResting },
          footer.resolveComposerTimelineInset({ currentInset, overlayHeight, isResting }),
        );
      }
  for (const hasCompletedInitialLayout of [false, true])
    for (const stateChanged of [false, true])
      for (const hasInterruptedAnimation of [false, true]) {
        const input = { hasCompletedInitialLayout, stateChanged, hasInterruptedAnimation };
        add("footerAnimate", input, footer.shouldAnimateComposerRestingTransition(input));
      }
  const next = rng(7);
  for (let index = 0; index < 400; index += 1) {
    const count = Math.floor(next() * 5);
    const widths = Array.from({ length: count }, () => Math.round(40 + next() * 160));
    const withIcons = next() < 0.5;
    const measurement = {
      gap: Math.round(next() * 10),
      naturalFixedWidth: Math.round(60 + next() * 200),
      minimumFixedWidth: Math.round(30 + next() * 100),
      blockWidths: widths,
      overflowWidth: Math.round(20 + next() * 30),
      ...(withIcons ? { iconOnlyBlockWidths: widths.map((w) => Math.round(w / 3)) } : {}),
    };
    const hostWidth = Math.round(next() * 700);
    const prevRoll = next();
    const previous =
      prevRoll < 0.4
        ? undefined
        : {
            hiddenCount: Math.floor(next() * (count + 1)),
            ...(withIcons ? { iconOnlyCount: Math.floor(next() * (count + 1)) } : {}),
            visible: next() < 0.5,
          };
    add(
      "footerControls",
      { measurement, hostWidth, previous },
      {
        natural: footer.resolveRestingComposerControlsNaturalWidth(measurement),
        layout: footer.resolveRestingComposerControlsLayout({
          ...measurement,
          hostWidth,
          previous,
        }),
      },
    );
  }
  for (const overlayHeight of [100, 250])
    for (const mainSurfaceTop of [40, 80]) {
      const attachments = [
        [{ top: 20, left: 0, right: 50 }],
        [
          { top: 60, left: 100, right: 200 },
          { top: 10, left: 300, right: 400 },
        ],
        [],
      ];
      for (const list of attachments)
        add(
          "scrollClearance",
          { overlayHeight, mainSurfaceTop, button: { left: 120, right: 160 }, attachments: list },
          footer.resolveScrollToEndClearance({
            overlayHeight,
            mainSurfaceTop,
            button: { left: 120, right: 160 },
            attachments: list,
          }),
        );
    }

  for (const key of ["PageUp", "Home", "PageDown", "End", "ArrowDown", "a"])
    for (const scrollTop of [0, 1, 2, 500])
      for (const isAtLogicalEnd of [false, true]) {
        const input = { key, scrollTop, scrollHeight: 1000, clientHeight: 400, isAtLogicalEnd };
        add("scrollKey", input, scroll.shouldCollapseComposerForScrollKey(input));
      }
  for (let seed = 1; seed <= 30; seed += 1) {
    const gen = rng(seed);
    const state = scroll.createComposerScrollGestureState();
    const events: any[] = [];
    const trace: unknown[] = [];
    let now = 1000;
    for (let step = 0; step < 16; step += 1) {
      now += Math.floor(gen() * 300);
      const roll = gen();
      if (roll < 0.15) {
        events.push({ kind: "suppress", now });
        scroll.suppressActiveComposerScrollGesture(state, now, 200);
      } else if (roll < 0.22) {
        events.push({ kind: "reset" });
        scroll.resetComposerScrollGesture(state);
      } else {
        const event = {
          now,
          deltaPx: Math.round(gen() * 60),
          collapseThresholdPx: 120,
          collapseEligible: gen() < 0.85,
          canScrollInGestureDirection: gen() < 0.9,
          scrollsTowardLogicalEnd: gen() < 0.2,
        };
        events.push({ kind: "record", ...event });
        trace.push({ collapsed: scroll.recordComposerScrollGestureEvent(state, event) });
      }
      trace.push({ accumulated: state.accumulatedDeltaPx, suppressed: state.collapseSuppressed });
    }
    add("scrollGesture", { events, seed }, trace);
  }
  for (const items of [[], [{ id: "a" }, { id: "b" }]])
    for (const highlightedItemId of [null, "a", "b", "zzz"])
      for (const [currentSearchKey, highlightedSearchKey] of [
        ["k", "k"],
        ["k", "other"],
        [null, null],
      ] as const) {
        const input = { items, highlightedItemId, currentSearchKey, highlightedSearchKey };
        add("menuHighlight", input, highlight.resolveComposerMenuActiveItemId(input));
      }
  return out;
}
