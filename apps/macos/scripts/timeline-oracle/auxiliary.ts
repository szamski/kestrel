// Derived values next to the rows: pending requests, live subagent ids, turn diff trees and the
// command program names the live labels use.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { repoRoot } from "../lib/load.ts";
import { liveAgentTaskIds, type Sources } from "./lib.ts";

const treeProjection = (nodes: any[]): any[] =>
  nodes.map((node) =>
    node.kind === "directory"
      ? {
          kind: "directory",
          name: node.name,
          path: node.path,
          stat: node.stat,
          children: treeProjection(node.children),
        }
      : { kind: "file", name: node.name, path: node.path, stat: node.stat },
  );

const LABEL_ROOTS: Array<string | null> = [null, "/w", "C:\\work\\proj"];

/** Display labels of every work row, for a few workspace roots. */
function entryLabels(src: Sources, thread: any) {
  const entries = src.sessionLogic.deriveWorkLogEntries(thread.activities);
  const roots = [
    ...LABEL_ROOTS,
    ...(typeof thread.worktreePath === "string" ? [thread.worktreePath] : []),
  ];
  return entries.map((entry: any) => ({
    id: entry.id,
    labels: roots.map((root) => ({
      root,
      display: src.rows.workEntryDisplayLabel(entry, root ?? undefined),
      live: src.rows.liveWorkEntryLabel(entry, root ?? undefined, true),
      settled: src.rows.liveWorkEntryLabel(entry, root ?? undefined, false),
    })),
  }));
}

const DRAFT_SHAPES: Array<(question: any) => any> = [
  () => undefined,
  () => ({ customAnswer: "  typed answer " }),
  (q) => ({ selectedOptionValues: [optionValue(q.options[0]) ?? "none"] }),
  (q) => ({
    selectedOptionValues: [...q.options.map(optionValue), optionValue(q.options[0]), "bogus"],
  }),
  () => ({ attachmentCount: 2 }),
  () => ({ attachmentsBlocked: true, customAnswer: "x" }),
  (q) => ({ customAnswer: "y", selectedOptionValues: [optionValue(q.options[0]) ?? "none"] }),
  () => ({ customAnswer: "   " }),
  (q) => ({ selectedOptionValues: [optionValue(q.options.at(-1))], attachmentCount: 1 }),
];
const optionValue = (option: any) => option?.value ?? option?.label;

/** Answer-building drafts replayed on every pending question prompt (apps/web/src/pendingUserInput.ts). */
function answerCases(src: Sources, userInputs: any[]) {
  const P = src.pendingUserInput;
  const cases: any[] = [];
  for (const prompt of userInputs) {
    for (const [shapeIndex, shape] of DRAFT_SHAPES.entries()) {
      const drafts: Record<string, any> = {};
      for (const question of prompt.questions) {
        const draft = shape(question);
        if (draft !== undefined) drafts[question.id] = draft;
      }
      for (const questionIndex of [-1, 0, 1, 5]) {
        const progress = P.derivePendingUserInputProgress(prompt.questions, drafts, questionIndex);
        const first = prompt.questions[0];
        cases.push({
          requestId: prompt.requestId,
          shapeIndex,
          questionIndex,
          drafts,
          progress: {
            questionIndex: progress.questionIndex,
            activeQuestionId: progress.activeQuestion?.id ?? null,
            selectedOptionValues: progress.selectedOptionValues,
            customAnswer: progress.customAnswer,
            resolvedAnswer: progress.resolvedAnswer,
            usingCustomAnswer: progress.usingCustomAnswer,
            answeredQuestionCount: progress.answeredQuestionCount,
            isLastQuestion: progress.isLastQuestion,
            isComplete: progress.isComplete,
            canAdvance: progress.canAdvance,
          },
          answers: P.buildPendingUserInputAnswers(prompt.questions, drafts),
          toggled: P.togglePendingUserInputOptionSelection(
            first,
            drafts[first.id],
            optionValue(first.options[0]) ?? "none",
          ),
          customSet: P.setPendingUserInputCustomAnswer(
            drafts[first.id],
            questionIndex < 0 ? "" : " custom ",
          ),
          carried: P.carryDisplacedCustomAnswerIntoPrompt(
            questionIndex === 0 ? "" : "draft  ",
            drafts[first.id]?.customAnswer,
          ),
        });
      }
    }
  }
  return cases;
}

export function derivedAuxiliary(src: Sources, thread: any) {
  const pending = src.pending.derivePendingRequests(thread.activities);
  const strip = (value: any) => JSON.parse(JSON.stringify(value));
  return {
    pending: strip({
      approvals: pending.approvals,
      userInputs: pending.userInputs,
    }),
    answerCases: answerCases(src, pending.userInputs),
    liveAgentTaskIds: liveAgentTaskIds(src, thread),
    labels: entryLabels(src, thread),
    turnDiffs: thread.checkpoints.map((summary: any) => ({
      turnId: summary.turnId,
      stats: src.turnDiffTree.summarizeTurnDiffStats(summary.files),
      tree: treeProjection(src.turnDiffTree.buildTurnDiffTree(summary.files)),
    })),
  };
}

/** Every string literal of a TypeScript test file, evaluated (the tables of `it.each` hold the inputs). */
function stringLiterals(source: string): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < source.length) {
    const c = source[i]!;
    if (c === "/" && source[i + 1] === "/") {
      while (i < source.length && source[i] !== "\n") i += 1;
    } else if (c === "/" && source[i + 1] === "*") {
      i = source.indexOf("*/", i + 2) + 2 || source.length;
    } else if (c === "'" || c === '"' || c === "`") {
      const start = i;
      i += 1;
      while (i < source.length && source[i] !== c) i += source[i] === "\\" ? 2 : 1;
      i += 1;
      const literal = source.slice(start, i);
      if (!(c === "`" && literal.includes("${"))) {
        try {
          const value = new Function(`return ${literal}`)();
          if (typeof value === "string") out.push(value);
        } catch {}
      }
    } else {
      i += 1;
    }
  }
  return out;
}

/** Shell strings for commandProgramName: every literal of commandLabel.test.ts plus extra shapes. Real commands are added by the oracle. */
export function fixedCommandCases(): string[] {
  const testFile = join(
    repoRoot,
    "packages",
    "client-runtime",
    "src",
    "work-log",
    "commandLabel.test.ts",
  );
  const cases = new Set<string>(
    stringLiterals(readFileSync(testFile, "utf8")).filter((value) => value.length < 400),
  );
  for (const extra of [
    "git status --short",
    "/bin/zsh -lc 'git status --short'",
    'bash -lc "cd /repo && npm test"',
    "cd /repo && pnpm run build",
    "FOO=bar BAZ=1 node script.js",
    "sudo -n apt-get install foo",
    "time npm run lint",
    "command -v node",
    "exec python3 -m http.server",
    "env NODE_ENV=production node server.js",
    "  rg -n 'todo' src | head -5",
    "cat <<'EOF'\nhello\nEOF",
    'powershell.exe -NoProfile -Command "Get-ChildItem -Recurse"',
    "pwsh -c 'Set-Location C:\\x; npm test'",
    "cmd.exe /c dir",
    "& 'C:\\Program Files\\nodejs\\node.exe' app.js",
    "Start-Process -FilePath node -ArgumentList app.js",
    "xcodebuild -scheme T3 build | xcpretty",
    "swift test --filter T3TimelineTests",
    "# comment only",
    "echo hello > out.txt",
    "if [ -f x ]; then echo y; fi",
    "for f in *.ts; do echo $f; done",
    "(cd sub && ls)",
    "$HOME/bin/tool --flag",
    "./scripts/run.sh arg",
    "~/bin/tool",
    'node -e "console.log(1)"',
    "python - <<'PY'\nprint(1)\nPY",
    "/usr/bin/env bash -c 'make test'",
    "nocorrect noglob ls",
    "builtin cd /tmp",
    "'git' status",
    '"C:\\tools\\a b\\tool.exe" --x',
    "set -euo pipefail; make",
    "true && false || echo no",
    "tail -f log | grep error",
    "docker compose up -d",
    "kubectl get pods -A",
    "",
    "   ",
  ])
    cases.add(extra);
  // commandLabel.test.ts builds this table with flatMap, so its strings are not literals.
  for (const setup of ["cd /tmp", "export CI=1", "unset DEBUG", "source env.sh", ". env.sh"]) {
    for (const operator of ["&&", " || ", ";", "\n", "|", " |& ", " & "])
      cases.add(`${setup}${operator}npm test`);
  }
  return [...cases];
}
