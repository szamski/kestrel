// T3Timeline: pure, Sendable derivation of everything the web chat view renders for one thread,
// so the native reading window matches the web 1:1. No UI lives here.
//
// Entry points:
//  - `deriveThreadTimeline(_:context:)` turns a thread read model into `ThreadTimeline`: work
//    entries, timeline entries, `TimelineRow`s, active plan, proposed plan and minimap items.
//  - `derivePendingPrompts(_:)` and the `PendingUserInput…` functions drive the composer panels.
//  - `deriveLiveAgentTaskIds(activities:sessionLive:)` feeds the subagent rows.
//  - `summarizeTurnDiffStats` / `buildTurnDiffTree` give the changed-files card as data.
//
// The TypeScript in apps/web (session-logic.ts, MessagesTimeline.logic.ts) and
// packages/client-runtime is the source of truth. scripts/timeline-oracle runs it on the same
// threads and the Swift tests compare the stable JSON projection (`ThreadTimeline.projection`).
