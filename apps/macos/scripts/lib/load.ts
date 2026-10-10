// Loads packages/contracts and the exact `effect` copy it resolves, without
// needing node_modules next to apps/macos. Both are plain ESM imports by file
// URL, so schema objects and the Effect runtime share one module instance.
import { createRequire, registerHooks } from "node:module";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

export const repoRoot = join(import.meta.dirname, "..", "..", "..", "..");
export const contractsSrc = join(repoRoot, "packages", "contracts", "src");
export const macosRoot = join(repoRoot, "apps", "macos");
export const frozenV1Dir = join(macosRoot, "scripts", "frozen-v1");

const effectDir = dirname(
  createRequire(join(repoRoot, "packages", "contracts", "package.json")).resolve(
    "effect/package.json",
  ),
);
// Contracts and the frozen V1 sources import bare `effect/...` specifiers.
// Frozen sources live outside any node_modules tree, so those go to the exact
// copy packages/contracts uses (package exports map `./*` to `./dist/*.js`),
// sharing one module instance. `effect/Schema` itself is swapped for a shim
// that keeps brands visible to the generator (see schema-shim.ts).
const schemaUrl = pathToFileURL(join(effectDir, "dist", "Schema.js")).href;
const shimUrl = pathToFileURL(join(import.meta.dirname, "schema-shim.ts")).href;
registerHooks({
  resolve(specifier, context, nextResolve) {
    const parent = context.parentURL ?? "";
    const inFrozen = parent.includes("/apps/macos/scripts/frozen-v1/");
    const inContracts = parent.includes("/packages/contracts/src/");
    if (specifier === "effect/Schema" && (inFrozen || inContracts))
      return { url: shimUrl, shortCircuit: true };
    if (inFrozen && /^effect\//.test(specifier))
      return {
        url: pathToFileURL(join(effectDir, "dist", `${specifier.slice(7)}.js`)).href,
        shortCircuit: true,
      };
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    // The shim is a template: point its imports at the real module.
    if (url !== shimUrl) return nextLoad(url, context);
    const source = readFileSync(new URL(shimUrl), "utf8").replaceAll("SCHEMA_URL", schemaUrl);
    return { format: "module-typescript", source, shortCircuit: true };
  },
});

const fromEffect = (name: string) => import(pathToFileURL(join(effectDir, "dist", name)).href);

export async function loadRuntime() {
  const [S, E, O, G] = await Promise.all([
    fromEffect("Schema.js"),
    fromEffect("Effect.js"),
    fromEffect("Option.js"),
    fromEffect("SchemaGetter.js"),
  ]);
  return { S, E, O, G } as { S: any; E: any; O: any; G: any };
}

export async function loadContracts() {
  const index = await import(pathToFileURL(join(contractsSrc, "index.ts")).href);
  // `relay` is a separate package entry point (`@t3tools/contracts/relay`), not part of the index.
  const relay = await import(pathToFileURL(join(contractsSrc, "relay.ts")).href);
  return { ...relay, ...index } as Record<string, any>;
}

export async function loadFrozenV1() {
  return (await import(pathToFileURL(join(frozenV1Dir, "index.ts")).href)) as Record<string, any>;
}

/** Export names per contracts module (and its source text), so generated types can be grouped by source file. */
export async function loadModuleExports(withFrozenV1 = false) {
  const files = readdirSync(contractsSrc)
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts") && f !== "index.ts")
    .sort();
  const out = new Map<string, { ns: Record<string, any>; source: string }>();
  const add = async (name: string, path: string) =>
    out.set(name, {
      ns: await import(pathToFileURL(path).href),
      source: readFileSync(path, "utf8"),
    });
  // Frozen first: where V1 and current schemas share an export name, V1 wins.
  if (withFrozenV1) await add("orchestration", join(frozenV1Dir, "orchestration.ts"));
  for (const f of files) await add(f.replace(/\.ts$/, ""), join(contractsSrc, f));
  return out;
}
