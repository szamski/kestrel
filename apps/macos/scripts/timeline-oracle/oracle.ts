// Differential oracle for the Swift timeline derivation.
//
// FROZEN: checks the Swift timeline derivation against orchestration protocol 1
// (V1 servers). Upstream deleted the V1 sources this reads when it moved to V2, so
// `../lib/frozen.ts` re-runs this script with its sources taken from a worktree of the pre-merge
// Kestrel tip (da938cb76; not the upstream merge base de251fc29, which predates apps/macos).
// If that worktree cannot be prepared it prints how to regenerate and exits 2.
// Check: run it, then `git diff --exit-code` on the fixtures directory.
//
//   node apps/macos/scripts/timeline-oracle/oracle.ts                       # sanitized fixtures + synthetic threads
//   node apps/macos/scripts/timeline-oracle/oracle.ts --raw [--raw-dir DIR] # private recordings, output stays in /private/tmp
//
// For every scenario this writes the input (`scenarios/<name>.json`: a wire thread plus the
// client-side context) and the projection the real TypeScript derivations produce
// (`expected/<name>.json`). The Swift tests decode the same thread with the generated types, run
// T3Timeline and compare the encoded projection.
import "../lib/frozen.ts";
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  contractsFixtures,
  defaultContext,
  deriveThreadProjection,
  loadSources,
  oracleRoot,
  type ScenarioContext,
} from "./lib.ts";
import { loadContracts, loadRuntime } from "../lib/load.ts";
import { syntheticScenarios, type Scenario } from "./synthetic.ts";
import { derivedAuxiliary, fixedCommandCases } from "./auxiliary.ts";
import { commandLabelTestCases } from "./commandLabelTests.ts";

const raw = process.argv.includes("--raw");
const argv = (name: string, fallback: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1]! : fallback;
};
const ARTIFACT = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78";
const rawDir = argv("raw-dir", `${ARTIFACT}/stageA-contracts/tmp/raw`);
const outDir = raw ? argv("out", `${ARTIFACT}/stageB-timeline/tmp/oracle-raw`) : oracleRoot;
if (raw && !outDir.startsWith("/private/tmp/"))
  throw new Error("Refusing to write private recordings outside /private/tmp");

const src = await loadSources();
const contracts = await loadContracts();
const { S } = await loadRuntime();
const validateThread = (thread: unknown) =>
  S.decodeUnknownSync(contracts.OrchestrationThread)(thread);

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, "scenarios"), { recursive: true });
mkdirSync(join(outDir, "expected"), { recursive: true });
const write = (kind: "scenarios" | "expected", name: string, value: unknown) =>
  writeFileSync(join(outDir, kind, `${name}.json`), JSON.stringify(value) + "\n");

const commands = new Set<string>(fixedCommandCases());
const counts = {
  scenarios: 0,
  rows: 0,
  workEntries: 0,
  kinds: new Map<string, number>(),
  itemTypes: new Map<string, number>(),
  entryKinds: new Map<string, number>(),
};
const bump = (map: Map<string, number>, key: string) => map.set(key, (map.get(key) ?? 0) + 1);

function allTurnIds(thread: any): string[] {
  const ids = new Set<string>();
  for (const m of thread.messages) if (m.turnId) ids.add(m.turnId);
  for (const a of thread.activities) if (a.turnId) ids.add(a.turnId);
  for (const c of thread.checkpoints) ids.add(c.turnId);
  return [...ids];
}

function allTaskIds(thread: any): string[] {
  const ids = new Set<string>();
  for (const a of thread.activities) {
    const taskId = a.payload && typeof a.payload === "object" ? a.payload.taskId : undefined;
    if (typeof taskId === "string") ids.add(taskId);
  }
  return [...ids];
}

type Variant = {
  name: string;
  context: ScenarioContext;
  projection: ReturnType<typeof deriveThreadProjection>;
};

function derive(thread: any, context: ScenarioContext, variant: string): Variant {
  const projection = deriveThreadProjection(src, thread, context);
  counts.scenarios += 1;
  counts.rows += projection.rows.length;
  counts.workEntries += projection.workEntries.length;
  for (const row of projection.rows) bump(counts.kinds, row.kind);
  for (const entry of projection.workEntries) {
    for (const command of [entry.command, entry.rawCommand])
      if (typeof command === "string" && command.length < 400) commands.add(command);
    bump(counts.entryKinds, entry.sourceActivityKind ?? "?");
    if (entry.itemType) bump(counts.itemTypes, entry.itemType);
  }
  return { name: variant, context, projection };
}

/**
 * One scenario file per thread: the wire thread plus its context variants (the author's, then
 * automatic default / expanded / working / idle ones), and one expected file with a projection
 * per variant.
 */
function runScenario(
  name: string,
  thread: any,
  contexts: Scenario["contexts"],
  validate = true,
  full = true,
) {
  if (validate) {
    try {
      validateThread(thread);
    } catch (error) {
      throw new Error(
        `scenario ${name} is not a valid OrchestrationThread: ${String(error).slice(0, 600)}`,
      );
    }
  }
  const variants: Variant[] = contexts.map(({ variant, context }) =>
    derive(thread, context, variant),
  );
  const base = defaultContext();
  const plain = derive(thread, base, "auto-default");
  const groupIds = (v: Variant) =>
    v.projection.rows.flatMap((r: any) => (typeof r.groupId === "string" ? [r.groupId] : []));
  variants.push(plain);
  variants.push(
    derive(
      thread,
      {
        ...base,
        expandedTurnIds: allTurnIds(thread),
        expandedWorkGroupIds: groupIds(plain),
        supportsConversationRollback: true,
      },
      "auto-expanded",
    ),
  );
  if (full) {
    const working = derive(
      thread,
      { ...base, isWorking: true, liveAgentTaskIds: allTaskIds(thread).slice(0, 2) },
      "auto-working",
    );
    variants.push(working);
    variants.push(
      derive(
        thread,
        {
          ...base,
          isWorking: true,
          expandedWorkGroupIds: groupIds(working),
          liveAgentTaskIds: allTaskIds(thread),
        },
        "auto-working-expanded",
      ),
    );
    variants.push(
      derive(
        thread,
        { ...base, isWorking: false, sendStartedAt: "2026-10-01T11:59:00.000Z" },
        "auto-idle",
      ),
    );
  }
  write("scenarios", name, {
    thread,
    variants: variants.map(({ name, context }) => ({ name, context })),
  });
  write("expected", name, {
    variants: Object.fromEntries(variants.map((v) => [v.name, v.projection])),
    ...derivedAuxiliary(src, thread),
  });
}

if (!raw) {
  for (const scenario of syntheticScenarios())
    runScenario(`syn-${scenario.name}`, scenario.thread, scenario.contexts);
  for (const n of [1, 2, 3, 4, 5]) {
    const thread = JSON.parse(
      readFileSync(join(contractsFixtures, `threads/thread-${n}.json`), "utf8"),
    ).thread;
    // Sanitized fixtures carry redacted attachment types that the schema rejects; they stay wire-shaped.
    runScenario(
      `fixture-${n}`,
      thread,
      [{ variant: "default", context: defaultContext() }],
      false,
      false,
    );
  }
} else {
  const files = readdirSync(join(rawDir, "threads")).filter((f) => f.endsWith(".json"));
  for (const f of files) {
    const thread = JSON.parse(readFileSync(join(rawDir, "threads", f), "utf8")).thread;
    const id = f.replace(/\.json$/, "").replace(/[^a-zA-Z0-9-]/g, "_");
    runScenario(`raw-${id}`, thread, [], false);
  }
}

if (!raw) write("expected", "_commandLabelTests", { cases: await commandLabelTestCases() });
const labels = [...commands];
write("scenarios", "_commandLabels", { cases: labels });
write("expected", "_commandLabels", {
  cases: labels.map((c) => ({
    command: c,
    program: src.commandLabel.commandProgramName(c) ?? null,
  })),
});

const table = (map: Map<string, number>) =>
  [...map]
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => `${k}=${v}`)
    .join(" ");
console.log(`${raw ? "raw" : "sanitized+synthetic"}: ${counts.scenarios} scenarios -> ${outDir}`);
console.log(`rows ${counts.rows}: ${table(counts.kinds)}`);
console.log(`work entries ${counts.workEntries}; item types: ${table(counts.itemTypes)}`);
console.log(`source activity kinds: ${table(counts.entryKinds)}`);
console.log(`command label cases: ${labels.length}`);
