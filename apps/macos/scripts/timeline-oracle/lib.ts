// Shared loading and projection for the timeline oracle: the real TypeScript derivations of the
// web chat view (apps/web/src/session-logic.ts, MessagesTimeline.logic.ts and the work-log /
// pending-request modules of packages/client-runtime), imported by file URL so the Swift port is
// compared against the code that ships, not a copy.
import { registerHooks } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot, macosRoot } from "../lib/load.ts";

// apps/web uses bundler-style extensionless imports; resolve them for node.
registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (error: any) {
      if (!/^\.{1,2}\//.test(specifier)) throw error;
      for (const suffix of [".ts", ".tsx", "/index.ts"]) {
        try {
          return nextResolve(specifier + suffix, context);
        } catch {}
      }
      throw error;
    }
  },
});

const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

export const oracleRoot = join(
  macosRoot,
  "T3Kit",
  "Tests",
  "T3TimelineTests",
  "Fixtures",
  "oracle",
);
export const contractsFixtures = join(macosRoot, "T3Kit", "Tests", "T3ContractsTests", "Fixtures");

export async function loadSources() {
  const cr = "packages/client-runtime/src/";
  const web = "apps/web/src/";
  const [
    sessionLogic,
    rows,
    pending,
    pendingUserInput,
    turnDiffTree,
    commandLabel,
    subagent,
    presentation,
  ] = await Promise.all([
    imp(web + "session-logic.ts"),
    imp(web + "components/chat/MessagesTimeline.logic.ts"),
    imp(cr + "pendingRequests.ts"),
    imp(web + "pendingUserInput.ts"),
    imp(web + "lib/turnDiffTree.ts"),
    imp(cr + "work-log/commandLabel.ts"),
    imp(cr + "state/subagentRuntime.ts"),
    imp(cr + "work-log/presentation.ts"),
  ]);
  const minimap = await imp(web + "components/chat/timelineMinimapItems.ts");
  return {
    sessionLogic,
    rows,
    pending,
    pendingUserInput,
    turnDiffTree,
    commandLabel,
    subagent,
    presentation,
    minimap,
  };
}
export type Sources = Awaited<ReturnType<typeof loadSources>>;

export interface ScenarioContext {
  isWorking: boolean | null;
  sendStartedAt: string | null;
  expandedTurnIds: string[];
  expandedWorkGroupIds: string[];
  supportsConversationRollback: boolean;
  liveAgentTaskIds: string[] | null;
  worktreeSetup: any | null;
  queuedMessages: Array<{ id: string; createdAt: string; text: string }>;
}

export const defaultContext = (): ScenarioContext => ({
  isWorking: null,
  sendStartedAt: null,
  expandedTurnIds: [],
  expandedWorkGroupIds: [],
  supportsConversationRollback: false,
  liveAgentTaskIds: null,
  worktreeSetup: null,
  queuedMessages: [],
});

// ---- projection (mirrors T3Timeline/TimelineProjection.swift) ---------------------------------

const ENTRY_KEYS = [
  "id",
  "createdAt",
  "turnId",
  "label",
  "tone",
  "questionAnswer",
  "toolCallId",
  "detail",
  "viewedImagePath",
  "command",
  "rawCommand",
  "changedFiles",
  "toolTitle",
  "toolSurface",
  "toolIcon",
  "toolSource",
  "toolData",
  "itemType",
  "requestKind",
  "toolLifecycleStatus",
  "sourceActivityKind",
  "taskId",
  "agentRole",
  "agentSpawn",
] as const;

export function projectEntry(entry: any) {
  const out: Record<string, unknown> = {};
  for (const key of ENTRY_KEYS) {
    const value = entry[key];
    if (key === "turnId") out[key] = value ?? null;
    else if (value !== undefined) out[key] = value;
  }
  return out;
}

const messageStub = (m: any) => ({ id: m.id, role: m.role, streaming: m.streaming });
const summaryProjection = (s: any) => ({
  turnId: s.turnId,
  checkpointTurnCount: s.checkpointTurnCount,
  status: s.status,
  files: s.files.map((f: any) => ({
    path: f.path,
    kind: f.kind,
    additions: f.additions,
    deletions: f.deletions,
  })),
  assistantMessageId: s.assistantMessageId ?? null,
  completedAt: s.completedAt,
});
const planProjection = (p: any) => ({
  id: p.id,
  turnId: p.turnId ?? null,
  planMarkdown: p.planMarkdown,
  implementedAt: p.implementedAt ?? null,
  implementationThreadId: p.implementationThreadId ?? null,
  createdAt: p.createdAt,
  updatedAt: p.updatedAt,
});
const snapshotProjection = (s: any) => ({
  threadId: s.threadId,
  phase: s.phase,
  startedAt: s.startedAt,
  sequence: s.sequence,
  stages: s.stages.map((st: any) => ({ id: st.id, status: st.status })),
});
const activityEntryProjection = (e: any) =>
  e.kind === "message"
    ? { kind: "message", message: messageStub(e.message) }
    : { kind: "work", entry: projectEntry(e.entry) };

export function projectTimelineEntry(entry: any) {
  const base = { kind: entry.kind, id: entry.id, createdAt: entry.createdAt };
  switch (entry.kind) {
    case "message":
      return { ...base, message: messageStub(entry.message) };
    case "proposed-plan":
      return { ...base, proposedPlan: planProjection(entry.proposedPlan) };
    default:
      return { ...base, entry: projectEntry(entry.entry) };
  }
}

export function projectRow(row: any) {
  const base = { kind: row.kind, id: row.id, createdAt: row.createdAt ?? null };
  switch (row.kind) {
    case "activity-group":
      return {
        ...base,
        turnId: row.turnId,
        groupId: row.groupId,
        entries: row.entries.map(activityEntryProjection),
        expanded: row.expanded,
        active: row.active,
      };
    case "work":
      return {
        ...base,
        groupedEntries: row.groupedEntries.map(projectEntry),
        isExpandedToolGroup: row.isExpandedToolGroup,
        ...(row.displayLabel !== undefined ? { displayLabel: row.displayLabel } : {}),
      };
    case "work-live":
      return {
        ...base,
        entry: projectEntry(row.entry),
        groupedEntries: row.groupedEntries.map(projectEntry),
        groupId: row.groupId,
        expanded: row.expanded,
        active: row.active,
      };
    case "work-toggle":
      return {
        ...base,
        turnId: row.turnId ?? null,
        groupId: row.groupId,
        hiddenCount: row.hiddenCount,
        expanded: row.expanded,
        summary: row.summary,
        summaryKind: row.summaryKind,
        ...(row.toolSurface !== undefined ? { toolSurface: row.toolSurface } : {}),
        ...(row.toolIcon !== undefined ? { toolIcon: row.toolIcon } : {}),
        ...(row.summaryToolIcon !== undefined ? { summaryToolIcon: row.summaryToolIcon } : {}),
        hasFailure: row.hasFailure,
      };
    case "turn-fold":
      return { ...base, turnId: row.turnId, label: row.label, expanded: row.expanded };
    case "context-compaction":
      return { ...base, label: row.label };
    case "message":
      return {
        ...base,
        message: messageStub(row.message),
        durationStart: row.durationStart,
        showAssistantMeta: row.showAssistantMeta,
        showAssistantCopyButton: row.showAssistantCopyButton,
        assistantCopyStreaming: row.assistantCopyStreaming,
        ...(row.assistantTurnDiffSummary
          ? { assistantTurnDiffSummary: summaryProjection(row.assistantTurnDiffSummary) }
          : {}),
        ...(row.revertTurnCount !== undefined ? { revertTurnCount: row.revertTurnCount } : {}),
      };
    case "assistant-meta":
      return {
        ...base,
        message: messageStub(row.message),
        showAssistantCopyButton: row.showAssistantCopyButton,
        assistantCopyStreaming: row.assistantCopyStreaming,
      };
    case "proposed-plan":
      return { ...base, proposedPlan: planProjection(row.proposedPlan) };
    case "working":
    case "thinking":
      return base;
    case "worktree-setup":
      return { ...base, snapshot: snapshotProjection(row.snapshot), embedded: row.embedded };
    case "queued-message":
      return { ...base, queuedMessageId: row.queuedMessage.id, isNext: row.isNext };
    default:
      throw new Error(`unknown row kind ${row.kind}`);
  }
}

const planStateProjection = (p: any) =>
  p === null
    ? null
    : {
        createdAt: p.createdAt,
        turnId: p.turnId ?? null,
        ...("explanation" in p ? { explanation: p.explanation ?? null } : {}),
        steps: p.steps.map((s: any) => ({
          ...(s.durationMs !== undefined ? { durationMs: s.durationMs } : {}),
          step: s.step,
          status: s.status,
        })),
      };
const proposedPlanStateProjection = (p: any) =>
  p === null
    ? null
    : {
        id: p.id,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        turnId: p.turnId ?? null,
        planMarkdown: p.planMarkdown,
        implementedAt: p.implementedAt ?? null,
        implementationThreadId: p.implementationThreadId ?? null,
      };

/** The ids MessagesTimeline.tsx passes as `liveAgentTaskIds` (agent panel liveness). */
export function liveAgentTaskIds(src: Sources, thread: any): string[] {
  const { subagent } = src;
  const session = thread.session ?? null;
  const phase = src.sessionLogic.derivePhase(session);
  const agents = subagent.foldSubagentActivities(thread.activities, {
    sessionLive: phase !== "disconnected",
  });
  const model = subagent.deriveAgentPanelModel({ agents });
  const ids: string[] = [];
  const consider = (agent: { id: string; status: any }) => {
    if (subagent.isActiveSubagentStatus(agent.status)) ids.push(agent.id);
  };
  model.directAgents.forEach(consider);
  for (const group of model.workflows) {
    if (!subagent.isTerminalSubagentStatus(group.workflow.status)) ids.push(group.workflow.id);
    group.unphasedMembers.forEach(consider);
    group.phases.forEach((phase: any) => phase.members.forEach(consider));
  }
  return ids.sort();
}

/** The ChatView glue + MessagesTimeline derivations for one thread (one scenario). */
export function deriveThreadProjection(src: Sources, thread: any, ctx: ScenarioContext) {
  const { sessionLogic: S, rows: R, minimap: M } = src;
  const session = thread.session ?? null;
  const latestTurn = thread.latestTurn ?? null;
  const phase = S.derivePhase(session);
  const workEntries = S.deriveWorkLogEntries(thread.activities);
  const timelineEntries = S.deriveTimelineEntries(
    thread.messages,
    thread.proposedPlans,
    workEntries,
  );
  const runningTurnId =
    (session?.status === "running" ? session.activeTurnId : null) ??
    (latestTurn?.state === "running" ? latestTurn.turnId : null);
  const isWorking = ctx.isWorking ?? phase === "running";
  const latestUserMessageAt =
    thread.messages.findLast((m: any) => m.role === "user")?.createdAt ?? null;
  const activeTurnStartedAt = S.deriveActiveWorkStartedAt(
    latestTurn,
    session,
    ctx.sendStartedAt,
    latestUserMessageAt,
  );
  const rows = R.deriveMessagesTimelineRows({
    timelineEntries,
    latestTurn,
    runningTurnId,
    expandedTurnIds: new Set(ctx.expandedTurnIds),
    expandedWorkGroupIds: new Set(ctx.expandedWorkGroupIds),
    isWorking,
    activeTurnStartedAt,
    turnDiffSummaries: thread.checkpoints,
    supportsConversationRollback: ctx.supportsConversationRollback,
    // The web derives the live ids from the agent panel model unless a caller overrides them.
    liveAgentTaskIds: new Set(ctx.liveAgentTaskIds ?? liveAgentTaskIds(src, thread)),
    worktreeSetup: ctx.worktreeSetup,
    queuedMessages: ctx.queuedMessages.map((q) => ({
      id: q.id,
      createdAt: q.createdAt,
      prompt: q.text,
    })),
  });
  const settled = S.isLatestTurnSettled(latestTurn, session);
  const minimapItems = M.deriveTimelineMinimapItems(rows);
  return {
    workEntries: workEntries.map(projectEntry),
    timelineEntries: timelineEntries.map(projectTimelineEntry),
    rows: rows.map(projectRow),
    phase,
    isWorking,
    activeTurnStartedAt: activeTurnStartedAt ?? null,
    runningTurnId: runningTurnId ?? null,
    activePlan: planStateProjection(
      S.deriveActivePlanState(thread.activities, latestTurn?.turnId ?? undefined),
    ),
    activeProposedPlan: settled
      ? proposedPlanStateProjection(
          S.findLatestProposedPlan(thread.proposedPlans, latestTurn?.turnId ?? null),
        )
      : null,
    minimap: minimapItems.map((i: any) => ({
      id: i.id,
      rowIndex: i.rowIndex,
      userText: i.userText ?? null,
      assistantText: i.assistantText ?? null,
    })),
  };
}
