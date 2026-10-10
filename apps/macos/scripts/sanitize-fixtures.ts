// Turns a raw recording (see record-fixtures.ts) into committed, redacted
// fixtures under apps/macos/T3Kit/Tests/T3ContractsTests/Fixtures.
//
//   node apps/macos/scripts/sanitize-fixtures.ts [--raw DIR]
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";
import { macosRoot } from "./lib/load.ts";
import { buildBoth } from "./lib/split.ts";
import { makeScrubber } from "./lib/scrub.ts";

const raw = (() => {
  const i = process.argv.indexOf("--raw");
  return i >= 0
    ? process.argv[i + 1]!
    : "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78/stageA-contracts/tmp/raw";
})();
const outDir = join(macosRoot, "T3Kit", "Tests", "T3ContractsTests", "Fixtures");
const read = (p: string) => JSON.parse(readFileSync(join(raw, p), "utf8"));

// Recordings come from a protocol-1 server: its own types (V1) win over same-named current ones.
const { current, frozen } = await buildBoth();
const allTypes = new Map([...current.builder.types, ...frozen.builder.types]);
const scrub = makeScrubber(allTypes);
const rootOf = (name: string) => ({ ir: { k: "ref", name } as const, nullable: false });
const types = {
  descriptor: rootOf("ExecutionEnvironmentDescriptor"),
  session: rootOf("AuthSessionState"),
  shell: rootOf("OrchestrationShellSnapshot"),
  thread: rootOf("OrchestrationThreadDetailSnapshot"),
  config: rootOf("ServerConfig"),
  settings: rootOf("ServerSettings"),
  configStream: rootOf("ServerConfigStreamEvent"),
  shellStream: rootOf("OrchestrationShellStreamItem"),
  threadStream: rootOf("OrchestrationThreadStreamItem"),
};
for (const [k, w] of Object.entries(types))
  if (!allTypes.has((w.ir as any).name)) throw new Error(`missing type for ${k}`);

// Start clean so removed recordings do not linger (reference/ belongs to encode-reference.ts).
for (const p of ["threads", "rpc", "descriptor.json", "session.json", "shell.json"])
  rmSync(join(outDir, p), { recursive: true, force: true });
mkdirSync(join(outDir, "threads"), { recursive: true });
mkdirSync(join(outDir, "rpc"), { recursive: true });
const write = (p: string, v: unknown) =>
  writeFileSync(join(outDir, p), JSON.stringify(v, null, 1) + "\n");

write("descriptor.json", scrub.wire(types.descriptor, read("descriptor.json")));
write("session.json", scrub.wire(types.session, read("session.json")));
write("shell.json", scrub.wire(types.shell, read("shell.json")));

// ---- diverse threads: greedy cover of the features a reader would care about ----------------------
interface Pick {
  id: string;
  features: Set<string>;
  size: number;
}
const threadIds = readdirSync(join(raw, "threads"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.replace(/\.json$/, ""));
const candidates: Pick[] = threadIds.map((id) => {
  const t = read(`threads/${id}.json`).thread ?? {};
  const f = new Set<string>();
  for (const a of t.activities ?? []) f.add(`activity:${a.kind}`);
  for (const m of t.messages ?? [])
    f.add(`message:${m.role}${(m.attachments ?? []).length ? "+attachments" : ""}`);
  if ((t.proposedPlans ?? []).length) f.add("plans");
  if ((t.checkpoints ?? []).length) f.add("checkpoints");
  if (t.session) f.add(`session:${t.session.status}`);
  if ((t.pullRequests ?? []).length) f.add("pullRequests");
  if (t.latestTurn) f.add(`turn:${t.latestTurn.state}`);
  if (t.archivedAt) f.add("archived");
  if (t.pinnedAt) f.add("pinned");
  return { id, features: f, size: JSON.stringify(t).length };
});
const covered = new Set<string>();
const picked: Pick[] = [];
while (picked.length < 8) {
  const best = candidates
    .filter((c) => !picked.includes(c))
    .map((c) => ({ c, gain: [...c.features].filter((x) => !covered.has(x)).length }))
    .sort((a, b) => b.gain - a.gain || a.c.size - b.c.size)[0];
  if (!best || (best.gain === 0 && picked.length >= 5)) break;
  picked.push(best.c);
  best.c.features.forEach((x) => covered.add(x));
}
const pickedIds = picked.map((p) => p.id);
pickedIds.forEach((id, i) =>
  write(`threads/thread-${i + 1}.json`, scrub.wire(types.thread, read(`threads/${id}.json`))),
);

// ---- rpc recordings -------------------------------------------------------------------------------------
const rpcFiles = readdirSync(join(raw, "rpc")).filter((f) => f.endsWith(".json"));
/** At most three frames per event type keeps replay samples small but varied. */
const sample = (values: any[]) => {
  const perType = new Map<string, number>();
  return values.filter((v) => {
    const key = v?.kind === "event" ? v.event.type : (v?.kind ?? "");
    const n = perType.get(key) ?? 0;
    perType.set(key, n + 1);
    return n < 3;
  });
};
const scrubMessages = (file: string, w: typeof types.config) => {
  const msgs = read(`rpc/${file}`) as any[];
  return msgs.map((m) => {
    if (m._tag === "Chunk")
      return { ...m, values: sample(m.values).map((v: unknown) => scrub.wire(w, v)) };
    if (m._tag === "Exit" && m.exit?._tag === "Success")
      return { ...m, exit: { ...m.exit, value: scrub.wire(w, m.exit.value) } };
    return m;
  });
};
const keep = (name: string, w: typeof types.config, as = name) => {
  if (existsSync(join(raw, "rpc", `${name}.json`)))
    write(`rpc/${as}.json`, scrubMessages(`${name}.json`, w));
};
keep("server.getConfig", types.config);
keep("server.getSettings", types.settings);
keep("subscribeServerConfig", types.configStream);
keep("orchestration.getArchivedShellSnapshot", types.shell);
keep("orchestration.subscribeShell", types.shellStream);
keep("orchestration.subscribeShell-replay", types.shellStream);
for (let i = 0; i < 5; i++) {
  keep(`orchestration.subscribeThread-${i}`, types.threadStream);
  keep(`orchestration.subscribeThread-replay-${i}`, types.threadStream);
}
// Event variety: add the wide replays that contribute the most unseen event types.
const eventTypes = (file: string) => {
  const s = new Set<string>();
  for (const m of read(`rpc/${file}`) as any[])
    for (const v of m.values ?? []) if (v.kind === "event") s.add(v.event.type);
  return s;
};
const seenEvents = new Set<string>();
const wide = rpcFiles.filter((f) => f.startsWith("orchestration.subscribeThread-replayall-"));
for (let n = 0; n < 4; n++) {
  const best = wide
    .map((f) => ({ f, gain: [...eventTypes(f)].filter((x) => !seenEvents.has(x)).length }))
    .sort((a, b) => b.gain - a.gain || (a.f < b.f ? -1 : 1))[0];
  if (!best || best.gain === 0) break;
  eventTypes(best.f).forEach((x) => seenEvents.add(x));
  write(
    `rpc/orchestration.subscribeThread-events-${n + 1}.json`,
    scrubMessages(best.f, types.threadStream),
  );
  wide.splice(wide.indexOf(best.f), 1);
}

// ---- safety net: nothing that looks private may survive -----------------------------------------------------
const leaks: string[] = [];
const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const bad = [
  /\/Users\//,
  /\/home\//,
  new RegExp(escapeRegExp(userInfo().username), "i"),
  /@[A-Za-z0-9-]+\.[a-z]{2,}/,
  /https?:\/\/(?!example\.)/,
  /Bearer /,
  /sk-[A-Za-z0-9]{10}/,
];
const walk = (dir: string) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith(".json")) {
      const text = readFileSync(p, "utf8");
      for (const re of bad) if (re.test(text)) leaks.push(`${p.replace(outDir, "")}: ${re}`);
    }
  }
};
walk(outDir);
if (leaks.length) {
  console.error(`Possible private data in fixtures:\n  ${leaks.join("\n  ")}`);
  process.exit(1);
}
console.log(`threads: ${pickedIds.length} (features covered: ${[...covered].sort().join(", ")})`);
console.log(`thread event types in samples: ${[...seenEvents].sort().join(", ")}`);
