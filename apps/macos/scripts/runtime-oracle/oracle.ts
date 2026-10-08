// Differential oracle for the Swift client runtime.
//
//   node apps/macos/scripts/runtime-oracle/oracle.ts                       # sanitized fixtures + synthetic streams
//   node apps/macos/scripts/runtime-oracle/oracle.ts --raw [--raw-dir DIR] # private recordings, output stays in /private/tmp
//
// For every scenario this writes the input (`scenarios/<name>.json`, wire JSON) and the state the
// real TypeScript reducers reach (`expected/<name>.json`). The Swift tests decode the same input
// with the generated types, run the Swift reducers and compare the encoded result.
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { contractsFixtures, loadSources, plain, runtimeRoot } from "./lib.ts";
import { loadContracts, loadRuntime } from "../lib/load.ts";
import {
  event,
  fixtureShell,
  fixtureThreadDetail,
  smallThread,
  syntheticProjects,
  syntheticShells,
  syntheticThreadEvents,
} from "./synthetic.ts";

const raw = process.argv.includes("--raw");
const argv = (name: string, fallback: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1]! : fallback;
};
const ARTIFACT = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78";
const rawDir = argv("raw-dir", `${ARTIFACT}/stageA-contracts/tmp/raw`);
const outDir = raw ? argv("out", `${ARTIFACT}/stageB-runtime/tmp/oracle-raw`) : runtimeRoot;
if (raw && !outDir.startsWith("/private/tmp/"))
  throw new Error("Refusing to write private recordings outside /private/tmp");

const src = await loadSources();
const contracts = await loadContracts();
const { S } = await loadRuntime();
const validate = (schema: string, value: unknown) => S.decodeUnknownSync(contracts[schema])(value);

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, "scenarios"), { recursive: true });
mkdirSync(join(outDir, "expected"), { recursive: true });
const write = (kind: "scenarios" | "expected", name: string, value: unknown) =>
  writeFileSync(join(outDir, kind, `${name}.json`), JSON.stringify(value) + "\n");
const readJson = (base: string, path: string) => JSON.parse(readFileSync(join(base, path), "utf8"));
const base = raw ? rawDir : contractsFixtures;
const chunkValues = (path: string): any[] =>
  readJson(base, path).flatMap((m: any) => (m._tag === "Chunk" ? m.values : []));
const counts = { shell: 0, thread: 0, derived: 0, steps: 0 };

// ---- shell -------------------------------------------------------------------------------------
function runShell(name: string, snapshot: any, items: any[], perStep: boolean) {
  let state = snapshot;
  const steps: any[] = [];
  for (const item of items) {
    if (item.kind === "snapshot") state = item.snapshot;
    else if (item.kind !== "synchronized")
      state = src.shellReducer.applyShellStreamEvent(state, item);
    steps.push(
      perStep
        ? plain(state)
        : {
            sequence: state.snapshotSequence,
            projects: state.projects.length,
            threads: state.threads.length,
          },
    );
    counts.steps += 1;
  }
  write("scenarios", `shell-${name}`, { kind: "shell", snapshot, items });
  write("expected", `shell-${name}`, { final: plain(state), steps, perStep });
  counts.shell += 1;
}

const shell = readJson(base, "shell.json");
runShell(
  "fixture-replay",
  shell,
  chunkValues("rpc/orchestration.subscribeShell-replay.json"),
  true,
);
runShell("fixture-stream", shell, chunkValues("rpc/orchestration.subscribeShell.json"), false);

{
  const snapshot = {
    ...fixtureShell(),
    snapshotSequence: 100,
    threads: fixtureShell().threads.slice(0, 4),
    projects: fixtureShell().projects.slice(0, 3),
  };
  const t = (id: string, extra: any = {}) => ({
    ...JSON.parse(JSON.stringify(snapshot.threads[0])),
    id,
    ...extra,
  });
  const items = [
    { kind: "thread-upserted", sequence: 101, thread: t("new-1", { title: "brand new" }) },
    {
      kind: "thread-upserted",
      sequence: 102,
      thread: { ...snapshot.threads[1], title: "replaced", settledOverride: "active" },
    },
    { kind: "thread-upserted", sequence: 102, thread: t("stale-same-sequence") },
    { kind: "thread-upserted", sequence: 90, thread: t("stale-older") },
    {
      kind: "project-upserted",
      sequence: 105,
      project: { ...snapshot.projects[0], title: "renamed project" },
    },
    {
      kind: "project-upserted",
      sequence: 106,
      project: { ...snapshot.projects[0], id: "proj-new", title: "added project" },
    },
    { kind: "thread-removed", sequence: 107, threadId: snapshot.threads[2].id },
    { kind: "thread-removed", sequence: 108, threadId: "does-not-exist" },
    { kind: "project-removed", sequence: 109, projectId: "proj-new" },
    { kind: "synchronized" },
    {
      kind: "thread-upserted",
      sequence: 120,
      thread: t("after-sync", { pinnedAt: "2026-10-01T00:00:00.000Z", pinOrderKey: "k" }),
    },
    {
      kind: "snapshot",
      snapshot: { ...snapshot, snapshotSequence: 300, threads: [t("only-one")] },
    },
    { kind: "thread-upserted", sequence: 301, thread: t("after-snapshot") },
  ];
  runShell("synthetic", snapshot, items, true);
}

// ---- thread ------------------------------------------------------------------------------------
function runThread(name: string, snapshot: any, events: any[], perStep: boolean) {
  let thread: any = snapshot.thread;
  let alive = true;
  const steps: any[] = [];
  for (const ev of events) {
    const result = src.threadReducer.applyThreadDetailEvent(thread, ev);
    if (result.kind === "updated") thread = result.thread;
    else if (result.kind === "deleted") alive = false;
    steps.push(
      perStep
        ? { kind: result.kind, thread: plain(result.kind === "updated" ? result.thread : null) }
        : { kind: result.kind },
    );
    counts.steps += 1;
    if (!alive) break;
  }
  write("scenarios", `thread-${name}`, {
    kind: "thread",
    snapshot,
    events: events.slice(0, steps.length),
  });
  write("expected", `thread-${name}`, {
    final: alive ? plain(thread) : null,
    steps,
    perStep,
    pending: alive ? plain(src.pendingRequests.derivePendingRequests(thread.activities)) : null,
  });
  counts.thread += 1;
}

{
  const snapshot = smallThread();
  const events = syntheticThreadEvents(snapshot.thread.id);
  for (const ev of events) validate("OrchestrationEvent", ev);
  runThread("synthetic", snapshot, events, true);
  // The same stream without the terminal events, so `pending` is computed on a live thread.
  runThread(
    "synthetic-live",
    snapshot,
    events.filter((e) => !["thread.reverted", "thread.created", "thread.deleted"].includes(e.type)),
    true,
  );
}
if (!raw) {
  for (const n of [1, 2, 3, 4, 5]) {
    const detail = fixtureThreadDetail(n);
    const fromRpc = chunkValues(`rpc/orchestration.subscribeThread-replay-${n - 1}.json`)
      .filter((v) => v.kind === "event")
      .map((v) => v.event);
    const live =
      n === 1
        ? chunkValues("rpc/orchestration.subscribeThread-events-1.json")
            .filter((v) => v.kind === "event")
            .map((v) => v.event)
        : [];
    runThread(`fixture-${n}`, detail, [...fromRpc, ...live], false);
  }
} else {
  const files = readdirSync(join(rawDir, "threads")).filter((f) => f.endsWith(".json"));
  for (const f of files) {
    const detail = readJson(rawDir, `threads/${f}`);
    const id = f.replace(/\.json$/, "");
    const replay = join(rawDir, "rpc", `orchestration.subscribeThread-replayall-${id}.json`);
    const events = existsSync(replay)
      ? readJson(rawDir, `rpc/orchestration.subscribeThread-replayall-${id}.json`)
          .flatMap((m: any) => (m._tag === "Chunk" ? m.values : []))
          .filter((v: any) => v.kind === "event")
          .map((v: any) => v.event)
      : [];
    runThread(`raw-${id.replace(/[^a-zA-Z0-9-]/g, "_")}`, detail, events, false);
  }
}

// ---- derived state -----------------------------------------------------------------------------
const cases: any[] = [];
const add = (op: string, name: string, input: any, expected: any) => {
  cases.push({ op, name, input });
  expectedCases.push({ name, expected: plain(expected) });
  counts.derived += 1;
};
const expectedCases: any[] = [];
/** Large row sets are written once and referenced by name from each case. */
const shared: Record<string, any> = {};

const layoutSummary = (layout: any) => ({
  items: layout.items.map((i: any) => [
    `${i.thread.environmentId}:${i.thread.id}`,
    i.variant,
    i.snoozed,
    i.pinned,
    i.isLast,
  ]),
  hiddenSettledCount: layout.hiddenSettledCount,
  snoozedCount: layout.snoozedCount,
  snoozedShelfHeaderIndex: layout.snoozedShelfHeaderIndex,
  settledCount: layout.settledCount,
  settledShelfHeaderIndex: layout.settledShelfHeaderIndex,
  nextSnoozeWakeAt: layout.nextSnoozeWakeAt,
});

{
  const threads = raw
    ? shell.threads.map((t: any, i: number) => ({ ...t, environmentId: i % 2 ? "env-b" : "env-a" }))
    : syntheticShells();
  shared.threads = threads;
  const matchedKey = (t: any) => JSON.stringify([t.environmentId, t.id]);
  // Boundary instants (12:01 = queued grace edge, 12:30 / 14:00 = exact wake times) matter as much as the in-between ones.
  const nows = [
    "2026-10-08T11:30:00.000Z",
    "2026-10-08T12:00:00.000Z",
    "2026-10-08T12:01:00.000Z",
    "2026-10-08T12:01:00.001Z",
    "2026-10-08T12:30:00.000Z",
    "2026-10-08T12:45:00.000Z",
    "2026-10-08T14:00:00.000Z",
    "2026-10-08T15:00:00.000Z",
  ];
  const optionSets: Record<string, any> = {
    plain: {},
    envA: { environmentId: "env-a" },
    project: {
      projectRefs: [
        { environmentId: "env-a", projectId: "p1" },
        { environmentId: "env-b", projectId: "p1" },
      ],
    },
    searchTitle: { searchQuery: " FOO " },
    searchPr: { searchQuery: "o/r#42" },
    searchLegacyPr: { searchQuery: "#5" },
    searchMatched: {
      searchQuery: "zzzz",
      matchedThreadKeys: [threads[1] ? matchedKey(threads[1]) : ""],
    },
    limit2: { settledLimit: 2 },
    limit2Selected: { settledLimit: 2, selectedThreadKey: "env-a:set-tie-x" },
    collapsedSettled: { settledShelfExpanded: false, selectedThreadKey: "env-a:set-1" },
    expandedSnoozed: { snoozedShelfExpanded: true },
    collapsedSnoozedSelected: { selectedThreadKey: "env-a:snz-future" },
    queued: { queuedThreadKeys: ["env-a:set-queued", "env-a:set-1"] },
    gatedA: { settlementEnvironmentIds: ["env-a"], snoozeEnvironmentIds: ["env-a"] },
    gatedNone: { settlementEnvironmentIds: [], snoozeEnvironmentIds: [] },
  };
  for (const now of nows) {
    for (const [label, options] of Object.entries(optionSets)) {
      const input = {
        threadsRef: "threads",
        now,
        options: { searchQuery: "", ...options },
      };
      const o = input.options;
      const layout = src.threadListV2.buildThreadListV2Items({
        threads,
        environmentId: o.environmentId ?? null,
        projectRefs: o.projectRefs ?? null,
        searchQuery: o.searchQuery,
        matchedThreadKeys: o.matchedThreadKeys ? new Set(o.matchedThreadKeys) : undefined,
        settlementEnvironmentIds: o.settlementEnvironmentIds
          ? new Set(o.settlementEnvironmentIds)
          : undefined,
        snoozeEnvironmentIds: o.snoozeEnvironmentIds ? new Set(o.snoozeEnvironmentIds) : undefined,
        settledLimit: o.settledLimit,
        now,
        snoozedShelfExpanded: o.snoozedShelfExpanded,
        settledShelfExpanded: o.settledShelfExpanded,
        selectedThreadKey: o.selectedThreadKey ?? null,
        queuedThreadKeys: o.queuedThreadKeys ? new Set(o.queuedThreadKeys) : undefined,
      });
      add("list", `list/${label}/${now}`, input, layoutSummary(layout));
    }
  }
  // per-thread lifecycle predicates over the same rows
  const {
    effectiveSnoozed,
    threadWokeAt,
    canSnooze,
    hasQueuedTurnStart,
    threadRaisedHandWhileSnoozed,
  } = src.threadSettled;
  for (const now of nows) {
    const rows = threads.map((t: any) => [
      `${t.environmentId}:${t.id}`,
      effectiveSnoozed(t, { now }),
      threadWokeAt(t, { now }),
      canSnooze(t, { now }),
      hasQueuedTurnStart(t, { now }),
      threadRaisedHandWhileSnoozed(t),
    ]);
    add("lifecycle", `lifecycle/${now}`, { threadsRef: "threads", now }, rows);
  }
  // pure sorts
  const ids = (list: any[]) => list.map((t) => `${t.environmentId}:${t.id}`);
  add(
    "sorts",
    "sorts/all",
    { threadsRef: "threads" },
    {
      settled: ids(src.threadSort.sortSettledThreads(threads)),
      pinned: ids(src.threadSort.sortPinnedThreadsByOrderKey(threads)),
      active: ids(src.threadSort.sortActiveThreadsByOrderKey(threads)),
      updatedAt: ids(src.threadSort.sortThreads(threads, "updated_at")),
      createdAt: ids(src.threadSort.sortThreads(threads, "created_at")),
      settledTimestamps: threads.map((t: any) => src.threadSort.resolveSettledThreadTimestamp(t)),
    },
  );
}

{
  const projects = raw
    ? shell.projects.map((p: any, i: number) => ({
        ...p,
        environmentId: i % 3 === 0 ? "env-b" : "env-a",
      }))
    : syntheticProjects();
  const settingsSets: Record<string, any> = {
    repository: { sidebarProjectGroupingMode: "repository", sidebarProjectGroupingOverrides: {} },
    repositoryPath: {
      sidebarProjectGroupingMode: "repository_path",
      sidebarProjectGroupingOverrides: {},
    },
    separate: { sidebarProjectGroupingMode: "separate", sidebarProjectGroupingOverrides: {} },
    override: {
      sidebarProjectGroupingMode: "repository",
      sidebarProjectGroupingOverrides: {
        "env-a:/work/repo/packages/web": "separate",
        "env-b:/home/me/repo": "repository_path",
      },
    },
  };
  shared.projects = projects;
  for (const [label, settings] of Object.entries(settingsSets)) {
    for (const preferred of [null, "env-b"]) {
      const groups = src.projectGrouping.buildProjectGroups({
        projects,
        settings,
        preferredEnvironmentId: preferred,
      });
      add(
        "groups",
        `groups/${label}/${preferred}`,
        { projectsRef: "projects", settings, preferredEnvironmentId: preferred },
        groups.map((g: any) => ({
          key: g.key,
          label: g.label,
          representative: `${g.representative.environmentId}:${g.representative.id}`,
          members: g.members.map((m: any) => [
            m.physicalProjectKey,
            `${m.project.environmentId}:${m.project.id}`,
          ]),
          memberProjectRefs: g.memberProjectRefs.map(
            (r: any) => `${r.environmentId}:${r.projectId}`,
          ),
        })),
      );
    }
  }
}

{
  // approvals / user input for every thread of the synthetic stream, plus the raw activities in raw mode
  const live = (() => {
    let thread: any = smallThread().thread;
    for (const ev of syntheticThreadEvents(thread.id)) {
      const r = src.threadReducer.applyThreadDetailEvent(thread, ev);
      if (r.kind === "updated") thread = r.thread;
      if (ev.type === "thread.pull-request-unlinked") break;
    }
    return thread;
  })();
  add(
    "pending",
    "pending/synthetic",
    { activities: live.activities },
    src.pendingRequests.derivePendingRequests(live.activities),
  );
}

{
  const keys = [null, "a", "b", "n", "z", "ab", "aab", "zz", "mm", "bb"];
  const between: any[] = [];
  for (const a of keys)
    for (const b of keys) {
      let result: any;
      try {
        result = src.threadSort.pinOrderKeyBetween(a, b);
      } catch (e: any) {
        result = `throw:${String(e.message).slice(0, 20)}`;
      }
      between.push([a, b, result]);
    }
  const spread = [1, 2, 3, 5, 10, 25, 26, 27, 100, 700, 1400].map((n) => [
    n,
    src.threadSort.generateSpreadPinOrderKeys(n),
  ]);
  const mapOf = (entries: [string, string | null][]) => new Map(entries);
  const plans: any[] = [];
  const planCases: {
    name: string;
    ordered: string[];
    keys: [string, string | null][];
    moved: string;
  }[] = [
    {
      name: "between-keyed",
      ordered: ["a", "x", "b"],
      keys: [
        ["a", "c"],
        ["x", null],
        ["b", "m"],
      ],
      moved: "x",
    },
    {
      name: "keyless-neighbour",
      ordered: ["a", "x", "b"],
      keys: [
        ["a", null],
        ["x", "k"],
        ["b", "m"],
      ],
      moved: "x",
    },
    {
      name: "to-top",
      ordered: ["x", "a", "b"],
      keys: [
        ["a", "c"],
        ["x", "m"],
        ["b", "q"],
      ],
      moved: "x",
    },
    {
      name: "to-bottom",
      ordered: ["a", "b", "x"],
      keys: [
        ["a", "c"],
        ["x", "a"],
        ["b", "q"],
      ],
      moved: "x",
    },
    {
      name: "hidden-reserved",
      ordered: ["a", "x"],
      keys: [
        ["a", "c"],
        ["x", "z"],
        ["h", "g"],
      ],
      moved: "x",
    },
    {
      name: "corrupt",
      ordered: ["a", "x", "b"],
      keys: [
        ["a", "q"],
        ["x", "k"],
        ["b", "c"],
      ],
      moved: "x",
    },
    {
      name: "unknown-moved",
      ordered: ["a", "b"],
      keys: [
        ["a", "c"],
        ["b", "q"],
      ],
      moved: "nope",
    },
  ];
  for (const c of planCases) {
    plans.push([
      c.name,
      src.threadSort.planPinnedReorder({
        orderedIds: c.ordered,
        keysById: mapOf(c.keys),
        movedId: c.moved,
      }),
    ]);
    for (const direction of ["up", "down"]) {
      plans.push([
        `${c.name}/move-${direction}`,
        src.threadSort.planPinnedMove({
          orderedIds: c.ordered,
          keysById: mapOf(c.keys),
          movedId: c.moved,
          direction,
        }),
      ]);
    }
  }
  add("pinKeys", "pinKeys/all", { keys, planCases }, { between, spread, plans });
}

{
  // presets and custom snooze depend on the local calendar: fix the zone on both sides
  const zones = ["UTC", "Europe/Warsaw", "America/New_York", "Pacific/Auckland"];
  const instants = [
    "2026-10-08T05:30:00.000Z",
    "2026-10-08T16:45:00.000Z",
    "2026-10-11T08:00:00.000Z",
    "2026-10-25T00:30:00.000Z",
    "2026-03-28T22:30:00.000Z",
    "2026-03-29T09:00:00.000Z",
  ];
  const result: any = { presets: [], custom: [], wake: [] };
  const input: any = { zones, instants, custom: [], wake: [] };
  const customInputs = [
    { mode: "date", date: "2026-10-09", time: "09:30" },
    { mode: "date", date: "2026-10-08", time: "00:01" },
    { mode: "date", date: "2026-02-30", time: "09:00" },
    { mode: "date", date: "2026-03-29", time: "02:30" },
    { mode: "date", date: "bad", time: "09:00" },
    { mode: "date", date: "2026-10-09", time: "9:00" },
    { mode: "duration", amount: "90", unit: "minutes" },
    { mode: "duration", amount: "2.5", unit: "hours" },
    { mode: "duration", amount: "3", unit: "days" },
    { mode: "duration", amount: "0", unit: "hours" },
    { mode: "duration", amount: "-1", unit: "hours" },
    { mode: "duration", amount: "abc", unit: "days" },
  ];
  input.custom = customInputs;
  for (const zone of zones) {
    process.env.TZ = zone;
    for (const instant of instants) {
      const now = new Date(instant);
      result.presets.push([
        zone,
        instant,
        src.threadSettled
          .resolveSnoozePresets(now)
          .map((p: any) => [p.id, p.label, p.snoozedUntil]),
      ]);
      result.custom.push([
        zone,
        instant,
        customInputs.map((c) => src.threadSettled.resolveCustomSnooze(c, now)),
      ]);
    }
  }
  const wakePairs: [string, string][] = [
    ["2026-10-08T12:00:00.000Z", "2026-10-08T12:00:30.000Z"],
    ["2026-10-08T12:30:00.000Z", "2026-10-08T12:00:00.000Z"],
    ["2026-10-08T14:00:00.000Z", "2026-10-08T12:00:00.000Z"],
    ["2026-10-09T12:00:01.000Z", "2026-10-08T12:00:00.000Z"],
    ["2026-10-20T12:00:00.000Z", "2026-10-08T12:00:00.000Z"],
    ["bad", "2026-10-08T12:00:00.000Z"],
  ];
  input.wake = wakePairs;
  for (const [until, now] of wakePairs)
    result.wake.push(src.threadSettled.snoozeWakeLabel(until, { now }));
  process.env.TZ = "UTC";
  add("snooze", "snooze/all", input, result);
}

{
  // Command builders: the canonical wire JSON Effect's codec produces for each command the client dispatches.
  const at = "2026-10-08T12:00:00.000Z";
  const meta = { commandId: "cmd-1", createdAt: at };
  const model = { instanceId: "codex", model: "gpt-5", options: [{ id: "effort", value: "high" }] };
  const T = "thread-1";
  const specs: { name: string; args: any; command: any }[] = [
    {
      name: "create",
      args: {
        threadId: T,
        projectId: "proj-1",
        title: "New",
        model,
        runtimeMode: "full-access",
        interactionMode: "plan",
        branch: "main",
        worktreePath: "/tmp/wt",
      },
      command: {
        type: "thread.create",
        commandId: meta.commandId,
        threadId: T,
        projectId: "proj-1",
        title: "New",
        modelSelection: model,
        runtimeMode: "full-access",
        interactionMode: "plan",
        branch: "main",
        worktreePath: "/tmp/wt",
        createdAt: at,
      },
    },
    {
      name: "create-minimal",
      args: {
        threadId: T,
        projectId: "proj-1",
        title: "New",
        model,
        runtimeMode: "approval-required",
      },
      command: {
        type: "thread.create",
        commandId: meta.commandId,
        threadId: T,
        projectId: "proj-1",
        title: "New",
        modelSelection: model,
        runtimeMode: "approval-required",
        interactionMode: "default",
        branch: null,
        worktreePath: null,
        createdAt: at,
      },
    },
    {
      name: "delete",
      args: { threadId: T },
      command: { type: "thread.delete", commandId: meta.commandId, threadId: T },
    },
    {
      name: "archive",
      args: { threadId: T },
      command: { type: "thread.archive", commandId: meta.commandId, threadId: T },
    },
    {
      name: "unarchive",
      args: { threadId: T },
      command: { type: "thread.unarchive", commandId: meta.commandId, threadId: T },
    },
    {
      name: "settle",
      args: { threadId: T },
      command: { type: "thread.settle", commandId: meta.commandId, threadId: T },
    },
    {
      name: "unsettle",
      args: { threadId: T },
      command: { type: "thread.unsettle", commandId: meta.commandId, threadId: T, reason: "user" },
    },
    {
      name: "snooze",
      args: { threadId: T, until: "2026-10-09T09:00:00.000Z" },
      command: {
        type: "thread.snooze",
        commandId: meta.commandId,
        threadId: T,
        snoozedUntil: "2026-10-09T09:00:00.000Z",
      },
    },
    {
      name: "unsnooze",
      args: { threadId: T },
      command: { type: "thread.unsnooze", commandId: meta.commandId, threadId: T, reason: "user" },
    },
    {
      name: "pin",
      args: { threadId: T },
      command: { type: "thread.pin", commandId: meta.commandId, threadId: T },
    },
    {
      name: "pin-key",
      args: { threadId: T, orderKey: "mm" },
      command: { type: "thread.pin", commandId: meta.commandId, threadId: T, orderKey: "mm" },
    },
    {
      name: "unpin",
      args: { threadId: T },
      command: { type: "thread.unpin", commandId: meta.commandId, threadId: T },
    },
    {
      name: "reorderPinned",
      args: { threadId: T, orderKey: "n" },
      command: {
        type: "thread.pin.reorder",
        commandId: meta.commandId,
        threadId: T,
        orderKey: "n",
      },
    },
    {
      name: "reorderActive",
      args: { threadId: T, orderKey: "q" },
      command: {
        type: "thread.active.reorder",
        commandId: meta.commandId,
        threadId: T,
        orderKey: "q",
      },
    },
    {
      name: "autoSettleOn",
      args: { threadId: T, enabled: true },
      command: {
        type: "thread.auto-settle.set",
        commandId: meta.commandId,
        threadId: T,
        enabled: true,
      },
    },
    {
      name: "autoSettleOff",
      args: { threadId: T, enabled: false },
      command: {
        type: "thread.auto-settle.set",
        commandId: meta.commandId,
        threadId: T,
        enabled: false,
      },
    },
    {
      name: "rename",
      args: { threadId: T, title: "Renamed" },
      command: {
        type: "thread.meta.update",
        commandId: meta.commandId,
        threadId: T,
        title: "Renamed",
      },
    },
    {
      name: "regenerateTitle",
      args: { threadId: T, regenerateTitle: true },
      command: {
        type: "thread.meta.update",
        commandId: meta.commandId,
        threadId: T,
        regenerateTitle: true,
      },
    },
    {
      name: "runtimeMode",
      args: { threadId: T, mode: "auto-accept-edits" },
      command: {
        type: "thread.runtime-mode.set",
        commandId: meta.commandId,
        threadId: T,
        runtimeMode: "auto-accept-edits",
        createdAt: at,
      },
    },
    {
      name: "interactionMode",
      args: { threadId: T, mode: "plan" },
      command: {
        type: "thread.interaction-mode.set",
        commandId: meta.commandId,
        threadId: T,
        interactionMode: "plan",
        createdAt: at,
      },
    },
    {
      name: "startTurn",
      args: {
        threadId: T,
        messageId: "msg-1",
        text: "Hello",
        runtimeMode: "full-access",
        interactionMode: "default",
      },
      command: {
        type: "thread.turn.start",
        commandId: meta.commandId,
        threadId: T,
        message: { messageId: "msg-1", role: "user", text: "Hello", attachments: [] },
        runtimeMode: "full-access",
        interactionMode: "default",
        createdAt: at,
      },
    },
    {
      name: "startTurnAttachments",
      args: {
        threadId: T,
        messageId: "msg-2",
        text: "See",
        runtimeMode: "full-access",
        interactionMode: "plan",
        model,
        titleSeed: "See",
        attachments: [
          { kind: "image", id: "att-1", name: "a.png", mimeType: "image/png", sizeBytes: 3 },
          { kind: "file", id: "att-2", name: "b.txt", mimeType: "text/plain", sizeBytes: 5 },
        ],
      },
      command: {
        type: "thread.turn.start",
        commandId: meta.commandId,
        threadId: T,
        message: {
          messageId: "msg-2",
          role: "user",
          text: "See",
          attachments: [
            { type: "image", id: "att-1", name: "a.png", mimeType: "image/png", sizeBytes: 3 },
            { type: "file", id: "att-2", name: "b.txt", mimeType: "text/plain", sizeBytes: 5 },
          ],
        },
        modelSelection: model,
        titleSeed: "See",
        runtimeMode: "full-access",
        interactionMode: "plan",
        createdAt: at,
      },
    },
    {
      name: "interrupt",
      args: { threadId: T },
      command: {
        type: "thread.turn.interrupt",
        commandId: meta.commandId,
        threadId: T,
        createdAt: at,
      },
    },
    {
      name: "interruptTurn",
      args: { threadId: T, turnId: "turn-1" },
      command: {
        type: "thread.turn.interrupt",
        commandId: meta.commandId,
        threadId: T,
        turnId: "turn-1",
        createdAt: at,
      },
    },
    {
      name: "approval",
      args: { threadId: T, requestId: "req-1", decision: "acceptForSession" },
      command: {
        type: "thread.approval.respond",
        commandId: meta.commandId,
        threadId: T,
        requestId: "req-1",
        decision: "acceptForSession",
        createdAt: at,
      },
    },
    {
      name: "userInput",
      args: {
        threadId: T,
        requestId: "req-2",
        answers: { q1: "A", q2: ["B", "C"], q3: { custom: true }, q4: 3 },
      },
      command: {
        type: "thread.user-input.respond",
        commandId: meta.commandId,
        threadId: T,
        requestId: "req-2",
        answers: { q1: "A", q2: ["B", "C"], q3: { custom: true }, q4: 3 },
        createdAt: at,
      },
    },
    {
      name: "dismissUserInput",
      args: { threadId: T, requestId: "req-2" },
      command: {
        type: "thread.user-input.dismiss",
        commandId: meta.commandId,
        threadId: T,
        requestId: "req-2",
        createdAt: at,
      },
    },
    {
      name: "revertFiles",
      args: { threadId: T, turnCount: 2, restoreFiles: true },
      command: {
        type: "thread.checkpoint.revert",
        commandId: meta.commandId,
        threadId: T,
        turnCount: 2,
        createdAt: at,
      },
    },
    {
      name: "revertConversation",
      args: { threadId: T, turnCount: 2, restoreFiles: false },
      command: {
        type: "thread.conversation.revert",
        commandId: meta.commandId,
        threadId: T,
        turnCount: 2,
        createdAt: at,
      },
    },
    {
      name: "stopSession",
      args: { threadId: T },
      command: {
        type: "thread.session.stop",
        commandId: meta.commandId,
        threadId: T,
        createdAt: at,
      },
    },
  ];
  const codec = contracts.ClientOrchestrationCommand;
  add(
    "commands",
    "commands/all",
    { meta, specs: specs.map(({ name, args }) => ({ name, args })) },
    specs.map(({ name, command }) => [
      name,
      plain(S.encodeSync(codec)(S.decodeUnknownSync(codec)(command))),
    ]),
  );
}

write("scenarios", "derived", { kind: "derived", shared, cases });
write("expected", "derived", { cases: expectedCases });
console.log(
  `${outDir}\n  shell scenarios: ${counts.shell}, thread scenarios: ${counts.thread}, derived cases: ${counts.derived}, reducer steps: ${counts.steps}`,
);
