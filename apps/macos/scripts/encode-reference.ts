// Produces the TS-encoder oracle for the Swift tests:
//   Fixtures/reference/samples.json   wire samples of every union and root type, with the
//                                     canonical JSON Effect's own codec encodes them to
//   Fixtures/reference/commands.json  a few explicitly constructed commands, encoded by Effect
//   Tests/T3ContractsTests/Generated/ReferenceCases.swift   type name -> round-trip closure
//
//   node apps/macos/scripts/encode-reference.ts [--check]
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { macosRoot } from "./lib/load.ts";
import { buildBoth } from "./lib/split.ts";
import { makeSampler } from "./lib/sample.ts";
import { HEADER } from "./lib/swift.ts";

const check = process.argv.includes("--check");
const tests = join(macosRoot, "T3Kit", "Tests", "T3ContractsTests");
const { current, frozen, reach, v1Own } = await buildBoth();
const rt = current.rt;
const { S } = rt;

const json = (v: unknown) => JSON.parse(JSON.stringify(v));
/** True when Effect only added keys (defaults) to `a`; false when its codec rewrote or dropped something. */
const isSubset = (a: any, b: any): boolean =>
  a !== null && typeof a === "object" && b !== null && typeof b === "object"
    ? Array.isArray(a)
      ? Array.isArray(b) && a.length === b.length && a.every((x, i) => isSubset(x, b[i]))
      : Object.keys(a).every((k) => k in b && isSubset(a[k], b[k]))
    : a === b;
const samples: {
  type: string;
  mode: string;
  idx: number;
  input: unknown;
  canonical: unknown;
  exact: boolean;
}[] = [];
const rejected = new Map<string, string>();
const caseNames: string[] = [];

/** Samples every union and root struct among `candidates`; V1's own types are named `V1.<name>`. */
function sampleModel(
  model: typeof current,
  candidates: Set<string>,
  swiftPrefix: string,
  types = model.builder.types,
) {
  const astByType = model.builder.astByType();
  const sampler = makeSampler(types);
  const rootStructs = new Set(model.roots.flatMap((w) => (w.ir.k === "ref" ? [w.ir.name] : [])));
  const names = [...candidates]
    .filter((n) => {
      const d = model.builder.types.get(n)!;
      return (
        d.kind === "union" || d.kind === "untagged" || (d.kind === "struct" && rootStructs.has(n))
      );
    })
    .sort();
  for (const name of names) {
    const ast = astByType.get(name);
    if (!ast) continue;
    caseNames.push(`${swiftPrefix}${name}`);
    const codec = S.make(ast);
    const decode = S.decodeUnknownSync(codec);
    const encode = S.encodeSync(codec);
    const seen = new Set<string>();
    for (const s of sampler.samples(name)) {
      const key = JSON.stringify(s.input);
      if (seen.has(key)) continue;
      seen.add(key);
      try {
        const canonical = json(encode(decode(s.input)));
        // Canonical output must be a fixed point of Effect's own codec, or it is not a usable oracle.
        if (JSON.stringify(json(encode(decode(canonical)))) !== JSON.stringify(canonical))
          throw new Error("canonical form is not stable");
        samples.push({
          type: `${swiftPrefix}${name}`,
          mode: s.mode,
          idx: s.idx,
          input: s.input,
          canonical,
          exact: isSubset(s.input, canonical),
        });
      } catch (e: any) {
        if (!rejected.has(`${swiftPrefix}${name}`))
          rejected.set(
            `${swiftPrefix}${name}`,
            String(e?.message ?? e)
              .split("\n")
              .slice(0, 3)
              .join(" | ")
              .slice(0, 200),
          );
      }
    }
  }
  return astByType;
}
sampleModel(current, reach, "");
const v1Asts = sampleModel(
  frozen,
  v1Own,
  "V1.",
  new Map([...current.builder.types, ...frozen.builder.types]),
);
const names = caseNames;

// ---- explicitly constructed commands (mirrored by hand in ReferenceTests.swift) -------------------------
const commandCodec = S.make(v1Asts.get("ClientOrchestrationCommand"));
const at = "2026-01-01T00:00:00.000Z";
const commandInputs: Record<string, unknown> = {
  projectCreate: {
    type: "project.create",
    commandId: "cmd-1",
    projectId: "proj-1",
    title: "Project",
    workspaceRoot: "/tmp/project",
    createWorkspaceRootIfMissing: true,
    defaultModelSelection: {
      instanceId: "codex",
      model: "gpt-5",
      options: [{ id: "effort", value: "high" }],
    },
    createdAt: at,
  },
  projectMetaUpdateClearsModel: {
    type: "project.meta.update",
    commandId: "cmd-2",
    projectId: "proj-1",
    title: "Renamed",
    defaultModelSelection: null,
    faviconPath: null,
  },
  threadCreate: {
    type: "thread.create",
    commandId: "cmd-3",
    threadId: "thread-1",
    projectId: "proj-1",
    title: "Thread",
    modelSelection: { instanceId: "claudeAgent", model: "opus" },
    runtimeMode: "approval-required",
    branch: null,
    worktreePath: null,
    createdAt: at,
  },
  threadTurnStart: {
    type: "thread.turn.start",
    commandId: "cmd-4",
    threadId: "thread-1",
    message: {
      messageId: "msg-1",
      role: "user",
      text: "Hello",
      attachments: [
        {
          type: "image",
          name: "a.png",
          mimeType: "image/png",
          sizeBytes: 3,
          dataUrl: "data:image/png;base64,AAAA",
        },
      ],
    },
    runtimeMode: "full-access",
    interactionMode: "plan",
    createdAt: at,
  },
  threadMetaUpdateTriState: {
    type: "thread.meta.update",
    commandId: "cmd-5",
    threadId: "thread-1",
    title: "New title",
    branch: null,
    worktreePath: "/tmp/wt",
  },
  threadApprovalRespond: {
    type: "thread.approval.respond",
    commandId: "cmd-6",
    threadId: "thread-1",
    requestId: "req-1",
    decision: "acceptForSession",
    createdAt: at,
  },
  threadSnooze: {
    type: "thread.snooze",
    commandId: "cmd-7",
    threadId: "thread-1",
    snoozedUntil: at,
  },
};
const commands = Object.entries(commandInputs).map(([name, input]) => ({
  name,
  input,
  canonical: json(S.encodeSync(commandCodec)(S.decodeUnknownSync(commandCodec)(input))),
}));

// ---- Swift side ------------------------------------------------------------------------------------------------
const swiftTable = [
  HEADER.replace("import Foundation", "import Foundation\n@testable import T3Contracts"),
  "/// type name -> decode `input`, re-encode, and return differences against Effect's canonical JSON.",
  "let referenceCases: [String: @Sendable (Data, Data) throws -> [String]] = [",
  ...names.map(
    (n) => `  ${JSON.stringify(n)}: { try JSONCheck.reencode(${n}.self, $0, expecting: $1) },`,
  ),
  "]",
  "",
].join("\n");

const files = new Map<string, string>([
  [join(tests, "Fixtures", "reference", "samples.json"), JSON.stringify(samples) + "\n"],
  [join(tests, "Fixtures", "reference", "commands.json"), JSON.stringify(commands, null, 1) + "\n"],
  [join(tests, "Generated", "ReferenceCases.swift"), swiftTable],
]);
if (check) {
  const stale = [...files]
    .filter(([p, c]) => !existsSync(p) || readFileSync(p, "utf8") !== c)
    .map(([p]) => p.replace(tests, ""));
  if (stale.length) {
    console.error(
      `Reference output is stale: ${stale.join(", ")}\nRun: node apps/macos/scripts/encode-reference.ts`,
    );
    process.exit(1);
  }
  console.log("Reference output is up to date");
} else {
  for (const [p, c] of files) {
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, c);
  }
  console.log(
    `${samples.length} samples over ${names.length} types, ${commands.length} commands; size ${(JSON.stringify(samples).length / 1024).toFixed(0)} KiB`,
  );
  console.log(`rejected by the TS codec (${rejected.size} types):`);
  for (const [n, m] of [...rejected].sort()) console.log(`  ${n}: ${m}`);
}
