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
import { join } from "node:path";
import { macosRoot } from "./lib/load.ts";
import { buildModel } from "./lib/model.ts";
import { pascal } from "./lib/names.ts";
import { emitHttp, emitRpc, emitType, HEADER } from "./lib/swift.ts";

const outDir = join(macosRoot, "T3Kit", "Sources", "T3Contracts", "Generated");
const check = process.argv.includes("--check");

const { builder, rpcs, https, roots } = await buildModel();
const reach = builder.reachable(roots);

const byFile = new Map<string, string[]>();
const counts: Record<string, number> = {};
for (const name of [...reach].sort()) {
  const def = builder.types.get(name)!;
  const file = def.module === "rpc" ? "RpcTypes" : def.module ? pascal(def.module) : "Shared";
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

const existing = existsSync(outDir) ? readdirSync(outDir).filter((f) => f.endsWith(".swift")) : [];
const stale: string[] = [];
for (const [f, content] of files) {
  if (!existsSync(join(outDir, f)) || readFileSync(join(outDir, f), "utf8") !== content)
    stale.push(f);
}
for (const f of existing) if (!files.has(f)) stale.push(`${f} (no longer generated)`);

const summary = `${reach.size} types ${JSON.stringify(counts)}, ${rpcs.length} RPCs, ${https.length} HTTP endpoints, ${files.size} files`;
if (check) {
  if (stale.length > 0) {
    console.error(
      `Generated Swift is stale:\n  ${stale.join("\n  ")}\nRun: node apps/macos/scripts/generate-contracts.ts`,
    );
    process.exit(1);
  }
  console.log(`Generated Swift is up to date (${summary})`);
} else {
  mkdirSync(outDir, { recursive: true });
  for (const [f, content] of files) writeFileSync(join(outDir, f), content);
  for (const f of existing) if (!files.has(f)) unlinkSync(join(outDir, f));
  console.log(`Wrote ${summary}`);
  console.log(`untagged unions (${builder.untagged.length}): ${builder.untagged.join(", ")}`);
  console.log(`Unknown/Any schemas emitted as JSONValue: ${builder.jsonFallbacks.length}`);
}
