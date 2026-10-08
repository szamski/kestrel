// Loads packages/contracts and the exact `effect` copy it resolves, without
// needing node_modules next to apps/macos. Both are plain ESM imports by file
// URL, so schema objects and the Effect runtime share one module instance.
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

export const repoRoot = join(import.meta.dirname, "..", "..", "..", "..");
export const contractsSrc = join(repoRoot, "packages", "contracts", "src");
export const macosRoot = join(repoRoot, "apps", "macos");

const effectDir = dirname(
  createRequire(join(repoRoot, "packages", "contracts", "package.json")).resolve(
    "effect/package.json",
  ),
);
const fromEffect = (name: string) => import(pathToFileURL(join(effectDir, "dist", name)).href);

export async function loadRuntime() {
  const [S, E, O] = await Promise.all([
    fromEffect("Schema.js"),
    fromEffect("Effect.js"),
    fromEffect("Option.js"),
  ]);
  return { S, E, O } as { S: any; E: any; O: any };
}

export async function loadContracts() {
  return (await import(pathToFileURL(join(contractsSrc, "index.ts")).href)) as Record<string, any>;
}

/** Export names per contracts module, so generated types can be grouped by source file. */
export async function loadModuleExports() {
  const files = readdirSync(contractsSrc)
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts") && f !== "index.ts")
    .sort();
  const out = new Map<string, Record<string, any>>();
  for (const f of files) {
    out.set(f.replace(/\.ts$/, ""), await import(pathToFileURL(join(contractsSrc, f)).href));
  }
  return out;
}
