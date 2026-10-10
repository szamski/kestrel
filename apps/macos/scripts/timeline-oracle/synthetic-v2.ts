// Synthetic protocol-2 threads for the timeline oracle. Each scenario is a wire-shaped thread
// projection (what `orchestration.subscribeThread` sends) built from small item helpers; the
// oracle validates it against the contracts schema, so a wrong shape fails here, not in Swift.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { contractsFixtures } from "./lib.ts";

type Json = Record<string, any>;

const T0 = Date.parse("2026-10-01T12:00:00.000Z");
/** Seconds after the scenario start, in the server's canonical ISO form. */
export const at = (seconds: number) => new Date(T0 + seconds * 1000).toISOString();

const THREAD = "thread-syn";
const MODEL = { instanceId: "codex", model: "gpt-5.4" };

const fixtureProjection = (): Json =>
  JSON.parse(
    readFileSync(join(contractsFixtures, "wire", "v2-thread-with-history-snapshot.json"), "utf8"),
  ).projection;

// ---- entity helpers ------------------------------------------------------------------------

export interface RunSpec {
  id: string;
  status?: string;
  start: number;
  end?: number | null;
  queueHeld?: boolean;
  /** Extra attempts after the first: the earlier ones are superseded. */
  attempts?: number;
}

const nodeIdOf = (runId: string, attempt = 1) => `node-${runId}-${attempt}`;
const attemptIdOf = (runId: string, attempt = 1) => `attempt-${runId}-${attempt}`;

function runEntities(spec: RunSpec, ordinal: number) {
  const status = spec.status ?? "completed";
  const attemptCount = spec.attempts ?? 1;
  const terminal = !["preparing", "queued", "starting", "running", "waiting"].includes(status);
  const run = {
    id: spec.id,
    threadId: THREAD,
    ordinal,
    providerInstanceId: "codex",
    modelSelection: MODEL,
    providerThreadId: "provider-thread-v2",
    userMessageId: `message-${spec.id}-user`,
    rootNodeId: nodeIdOf(spec.id, attemptCount),
    activeAttemptId: terminal ? null : attemptIdOf(spec.id, attemptCount),
    status,
    ...(spec.queueHeld === undefined ? {} : { queueHeld: spec.queueHeld }),
    requestedAt: at(spec.start),
    startedAt: status === "queued" ? null : at(spec.start + 1),
    completedAt: terminal ? at(spec.end ?? spec.start + 60) : null,
    checkpointId: null,
    contextHandoffId: null,
  };
  const attempts: Json[] = [];
  const nodes: Json[] = [];
  for (let n = 1; n <= attemptCount; n += 1) {
    const last = n === attemptCount;
    const attemptStatus = last
      ? terminal
        ? status === "completed" || status === "interrupted" || status === "failed"
          ? status
          : "cancelled"
        : "running"
      : "superseded";
    attempts.push({
      id: attemptIdOf(spec.id, n),
      runId: spec.id,
      attemptOrdinal: n,
      rootNodeId: nodeIdOf(spec.id, n),
      providerInstanceId: "codex",
      providerThreadId: "provider-thread-v2",
      providerTurnId: `provider-turn-${spec.id}-${n}`,
      reason: n === 1 ? "initial" : "steering_restart",
      status: attemptStatus,
      startedAt: at(spec.start + n),
      completedAt: last && !terminal ? null : at(spec.start + n + 20),
    });
    nodes.push({
      id: nodeIdOf(spec.id, n),
      threadId: THREAD,
      runId: spec.id,
      parentNodeId: null,
      rootNodeId: nodeIdOf(spec.id, n),
      kind: "root_turn",
      status: last
        ? terminal
          ? status === "failed"
            ? "failed"
            : status === "interrupted"
              ? "interrupted"
              : "completed"
          : "running"
        : "cancelled",
      countsForRun: true,
      providerThreadId: "provider-thread-v2",
      providerTurnId: `provider-turn-${spec.id}-${n}`,
      nativeItemRef: null,
      runtimeRequestId: null,
      checkpointScopeId: null,
      startedAt: at(spec.start + n),
      completedAt: last && !terminal ? null : at(spec.start + n + 20),
    });
  }
  return { run, attempts, nodes };
}

let itemCounter = 0;
/** One turn item with its base fields; `t` is seconds after the scenario start. */
export function item(type: string, runId: string | null, t: number, fields: Json = {}): Json {
  itemCounter += 1;
  const attempt = fields.attempt ?? 1;
  const { attempt: _attempt, ...rest } = fields;
  return {
    id: rest.id ?? `item-${type}-${itemCounter}`,
    threadId: THREAD,
    runId,
    nodeId: runId === null ? null : nodeIdOf(runId, attempt),
    providerThreadId: "provider-thread-v2",
    providerTurnId: runId === null ? null : `provider-turn-${runId}-${attempt}`,
    nativeItemRef: null,
    parentItemId: null,
    ordinal: itemCounter,
    status: "completed",
    title: null,
    startedAt: at(t),
    completedAt: at(t + 1),
    updatedAt: at(t + 1),
    type,
    ...rest,
  };
}

export const user = (runId: string, t: number, text: string, f: Json = {}) =>
  item("user_message", runId, t, {
    createdBy: "user",
    creationSource: "web",
    messageId: `message-${runId}-user`,
    inputIntent: "turn_start",
    text,
    attachments: [],
    ...f,
  });
export const assistant = (runId: string, t: number, text: string, f: Json = {}) =>
  item("assistant_message", runId, t, {
    messageId: `message-${runId}-assistant-${itemCounter + 1}`,
    text,
    streaming: false,
    ...f,
  });
export const reasoning = (runId: string, t: number, text: string, f: Json = {}) =>
  item("reasoning", runId, t, { text, streaming: false, ...f });
export const command = (runId: string, t: number, input: string, f: Json = {}) =>
  item("command_execution", runId, t, { input, ...f });
export const fileChange = (runId: string, t: number, fileName: string, f: Json = {}) =>
  item("file_change", runId, t, { fileName, additions: 3, deletions: 1, ...f });
export const dynamicTool = (
  runId: string,
  t: number,
  toolName: string | null,
  input: unknown,
  f: Json = {},
) => item("dynamic_tool", runId, t, { toolName, input, ...f });

function buildProjection(opts: {
  runs: RunSpec[];
  items: Json[];
  plans?: Json[];
  checkpoints?: Json[];
  thread?: Json;
  nodes?: Json[];
  subagents?: Json[];
}): Json {
  const base = fixtureProjection();
  const runs: Json[] = [];
  const attempts: Json[] = [];
  const nodes: Json[] = [...(opts.nodes ?? [])];
  opts.runs.forEach((spec, index) => {
    const entities = runEntities(spec, index + 1);
    runs.push(entities.run);
    attempts.push(...entities.attempts);
    nodes.push(...entities.nodes);
  });
  const messages = opts.items.flatMap((entry) =>
    entry.type === "user_message" || entry.type === "assistant_message"
      ? [
          {
            createdBy: entry.createdBy ?? "agent",
            creationSource: entry.creationSource ?? "provider",
            id: entry.messageId,
            threadId: THREAD,
            runId: entry.runId,
            nodeId: entry.nodeId,
            role: entry.type === "user_message" ? "user" : "assistant",
            text: entry.text,
            attachments: entry.attachments ?? [],
            streaming: entry.streaming ?? false,
            createdAt: entry.startedAt ?? entry.updatedAt,
            updatedAt: entry.updatedAt,
          },
        ]
      : [],
  );
  const checkpointScopes = (opts.checkpoints ?? []).map((checkpoint) => ({
    id: checkpoint.scopeId,
    threadId: THREAD,
    runId: checkpoint.runId,
    nodeId: checkpoint.nodeId,
    parentScopeId: null,
    providerThreadId: "provider-thread-v2",
    kind: "root_run",
    ordinalWithinParent: 0,
    advancesAppRunCount: true,
    cwd: "/workspace/project",
    createdAt: at(0),
  }));
  return {
    ...base,
    thread: { ...base.thread, id: THREAD, ...(opts.thread ?? {}) },
    runs,
    attempts,
    nodes,
    subagents: opts.subagents ?? [],
    providerSessions: [],
    runtimeRequests: [],
    messages,
    plans: opts.plans ?? [],
    turnItems: opts.items,
    checkpointScopes,
    checkpoints: opts.checkpoints ?? [],
    contextHandoffs: [],
    contextTransfers: [],
    visibleTurnItems: opts.items.map((entry, position) => ({
      position,
      visibility: "local",
      sourceThreadId: THREAD,
      sourceItemId: entry.id,
      item: entry,
    })),
    updatedAt: at(9999),
  };
}

const checkpoint = (runId: string, ordinal: number, t: number, files: Json[]) => ({
  id: `checkpoint-${runId}`,
  threadId: THREAD,
  scopeId: `scope-${runId}`,
  runId,
  nodeId: nodeIdOf(runId),
  parentCheckpointId: null,
  ordinalWithinScope: 0,
  appRunOrdinal: ordinal,
  ref: `refs/t3/checkpoints/${runId}`,
  status: "ready",
  files,
  capturedAt: at(t),
});

const todoPlan = (id: string, runId: string, steps: Json[], explanation?: string) => ({
  id,
  threadId: THREAD,
  runId,
  nodeId: nodeIdOf(runId),
  status: "active",
  kind: "todo_list",
  steps,
  ...(explanation === undefined ? {} : { explanation }),
});
const proposedPlanArtifact = (id: string, runId: string, markdown: string, status = "active") => ({
  id,
  threadId: THREAD,
  runId,
  nodeId: nodeIdOf(runId),
  status,
  kind: "proposed_plan",
  markdown,
});

// ---- scenarios -----------------------------------------------------------------------------

export interface SyntheticV2 {
  name: string;
  projection: Json;
}

export function syntheticScenarios(): SyntheticV2[] {
  const out: SyntheticV2[] = [];
  const add = (name: string, projection: Json) => out.push({ name, projection });
  const reset = () => {
    itemCounter = 0;
  };

  reset();
  add("empty", buildProjection({ runs: [], items: [] }));

  // A settled turn: reasoning, commands, a file change and the answer fold behind "Worked for".
  reset();
  add(
    "settled-turn",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 95 }],
      items: [
        user("run-a", 0, "Fix the flaky test"),
        reasoning("run-a", 3, "Looking at the failing spec first."),
        command("run-a", 6, "rg -n flaky Tests"),
        command("run-a", 9, "bash -lc 'swift test --filter Flaky'", {
          exitCode: 1,
          outputIndicatesFailure: true,
        }),
        fileChange("run-a", 20, "Tests/FlakyTests.swift", {
          changes: [{ operation: "edit", path: "Tests/FlakyTests.swift" }],
        }),
        fileChange("run-a", 24, "Sources/Core.swift", { additions: 8, deletions: 0 }),
        command("run-a", 30, "swift test"),
        assistant("run-a", 90, "Fixed: the test raced a timer."),
      ],
      checkpoints: [
        checkpoint("run-a", 1, 92, [
          { path: "Tests/FlakyTests.swift", kind: "modified", additions: 3, deletions: 1 },
          { path: "Sources/Core.swift", kind: "modified", additions: 8, deletions: 0 },
        ]),
      ],
    }),
  );

  // Two turns, the second still running with an in-progress command and streaming answer.
  reset();
  add(
    "running-tools",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 40 },
        { id: "run-b", start: 100, status: "running" },
      ],
      items: [
        user("run-a", 0, "First question"),
        command("run-a", 5, "ls"),
        assistant("run-a", 30, "First answer"),
        user("run-b", 100, "Second question"),
        reasoning("run-b", 103, "**Plan the search**\nWe look through the repo."),
        command("run-b", 106, "git status"),
        command("run-b", 108, "swift build", { status: "running", completedAt: null }),
      ],
    }),
  );

  // Tool variety: reads, searches, web, T3 MCP tools, titled CUA call, a Skill call.
  reset();
  add(
    "tool-variety",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 80 }],
      items: [
        user("run-a", 0, "Survey the repo"),
        dynamicTool("run-a", 2, "Read", { file_path: "/workspace/project/Package.swift" }),
        dynamicTool("run-a", 3, "Read", { file_path: "/workspace/project/README.md" }),
        item("file_search", "run-a", 4, {
          pattern: "TODO",
          results: [{ fileName: "Sources/A.swift", line: 3, preview: "// TODO" }],
        }),
        item("file_search", "run-a", 5, { pattern: "FIXME", title: "Search for FIXME" }),
        item("web_search", "run-a", 6, { patterns: ["swift concurrency", "actors"] }),
        item("web_search", "run-a", 7, { title: "grep calls in repo", patterns: [] }),
        dynamicTool("run-a", 8, "Grep", { pattern: "needle", path: "/workspace/project/Sources" }),
        dynamicTool(
          "run-a",
          9,
          "mcp__t3-code__link_pull_request",
          { url: "https://github.com/acme/app/pull/42" },
          {
            output: { content: [{ type: "text", text: JSON.stringify({ linked: true }) }] },
          },
        ),
        dynamicTool("run-a", 10, "mcp__t3-code__preview_open", { url: "http://localhost:3000" }),
        dynamicTool("run-a", 11, "cua_repl.js", {
          title: "Click the button",
          code: "await click()",
        }),
        dynamicTool("run-a", 12, "Skill", { skill: "deploy", args: "--prod" }),
        dynamicTool(
          "run-a",
          13,
          "t3-code.t3_thread_read",
          { threadId: "thread-other" },
          {
            output: { threadId: "thread-other" },
          },
        ),
        dynamicTool("run-a", 14, null, { anything: true }),
        assistant("run-a", 70, "Survey complete."),
      ],
    }),
  );

  // Failures: a failed command, a provider error with retries, usage limit, system notice.
  reset();
  add(
    "failures",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 50, status: "failed" },
        { id: "run-b", start: 60, end: 90, status: "failed" },
      ],
      items: [
        user("run-a", 0, "Run the build"),
        command("run-a", 4, "swift build", { status: "failed", exitCode: 2 }),
        item("error", "run-a", 10, {
          status: "running",
          failure: { class: "provider_error", message: "Overloaded", code: null, retryable: true },
          retry: { attempt: 1, maxAttempts: 3, retryDelayMs: 1500 },
        }),
        item("error", "run-a", 14, {
          status: "failed",
          failure: {
            class: "provider_error",
            message: "Overloaded again",
            code: null,
            retryable: false,
          },
          retry: { attempt: 3, maxAttempts: 3, retryDelayMs: null },
        }),
        item("system_notice", "run-a", 15, { message: "Provider session restarted" }),
        user("run-b", 60, "Try once more"),
        command("run-b", 63, "swift build"),
        item("error", "run-b", 70, {
          status: "failed",
          failure: {
            class: "usage_limit",
            message: "Usage limit reached for today",
            code: null,
            retryable: false,
          },
        }),
      ],
    }),
  );

  // A steer: the first attempt is superseded and folds; the steer message stays visible.
  reset();
  add(
    "steer-attempts",
    buildProjection({
      runs: [{ id: "run-a", start: 0, status: "running", attempts: 2 }],
      items: [
        user("run-a", 0, "Refactor the module"),
        reasoning("run-a", 3, "Starting the refactor.", { attempt: 1 }),
        command("run-a", 5, "rg -n module", { attempt: 1 }),
        assistant("run-a", 8, "I will restructure it.", { attempt: 1 }),
        user("run-a", 10, "Actually keep the old API", {
          messageId: "message-run-a-steer",
          inputIntent: "steer",
        }),
        reasoning("run-a", 12, "Adjusting the approach.", {
          attempt: 2,
          status: "running",
          completedAt: null,
        }),
        command("run-a", 14, "git diff", { attempt: 2 }),
      ],
    }),
  );

  // Subagents: a live batch and a settled one, plus the delegation tool row that gets dropped.
  reset();
  add(
    "subagents",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 100 }],
      items: [
        user("run-a", 0, "Fan out the work"),
        dynamicTool(
          "run-a",
          3,
          "mcp__t3-code__delegate_task",
          { prompt: "do x" },
          {
            output: { taskId: "task-1" },
          },
        ),
        item("subagent", "run-a", 4, {
          subagentId: "task-1",
          origin: "app_owned",
          driver: "codex",
          providerInstanceId: "codex",
          childThreadId: "thread-child-1",
          prompt: "do x",
          result: null,
          status: "running",
          completedAt: null,
        }),
        item("subagent", "run-a", 5, {
          subagentId: "task-2",
          origin: "provider_native",
          driver: "codex",
          providerInstanceId: "codex",
          childThreadId: null,
          prompt: "do y",
          result: "done",
        }),
        item("thread_created", "run-a", 6, {
          targetThreadId: "thread-created-1",
          targetRunId: "run-created-1",
          targetProviderInstanceId: "codex",
          targetModel: "gpt-5.4",
        }),
        assistant("run-a", 90, "All delegated."),
      ],
    }),
  );

  // Compaction (running and done), notification wake, hidden workspace preparation.
  reset();
  add(
    "compaction-notification",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 50 },
        { id: "run-b", start: 60, status: "running" },
      ],
      items: [
        command("run-a", 0, "Preparing workspace", { runId: "run-a" }),
        item("error", "run-a", 0, {
          status: "cancelled",
          failure: {
            class: "unknown",
            message: "prep",
            code: "workspace_preparation_failed",
            retryable: null,
          },
        }),
        user("run-a", 1, "Compact please"),
        item("compaction", "run-a", 5, {
          driver: "codex",
          beforeTokenCount: 123456,
          afterTokenCount: 4321,
          summary: "Condensed history",
        }),
        assistant("run-a", 40, "Compacted."),
        item("notification", "run-b", 60, {
          status: "completed",
          source: { kind: "monitor" },
          outcome: "completed",
          summary: "Subagent finished",
          detail: "All good",
        }),
        item("compaction", "run-b", 62, { status: "running", completedAt: null, driver: "codex" }),
      ],
    }),
  );

  // Approvals and questions: an approval, a pending question and an answered one with its folded answer.
  reset();
  add(
    "approvals-questions",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 100 }],
      items: [
        user("run-a", 0, "Do the risky thing"),
        item("approval_request", "run-a", 5, {
          requestId: "request-1",
          requestKind: "command",
          prompt: "Run rm -rf build?",
          status: "waiting",
          completedAt: null,
        }),
        item("user_input_request", "run-a", 10, {
          requestId: "request-2",
          questions: [
            {
              id: "scope",
              header: "Scope",
              question: "Which scope?",
              options: [{ label: "Small", description: "Just one file" }],
            },
          ],
          status: "waiting",
          completedAt: null,
        }),
        item("user_input_request", "run-a", 20, {
          requestId: "request-3",
          questions: [
            {
              id: "mode",
              header: "Mode",
              question: "Which mode?",
              options: [{ label: "Fast", description: "Quick" }],
            },
          ],
          questionAnswer: {
            requestId: "request-3",
            questionTextById: { mode: "Which mode?" },
            answers: { mode: "Fast" },
            attachmentsByQuestionId: {},
          },
        }),
        user("run-a", 22, "answer", {
          messageId: "async-answer:request-3",
          inputIntent: "turn_start",
        }),
        assistant("run-a", 90, "Proceeding."),
      ],
    }),
  );

  // Plans: a todo list with plan artifact and a proposed plan.
  reset();
  add(
    "plans",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 100 }],
      items: [
        user("run-a", 0, "Plan the migration"),
        item("todo_list", "run-a", 4, {
          planId: "plan-todo",
          steps: [
            { id: "a", text: "Read the code", status: "completed", durationMs: 1200 },
            { id: "b", text: "Write the migration", status: "running" },
          ],
          explanation: "Two steps",
        }),
        item("proposed_plan", "run-a", 8, {
          planId: "plan-prop",
          markdown: "# Plan\n- one\n- two",
          streaming: false,
        }),
        assistant("run-a", 90, "Here is the plan."),
      ],
      plans: [
        todoPlan(
          "plan-todo",
          "run-a",
          [
            { id: "a", text: "Read the code", status: "completed", durationMs: 1200 },
            { id: "b", text: "Write the migration", status: "running" },
          ],
          "Two steps",
        ),
        proposedPlanArtifact("plan-prop", "run-a", "# Plan\n- one\n- two"),
      ],
    }),
  );

  // Interrupt: request + result, interrupted run ("You stopped after").
  reset();
  add(
    "interrupt",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 30, status: "interrupted" }],
      items: [
        user("run-a", 0, "Long task"),
        command("run-a", 4, "sleep 100", { status: "interrupted" }),
        item("run_interrupt_request", "run-a", 25, { message: "Stop requested" }),
        item("run_interrupt_result", "run-a", 26, { message: "Stopped" }),
        assistant("run-a", 27, "Stopped early."),
      ],
    }),
  );

  // Resources: fork, handoff, secret request.
  reset();
  add(
    "resources",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 100 }],
      items: [
        user("run-a", 0, "Branch off"),
        item("fork", "run-a", 5, {
          source: { type: "run", threadId: THREAD, runId: "run-a" },
          targetThreadId: "thread-fork-1",
        }),
        item("handoff", "run-a", 8, {
          contextHandoffId: "handoff-1",
          fromProviderThreadIds: ["provider-thread-v2"],
          toProviderThreadId: "provider-thread-2",
          fromProviderInstanceIds: ["codex"],
          toProviderInstanceId: "claude",
          strategy: "full_thread_summary",
          summary: "Moved to Claude",
        }),
        item("secret_request", "run-a", 10, {
          label: "API token",
          reason: "Needed for deploy",
          secretStatus: "pending",
          status: "waiting",
          completedAt: null,
        }),
        assistant("run-a", 90, "Done."),
      ],
    }),
  );

  // Published pages: an html_render result and an MCP App.
  reset();
  add(
    "pages",
    buildProjection({
      runs: [{ id: "run-a", start: 0, end: 100 }],
      items: [
        user("run-a", 0, "Show me a page"),
        dynamicTool(
          "run-a",
          4,
          "mcp__t3-code__html_render",
          { html: "<p>hi</p>" },
          {
            output: {
              htmlRender: { attachmentId: "attachment-html", title: "Preview", height: 400 },
            },
          },
        ),
        dynamicTool(
          "run-a",
          8,
          "figma.render_frame",
          { frame: 1 },
          {
            output: {
              t3McpApp: {
                attachmentId: "attachment-app",
                server: "figma",
                tool: "render_frame",
                resourceUri: "ui://figma/frame",
              },
            },
          },
        ),
        assistant("run-a", 90, "Rendered."),
      ],
    }),
  );

  // Checkpoints over several runs, with rollback-eligible user messages and a queued run.
  reset();
  add(
    "checkpoints",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 40 },
        { id: "run-b", start: 50, end: 90 },
        { id: "run-c", start: 100, status: "queued", queueHeld: true },
      ],
      items: [
        user("run-a", 0, "One"),
        fileChange("run-a", 5, "a.txt"),
        assistant("run-a", 30, "A done"),
        user("run-b", 50, "Two"),
        fileChange("run-b", 55, "b.txt"),
        assistant("run-b", 80, "B done"),
      ],
      checkpoints: [
        checkpoint("run-a", 1, 35, [{ path: "a.txt", kind: "added", additions: 1, deletions: 0 }]),
        checkpoint("run-b", 2, 85, [{ path: "b.txt", kind: "added", additions: 2, deletions: 0 }]),
      ],
    }),
  );

  // A provider-native subagent thread: the work is a runless root turn.
  reset();
  add(
    "runless-subagent",
    buildProjection({
      runs: [],
      thread: {
        lineage: {
          parentThreadId: "thread-parent",
          relationshipToParent: "subagent",
          rootThreadId: "thread-parent",
        },
        creationSource: "provider",
      },
      nodes: [
        {
          id: "node-runless",
          threadId: THREAD,
          runId: null,
          parentNodeId: null,
          rootNodeId: "node-runless",
          kind: "root_turn",
          status: "running",
          countsForRun: false,
          providerThreadId: "provider-thread-v2",
          providerTurnId: "provider-turn-runless",
          nativeItemRef: null,
          runtimeRequestId: null,
          checkpointScopeId: null,
          startedAt: at(0),
          completedAt: null,
        },
      ],
      items: [
        user("run-x", 0, "Subtask prompt", { runId: null, nodeId: null, providerTurnId: null }),
        command("run-x", 3, "ls", { runId: null, nodeId: null, providerTurnId: null }),
        item("reasoning", null, 5, {
          text: "thinking",
          streaming: true,
          status: "running",
          completedAt: null,
        }),
      ],
    }),
  );

  // A running turn with commentary between tool bursts: groups, a live tail and the thought line.
  reset();
  add(
    "running-commentary",
    buildProjection({
      runs: [{ id: "run-a", start: 0, status: "running" }],
      items: [
        user("run-a", 0, "Implement the feature", {
          attachments: [
            {
              type: "image",
              id: "attachment-1",
              name: "mock.png",
              mimeType: "image/png",
              sizeBytes: 128,
            },
          ],
        }),
        reasoning("run-a", 3, "**Reading the code**\nFirst look at the module."),
        command("run-a", 5, "rg -n feature Sources"),
        dynamicTool("run-a", 6, "Read", { file_path: "/workspace/project/Sources/A.swift" }),
        assistant("run-a", 8, "I found the entry point."),
        fileChange("run-a", 10, "Sources/A.swift"),
        fileChange("run-a", 11, "Sources/B.swift"),
        reasoning("run-a", 13, "Now run the tests and check.", {
          status: "running",
          completedAt: null,
        }),
        command("run-a", 14, "swift test", { status: "running", completedAt: null }),
      ],
    }),
  );

  // A completed run without a final answer, an interrupted tool and a cancelled reasoning item.
  reset();
  add(
    "no-terminal-stopped",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 20 },
        { id: "run-b", start: 30, end: 50, status: "interrupted" },
      ],
      items: [
        user("run-a", 0, "Just do things"),
        command("run-a", 4, "echo hi"),
        fileChange("run-a", 8, "x.txt"),
        user("run-b", 30, "Another"),
        reasoning("run-b", 32, "Hmm.", { status: "cancelled" }),
        command("run-b", 34, "sleep 60", { status: "cancelled" }),
      ],
    }),
  );

  // What the Debug fixture reader shows (`-T3TimelineFixture`): a settled turn with real-looking
  // tool activity and changed files, then a running one with a live tool and a subagent.
  reset();
  add(
    "showcase",
    buildProjection({
      runs: [
        { id: "run-a", start: 0, end: 142 },
        { id: "run-b", start: 200, status: "running" },
      ],
      items: [
        user("run-a", 0, "Add a retry with backoff to the sync client and cover it with a test."),
        reasoning(
          "run-a",
          4,
          "**Reading the sync client**\nStart with how requests are issued and where failures surface.",
        ),
        command("run-a", 8, 'rg -n "SyncClient" Sources Tests'),
        dynamicTool("run-a", 12, "Read", {
          file_path: "/workspace/project/Sources/Sync/SyncClient.swift",
        }),
        dynamicTool("run-a", 14, "Read", {
          file_path: "/workspace/project/Tests/SyncTests/SyncClientTests.swift",
        }),
        assistant(
          "run-a",
          20,
          "The client has a single `send` path, so a retry loop fits there. I will add exponential backoff and a test with a flaky transport.",
        ),
        fileChange("run-a", 40, "Sources/Sync/SyncClient.swift", {
          additions: 24,
          deletions: 3,
          changes: [{ operation: "edit", path: "Sources/Sync/SyncClient.swift" }],
        }),
        fileChange("run-a", 70, "Tests/SyncTests/SyncClientTests.swift", {
          additions: 38,
          deletions: 0,
          changes: [{ operation: "edit", path: "Tests/SyncTests/SyncClientTests.swift" }],
        }),
        command("run-a", 90, "swift test --filter SyncClientTests", {
          exitCode: 1,
          outputIndicatesFailure: true,
          status: "failed",
        }),
        reasoning(
          "run-a",
          100,
          "The test failed because the fake transport never recovers. Fix the fixture.",
        ),
        fileChange("run-a", 110, "Tests/SyncTests/SyncClientTests.swift", {
          additions: 2,
          deletions: 2,
        }),
        command("run-a", 120, "swift test --filter SyncClientTests"),
        assistant(
          "run-a",
          138,
          "Done. `SyncClient.send` now retries up to three times with exponential backoff, and `SyncClientTests` covers the flaky-transport case. All tests pass.",
        ),
        user("run-b", 200, "Now document it in the README."),
        reasoning(
          "run-b",
          204,
          "**Finding the right section**\nThe README has a Networking section.",
        ),
        command("run-b", 208, 'rg -n "## Networking" README.md'),
        dynamicTool("run-b", 211, "Read", { file_path: "/workspace/project/README.md" }),
        item("subagent", "run-b", 213, {
          subagentId: "task-docs",
          origin: "provider_native",
          driver: "codex",
          providerInstanceId: "codex",
          childThreadId: null,
          title: "Check docs links",
          prompt: "Verify the links in README.md still resolve",
          progress: "Checking 14 links",
          result: null,
          status: "running",
          completedAt: null,
        }),
        fileChange("run-b", 216, "README.md", { additions: 9, deletions: 0 }),
        command("run-b", 220, "swift build", { status: "running", completedAt: null }),
      ],
      checkpoints: [
        checkpoint("run-a", 1, 140, [
          { path: "Sources/Sync/SyncClient.swift", kind: "modified", additions: 24, deletions: 3 },
          {
            path: "Tests/SyncTests/SyncClientTests.swift",
            kind: "modified",
            additions: 40,
            deletions: 2,
          },
        ]),
      ],
    }),
  );

  // A user message with a long running assistant stream and queued steer-by-notification.
  reset();
  add(
    "streaming",
    buildProjection({
      runs: [{ id: "run-a", start: 0, status: "running" }],
      items: [
        user("run-a", 0, "Write a long essay"),
        assistant("run-a", 4, "Once upon a", {
          streaming: true,
          status: "running",
          completedAt: null,
        }),
      ],
    }),
  );

  return out;
}
