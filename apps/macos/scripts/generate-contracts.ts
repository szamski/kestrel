// Generates Swift Codable types and RpcSpec/HttpSpec constants from
// packages/contracts. `--check` fails (exit 1) when checked-in output is stale.
//
//   node apps/macos/scripts/generate-contracts.ts [--check]
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, join } from "node:path";
import { macosRoot } from "./lib/load.ts";
import { buildBoth } from "./lib/split.ts";
import { pascal } from "./lib/names.ts";
import { emitHttp, emitRpc, emitType, HEADER, HEADER_V1 } from "./lib/swift.ts";

const outDir = join(macosRoot, "T3Kit", "Sources", "T3Contracts", "Generated");
const outDirV1 = join(macosRoot, "T3Kit", "Sources", "T3Contracts", "GeneratedV1");
const check = process.argv.includes("--check");

const { current, frozen, reach, v1Reach, v1Own } = await buildBoth();
const { builder, rpcs, https } = current;
const v1Builder = frozen.builder;

const byFile = new Map<string, string[]>();
const counts: Record<string, number> = {};
const fileOf = (module: string) =>
  module === "rpc" ? "RpcTypes" : module ? pascal(module) : "Shared";
for (const name of [...reach].sort()) {
  const def = builder.types.get(name)!;
  const file = fileOf(def.module);
  if (!byFile.has(file)) byFile.set(file, []);
  byFile.get(file)!.push(emitType(def));
  counts[def.kind] = (counts[def.kind] ?? 0) + 1;
}

const files = new Map<string, string>();
for (const [file, chunks] of byFile)
  files.set(`${file}.swift`, `${HEADER}\n${chunks.join("\n\n")}\n`);
const taken = new Set(builder.types.keys());
files.set("RpcSpecs.swift", emitRpc(rpcs, taken));
files.set("HttpSpecs.swift", emitHttp(https, taken));

// ---- protocol 1: the frozen orchestration surface, namespaced as `V1` ------------------
// A V1 type identical to the current one (same Swift text, and so are all its dependencies) is
// shared: V1 code refers to it by its plain name. The rest is emitted inside `extension V1`,
// where it shadows the current name (see lib/split.ts).
const wrapV1 = (body: string) => `${HEADER_V1}\nextension V1 {\n${body.trim()}\n}\n`;
const v1ByFile = new Map<string, string[]>();
for (const name of [...v1Own].sort()) {
  const def = v1Builder.types.get(name)!;
  const file = fileOf(def.module);
  if (!v1ByFile.has(file)) v1ByFile.set(file, []);
  v1ByFile.get(file)!.push(emitType(def));
}
const filesV1 = new Map<string, string>();
filesV1.set(
  "V1.swift",
  `${HEADER_V1}\n/// Orchestration protocol 1 (servers without protocol negotiation, e.g. T3 Code 0.0.45).\n/// Types here shadow the current ones of the same name; everything not redeclared is shared.\npublic enum V1 {}\n`,
);
for (const [file, chunks] of v1ByFile) filesV1.set(`V1${file}.swift`, wrapV1(chunks.join("\n\n")));
const takenV1 = new Set([...taken, ...v1Builder.types.keys()]);
filesV1.set("V1RpcSpecs.swift", wrapV1(emitRpc(frozen.rpcs, takenV1).replace(HEADER, "")));
filesV1.set("V1HttpSpecs.swift", wrapV1(emitHttp(frozen.https, takenV1).replace(HEADER, "")));

const stale: string[] = [];
const sync = (dir: string, wanted: Map<string, string>) => {
  const existing = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith(".swift")) : [];
  for (const [f, content] of wanted)
    if (!existsSync(join(dir, f)) || readFileSync(join(dir, f), "utf8") !== content)
      stale.push(`${basename(dir)}/${f}`);
  for (const f of existing)
    if (!wanted.has(f)) stale.push(`${basename(dir)}/${f} (no longer generated)`);
  if (!check) {
    mkdirSync(dir, { recursive: true });
    for (const [f, content] of wanted) writeFileSync(join(dir, f), content);
    for (const f of existing) if (!wanted.has(f)) unlinkSync(join(dir, f));
  }
};
sync(outDir, files);
sync(outDirV1, filesV1);

const summary = `${reach.size} types ${JSON.stringify(counts)}, ${rpcs.length} RPCs, ${https.length} HTTP endpoints, ${files.size} files; V1: ${v1Own.size}/${v1Reach.size} own types (${v1Reach.size - v1Own.size} shared), ${frozen.rpcs.length} RPCs, ${frozen.https.length} HTTP endpoints, ${filesV1.size} files`;
if (check) {
  if (stale.length > 0) {
    console.error(
      `Generated Swift is stale:\n  ${stale.join("\n  ")}\nRun: node apps/macos/scripts/generate-contracts.ts`,
    );
    process.exit(1);
  }
  console.log(`Generated Swift is up to date (${summary})`);
} else {
  console.log(`Wrote ${summary}`);
  console.log(`untagged unions (${builder.untagged.length}): ${builder.untagged.join(", ")}`);
  console.log(`Unknown/Any schemas emitted as JSONValue: ${builder.jsonFallbacks.length}`);
}
