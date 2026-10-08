// Replays packages/client-runtime/src/work-log/commandLabel.test.ts through a stub test runner
// and returns every (command, expected program) pair it asserts, so the Swift port is held to the
// same expectations as the TypeScript. A failing TypeScript expectation aborts the oracle.
import { registerHooks } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";

const here = import.meta.dirname;
const workLog = join(repoRoot, "packages", "client-runtime", "src", "work-log");

export async function commandLabelTestCases(): Promise<
  Array<{ title: string; command: string; program: string | null }>
> {
  const stubUrl = pathToFileURL(join(here, "vitest-stub.ts")).href;
  const real = await import(pathToFileURL(join(workLog, "commandLabel.ts")).href);
  const g = globalThis as {
    __lastInput?: unknown;
    __commandProgramName?: (command: string) => string | null;
  };
  g.__commandProgramName = (command: string) => {
    g.__lastInput = command;
    return real.commandProgramName(command);
  };
  const wrapper =
    "data:text/javascript,export const commandProgramName = (command) => globalThis.__commandProgramName(command);";
  const hook = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === "vite-plus/test") return { url: stubUrl, shortCircuit: true };
      if (specifier === "./commandLabel.ts" && context.parentURL?.endsWith("commandLabel.test.ts"))
        return { url: wrapper, shortCircuit: true };
      return nextResolve(specifier, context);
    },
  });
  try {
    await import(pathToFileURL(join(workLog, "commandLabel.test.ts")).href);
  } finally {
    hook.deregister();
  }
  const { records } = await import(stubUrl);
  return records().map((r: any) => {
    if (r.actual !== r.expected)
      throw new Error(
        `TypeScript expectation failed for ${JSON.stringify(r.input)}: ${r.actual} !== ${r.expected}`,
      );
    return { title: r.title, command: r.input as string, program: r.expected as string | null };
  });
}
