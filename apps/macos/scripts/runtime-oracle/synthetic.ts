// Synthetic scenario inputs: wire-shaped values built from a sanitized fixture thread/shell so the
// differential oracle covers every reducer branch (streaming deltas, settle/pin/snooze, revert,
// approvals, user input, pagination) that a short recording never contains.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { contractsFixtures } from "./lib.ts";

const read = (name: string) => JSON.parse(readFileSync(join(contractsFixtures, name), "utf8"));
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));

export const fixtureShell = () => read("shell.json");
export const fixtureThreadDetail = (n: number) => read(`threads/thread-${n}.json`);

/** A small, schema-valid thread to hang events on (keeps per-step expected states tiny). */
export function smallThread() {
  const detail = fixtureThreadDetail(4);
  const t = clone(detail.thread);
  t.messages = t.messages.slice(0, 3);
  t.activities = t.activities.slice(0, 3);
  t.checkpoints = t.checkpoints.slice(0, 2);
  t.proposedPlans = [];
  t.session = null;
  t.latestTurn = null;
  return { snapshotSequence: 1000, thread: t };
}

let seq = 1000;
const at = (n: number) => new Date(Date.UTC(2026, 9, 1, 12, 0, 0) + n * 1000).toISOString();

export function event(
  threadId: string,
  type: string,
  payload: any,
  extra: { occurredAt?: string; sequence?: number } = {},
) {
  seq += 1;
  return {
    sequence: extra.sequence ?? seq,
    eventId: `ev-${extra.sequence ?? seq}`,
    aggregateKind: "thread",
    aggregateId: threadId,
    occurredAt: extra.occurredAt ?? at(seq - 1000),
    commandId: null,
    causationEventId: null,
    correlationId: null,
    metadata: {},
    type,
    payload: { threadId, ...payload },
  };
}

const session = (threadId: string, status: string, activeTurnId: string | null, n: number) => ({
  threadId,
  status,
  providerName: "codex",
  providerInstanceId: "codex",
  runtimeMode: "full-access",
  activeTurnId,
  lastError: status === "error" ? "boom" : null,
  updatedAt: at(n),
});

const activity = (
  id: string,
  kind: string,
  turnId: string | null,
  sequence: number | null,
  n: number,
  payload: any = {},
) => ({
  id,
  tone: "info",
  kind,
  summary: `${kind} ${id}`,
  payload,
  turnId,
  ...(sequence === null ? {} : { sequence }),
  createdAt: at(n),
});

export function syntheticThreadEvents(threadId: string): any[] {
  seq = 1000;
  const e = (type: string, payload: any, extra?: any) => event(threadId, type, payload, extra);
  const T1 = "turn-1",
    T2 = "turn-2",
    T3 = "turn-3";
  const msg = (
    id: string,
    role: string,
    text: string,
    turnId: string | null,
    streaming: boolean,
    n: number,
    extra: any = {},
  ) => ({
    messageId: id,
    role,
    text,
    turnId,
    streaming,
    createdAt: at(n),
    updatedAt: at(n + 1),
    ...extra,
  });
  const events = [
    e("thread.message-sent", msg("m-user-1", "user", "Please refactor", null, false, 1)),
    e("thread.turn-start-requested", {
      messageId: "m-user-1",
      runtimeMode: "full-access",
      interactionMode: "default",
      createdAt: at(2),
    }),
    e("thread.session-set", { session: session(threadId, "running", T1, 3) }),
    // streaming deltas append; a final non-empty text replaces; the turn stays running with the session
    e("thread.message-sent", msg("m-asst-1", "assistant", "Hel", T1, true, 4)),
    e("thread.message-sent", msg("m-asst-1", "assistant", "lo ", T1, true, 5)),
    e("thread.message-sent", msg("m-asst-1", "assistant", "wor", T1, true, 6)),
    e("thread.message-sent", msg("m-asst-1", "assistant", "Hello world", T1, false, 7)),
    // a second final assistant message with an empty text keeps the old text
    e("thread.message-sent", msg("m-asst-2", "assistant", "Commentary", T1, true, 8)),
    e("thread.message-sent", msg("m-asst-2", "assistant", "", T1, false, 9)),
    e("thread.message-sent", msg("m-reason-1", "reasoning", "think", T1, true, 10)),
    e("thread.message-sent", msg("m-sys-1", "system", "System note", null, false, 11)),
    // activities: out of order, ties, null sequence, redelivered id, context-window supersede
    e("thread.activity-appended", { activity: activity("a-03", "tool.started", T1, 3, 12) }),
    e("thread.activity-appended", { activity: activity("a-01", "tool.started", T1, 1, 13) }),
    e("thread.activity-appended", { activity: activity("a-02", "tool.completed", T1, 2, 14) }),
    e("thread.activity-appended", { activity: activity("a-nosq", "info", T1, null, 15) }),
    e("thread.activity-appended", { activity: activity("a-03", "tool.started", T1, 3, 12) }),
    e("thread.activity-appended", { activity: activity("a-tie-b", "info", T1, 5, 16) }),
    e("thread.activity-appended", { activity: activity("a-tie-a", "info", T1, 5, 16) }),
    e("thread.activity-appended", {
      activity: activity("cw-1", "context-window.updated", T1, 6, 17, { usedTokens: 100 }),
    }),
    e("thread.activity-appended", {
      activity: activity("cw-2", "context-window.updated", T1, 7, 18, { usedTokens: 200 }),
    }),
    e("thread.activity-appended", {
      activity: activity("cw-bad", "context-window.updated", T1, 8, 19, { usedTokens: -1 }),
    }),
    e("thread.activity-appended", {
      activity: activity("cw-other", "context-window.updated", T2, 9, 20, { usedTokens: 5 }),
    }),
    e("thread.activity-appended", {
      activity: activity("cw-3", "context-window.updated", T1, 10, 21, { usedTokens: 300 }),
    }),
    // approvals and user input
    e("thread.activity-appended", {
      activity: activity("ap-1", "approval.requested", T1, 11, 22, {
        requestId: "req-1",
        requestKind: "command",
        detail: "rm -rf",
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ap-2", "approval.requested", T1, 12, 23, {
        requestId: "req-2",
        requestType: "apply_patch_approval",
        appName: "Codex",
        options: [
          { decision: "accept", label: "Allow" },
          { decision: "decline", label: "Deny", warning: "careful" },
        ],
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ui-1", "user-input.requested", T1, 13, 24, {
        requestId: "req-3",
        responseMode: "message",
        questions: [
          {
            id: "q1",
            header: "H",
            question: "Which?",
            options: [
              { label: "A", description: "a" },
              { label: "B", description: "b", value: "bee" },
            ],
            multiSelect: true,
          },
        ],
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ui-2", "user-input.requested", T1, 14, 25, {
        requestId: "req-4",
        questions: [
          { id: "q2", header: "H2", question: "Name?", options: [], allowCustomAnswer: true },
        ],
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ap-1-res", "approval.resolved", T1, 15, 26, { requestId: "req-1" }),
    }),
    e("thread.activity-appended", {
      activity: activity("ap-1-again", "approval.requested", T1, 16, 27, {
        requestId: "req-1",
        requestKind: "permission",
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ap-2-fail", "provider.approval.respond.failed", T1, 17, 28, {
        requestId: "req-2",
        detail: "Stale pending approval request: req-2",
      }),
    }),
    e("thread.activity-appended", {
      activity: activity("ui-2-fail", "provider.user-input.respond.failed", T1, 18, 29, {
        requestId: "req-4",
        detail: "network down",
      }),
    }),
    // proposed plans (out of order, replaced)
    e("thread.proposed-plan-upserted", {
      proposedPlan: {
        id: "plan-b",
        turnId: T1,
        planMarkdown: "# B",
        implementedAt: null,
        implementationThreadId: null,
        createdAt: at(31),
        updatedAt: at(31),
      },
    }),
    e("thread.proposed-plan-upserted", {
      proposedPlan: {
        id: "plan-a",
        turnId: T1,
        planMarkdown: "# A",
        implementedAt: null,
        implementationThreadId: null,
        createdAt: at(30),
        updatedAt: at(30),
      },
    }),
    e("thread.proposed-plan-upserted", {
      proposedPlan: {
        id: "plan-b",
        turnId: T1,
        planMarkdown: "# B2",
        implementedAt: at(40),
        implementationThreadId: "impl-thread",
        createdAt: at(31),
        updatedAt: at(41),
      },
    }),
    // checkpoints: running session keeps the turn unsettled; a missing one never overwrites ready
    e("thread.turn-diff-completed", {
      turnId: T1,
      checkpointTurnCount: 3,
      checkpointRef: "refs/t3/c/3",
      status: "ready",
      files: [{ path: "a.ts", kind: "modified", additions: 1, deletions: 0 }],
      assistantMessageId: "m-asst-1",
      completedAt: at(50),
    }),
    e("thread.turn-diff-completed", {
      turnId: T1,
      checkpointTurnCount: 3,
      checkpointRef: "refs/t3/c/3",
      status: "missing",
      files: [],
      assistantMessageId: "m-asst-1",
      completedAt: at(51),
    }),
    e("thread.session-set", { session: session(threadId, "ready", null, 52) }),
    e("thread.turn-diff-completed", {
      turnId: T2,
      checkpointTurnCount: 2,
      checkpointRef: "refs/t3/c/2",
      status: "error",
      files: [],
      assistantMessageId: null,
      completedAt: at(53),
    }),
    // a turn that finishes by its last assistant message while the session is idle
    e("thread.message-sent", msg("m-asst-3", "assistant", "Done", T3, false, 54)),
    e("thread.session-set", { session: session(threadId, "running", T3, 55) }),
    e("thread.message-sent", msg("m-asst-3b", "assistant", "More", T3, false, 56)),
    e("thread.turn-interrupt-requested", { turnId: T3, createdAt: at(57) }),
    e("thread.turn-interrupt-requested", { turnId: "other-turn", createdAt: at(58) }),
    e("thread.turn-interrupt-requested", { createdAt: at(58) }),
    e("thread.session-set", { session: session(threadId, "interrupted", null, 59) }),
    e("thread.session-set", { session: session(threadId, "error", null, 60) }),
    e("thread.session-set", { session: session(threadId, "running", "turn-4", 61) }),
    e("thread.session-stop-requested", { createdAt: at(62) }),
    e("thread.session-set", { session: session(threadId, "stopped", null, 63) }),
    // modes
    e("thread.runtime-mode-set", { runtimeMode: "approval-required", updatedAt: at(64) }),
    e("thread.interaction-mode-set", { interactionMode: "plan", updatedAt: at(65) }),
    e("thread.turn-start-requested", {
      messageId: "m-user-2",
      modelSelection: { instanceId: "claudeAgent", model: "opus" },
      runtimeMode: "auto",
      interactionMode: "default",
      createdAt: at(66),
    }),
    // metadata
    e("thread.meta-updated", { title: "Renamed", updatedAt: at(67) }),
    e("thread.meta-updated", { branch: null, worktreePath: "/tmp/wt", updatedAt: at(68) }),
    e("thread.meta-updated", {
      branch: "feature/x",
      titleState: { source: "manual", version: "v1", needsRefinement: false },
      titleRegeneration: null,
      updatedAt: at(69),
    }),
    e("thread.meta-updated", {
      linkedPullRequest: {
        projectId: "p",
        repository: "o/r",
        number: 7,
        url: "https://github.com/o/r/pull/7",
      },
      branchPullRequest: null,
      activeOrderKey: null,
      updatedAt: at(70),
    }),
    e("thread.meta-updated", {
      modelSelection: { instanceId: "codex", model: "gpt-5" },
      activeOrderKey: "mm",
      updatedAt: at(71),
    }),
    // lifecycle
    e("thread.archived", { archivedAt: at(72), updatedAt: at(72) }),
    e("thread.unarchived", { updatedAt: at(73) }),
    e("thread.settled", { settledAt: at(74), updatedAt: at(74) }),
    e("thread.unsettled", { reason: "user", updatedAt: at(75) }),
    e("thread.unsettled", { reason: "activity", updatedAt: at(76) }),
    e("thread.settled", { settledAt: at(77), updatedAt: at(77) }),
    e("thread.unsettled", { reason: "activity", updatedAt: at(78) }),
    e("thread.snoozed", { snoozedUntil: at(5000), snoozedAt: at(79), updatedAt: at(79) }),
    e("thread.unsnoozed", { reason: "user", updatedAt: at(80) }),
    e("thread.pinned", { pinnedAt: at(81), pinOrderKey: "n", updatedAt: at(81) }),
    e("thread.pinned", { pinnedAt: at(82), updatedAt: at(82) }),
    e("thread.pin-reordered", { orderKey: "p", updatedAt: at(83) }),
    e("thread.unpinned", { updatedAt: at(84) }),
    e("thread.auto-settle-set", { autoSettleDisabledAt: at(85), updatedAt: at(85) }),
    e("thread.auto-settle-set", { autoSettleDisabledAt: null, updatedAt: at(86) }),
    // pull requests
    e("thread.pull-request-linked", {
      link: {
        host: "github.com",
        repository: "Owner/Repo",
        number: 7,
        url: "https://github.com/owner/repo/pull/7",
        source: "manual",
        linkedAt: at(87),
        snapshot: null,
        stack: null,
      },
      updatedAt: at(87),
    }),
    e("thread.pull-request-linked", {
      link: {
        host: "github.com",
        repository: "owner/repo",
        number: 8,
        url: "https://github.com/owner/repo/pull/8",
        source: "agent",
        linkedAt: at(88),
        snapshot: null,
        stack: null,
      },
      updatedAt: at(88),
    }),
    e("thread.pull-request-linked", {
      link: {
        host: "GITHUB.com",
        repository: "owner/repo",
        number: 7,
        url: "https://github.com/owner/repo/pull/7",
        source: "created",
        linkedAt: at(89),
        snapshot: null,
        stack: null,
      },
      updatedAt: at(89),
    }),
    e("thread.pull-request-synced", {
      host: "github.com",
      repository: "owner/repo",
      number: 7,
      snapshot: {
        state: "open",
        title: "Add x",
        headBranch: "x",
        baseBranch: "main",
        isDraft: false,
        updatedAt: at(90),
        syncedAt: at(90),
      },
      stack: null,
      updatedAt: at(90),
    }),
    e("thread.pull-request-synced", {
      host: "github.com",
      repository: "owner/repo",
      number: 99,
      snapshot: {
        state: "open",
        title: "nope",
        headBranch: "x",
        baseBranch: "main",
        isDraft: false,
        updatedAt: at(91),
        syncedAt: at(91),
      },
      stack: null,
      updatedAt: at(91),
    }),
    e("thread.pull-request-unlinked", {
      host: "github.com",
      repository: "owner/repo",
      number: 8,
      updatedAt: at(92),
    }),
    // no-op events
    e("thread.approval-response-requested", {
      requestId: "req-1",
      decision: "accept",
      createdAt: at(93),
    }),
    e("thread.user-input-response-requested", {
      requestId: "req-3",
      answers: {},
      createdAt: at(94),
    }),
    e("thread.checkpoint-revert-requested", { turnCount: 1, createdAt: at(95) }),
    // stale event (sequence <= cursor in the machine) is exercised in the machine test, not here
    e("thread.reverted", { turnCount: 2 }),
    e("thread.created", {
      projectId: "p",
      title: "Fresh",
      modelSelection: { instanceId: "codex", model: "gpt-5" },
      runtimeMode: "full-access",
      interactionMode: "default",
      branch: null,
      worktreePath: null,
      createdAt: at(96),
      updatedAt: at(96),
    }),
    e("thread.deleted", { deletedAt: at(97) }),
  ];
  return events;
}

/** A shell with every sidebar-relevant field exercised, as `{ environmentId, ...shell }` rows. */
export function syntheticShells() {
  const base = fixtureShell().threads[0];
  const T = (id: string, environmentId: string, overrides: any = {}) => ({
    ...clone(base),
    id,
    projectId: overrides.projectId ?? "p1",
    title: overrides.title ?? `Thread ${id}`,
    createdAt: "2026-09-01T10:00:00.000Z",
    updatedAt: "2026-09-01T10:00:00.000Z",
    settledOverride: null,
    settledAt: null,
    unsettledAt: null,
    snoozedUntil: null,
    snoozedAt: null,
    pinnedAt: null,
    pinOrderKey: null,
    activeOrderKey: null,
    archivedAt: null,
    latestTurn: null,
    session: null,
    latestUserMessageAt: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    hasActionableProposedPlan: false,
    pullRequests: [],
    environmentId,
    ...overrides,
  });
  const d = (n: number) => new Date(Date.UTC(2026, 9, 8, 12, 0, 0) + n * 60_000).toISOString();
  const turn = (state: string, completedAt: string | null) => ({
    turnId: "tt",
    state,
    requestedAt: d(-120),
    startedAt: d(-119),
    completedAt,
    assistantMessageId: null,
  });
  const session = (status: string, updatedAt: string) => ({
    threadId: "x",
    status,
    providerName: "codex",
    providerInstanceId: "codex",
    runtimeMode: "full-access",
    activeTurnId: null,
    lastError: null,
    updatedAt,
  });
  return [
    T("pin-b", "env-a", { pinnedAt: d(-500), pinOrderKey: "b" }),
    T("pin-a", "env-a", { pinnedAt: d(-400), pinOrderKey: "a" }),
    T("pin-a", "env-b", { pinnedAt: d(-400), pinOrderKey: "a" }),
    T("pin-new", "env-a", { pinnedAt: d(-300), createdAt: "2026-09-20T10:00:00.000Z" }),
    T("pin-old", "env-b", { pinnedAt: d(-300), createdAt: "2026-09-10T10:00:00.000Z" }),
    T("act-m", "env-a", { activeOrderKey: "m" }),
    T("act-c", "env-a", { activeOrderKey: "c" }),
    T("act-new", "env-a", { createdAt: "2026-09-25T10:00:00.000Z", title: "Needs foo fix" }),
    T("act-reopened", "env-b", {
      createdAt: "2026-09-02T10:00:00.000Z",
      unsettledAt: "2026-09-28T10:00:00.000Z",
      settledOverride: "active",
    }),
    T("act-old", "env-b", { createdAt: "2026-08-02T10:00:00.000Z" }),
    T("act-pr", "env-a", {
      pullRequests: [
        {
          host: "github.com",
          repository: "o/r",
          number: 42,
          url: "https://github.com/o/r/pull/42",
          source: "manual",
          linkedAt: d(-10),
          snapshot: null,
          stack: null,
        },
        {
          host: "github.com",
          repository: "o/r",
          number: 43,
          url: "https://github.com/o/r/pull/43",
          source: "stack-dismissed",
          linkedAt: d(-10),
          snapshot: null,
          stack: null,
        },
      ],
    }),
    T("act-legacy-pr", "env-a", {
      linkedPullRequest: {
        projectId: "p1",
        repository: "o/legacy",
        number: 5,
        url: "https://github.com/o/legacy/pull/5",
      },
    }),
    T("set-1", "env-a", { settledOverride: "settled", settledAt: d(-1000) }),
    T("set-2", "env-a", { settledOverride: "settled", settledAt: d(-2000) }),
    T("set-nostamp", "env-b", {
      settledOverride: "settled",
      latestUserMessageAt: d(-1500),
      latestTurn: turn("completed", d(-1400)),
    }),
    T("set-turnonly", "env-b", {
      settledOverride: "settled",
      latestTurn: turn("completed", d(-3000)),
    }),
    T("set-updated", "env-b", { settledOverride: "settled", updatedAt: d(-4000) }),
    T("set-tie-x", "env-a", { settledOverride: "settled", settledAt: d(-5000) }),
    T("set-tie-X", "env-b", { settledOverride: "settled", settledAt: d(-5000) }),
    T("set-pinned", "env-a", {
      settledOverride: "settled",
      settledAt: d(-6000),
      pinnedAt: d(-7000),
    }),
    T("set-queued", "env-a", { settledOverride: "settled", settledAt: d(-6000) }),
    T("snz-future", "env-a", { snoozedUntil: d(120), snoozedAt: d(-30) }),
    T("snz-soon", "env-b", {
      snoozedUntil: d(30),
      snoozedAt: d(-30),
      pinnedAt: d(-50),
      settledOverride: "settled",
    }),
    T("snz-approval", "env-a", {
      snoozedUntil: d(120),
      snoozedAt: d(-30),
      hasPendingApprovals: true,
    }),
    T("snz-input", "env-a", { snoozedUntil: d(120), snoozedAt: d(-30), hasPendingUserInput: true }),
    T("snz-completed-after", "env-a", {
      snoozedUntil: d(120),
      snoozedAt: d(-30),
      latestTurn: turn("completed", d(-5)),
    }),
    T("snz-completed-before", "env-a", {
      snoozedUntil: d(120),
      snoozedAt: d(-30),
      latestTurn: turn("completed", d(-50)),
    }),
    T("snz-failed-fresh", "env-a", {
      snoozedUntil: d(120),
      snoozedAt: d(-30),
      session: session("error", d(-10)),
    }),
    T("snz-failed-old", "env-a", {
      snoozedUntil: d(120),
      snoozedAt: d(-30),
      session: session("error", d(-60)),
    }),
    T("snz-elapsed", "env-a", { snoozedUntil: d(-5), snoozedAt: d(-90) }),
    T("snz-malformed", "env-a", { snoozedUntil: "not-a-date", snoozedAt: d(-90) }),
    T("snz-noat", "env-a", { snoozedUntil: d(60) }),
    T("snz-failed-noat", "env-b", { snoozedUntil: d(60), session: session("error", d(-10)) }),
    T("queued-user-msg", "env-a", { latestUserMessageAt: d(-1), latestTurn: null }),
    T("queued-adopted", "env-a", {
      latestUserMessageAt: d(-1),
      latestTurn: {
        turnId: "t",
        state: "running",
        requestedAt: d(-1),
        startedAt: d(-1),
        completedAt: null,
        assistantMessageId: null,
      },
    }),
    T("queued-old", "env-a", { latestUserMessageAt: d(-10), latestTurn: null }),
    T("queued-failed", "env-a", {
      latestUserMessageAt: d(-1),
      latestTurn: null,
      session: session("error", d(-1)),
    }),
    T("queued-future", "env-a", { latestUserMessageAt: d(5), latestTurn: null }),
    T("run-approval", "env-b", { hasPendingApprovals: true, session: session("running", d(-3)) }),
    T("run-input", "env-b", { hasPendingUserInput: true }),
    T("run-working", "env-b", { session: session("starting", d(-3)) }),
    T("run-failed", "env-b", { session: session("error", d(-3)) }),
    T("run-bg", "env-b", { backgroundLiveness: "monitoring" }),
    T("other-project", "env-a", { projectId: "p2" }),
  ];
}

export function syntheticProjects() {
  const base = fixtureShell().projects[0];
  const P = (
    id: string,
    environmentId: string,
    workspaceRoot: string,
    identity: any,
    overrides: any = {},
  ) => ({
    ...clone(base),
    id,
    title: overrides.title ?? `Project ${id}`,
    workspaceRoot,
    repositoryIdentity: identity,
    createdAt: "2026-09-01T10:00:00.000Z",
    updatedAt: "2026-09-01T10:00:00.000Z",
    environmentId,
    ...overrides,
  });
  const ident = (canonicalKey: string, rootPath: string | null, extra: any = {}) => ({
    canonicalKey,
    locator: { source: "git-remote", remoteName: "origin", remoteUrl: `git@x:${canonicalKey}.git` },
    rootPath,
    displayName: extra.displayName,
    name: extra.name,
    provider: "github",
  });
  return [
    P(
      "a1",
      "env-a",
      "/work/repo",
      ident("github.com/o/repo", "/work/repo", { displayName: "o/repo", name: "repo" }),
    ),
    P(
      "a2",
      "env-a",
      "/work/repo/packages/web/",
      ident("github.com/o/repo", "/work/repo", { displayName: "o/repo", name: "repo" }),
      { title: "web" },
    ),
    P(
      "b1",
      "env-b",
      "/home/me/repo",
      ident("github.com/o/repo", "/home/me/repo", { displayName: "o/repo", name: "repo" }),
      { title: "repo", updatedAt: "2026-09-05T10:00:00.000Z" },
    ),
    P(
      "b2",
      "env-b",
      "/home/me/repo",
      ident("github.com/o/repo", "/home/me/repo", { displayName: "o/repo", name: "repo" }),
      { title: "repo copy", updatedAt: "2026-09-03T10:00:00.000Z" },
    ),
    P("b3", "env-b", "/srv/other", null, { title: "Other" }),
    P("b4", "env-b", "/srv/other", ident("github.com/o/other", "/srv/other", { name: "other" }), {
      title: "Other",
      updatedAt: "2026-09-02T10:00:00.000Z",
    }),
    P(
      "a3",
      "env-a",
      "C:\\Work\\Win\\",
      ident("github.com/o/win", "C:\\Work\\Win", { displayName: "o/win" }),
      { title: "Win" },
    ),
    P(
      "a4",
      "env-a",
      "c:/work/win/sub",
      ident("github.com/o/win", "C:\\Work\\Win", { displayName: "o/win" }),
      { title: "Sub" },
    ),
    P("a5", "env-a", "/solo", null, { title: "Solo" }),
    P("b5", "env-b", "/solo", null, { title: "Solo" }),
  ];
}
