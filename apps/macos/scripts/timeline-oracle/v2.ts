// Differential oracle for the Swift protocol-2 timeline derivation.
//
//   node apps/macos/scripts/timeline-oracle/v2.ts
//
// For every scenario (synthetic threads and the V2 wire fixtures) this writes the wire thread
// projection plus the client-side contexts (`oracle-v2/scenarios/<name>.json`) and the document
// the web's own TypeScript derivations produce for each context (`oracle-v2/expected/<name>.json`).
// The Swift tests decode the same projection with the generated types, run T3Timeline and compare.
//
// The protocol-1 oracle (oracle.ts) cannot run against this checkout: the web no longer derives
// from V1 threads. Its committed fixtures stay valid for the Swift V1 path.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import { loadContracts, loadRuntime, macosRoot, repoRoot } from "../lib/load.ts";
import { contractsFixtures } from "./lib.ts";
import { syntheticScenarios } from "./synthetic-v2.ts";

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
const outDir = join(macosRoot, "T3Kit", "Tests", "T3TimelineTests", "Fixtures", "oracle-v2");

const [S, R, E, CP, M] = await Promise.all([
  imp("apps/web/src/session-logic.ts"),
  imp("apps/web/src/components/chat/MessagesTimeline.logic.ts"),
  imp("packages/client-runtime/src/state/threadExecution.ts"),
  imp("packages/client-runtime/src/state/threadCheckpoints.ts"),
  imp("apps/web/src/components/chat/timelineMinimapItems.ts"),
]);
const contracts = await loadContracts();
const { S: Schema } = await loadRuntime();
// The wire form: timestamps arrive as ISO strings and decode to DateTime values.
const projectionCodec = Schema.toCodecJson(contracts.OrchestrationV2ThreadProjection);
const decodeProjection = (wire: unknown) => Schema.decodeUnknownSync(projectionCodec)(wire);

interface Context {
  isWorking: boolean | null;
  sendStartedAt: string | null;
  expandedRunIds: string[];
  expandedAttemptIds: string[];
  expandedWorkGroupIds: string[];
  supportsConversationRollback: boolean;
  worktreeSetup: any | null;
}
const defaultContext = (): Context => ({
  isWorking: null,
  sendStartedAt: null,
  expandedRunIds: [],
  expandedAttemptIds: [],
  expandedWorkGroupIds: [],
  supportsConversationRollback: false,
  worktreeSetup: null,
});

// ---- projection (mirrors T3Timeline/V2/ProjectionV2.swift) ---------------------------------

const ENTRY_KEYS = [
  "id",
  "createdAt",
  "label",
  "tone",
  "detail",
  "command",
  "rawCommand",
  "changedFiles",
  "toolTitle",
  "viewedImagePath",
  "toolSurface",
  "toolIcon",
  "toolSource",
  "itemType",
  "toolLifecycleStatus",
  "sourceActivityKind",
] as const;

function projectEntry(entry: any) {
  const out: Record<string, unknown> = {};
  for (const key of ENTRY_KEYS) if (entry[key] !== undefined) out[key] = entry[key];
  out.runId = entry.runId ?? null;
  if (entry.questionAnswer) out.questionAnswerRequestId = entry.questionAnswer.requestId;
  return out;
}

const itemStub = (item: any) => ({
  id: item.id,
  type: item.type,
  status: item.status,
  runId: item.runId ?? null,
});
const messageStub = (m: any) => ({
  id: m.id,
  role: m.role,
  streaming: m.streaming,
  runId: m.runId ?? null,
  ...(m.inputIntent !== undefined ? { inputIntent: m.inputIntent } : {}),
});
const planProjection = (p: any) => ({
  id: p.id,
  runId: p.runId ?? null,
  planMarkdown: p.planMarkdown,
  status: p.status,
  createdAt: p.createdAt,
  updatedAt: p.updatedAt,
});
const htmlProjection = (h: any) => ({
  attachmentId: h.attachmentId,
  title: h.title,
  height: h.height,
});
const summaryProjection = (s: any) => ({
  runId: s.runId,
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
const mcpProjection = (e: any) => ({
  sourceThreadId: e.sourceThreadId,
  itemId: e.itemId,
  revision: e.revision,
  mcpApp: {
    attachmentId: e.mcpApp.attachmentId,
    server: e.mcpApp.server,
    tool: e.mcpApp.tool,
    resourceUri: e.mcpApp.resourceUri,
  },
});

function projectTimelineEntry(entry: any) {
  const base: Record<string, unknown> = {
    kind: entry.kind,
    id: entry.id,
    createdAt: entry.createdAt,
    ...(entry.attempt
      ? {
          attempt: {
            id: entry.attempt.id,
            runId: entry.attempt.runId,
            status: entry.attempt.status,
          },
        }
      : {}),
  };
  switch (entry.kind) {
    case "message":
      return { ...base, message: messageStub(entry.message) };
    case "proposed-plan":
      return { ...base, proposedPlan: planProjection(entry.proposedPlan) };
    case "html-render":
      return { ...base, htmlRender: htmlProjection(entry.htmlRender) };
    case "mcp-app":
      return { ...base, mcpApp: mcpProjection(entry) };
    case "work":
      return { ...base, entry: projectEntry(entry.entry) };
    case "event":
      return { ...base, item: itemStub(entry.projectedItem.item) };
    default:
      throw new Error(`unknown entry kind ${entry.kind}`);
  }
}

function projectRow(row: any) {
  const base = { kind: row.kind, id: row.id, createdAt: row.createdAt ?? null };
  const flag = row.continuesWorkLog ? { continuesWorkLog: true } : {};
  switch (row.kind) {
    case "work":
      return {
        ...base,
        groupedEntries: row.groupedEntries.map(projectEntry),
        isExpandedToolGroup: row.isExpandedToolGroup,
        ...(row.displayLabel !== undefined ? { displayLabel: row.displayLabel } : {}),
        ...flag,
      };
    case "work-live":
      return {
        ...base,
        entry: projectEntry(row.entry),
        groupedEntries: row.groupedEntries.map(projectEntry),
        groupId: row.groupId,
        expanded: row.expanded,
        active: row.active,
        ...(row.thought ? { thought: projectEntry(row.thought) } : {}),
        ...flag,
      };
    case "work-toggle":
      return {
        ...base,
        runId: row.runId ?? null,
        groupId: row.groupId,
        hiddenCount: row.hiddenCount,
        expanded: row.expanded,
        summary: row.summary,
        summaryKind: row.summaryKind,
        ...(row.toolSurface !== undefined ? { toolSurface: row.toolSurface } : {}),
        ...(row.toolIcon !== undefined ? { toolIcon: row.toolIcon } : {}),
        ...(row.summaryToolIcon !== undefined ? { summaryToolIcon: row.summaryToolIcon } : {}),
        hasFailure: row.hasFailure,
        ...flag,
      };
    case "turn-fold":
      return { ...base, runId: row.runId, label: row.label, expanded: row.expanded };
    case "attempt-fold":
      return {
        ...base,
        runId: row.runId,
        attemptId: row.attemptId,
        label: row.label,
        expanded: row.expanded,
      };
    case "context-compaction":
      return { ...base, label: row.label, active: row.active };
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
    case "event":
      return {
        ...base,
        item: itemStub(row.projectedItem.item),
        ...(row.subagents ? { subagents: row.subagents.map((s: any) => itemStub(s.item)) } : {}),
        ...(row.resourceSummary ? { resourceSummary: true } : {}),
      };
    case "proposed-plan":
      return { ...base, proposedPlan: planProjection(row.proposedPlan) };
    case "html-render":
      return { ...base, htmlRender: htmlProjection(row.htmlRender) };
    case "mcp-app":
      return { ...base, mcpApp: mcpProjection(row) };
    case "working":
      return base;
    case "thinking":
      return {
        ...base,
        ...(row.groupId !== undefined
          ? { groupId: row.groupId, expanded: row.expanded ?? false }
          : {}),
        ...flag,
      };
    case "worktree-setup":
      return {
        ...base,
        snapshot: {
          threadId: row.snapshot.threadId,
          phase: row.snapshot.phase,
          startedAt: row.snapshot.startedAt,
          sequence: row.snapshot.sequence,
          stages: row.snapshot.stages.map((st: any) => ({ id: st.id, status: st.status })),
        },
        embedded: row.embedded,
      };
    default:
      throw new Error(`unknown row kind ${row.kind}`);
  }
}

function deriveProjection(wire: unknown, ctx: Context) {
  const projection = decodeProjection(wire);
  const runtime = E.deriveThreadRuntime(projection);
  const activityRun = E.deriveThreadActivityRun(projection);
  const latestRun = E.deriveLatestThreadRun(projection);
  const runless = E.deriveRunlessWorkStartedAt(projection);
  const phase = S.derivePhase(runtime);
  const isWorking = ctx.isWorking ?? (phase === "running" || runless !== null);
  const activeTurnStartedAt =
    S.deriveActiveWorkStartedAt(activityRun, runtime, ctx.sendStartedAt) ?? runless;
  const checkpoints = CP.deriveThreadCheckpointSummaries(projection);
  const entries = S.deriveTimelineEntriesFromVisibleTurnItems({
    visibleTurnItems: projection.visibleTurnItems,
    optimisticMessages: [],
    attempts: projection.attempts,
    nodes: projection.nodes,
    plans: projection.plans,
  });
  const rows = R.deriveMessagesTimelineRows({
    timelineEntries: entries,
    latestRun: activityRun,
    runningRunId: runtime?.activeRunId ?? null,
    expandedRunIds: new Set(ctx.expandedRunIds),
    expandedAttemptIds: new Set(ctx.expandedAttemptIds),
    expandedWorkGroupIds: new Set(ctx.expandedWorkGroupIds),
    isWorking,
    runlessWorkActive: runless !== null,
    activeTurnStartedAt,
    turnDiffSummaries: checkpoints,
    supportsConversationRollback: ctx.supportsConversationRollback,
    worktreeSetup: ctx.worktreeSetup,
  });
  const settled = S.isLatestRunSettled(latestRun, runtime);
  const plan = S.deriveActivePlanState(projection, activityRun?.runId);
  const proposed = settled ? S.findLatestProposedPlan(projection, latestRun?.runId ?? null) : null;
  return {
    entries,
    rows,
    document: {
      timelineEntries: entries.map(projectTimelineEntry),
      rows: rows.map(projectRow),
      phase,
      isWorking,
      activeTurnStartedAt: activeTurnStartedAt ?? null,
      runningRunId: runtime?.activeRunId ?? null,
      activePlan:
        plan === null
          ? null
          : {
              createdAt: plan.createdAt,
              runId: plan.runId ?? null,
              explanation: plan.explanation ?? null,
              steps: plan.steps.map((s: any) => ({
                ...(s.durationMs !== undefined ? { durationMs: s.durationMs } : {}),
                step: s.step,
                status: s.status,
              })),
            },
      activeProposedPlan:
        proposed === null
          ? null
          : {
              id: proposed.id,
              createdAt: proposed.createdAt,
              updatedAt: proposed.updatedAt,
              runId: proposed.runId ?? null,
              planMarkdown: proposed.planMarkdown,
              status: proposed.status,
            },
      minimap: M.deriveTimelineMinimapItems(rows).map((i: any) => ({
        id: i.id,
        rowIndex: i.rowIndex,
        userText: i.userText ?? null,
        assistantText: i.assistantText ?? null,
      })),
      checkpoints: checkpoints.map(summaryProjection),
    },
  };
}

const LABEL_ROOTS: Array<string | null> = [null, "/workspace/project", "C:\\work\\proj"];

function entryLabels(entries: any[]) {
  return entries
    .filter((entry) => entry.kind === "work")
    .map((entry) => ({
      id: entry.id,
      labels: LABEL_ROOTS.map((root) => ({
        root,
        display: R.workEntryDisplayLabel(entry.entry, root ?? undefined),
        live: R.liveWorkEntryLabel(entry.entry, root ?? undefined, true),
        settled: R.liveWorkEntryLabel(entry.entry, root ?? undefined, false),
      })),
    }));
}

// ---- run -----------------------------------------------------------------------------------

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, "scenarios"), { recursive: true });
mkdirSync(join(outDir, "expected"), { recursive: true });
const write = (kind: "scenarios" | "expected", name: string, value: unknown) =>
  writeFileSync(join(outDir, kind, `${name}.json`), JSON.stringify(value) + "\n");

const counts = {
  scenarios: 0,
  rows: 0,
  entries: 0,
  kinds: new Map<string, number>(),
  itemTypes: new Map<string, number>(),
};
const bump = (map: Map<string, number>, key: string) => map.set(key, (map.get(key) ?? 0) + 1);

function runScenario(name: string, wire: any) {
  const base = defaultContext();
  const variants: Array<{ name: string; context: Context }> = [
    { name: "auto-default", context: base },
  ];
  const plain = deriveProjection(wire, base);
  const groupIds = (rows: any[]) =>
    rows.flatMap((r) => (typeof r.groupId === "string" ? [r.groupId] : []));
  const runIds = wire.runs.map((r: any) => r.id);
  const attemptIds = wire.attempts.map((a: any) => a.id);
  variants.push({
    name: "auto-expanded",
    context: {
      ...base,
      expandedRunIds: runIds,
      expandedAttemptIds: attemptIds,
      expandedWorkGroupIds: groupIds(plain.document.rows),
      supportsConversationRollback: true,
    },
  });
  const working = { ...base, isWorking: true, sendStartedAt: "2026-10-01T11:59:00.000Z" };
  const workingDerived = deriveProjection(wire, working);
  variants.push({ name: "auto-working", context: working });
  variants.push({
    name: "auto-working-expanded",
    context: { ...working, expandedWorkGroupIds: groupIds(workingDerived.document.rows) },
  });
  variants.push({
    name: "auto-idle",
    context: { ...base, isWorking: false, sendStartedAt: "2026-10-01T11:59:00.000Z" },
  });

  const expected: Record<string, unknown> = {};
  let labels: unknown = [];
  for (const variant of variants) {
    const derived = deriveProjection(wire, variant.context);
    expected[variant.name] = derived.document;
    counts.scenarios += 1;
    counts.rows += derived.rows.length;
    counts.entries += derived.entries.length;
    for (const row of derived.rows) bump(counts.kinds, row.kind);
    if (variant.name === "auto-default") {
      labels = entryLabels(derived.entries);
      for (const entry of derived.entries) {
        const type =
          entry.kind === "work"
            ? entry.entry.itemType
            : entry.kind === "event"
              ? entry.projectedItem.item.type
              : entry.kind;
        bump(counts.itemTypes, type ?? "?");
      }
    }
  }
  write("scenarios", name, { projection: wire, variants });
  write("expected", name, { variants: expected, labels });
}

for (const scenario of syntheticScenarios())
  runScenario(`syn-${scenario.name}`, scenario.projection);
for (const file of [
  "v2-thread-with-history-snapshot",
  "v2-thread-bounded-snapshot",
  "v2-thread-after-events-snapshot",
  "v2-thread-stream-snapshot",
]) {
  const wire = JSON.parse(readFileSync(join(contractsFixtures, "wire", `${file}.json`), "utf8"));
  runScenario(`wire-${file.replace(/^v2-thread-/, "")}`, wire.projection);
}

const table = (map: Map<string, number>) =>
  [...map]
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => `${k}=${v}`)
    .join(" ");
console.log(`v2: ${counts.scenarios} derivations -> ${outDir}`);
console.log(`rows ${counts.rows}: ${table(counts.kinds)}`);
console.log(`entries ${counts.entries} (default variants): ${table(counts.itemTypes)}`);
