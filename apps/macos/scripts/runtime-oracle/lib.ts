// Shared loading for the runtime oracle: the real TypeScript reducers and derived-state
// functions of packages/client-runtime (and the mobile list partition built on them), imported
// by file URL so the Swift port is compared against the code that ships, not a copy.
import { registerHooks } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot, macosRoot } from "../lib/load.ts";

// apps/mobile uses bundler-style extensionless imports; resolve them for node.
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

export const runtimeRoot = join(
  macosRoot,
  "T3Kit",
  "Tests",
  "T3ClientRuntimeTests",
  "Fixtures",
  "oracle",
);
export const contractsFixtures = join(macosRoot, "T3Kit", "Tests", "T3ContractsTests", "Fixtures");

export async function loadSources() {
  const cr = "packages/client-runtime/src/";
  const [
    shellReducer,
    threadReducer,
    threadSort,
    threadSettled,
    projectGrouping,
    pendingRequests,
    threadListV2,
  ] = await Promise.all([
    imp(cr + "state/shellReducer.ts"),
    imp(cr + "state/threadReducer.ts"),
    imp(cr + "state/threadSort.ts"),
    imp(cr + "state/threadSettled.ts"),
    imp(cr + "state/projectGrouping.ts"),
    imp(cr + "pendingRequests.ts"),
    imp("apps/mobile/src/features/threads/threadListV2.ts"),
  ]);
  return {
    shellReducer,
    threadReducer,
    threadSort,
    threadSettled,
    projectGrouping,
    pendingRequests,
    threadListV2,
  };
}

/** JSON round trip: drops `undefined` exactly like the wire does. */
export const plain = <T>(value: T): any =>
  JSON.parse(JSON.stringify(value === undefined ? null : value));
