// Queue, stash and dispatch-acknowledgement state machines driven through the real stores.
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";
import type { Sources } from "./lib.ts";

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

const sendSettings = (n: number) => ({
  modelSelection: { instanceId: "codex", model: `m${n}` },
  runtimeMode: "full-access",
  interactionMode: "default",
  promptEffort: n % 2 === 0 ? null : "high",
});

const snapshot = (n: number) => ({
  startedAt: `2026-01-01T00:00:0${n % 10}.000Z`,
  preparingWorktree: false,
  submissionIntent: "foreground",
  latestUserMessageId: n % 3 === 0 ? null : `user-${n}`,
  latestTurnTurnId: `turn-${n}`,
  latestTurnRequestedAt: null,
  latestTurnStartedAt: null,
  latestTurnCompletedAt: null,
  sessionStatus: "ready",
  sessionUpdatedAt: null,
  latestTurnStartFailureId: null,
});

export async function stateMachineCases(s: Sources): Promise<Case[]> {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  // The client queue is gone upstream (V2 queues on the server); these groups run against the
  // frozen V1 copy and only guard the Swift store used with V1 servers.
  const queueModule = await imp("apps/macos/scripts/frozen-v1/queuedMessageStore.ts");
  const store = queueModule.useQueuedMessageStore;

  // --- queue sequences ----------------------------------------------------------------------
  type Op =
    | { op: "enqueue"; key: string; alias: string; prompt: string; tool: string | null; n: number }
    | {
        op: "beginSend" | "finishSend" | "failSend" | "remove";
        key: string;
        alias: string;
        tool?: string | null;
      }
    | { op: "markDispatching"; key: string; alias: string; n: number }
    | { op: "drain"; key: string };

  const keys = ["env:t1", "env:t2"];
  const run = (ops: Op[]) => {
    store.setState({ queuesByThreadKey: {}, lastDispatchByThreadKey: {} });
    const aliasByRealId = new Map<string, string>();
    const realByAlias = new Map<string, string>();
    const norm = (value: any): any => {
      if (Array.isArray(value)) return value.map(norm);
      if (value && typeof value === "object")
        return Object.fromEntries(
          Object.entries(value).map(([k, v]) => [
            k,
            k === "id" || k === "messageId" ? (aliasByRealId.get(v as string) ?? v) : norm(v),
          ]),
        );
      return value;
    };
    const message = (m: any) =>
      m && {
        id: aliasByRealId.get(m.id) ?? m.id,
        prompt: m.prompt,
        queuedAfterToolActivityId: m.queuedAfterToolActivityId,
        createdAt: m.createdAt,
        holdUntilUserAction: m.holdUntilUserAction ?? false,
        sending: m.sending ?? null,
        sendSettings: m.sendSettings,
      };
    const state = () => {
      const { queuesByThreadKey, lastDispatchByThreadKey } = store.getState();
      return {
        queues: Object.fromEntries(
          Object.entries(queuesByThreadKey).map(([k, q]: any) => [k, q.map(message)]),
        ),
        lastDispatch: norm(lastDispatchByThreadKey),
      };
    };
    const trace: unknown[] = [];
    for (const op of ops) {
      const st = store.getState();
      let result: unknown = null;
      const real = (alias: string) => realByAlias.get(alias) ?? `missing-${alias}`;
      switch (op.op) {
        case "enqueue": {
          const entry = st.enqueue(op.key, {
            prompt: op.prompt,
            images: [],
            files: [],
            terminalContexts: [],
            previewAnnotations: [],
            reviewComments: [],
            sendSettings: sendSettings(op.n),
            queuedAfterToolActivityId: op.tool,
            createdAt: `2026-01-01T00:00:0${op.n % 10}.000Z`,
          });
          aliasByRealId.set(entry.id, op.alias);
          realByAlias.set(op.alias, entry.id);
          result = message(entry);
          break;
        }
        case "beginSend":
          result = message(st.beginSend(op.key, real(op.alias), op.tool ?? null));
          break;
        case "markDispatching":
          result = st.markDispatching(op.key, real(op.alias), snapshot(op.n));
          break;
        case "finishSend":
          st.finishSend(op.key, real(op.alias));
          break;
        case "failSend":
          result = st.failSend(op.key, real(op.alias));
          break;
        case "remove":
          result = message(st.remove(op.key, real(op.alias)));
          break;
        case "drain":
          result = st.drain(op.key).map(message);
          break;
      }
      trace.push({ op, result, state: state() });
    }
    return trace;
  };

  const scripted: Op[][] = [
    [
      { op: "enqueue", key: "env:t1", alias: "a", prompt: "first", tool: null, n: 1 },
      { op: "enqueue", key: "env:t1", alias: "b", prompt: "second", tool: "t-1", n: 2 },
      { op: "beginSend", key: "env:t1", alias: "a", tool: "t-2" },
      { op: "beginSend", key: "env:t1", alias: "b", tool: "t-2" },
      { op: "markDispatching", key: "env:t1", alias: "a", n: 3 },
      { op: "remove", key: "env:t1", alias: "a" },
      { op: "drain", key: "env:t1" },
      { op: "finishSend", key: "env:t1", alias: "a" },
      { op: "beginSend", key: "env:t1", alias: "b", tool: "t-3" },
      { op: "markDispatching", key: "env:t1", alias: "b", n: 4 },
      { op: "finishSend", key: "env:t1", alias: "b" },
    ],
    [
      { op: "enqueue", key: "env:t1", alias: "a", prompt: "x", tool: "t-0", n: 1 },
      { op: "enqueue", key: "env:t1", alias: "b", prompt: "y", tool: "t-0", n: 2 },
      { op: "beginSend", key: "env:t1", alias: "b", tool: "t-1" },
      { op: "markDispatching", key: "env:t1", alias: "b", n: 5 },
      { op: "failSend", key: "env:t1", alias: "b" },
      { op: "beginSend", key: "env:t1", alias: "a", tool: "t-1" },
      { op: "markDispatching", key: "env:t1", alias: "a", n: 6 },
      { op: "failSend", key: "env:t1", alias: "a" },
      { op: "failSend", key: "env:t1", alias: "gone" },
      { op: "drain", key: "env:t1" },
    ],
    [
      { op: "enqueue", key: "env:t1", alias: "a", prompt: "x", tool: null, n: 1 },
      { op: "beginSend", key: "env:t1", alias: "a", tool: null },
      { op: "drain", key: "env:t1" },
      { op: "markDispatching", key: "env:t1", alias: "a", n: 1 },
      { op: "failSend", key: "env:t1", alias: "a" },
      { op: "remove", key: "env:t1", alias: "a" },
      { op: "markDispatching", key: "env:t1", alias: "a", n: 2 },
    ],
    [
      { op: "enqueue", key: "env:t1", alias: "a", prompt: "x", tool: null, n: 1 },
      { op: "enqueue", key: "env:t2", alias: "b", prompt: "y", tool: null, n: 2 },
      { op: "beginSend", key: "env:t2", alias: "a", tool: null },
      { op: "remove", key: "env:t2", alias: "b" },
      { op: "drain", key: "env:t2" },
      { op: "drain", key: "env:t1" },
    ],
  ];
  scripted.forEach((ops, index) => add("queueScript", { ops, index }, run(ops)));

  // random sequences, replayed against both implementations
  for (let seed = 1; seed <= 60; seed += 1) {
    const next = rng(seed);
    const pick = <T>(items: T[]) => items[Math.floor(next() * items.length)]!;
    const aliases = ["a", "b", "c", "d"];
    const ops: Op[] = [];
    const used = new Set<string>();
    for (let step = 0; step < 24; step += 1) {
      const key = pick(keys);
      const alias = pick(aliases);
      const tool = pick([null, "t-1", "t-2", "t-3"]);
      const roll = next();
      if (roll < 0.28 || used.size === 0) {
        const fresh = aliases.find((candidate) => !used.has(`${key}:${candidate}`)) ?? `x${step}`;
        used.add(`${key}:${fresh}`);
        ops.push({ op: "enqueue", key, alias: fresh, prompt: `p${step}`, tool, n: step });
      } else if (roll < 0.5) ops.push({ op: "beginSend", key, alias, tool });
      else if (roll < 0.65) ops.push({ op: "markDispatching", key, alias, n: step });
      else if (roll < 0.75) ops.push({ op: "finishSend", key, alias });
      else if (roll < 0.85) ops.push({ op: "failSend", key, alias });
      else if (roll < 0.93) ops.push({ op: "remove", key, alias });
      else ops.push({ op: "drain", key });
    }
    // aliases are per (key, alias) in the oracle, but ids are global: keep aliases unique across keys
    const globallyUnique = ops.map((op: any) =>
      op.alias ? { ...op, alias: `${op.key}/${op.alias}` } : op,
    );
    add("queueScript", { ops: globallyUnique, index: 100 + seed }, run(globallyUnique as Op[]));
  }

  for (const activities of [
    [],
    [{ id: "a", kind: "tool.started", createdAt: "2026-01-01" }],
    [
      { id: "a", kind: "tool.completed", createdAt: "2026-01-01" },
      { id: "b", kind: "tool.completed", createdAt: "2026-01-02" },
    ],
    [
      { id: "a", kind: "tool.completed", sequence: 5, createdAt: "2026-01-01" },
      { id: "b", kind: "tool.completed", sequence: 2, createdAt: "2026-01-09" },
    ],
    [
      { id: "a", kind: "tool.completed", sequence: 5, createdAt: "2026-01-02" },
      { id: "b", kind: "tool.completed", sequence: 5, createdAt: "2026-01-01" },
    ],
    [
      { id: "a", kind: "tool.completed", createdAt: "2026-01-02" },
      { id: "b", kind: "tool.completed", sequence: 0, createdAt: "2026-01-01" },
    ],
  ])
    add(
      "latestToolActivity",
      { activities },
      queueModule.latestCompletedToolActivityId(activities),
    );
  for (const holdUntilUserAction of [false, true])
    for (const phase of ["connecting", "running", "ready", "disconnected"])
      for (const queuedAfter of [null, "t-1"])
        for (const latest of [null, "t-1", "t-2"]) {
          const input = {
            holdUntilUserAction,
            phase,
            queuedAfterToolActivityId: queuedAfter,
            latestToolActivityId: latest,
          };
          add(
            "queuedDue",
            input,
            queueModule.isQueuedMessageDue({
              message: { queuedAfterToolActivityId: queuedAfter, holdUntilUserAction },
              phase,
              latestToolActivityId: latest,
            }),
          );
        }

  // --- prompt stash ---------------------------------------------------------------------------
  const stashModule = await imp("apps/web/src/promptStashStore.ts");
  const stashStore = stashModule.usePromptStashStore;
  const entry = (id: string, extra: Record<string, unknown> = {}) => ({
    id,
    createdAt: `2026-01-01T00:00:00.000Z`,
    prompt: `prompt ${id}`,
    attachments: [],
    droppedImageNames: [],
    ...extra,
  });
  const image = (id: string, length: number) => ({
    id,
    name: `${id}.png`,
    mimeType: "image/png",
    sizeBytes: 10,
    dataUrl: "x".repeat(length),
  });
  const brief = (e: any) => ({
    id: e.id,
    prompt: e.prompt,
    attachments: e.attachments.map((a: any) => ({ id: a.id, length: a.dataUrl.length })),
    dropped: e.droppedImageNames,
    unreadable: e.unreadableImageNames ?? null,
    pending: e.pendingImageCount ?? null,
  });
  type StashOp =
    | { op: "stash"; entry: any }
    | { op: "take"; id: string }
    | {
        op: "finalize";
        id: string;
        images: Array<{ id: string; length: number }>;
        dropped: string[];
        unreadable: string[];
      };
  const describeEntry = (e: any) => ({
    ...e,
    attachments: e.attachments.map((a: any) => ({ id: a.id, length: a.dataUrl.length })),
  });
  const runStash = (initial: any[], ops: StashOp[]) => {
    stashModule.writePromptStashStorageForTest(
      initial.length === 0 ? "" : JSON.stringify({ version: 2, state: { entries: initial } }),
    );
    const trace: unknown[] = [{ start: stashStore.getState().entries.map(brief) }];
    for (const op of ops) {
      const st = stashStore.getState();
      let result: unknown = null;
      if (op.op === "stash") {
        const { evicted } = st.stashEntry({
          ...op.entry,
          attachments: op.entry.attachments.map((a: any) => image(a.id, a.length)),
        });
        result = evicted ? evicted.id : null;
      } else if (op.op === "take") result = st.takeEntry(op.id).entry?.id ?? null;
      else
        result = st.finalizeEntryImages(op.id, {
          attachments: op.images.map((a) => image(a.id, a.length)),
          droppedImageNames: op.dropped,
          unreadableImageNames: op.unreadable,
        }).attached;
      trace.push({ result, entries: stashStore.getState().entries.map(brief) });
    }
    return trace;
  };
  const stashed = (id: string, extra: Record<string, unknown> = {}) =>
    describeEntry(entry(id, extra));
  const orphan = [
    entry("o1", { pendingImageCount: 2 }),
    entry("o2", { pendingImageCount: 1, unreadableImageNames: ["bad.png"] }),
    entry("o3", { pendingImageCount: 0 }),
  ];
  const stashScripts: Array<{ initial: any[]; ops: StashOp[] }> = [
    {
      initial: [],
      ops: [
        { op: "stash", entry: stashed("a") },
        { op: "stash", entry: stashed("b") },
        { op: "take", id: "a" },
        { op: "take", id: "a" },
        { op: "stash", entry: stashed("c") },
      ],
    },
    {
      initial: [],
      ops: Array.from({ length: 23 }, (_, i) => ({
        op: "stash" as const,
        entry: stashed(`e${i}`),
      })),
    },
    {
      initial: orphan,
      ops: [
        { op: "take", id: "o1" },
        {
          op: "finalize",
          id: "o2",
          images: [{ id: "i1", length: 10 }],
          dropped: ["big.png"],
          unreadable: [],
        },
        { op: "finalize", id: "gone", images: [], dropped: [], unreadable: [] },
      ],
    },
    {
      initial: [],
      ops: [
        { op: "stash", entry: stashed("p", { pendingImageCount: 2 }) },
        {
          op: "finalize",
          id: "p",
          images: [
            { id: "i1", length: 5 },
            { id: "i2", length: 6 },
          ],
          dropped: [],
          unreadable: ["x.png"],
        },
        { op: "take", id: "p" },
        { op: "finalize", id: "p", images: [], dropped: [], unreadable: [] },
      ],
    },
  ];
  stashScripts.forEach(({ initial, ops }, index) =>
    add("stashScript", { initial: initial.map(describeEntry), ops, index }, runStash(initial, ops)),
  );
  for (const lengths of [
    [],
    [100],
    [1_300_000, 1_300_000],
    [1_300_000, 1_300_000, 1],
    [2_700_000],
    [2_700_001],
    [1_000_000, 2_000_000, 1_500_000, 100],
  ]) {
    const partition = stashModule.partitionStashAttachments(
      lengths.map((length, i) => image(`i${i}`, length)),
    );
    add(
      "stashPartition",
      { lengths },
      { kept: partition.kept.map((a: any) => a.id), dropped: partition.droppedNames },
    );
  }

  // --- draft store: model selection, sticky state, modes ----------------------------------------
  const draftModule = await imp("apps/web/src/composerDraftStore.ts");
  const draftStore = draftModule.useComposerDraftStore;
  const DraftId = draftModule.DraftId;
  type DraftOp =
    | { op: "setPrompt"; prompt: string }
    | { op: "setModelSelection"; selection: any; explicit: boolean; replaceOptions: boolean }
    | { op: "setSticky"; selection: any }
    | { op: "applySticky" }
    | {
        op: "setOptions";
        instanceId: string;
        model: string;
        options: any[] | null;
        persistSticky: boolean;
      }
    | { op: "setRuntimeMode"; mode: string | null }
    | { op: "setInteractionMode"; mode: string | null };
  const draftKey = "draft-oracle";
  const target = DraftId.make(draftKey);
  const resetDrafts = () =>
    draftStore.setState({
      draftsByThreadKey: {},
      stickyModelSelectionByProvider: {},
      stickyActiveProvider: null,
    });
  const draftSnapshot = () => {
    const state = draftStore.getState();
    const draft = state.draftsByThreadKey[draftKey];
    return {
      draft: draft
        ? {
            prompt: draft.prompt,
            modelSelectionByProvider: draft.modelSelectionByProvider,
            activeProvider: draft.activeProvider,
            explicit: draft.modelSelectionExplicit ?? null,
            runtimeMode: draft.runtimeMode,
            interactionMode: draft.interactionMode,
          }
        : null,
      sticky: state.stickyModelSelectionByProvider,
      stickyActive: state.stickyActiveProvider,
    };
  };
  const runDrafts = (ops: DraftOp[]) => {
    resetDrafts();
    const trace: unknown[] = [];
    for (const op of ops) {
      const st = draftStore.getState();
      switch (op.op) {
        case "setPrompt":
          st.setPrompt(target, op.prompt);
          break;
        case "setModelSelection":
          st.setModelSelection(target, op.selection, {
            explicit: op.explicit,
            replaceOptions: op.replaceOptions,
          });
          break;
        case "setSticky":
          st.setStickyModelSelection(op.selection);
          break;
        case "applySticky":
          st.applyStickyState(target);
          break;
        case "setOptions":
          st.setProviderModelOptions(target, op.instanceId, op.options ?? undefined, {
            instanceId: op.instanceId,
            model: op.model,
            persistSticky: op.persistSticky,
          });
          break;
        case "setRuntimeMode":
          st.setRuntimeMode(target, op.mode);
          break;
        case "setInteractionMode":
          st.setInteractionMode(target, op.mode);
          break;
      }
      trace.push(draftSnapshot());
    }
    return trace;
  };
  for (let seed = 1; seed <= 80; seed += 1) {
    const next = rng(seed * 31);
    const pick = <T>(items: T[]) => items[Math.floor(next() * items.length)]!;
    const instances = ["codex", "codex_personal", "claudeAgent", "opencode"];
    const optionSets: any[][] = [
      [{ id: "effort", value: "low" }],
      [
        { id: "effort", value: "high" },
        { id: "fastMode", value: true },
      ],
      [{ id: "thinking", value: false }],
    ];
    const ops: DraftOp[] = [];
    for (let step = 0; step < 14; step += 1) {
      const instanceId = pick(instances);
      const model = pick(["m1", "m2", "m3"]);
      const roll = next();
      if (roll < 0.2)
        ops.push({
          op: "setModelSelection",
          selection: { instanceId, model },
          explicit: next() < 0.5,
          replaceOptions: false,
        });
      else if (roll < 0.32)
        ops.push({
          op: "setModelSelection",
          selection: { instanceId, model, options: pick(optionSets) },
          explicit: next() < 0.5,
          replaceOptions: next() < 0.3,
        });
      else if (roll < 0.42)
        ops.push({
          op: "setModelSelection",
          selection: { instanceId, model },
          explicit: true,
          replaceOptions: true,
        });
      else if (roll < 0.52)
        ops.push({
          op: "setSticky",
          selection:
            next() < 0.5 ? { instanceId, model } : { instanceId, model, options: pick(optionSets) },
        });
      else if (roll < 0.6) ops.push({ op: "applySticky" });
      else if (roll < 0.78)
        ops.push({
          op: "setOptions",
          instanceId,
          model,
          options: next() < 0.25 ? null : pick(optionSets),
          persistSticky: next() < 0.5,
        });
      else if (roll < 0.86) ops.push({ op: "setPrompt", prompt: next() < 0.5 ? "" : `p${step}` });
      else if (roll < 0.93)
        ops.push({ op: "setRuntimeMode", mode: pick(["full-access", "auto", null]) });
      else ops.push({ op: "setInteractionMode", mode: pick(["plan", "default", null]) });
    }
    add("draftScript", { ops, seed }, runDrafts(ops));
  }
  return out;
}
