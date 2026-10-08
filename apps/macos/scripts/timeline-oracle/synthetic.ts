// Synthetic thread read models for the timeline oracle: wire-shaped OrchestrationThread values
// built from a sanitized fixture thread so every row kind, every tool item type, approvals, user
// input, plans, compaction, reverts, worktree setup and streaming turns are covered. (The
// sanitized fixtures redact payloads down to "redacted", so they alone exercise almost nothing.)
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { contractsFixtures, defaultContext, type ScenarioContext } from "./lib.ts";

const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v));
const fixtureThread = (n: number) =>
  JSON.parse(readFileSync(join(contractsFixtures, `threads/thread-${n}.json`), "utf8")).thread;

export const at = (n: number) => new Date(Date.UTC(2026, 9, 1, 12, 0, 0) + n * 1000).toISOString();

export interface Scenario {
  name: string;
  thread: any;
  contexts: Array<{ variant: string; context: ScenarioContext }>;
}

type Payload = Record<string, any>;

/** Chronological builder: every call advances the clock by `step` seconds unless `n` is given. */
export class ThreadBuilder {
  thread: any;
  clock = 0;
  private seq = 0;
  private ids = 0;

  constructor(id: string) {
    const base = clone(fixtureThread(4));
    this.thread = {
      ...base,
      id,
      messages: [],
      activities: [],
      checkpoints: [],
      proposedPlans: [],
      latestTurn: null,
      session: null,
    };
  }

  private tick(n?: number) {
    if (n !== undefined) this.clock = n;
    else this.clock += 1;
    return this.clock;
  }

  private nextId(prefix: string) {
    this.ids += 1;
    return `${prefix}-${String(this.ids).padStart(4, "0")}`;
  }

  user(text: string, opts: { id?: string; n?: number; attachments?: any[] } = {}) {
    const n = this.tick(opts.n);
    this.thread.messages.push({
      id: opts.id ?? this.nextId("user"),
      role: "user",
      text,
      ...(opts.attachments ? { attachments: opts.attachments } : {}),
      turnId: null,
      streaming: false,
      createdAt: at(n),
      updatedAt: at(n),
    });
    return this;
  }

  assistant(
    text: string,
    turnId: string | null,
    opts: { id?: string; n?: number; streaming?: boolean; role?: string; end?: number } = {},
  ) {
    const n = this.tick(opts.n);
    this.thread.messages.push({
      id: opts.id ?? this.nextId("assistant"),
      role: opts.role ?? "assistant",
      text,
      turnId,
      streaming: opts.streaming ?? false,
      createdAt: at(n),
      updatedAt: at(opts.end ?? n + 1),
    });
    return this;
  }

  reasoning(
    text: string,
    turnId: string | null,
    opts: { id?: string; n?: number; streaming?: boolean } = {},
  ) {
    return this.assistant(text, turnId, { ...opts, role: "reasoning" });
  }

  act(
    kind: string,
    summary: string,
    payload: Payload,
    opts: { turn?: string | null; tone?: string; n?: number; sequence?: number; id?: string } = {},
  ) {
    const n = this.tick(opts.n);
    this.thread.activities.push({
      id: opts.id ?? this.nextId("act"),
      tone: opts.tone ?? "info",
      kind,
      summary,
      payload,
      turnId: opts.turn ?? null,
      ...(opts.sequence !== undefined ? { sequence: opts.sequence } : {}),
      createdAt: at(n),
    });
    return this;
  }

  /** `tool.started` / `tool.updated` / `tool.completed` in one go. */
  tool(
    itemType: string,
    turn: string,
    opts: {
      id?: string;
      title?: string;
      detail?: string;
      data?: any;
      kinds?: Array<"started" | "updated" | "completed">;
      status?: string;
      noId?: boolean;
      extra?: Payload;
      tone?: string;
      finalStatus?: string;
    } = {},
  ) {
    const id = opts.noId ? undefined : (opts.id ?? this.nextId("toolu"));
    const kinds = opts.kinds ?? ["started", "completed"];
    for (const kind of kinds) {
      const status =
        kind === "completed" ? (opts.finalStatus ?? "completed") : (opts.status ?? "inProgress");
      this.act(
        `tool.${kind}`,
        `${opts.title ?? "Tool call"}${kind === "started" ? " started" : ""}`,
        {
          itemType,
          ...(id ? { toolCallId: id } : {}),
          status,
          ...(opts.title ? { title: opts.title } : {}),
          ...(opts.detail ? { detail: opts.detail } : {}),
          ...(opts.data !== undefined ? { data: opts.data } : {}),
          ...(opts.extra ?? {}),
        },
        { turn, tone: opts.tone ?? "tool" },
      );
    }
    return this;
  }

  checkpoint(
    turnId: string,
    count: number,
    assistantMessageId: string | null,
    files: any[] = [],
    opts: { n?: number } = {},
  ) {
    const n = this.tick(opts.n);
    this.thread.checkpoints.push({
      turnId,
      checkpointTurnCount: count,
      checkpointRef: `refs/t3/checkpoints/x/turn/${count}`,
      status: "ready",
      files,
      assistantMessageId,
      completedAt: at(n),
    });
    return this;
  }

  plan(
    id: string,
    turnId: string | null,
    markdown: string,
    opts: {
      n?: number;
      implementedAt?: string | null;
      implementationThreadId?: string | null;
      updated?: number;
    } = {},
  ) {
    const n = this.tick(opts.n);
    this.thread.proposedPlans.push({
      id,
      turnId,
      planMarkdown: markdown,
      implementedAt: opts.implementedAt ?? null,
      implementationThreadId: opts.implementationThreadId ?? null,
      createdAt: at(n),
      updatedAt: at(opts.updated ?? n),
    });
    return this;
  }

  latestTurn(
    turnId: string,
    state: string,
    opts: {
      requested?: number;
      started?: number | null;
      completed?: number | null;
      assistantMessageId?: string | null;
    } = {},
  ) {
    this.thread.latestTurn = {
      turnId,
      state,
      requestedAt: at(opts.requested ?? this.clock),
      startedAt: opts.started === null ? null : at(opts.started ?? this.clock),
      completedAt:
        opts.completed === null || opts.completed === undefined ? null : at(opts.completed),
      assistantMessageId: opts.assistantMessageId ?? null,
    };
    return this;
  }

  session(status: string, activeTurnId: string | null = null) {
    this.thread.session = {
      threadId: this.thread.id,
      status,
      providerName: "codex",
      providerInstanceId: "codex",
      runtimeMode: "full-access",
      activeTurnId,
      lastError: status === "error" ? "boom" : null,
      updatedAt: at(this.clock),
    };
    return this;
  }
}

const ctx = (patch: Partial<ScenarioContext> = {}): ScenarioContext => ({
  ...defaultContext(),
  ...patch,
});
const single = (variant = "default", patch: Partial<ScenarioContext> = {}) => [
  { variant, context: ctx(patch) },
];

const T1 = "turn-1";
const T2 = "turn-2";
const T3 = "turn-3";

// ---- scenarios ---------------------------------------------------------------------------------

function basicConversation(): Scenario {
  const b = new ThreadBuilder("syn-basic");
  b.user("Hello", { id: "u1" });
  b.assistant("Hi there", T1, { id: "a1" });
  b.checkpoint(T1, 1, "a1", [{ path: "src/a.ts", kind: "modified", additions: 3, deletions: 1 }]);
  b.user("Thanks, now fix the bug", { id: "u2" });
  b.assistant("Working on it", T2, { id: "a2-commentary" });
  b.assistant("Done, bug fixed", T2, { id: "a2" });
  b.checkpoint(T2, 2, "a2", [
    { path: "src/b.ts", kind: "modified", additions: 10, deletions: 2 },
    { path: "docs/readme.md", kind: "added", additions: 4, deletions: 0 },
  ]);
  b.latestTurn(T2, "completed", { started: 5, completed: 9, assistantMessageId: "a2" });
  b.session("ready");
  return {
    name: "basic-conversation",
    thread: b.thread,
    contexts: [
      ...single(),
      { variant: "rollback", context: ctx({ supportsConversationRollback: true }) },
      {
        variant: "queued",
        context: ctx({
          queuedMessages: [
            { id: "q1", createdAt: at(30), text: "later" },
            { id: "q2", createdAt: at(31), text: "later 2" },
          ],
        }),
      },
    ],
  };
}

function commandTools(): Scenario {
  const b = new ThreadBuilder("syn-commands");
  b.user("Run some commands", { id: "u1" });
  b.assistant("On it.", T1, { id: "a1-pre" });
  // codex style: command in item, output in aggregatedOutput, exit marker in detail
  b.tool("command_execution", T1, {
    id: "c-ok",
    title: "Ran command",
    detail: "/bin/zsh -lc 'git status --short' <exited with exit code 0>",
    data: {
      item: {
        command: "/bin/zsh -lc 'git status --short'",
        aggregatedOutput: " M src/a.ts\n<exited with exit code 0>",
      },
    },
  });
  // failed status
  b.tool("command_execution", T1, {
    id: "c-fail",
    title: "Ran command",
    detail: 'bash -lc "cat nope.txt"',
    data: {
      item: {
        command: ["bash", "-lc", "cat nope.txt"],
        aggregatedOutput: "cat: nope.txt: No such file or directory",
      },
    },
    finalStatus: "failed",
  });
  // completed status but failing output (heuristic)
  b.tool("command_execution", T1, {
    id: "c-heuristic",
    title: "Ran command",
    detail: "zsh: command not found: foo",
    data: { item: { command: "foo --bar" } },
  });
  // array command with quoting; powershell wrapper
  b.tool("command_execution", T1, {
    id: "c-array",
    title: "Terminal",
    data: { item: { command: ["rg", "-n", "hello world", "src dir/"] } },
  });
  b.tool("command_execution", T1, {
    id: "c-ps",
    title: "Ran command",
    data: {
      item: { command: 'powershell.exe -Command "Get-ChildItem -Recurse"' },
      rawOutput: { stdout: "a\nb" },
    },
  });
  // legacy rows without toolCallId collapse by label
  b.tool("command_execution", T1, {
    noId: true,
    title: "Ran command",
    detail: "npm test",
    kinds: ["started", "updated", "completed"],
    data: {},
  });
  // claude style: toolName + detail "Bash: {...}" echo of the command
  b.tool("command_execution", T1, {
    id: "c-claude",
    title: "Bash",
    detail: "Bash: ls -la",
    data: { toolName: "Bash", input: { command: "ls -la" }, toolCallId: "c-claude" },
    kinds: ["started", "updated", "completed"],
  });
  // acp style
  b.tool("command_execution", T1, {
    id: "c-acp",
    title: "Terminal",
    data: {
      kind: "execute",
      rawInput: { command: "pwd" },
      content: [{ type: "content", content: { text: "/tmp" } }],
      toolCallId: "c-acp",
    },
  });
  b.assistant("All done.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 2, completed: 40, assistantMessageId: "a1" });
  b.session("ready");
  return {
    name: "command-tools",
    thread: b.thread,
    contexts: [
      ...single(),
      { variant: "fold-open", context: ctx({ expandedTurnIds: [T1] }) },
      {
        variant: "fold-open-groups-open",
        context: ctx({
          expandedTurnIds: [T1],
          expandedWorkGroupIds: [
            "work-group:tool:turn-1:c-ok",
            "work-group:tool:turn-1:c-fail",
            "work-group:tool:turn-1:c-heuristic",
          ],
        }),
      },
    ],
  };
}

function mixedTools(): Scenario {
  const b = new ThreadBuilder("syn-mixed-tools");
  b.user("Use every tool", { id: "u1" });
  b.tool("file_change", T1, {
    id: "fc1",
    title: "File change",
    data: {
      files: [{ path: "/w/src/a.ts" }, { path: "/w/src/b.ts" }],
      changes: [{ path: "/w/src/a.ts" }, { newPath: "/w/src/c.ts", oldPath: "/w/src/old.ts" }],
    },
  });
  b.tool("file_change", T1, {
    id: "fc2",
    title: "File change",
    detail: 'Edit: {"file_path":"/w/README.md"}',
    data: { toolName: "Edit", input: { file_path: "/w/README.md" } },
  });
  b.tool("mcp_tool_call", T1, {
    id: "m1",
    title: "mempalace · mempalace_status",
    data: {
      item: {
        type: "mcpToolCall",
        tool: "mempalace_status",
        server: "mempalace",
        status: "completed",
        arguments: {},
        error: null,
      },
    },
  });
  b.tool("mcp_tool_call", T1, {
    id: "m2",
    title: "t3-code · link_pull_request",
    data: {
      item: {
        tool: "link_pull_request",
        server: "t3-code",
        arguments: { url: "https://github.com/acme/app/pull/42" },
      },
    },
  });
  b.tool("mcp_tool_call", T1, {
    id: "m3",
    title: "mcp__t3-code__list_thread_pull_requests",
    data: { toolName: "mcp__t3-code__list_thread_pull_requests", input: {} },
  });
  b.tool("mcp_tool_call", T1, {
    id: "m4",
    title: "mcp__t3-code__preview_open",
    data: { toolName: "mcp__t3-code__preview_open", input: { url: "http://localhost:3000" } },
    extra: {
      toolSurface: "browser",
      toolIcon: {
        _tag: "website",
        pageUrl: "http://Localhost:3000",
        faviconUrl: "http://localhost:3000/favicon.ico",
      },
      toolSource: {
        key: "t3-preview",
        name: "Preview",
        kind: "browser",
        icon: { _tag: "themed-logo", logoUrl: "https://example.com/logo.png" },
      },
    },
  });
  b.tool("mcp_tool_call", T1, {
    id: "m5",
    title: "device_list",
    data: { toolName: "device_list" },
  });
  b.tool("dynamic_tool_call", T1, {
    id: "d1",
    title: "Read file",
    detail: "src/a.ts",
    data: { toolName: "Read" },
  });
  b.tool("dynamic_tool_call", T1, {
    id: "d2",
    title: "Tool call",
    detail: 'ToolSearch: {"query":"select"}',
    data: { toolName: "ToolSearch" },
  });
  b.tool("collab_agent_tool_call", T1, {
    id: "ca1",
    title: "Subagent task",
    detail: "Timeline iOS parity",
    data: { toolName: "Agent" },
    kinds: ["updated", "completed"],
  });
  b.tool("web_search", T1, {
    id: "w1",
    title: "Web search",
    detail: "'swift concurrency'",
    data: {},
  });
  b.tool("web_search", T1, {
    id: "w2",
    title: "grep",
    detail: "TODO",
    data: { rawInput: { pattern: "TODO" } },
  });
  b.tool("web_search", T1, {
    id: "w3",
    title: "Find",
    data: { rawOutput: { totalFiles: 1234, truncated: true } },
  });
  b.tool("image_view", T1, {
    id: "iv1",
    title: "Image view",
    detail: "/w/shots/one.png",
    data: { imagePath: "/w/shots/one.png", toolName: "Read" },
  });
  b.tool("image_view", T1, {
    id: "iv2",
    title: "Image view",
    detail: "docs/two.jpeg",
    data: { files: [{ path: "docs/two.jpeg" }] },
  });
  // review events and plain errors are not tool lifecycle items
  b.tool("review_entered", T1, { id: "re1", title: "Code review started", tone: "info" });
  b.tool("review_exited", T1, { id: "re2", title: "Code review finished", tone: "info" });
  b.act(
    "runtime.error",
    "Runtime error",
    { message: "Provider crashed unexpectedly" },
    { turn: T1, tone: "error" },
  );
  b.act(
    "runtime.warning",
    "Heads up",
    { message: "Something looks odd", detail: { x: 1 } },
    { turn: T1 },
  );
  b.act(
    "runtime.warning",
    "Unknown message (no displayable text content)",
    { message: "x" },
    { turn: T1 },
  );
  b.act(
    "tool.denied",
    "Tool denied: Bash",
    { toolName: "Bash", detail: "blocked by policy" },
    { turn: T1, tone: "error" },
  );
  b.act(
    "provider.turn.start.failed",
    "Failed to start",
    { detail: "no session" },
    { turn: T1, tone: "error" },
  );
  b.act("checkpoint.captured", "Checkpoint captured", { turnCount: 1 }, { turn: T1 });
  b.act("context-window.updated", "Context window updated", { usedTokens: 1 }, { turn: T1 });
  b.assistant("Tried them all.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 1, completed: 60, assistantMessageId: "a1" });
  b.session("ready");
  const groups = [
    "work-group:tool:turn-1:fc1",
    "work-group:tool:turn-1:m1",
    "work-group:tool:turn-1:m4",
    "work-group:tool:turn-1:w1",
  ];
  return {
    name: "mixed-tools",
    thread: b.thread,
    contexts: [
      ...single(),
      { variant: "open", context: ctx({ expandedTurnIds: [T1], expandedWorkGroupIds: groups }) },
    ],
  };
}

function approvals(): Scenario {
  const b = new ThreadBuilder("syn-approvals");
  b.user("Edit files please", { id: "u1" });
  b.act(
    "approval.requested",
    "Command approval requested",
    {
      requestId: "ap1",
      requestKind: "command",
      requestType: "command_execution_approval",
      detail: "rm -rf build",
    },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.resolved",
    "Approval resolved",
    {
      requestId: "ap1",
      requestKind: "command",
      requestType: "command_execution_approval",
      decision: "accept",
    },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "File-change approval requested",
    { requestId: "ap2", requestType: "apply_patch_approval", detail: "src/a.ts" },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "File-read approval requested",
    {
      requestId: "ap3",
      requestKind: "file-read",
      detail: "/etc/hosts",
      options: [
        { decision: "accept", label: "Allow" },
        { decision: "decline", label: "Deny", warning: "careful" },
      ],
    },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "App access",
    { requestId: "ap4", requestType: "mcp_elicitation_approval", appName: "Notes" },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "Permission",
    { requestId: "ap5", requestKind: "permission" },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "Unknown",
    { requestId: "ap6", requestType: "mystery" },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "approval.requested",
    "tool user input shadow",
    { requestId: "ap7", requestType: "tool_user_input" },
    { turn: T1, tone: "approval" },
  );
  b.act(
    "provider.approval.respond.failed",
    "Failed to respond",
    { requestId: "ap2", detail: "Stale pending approval request" },
    { turn: T1, tone: "error" },
  );
  b.act(
    "provider.approval.respond.failed",
    "Failed to respond",
    { requestId: "ap3", detail: "network down" },
    { turn: T1, tone: "error" },
  );
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return {
    name: "approvals",
    thread: b.thread,
    contexts: [...single(), { variant: "idle", context: ctx({ isWorking: false }) }],
  };
}

function userInput(): Scenario {
  const b = new ThreadBuilder("syn-user-input");
  b.user("Ask me something", { id: "u1" });
  const q = (id: string, text: string, options: any[] = []) => ({
    id,
    header: "Question",
    question: text,
    options,
    allowCustomAnswer: true,
    multiSelect: false,
  });
  const opts = [
    { label: "Alpha", description: "first", value: "alpha" },
    { label: "Beta", description: "second" },
  ];
  // answered synchronously
  b.act(
    "user-input.requested",
    "User input requested",
    { requestId: "ui1", questions: [q("q1", "Pick one", opts), q("q2", "Why?")] },
    { turn: T1 },
  );
  b.tool("dynamic_tool_call", T1, {
    id: "qt1",
    title: "AskUserQuestion",
    data: {
      toolName: "AskUserQuestion",
      input: { questions: [{ question: "Pick one" }, { question: "Why?" }] },
    },
  });
  b.act(
    "user-input.answer-submitted",
    "User input submitted",
    {
      requestId: "ui1",
      answers: { q1: "alpha", q2: "because" },
      questionTextById: { q1: "Pick one", q2: "Why?" },
    },
    { turn: T1 },
  );
  b.act(
    "user-input.resolved",
    "User input resolved",
    { requestId: "ui1", answers: { q1: "alpha", q2: "because" } },
    { turn: T1 },
  );
  // async (message mode) answered with an attachment, shown folded
  b.act(
    "user-input.requested",
    "User input requested",
    {
      requestId: "codex-async:t:1",
      questions: [q("0", "Which build?", opts)],
      responseMode: "message",
    },
    { turn: T1 },
  );
  b.act(
    "user-input.resolved",
    "User input submitted",
    { requestId: "codex-async:t:1", responseMode: "message", answers: { "0": "Beta" } },
    { turn: T1 },
  );
  b.user("Beta", { id: "async-answer:codex-async:t:1" });
  // dismissed without an answer
  b.act(
    "user-input.requested",
    "User input requested",
    { requestId: "ui3", questions: [q("a", "Dismiss me?", [])], responseMode: "message" },
    { turn: T1 },
  );
  b.act("user-input.resolved", "User input dismissed", { requestId: "ui3" }, { turn: T1 });
  // still pending
  b.act(
    "user-input.requested",
    "User input requested",
    { requestId: "ui4", questions: [q("z", "Still open", opts), q("y", "Multi", opts)] },
    { turn: T1 },
  );
  // invalid question shapes are skipped
  b.act(
    "user-input.requested",
    "User input requested",
    {
      requestId: "ui5",
      questions: [{ id: "n", header: "h", question: "q", options: [], allowCustomAnswer: false }],
    },
    { turn: T1 },
  );
  b.assistant("Thanks.", T1, { id: "a1" });
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return {
    name: "user-input",
    thread: b.thread,
    contexts: [...single(), { variant: "settled", context: ctx({ isWorking: false }) }],
  };
}

function userInputQuestions(): Scenario {
  const b = new ThreadBuilder("syn-user-input-questions");
  b.user("Questions of every shape", { id: "u1" });
  const opts = [
    { label: "Alpha", description: "first", value: "alpha" },
    { label: "Beta", description: "second" },
    { label: " Gamma ", description: "" },
  ];
  b.act(
    "user-input.requested",
    "Questions",
    {
      requestId: "multi",
      questions: [
        {
          id: "m1",
          header: "Pick several",
          question: "Which ones?",
          options: opts,
          allowCustomAnswer: true,
          multiSelect: true,
        },
        {
          id: "m2",
          header: "Required",
          question: "Choose one",
          options: opts,
          allowCustomAnswer: false,
        },
        {
          id: "m3",
          header: "Free text",
          question: "Anything else?",
          options: [],
          allowCustomAnswer: true,
        },
        {
          id: " m4 ",
          header: "Keys stay raw",
          question: "Spacey",
          options: [
            { label: "x", description: "", value: " raw " },
            { label: "bad", value: 3 },
          ],
          multiSelect: false,
        },
      ],
      responseMode: "message",
    },
    { turn: T1 },
  );
  b.act(
    "user-input.requested",
    "Questions",
    {
      requestId: "single",
      questions: [{ id: "s1", header: "One", question: "Only one", options: opts }],
    },
    { turn: T1 },
  );
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return { name: "user-input-questions", thread: b.thread, contexts: single() };
}

function plans(): Scenario {
  const b = new ThreadBuilder("syn-plans");
  b.user("Plan this", { id: "u1" });
  const planPayload = (steps: Array<[string, string]>, explanation?: string | null) => ({
    plan: steps.map(([step, status]) => ({ step, status })),
    ...(explanation !== undefined ? { explanation } : {}),
  });
  b.act(
    "turn.plan.updated",
    "Plan updated",
    planPayload(
      [
        ["Read code", "inProgress"],
        ["Write code", "pending"],
        ["Test", "pending"],
      ],
      "Initial",
    ),
    { turn: T1, n: 10 },
  );
  b.act(
    "turn.plan.updated",
    "Plan updated",
    planPayload([
      ["Read code", "completed"],
      ["Write code", "inProgress"],
      ["Test", "pending"],
    ]),
    { turn: T1, n: 25 },
  );
  b.act(
    "turn.plan.updated",
    "Plan updated",
    planPayload(
      [
        ["Read code", "completed"],
        ["Write code", "completed"],
        ["Test", "inProgress"],
        ["Test", "pending"],
      ],
      null,
    ),
    { turn: T1, n: 70 },
  );
  b.act(
    "turn.plan.updated",
    "Plan updated",
    planPayload([
      ["Read code", "completed"],
      ["Write code", "completed"],
      ["Test", "completed"],
      ["Test", "completed"],
    ]),
    { turn: T1, n: 100 },
  );
  b.assistant("Plan done", T1, { id: "a1", n: 101 });
  b.plan("plan-1", T1, "# Plan\n- one", { n: 102 });
  b.plan("plan-2", T1, "# Plan v2\n- one\n- two", { n: 103, updated: 110 });
  b.plan("plan-3", null, "# Old plan", {
    n: 5,
    implementedAt: at(50),
    implementationThreadId: "thread-x",
  });
  b.user("Follow up", { id: "u2", n: 120 });
  // a second turn clears the plan (empty plan array) after having one
  b.act("turn.plan.updated", "Plan updated", planPayload([["Later step", "pending"]]), {
    turn: T2,
    n: 121,
  });
  b.act("turn.plan.updated", "Plan cleared", { plan: [] }, { turn: T2, n: 122 });
  b.act("turn.plan.updated", "Plan updated", planPayload([["Fresh", "inProgress"]]), {
    turn: T2,
    n: 123,
  });
  b.assistant("Second turn", T2, { id: "a2", n: 124 });
  b.latestTurn(T2, "completed", { started: 120, completed: 125, assistantMessageId: "a2" });
  b.session("ready");
  const settled = b.thread;
  return {
    name: "plans",
    thread: settled,
    contexts: single(),
  };
}

function plansRunning(): Scenario {
  const b = new ThreadBuilder("syn-plans-running");
  b.user("Plan this", { id: "u1" });
  b.act(
    "turn.plan.updated",
    "Plan updated",
    { plan: [{ step: "Only step", status: "inProgress" }] },
    { turn: T1 },
  );
  b.plan("plan-1", T1, "# Streaming plan");
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return { name: "plans-running", thread: b.thread, contexts: single() };
}

function compaction(): Scenario {
  const b = new ThreadBuilder("syn-compaction");
  b.user("Long session", { id: "u1" });
  b.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "ls" } },
  });
  b.act(
    "context-compaction",
    "Compacted context 233K → 38.4K tokens",
    { state: "compacted", beforeTokens: 233402, afterTokens: 38390 },
    { turn: T1 },
  );
  b.tool("command_execution", T1, {
    id: "c2",
    title: "Ran command",
    data: { item: { command: "pwd" } },
  });
  b.assistant("Compacted and continued.", T1, { id: "a1" });
  // a lone compaction in its own turn stays visible when the turn folds
  b.user("Again", { id: "u2" });
  b.act("context-compaction", "Compacted context", { state: "compacted" }, { turn: T2 });
  b.assistant("Fine.", T2, { id: "a2" });
  b.latestTurn(T2, "completed", { started: 20, completed: 30, assistantMessageId: "a2" });
  b.session("ready");
  return {
    name: "compaction",
    thread: b.thread,
    contexts: [...single(), { variant: "open", context: ctx({ expandedTurnIds: [T1, T2] }) }],
  };
}

function revert(): Scenario {
  const b = new ThreadBuilder("syn-revert");
  for (let i = 1; i <= 4; i += 1) {
    const turn = `rv-${i}`;
    b.user(`Request ${i}`, { id: `u${i}` });
    b.assistant(`Answer ${i}`, turn, { id: `a${i}` });
    b.checkpoint(
      turn,
      i,
      `a${i}`,
      i % 2 === 0 ? [{ path: `f${i}.ts`, kind: "modified", additions: i, deletions: 0 }] : [],
    );
  }
  // a user message with no checkpoint, and a trailing user message
  b.user("No checkpoint", { id: "u5" });
  b.assistant("No summary", "rv-5", { id: "a5" });
  b.user("Pending", { id: "u6" });
  b.latestTurn("rv-5", "completed", { started: 20, completed: 25, assistantMessageId: "a5" });
  b.session("ready");
  return {
    name: "revert",
    thread: b.thread,
    contexts: [
      { variant: "rollback", context: ctx({ supportsConversationRollback: true }) },
      ...single(),
    ],
  };
}

function worktreeSetup(): Scenario {
  const b = new ThreadBuilder("syn-worktree");
  b.user("Set up a worktree and go", { id: "u1" });
  const snapshot = (phase: string, stages: Array<[string, string]>, sequence: number) => ({
    threadId: "syn-worktree",
    phase,
    startedAt: at(2),
    endedAt: phase === "running" ? null : at(20),
    branch: "feat/x",
    baseRef: "main",
    worktreePath: "/w/wt",
    setupScript: null,
    stages: stages.map(([id, status]) => ({
      id,
      status,
      startedAt: null,
      endedAt: null,
      percent: null,
      detail: null,
      tail: [],
    })),
    error: null,
    sequence,
  });
  b.act(
    "worktree-setup",
    "Worktree setup",
    snapshot(
      "done",
      [
        ["fetch", "done"],
        ["checkout", "done"],
        ["agent", "done"],
      ],
      3,
    ),
    { turn: null },
  );
  b.act("setup-script.requested", "Setup script requested", { script: "npm i" }, { turn: null });
  b.act("setup-script.started", "Setup script started", {}, { turn: null });
  b.act(
    "setup-script.failed",
    "Setup script failed",
    { detail: "exit 1" },
    { turn: null, tone: "error" },
  );
  b.assistant("Ready.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 10, completed: 12, assistantMessageId: "a1" });
  b.session("ready");
  const running = snapshot(
    "running",
    [
      ["fetch", "done"],
      ["checkout", "running"],
    ],
    2,
  );
  const handedOff = snapshot(
    "running",
    [
      ["fetch", "done"],
      ["agent", "done"],
    ],
    4,
  );
  const failed = snapshot("failed", [["fetch", "failed"]], 5);
  const done = snapshot(
    "done",
    [
      ["fetch", "done"],
      ["agent", "done"],
    ],
    6,
  );
  return {
    name: "worktree-setup",
    thread: b.thread,
    contexts: [
      ...single("none"),
      { variant: "running", context: ctx({ worktreeSetup: running, isWorking: true }) },
      { variant: "handed-off-running", context: ctx({ worktreeSetup: handedOff }) },
      { variant: "failed", context: ctx({ worktreeSetup: failed }) },
      { variant: "done", context: ctx({ worktreeSetup: done }) },
    ],
  };
}

function streaming(): Scenario {
  const b = new ThreadBuilder("syn-streaming");
  b.user("Do work", { id: "u1" });
  b.assistant("Let me look.", T1, { id: "a-comm", streaming: false });
  b.reasoning("thinking about it", T1, { id: "r1" });
  b.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "ls" } },
  });
  b.tool("command_execution", T1, {
    id: "c2",
    title: "Ran command",
    data: { item: { command: "git status" } },
    kinds: ["started"],
  });
  b.assistant("partial answ", T1, { id: "a-stream", streaming: true });
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return {
    name: "streaming",
    thread: b.thread,
    contexts: [
      ...single(),
      {
        variant: "open",
        context: ctx({
          expandedWorkGroupIds: [
            "work-group:tool:turn-1:c2",
            "work-group:tool:turn-1:c1",
            "activity-group:r1",
          ],
        }),
      },
      { variant: "send-pending", context: ctx({ sendStartedAt: at(0) }) },
    ],
  };
}

function streamingTools(): Scenario {
  const b = new ThreadBuilder("syn-streaming-tools");
  b.user("Run tests", { id: "u1" });
  b.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "npm run build" } },
  });
  b.tool("command_execution", T1, {
    id: "c2",
    title: "Ran command",
    data: { item: { command: "npm test" } },
    kinds: ["started"],
  });
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return {
    name: "streaming-tools",
    thread: b.thread,
    contexts: [
      ...single(),
      {
        variant: "open",
        context: ctx({
          expandedWorkGroupIds: ["work-group:tool:turn-1:c1", "work-group:tool:turn-1:c2"],
        }),
      },
    ],
  };
}

function streamingToolFailed(): Scenario {
  const f = new ThreadBuilder("syn-streaming-failed");
  f.user("Run tests", { id: "u1" });
  f.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "npm run build" } },
  });
  f.tool("command_execution", T1, {
    id: "c2",
    title: "Ran command",
    data: { item: { command: "npm test" } },
    finalStatus: "failed",
  });
  f.latestTurn(T1, "running", { started: 1 });
  f.session("running", T1);
  return { name: "streaming-tool-failed", thread: f.thread, contexts: single() };
}

function subagents(): Scenario {
  const b = new ThreadBuilder("syn-subagents");
  b.user("Spawn some agents", { id: "u1" });
  b.assistant("Launching.", T1, { id: "a1-pre" });
  // Claude-style: launch tool row + task rows (agent kind) replace the launch row
  b.tool("collab_agent_tool_call", T1, {
    id: "toolu-launch-1",
    title: "Subagent task",
    detail: "Code: do a thing",
    data: { toolName: "Agent" },
    kinds: ["updated"],
  });
  b.act(
    "task.started",
    "Subagent started",
    { taskId: "t-a", agentKind: "agent", title: "A", role: "coder", toolUseId: "toolu-launch-1" },
    { turn: T1 },
  );
  b.act(
    "task.started",
    "Subagent started",
    { taskId: "t-b", agentKind: "agent", title: "B", role: "reviewer" },
    { turn: T1 },
  );
  b.act(
    "task.progress",
    "A",
    {
      taskId: "t-a",
      agentKind: "agent",
      summary: "reading",
      detail: "reading files",
      role: "coder",
    },
    { turn: T1 },
  );
  b.act(
    "task.updated",
    "Task running",
    { taskId: "t-a", agentKind: "agent", status: "running" },
    { turn: T1 },
  );
  b.act(
    "task.progress",
    "B",
    { taskId: "t-b", agentKind: "agent", summary: "reviewing" },
    { turn: T1 },
  );
  b.tool("command_execution", T1, {
    id: "inner",
    title: "Ran command",
    data: { item: { command: "ls" } },
    extra: { agentId: "t-a" },
  });
  b.act(
    "task.completed",
    "Task completed",
    { taskId: "t-a", agentKind: "agent", status: "completed", summary: "A done" },
    { turn: T1 },
  );
  // workflow with members
  b.act(
    "task.started",
    "Workflow started",
    {
      taskId: "wf-1",
      agentKind: "agent",
      taskType: "local_workflow",
      workflowName: "audit",
      title: "audit",
    },
    { turn: T2 },
  );
  b.act(
    "task.started",
    "member",
    { taskId: "wf-1:wf:m1", agentKind: "agent", title: "m1" },
    { turn: T2 },
  );
  b.act(
    "task.progress",
    "member",
    { taskId: "wf-1:wf:m1", agentKind: "agent", summary: "step" },
    { turn: T2 },
  );
  // background shell tasks stay ordinary rows
  b.act(
    "task.started",
    "local_bash task started",
    {
      taskId: "bg-1",
      taskType: "local_bash",
      detail: "export docs",
      agentKind: "background",
      title: "export docs",
      toolUseId: "toolu-bg",
    },
    { turn: T2 },
  );
  b.act(
    "task.completed",
    "Task completed",
    {
      taskId: "bg-1",
      status: "completed",
      summary: "export docs",
      detail: "export docs",
      agentKind: "background",
      taskType: "local_bash",
    },
    { turn: T2 },
  );
  // codex children: all rows bypass the timeline
  b.act(
    "task.started",
    "child",
    { taskId: "cx-1", agentKind: "agent", timelineBypass: true, title: "child" },
    { turn: T3 },
  );
  b.act(
    "task.progress",
    "child",
    { taskId: "cx-1", agentKind: "agent", timelineBypass: true, summary: "assistant message" },
    { turn: T3 },
  );
  b.act(
    "task.completed",
    "child",
    { taskId: "cx-1", agentKind: "agent", timelineBypass: true, status: "stopped" },
    { turn: T3 },
  );
  b.assistant("Agents running.", T3, { id: "a3" });
  b.latestTurn(T3, "running", { started: 1 });
  b.session("running", T3);
  return {
    name: "subagents",
    thread: b.thread,
    contexts: [
      ...single(),
      { variant: "live-agents", context: ctx({ liveAgentTaskIds: ["t-b", "wf-1"] }) },
      { variant: "settled", context: ctx({ isWorking: false, liveAgentTaskIds: [] }) },
    ],
  };
}

function subagentsSettled(): Scenario {
  const b = new ThreadBuilder("syn-subagents-settled");
  b.user("Spawn some agents", { id: "u1" });
  b.act(
    "task.started",
    "Subagent started",
    { taskId: "t-a", agentKind: "agent", title: "A", role: "coder" },
    { turn: T1 },
  );
  b.act(
    "task.progress",
    "A",
    { taskId: "t-a", agentKind: "agent", summary: "reading" },
    { turn: T1 },
  );
  b.act(
    "task.completed",
    "Task completed",
    { taskId: "t-a", agentKind: "agent", status: "completed", summary: "A done" },
    { turn: T1 },
  );
  b.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "ls" } },
  });
  b.assistant("Agents finished.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 1, completed: 30, assistantMessageId: "a1" });
  b.session("ready");
  return {
    name: "subagents-settled",
    thread: b.thread,
    contexts: [...single(), { variant: "open", context: ctx({ expandedTurnIds: [T1] }) }],
  };
}

function agentsLifecycle(): Scenario {
  const b = new ThreadBuilder("syn-agents-lifecycle");
  b.user("Lots of agents", { id: "u1" });
  const started = (taskId: string, extra: Payload = {}) =>
    b.act("task.started", "start", { taskId, agentKind: "agent", ...extra }, { turn: T1 });
  const updated = (taskId: string, status: string, extra: Payload = {}) =>
    b.act("task.updated", "upd", { taskId, agentKind: "agent", status, ...extra }, { turn: T1 });
  const progress = (taskId: string, extra: Payload = {}) =>
    b.act(
      "task.progress",
      "prog",
      { taskId, agentKind: "agent", summary: "s", ...extra },
      { turn: T1 },
    );
  const completed = (taskId: string, status: string) =>
    b.act(
      "task.completed",
      "done",
      { taskId, agentKind: "agent", status, summary: "x" },
      { turn: T1 },
    );
  started("a-running");
  started("a-waiting");
  updated("a-waiting", "waiting");
  started("a-idle");
  updated("a-idle", "idle");
  started("a-reactivated");
  completed("a-reactivated", "completed");
  updated("a-reactivated", "running");
  started("a-failed");
  completed("a-failed", "failed");
  started("a-stopped");
  completed("a-stopped", "stopped");
  started("a-cancelled");
  updated("a-cancelled", "cancelled");
  started("a-late-start");
  completed("a-late-start", "completed");
  started("a-late-start");
  updated("a-first-terminal", "failed");
  started("a-first-terminal");
  progress("a-progress-first");
  progress("a-usage-snapshot", { usageSnapshot: true });
  started("a-idle-progress");
  updated("a-idle-progress", "idle");
  progress("a-idle-progress");
  started("a-idle-start");
  updated("a-idle-start", "idle");
  started("a-idle-start");
  started("a-pending");
  updated("a-pending", "pending");
  // batch + workflow with a cascade: the coordinator settles, its members never reported back
  started("wf-9", { taskType: "local_workflow", workflowName: "w" });
  started("wf-9:wf:one", { parentAgentId: "wf-9" });
  started("wf-9:wf:two", { parentAgentId: "wf-9" });
  updated("wf-9:wf:two", "idle");
  started("wf-9:wf:three", { parentAgentId: "wf-9" });
  completed("wf-9:wf:three", "failed");
  completed("wf-9", "failed");
  started("wf-10", { taskType: "local_workflow" });
  started("wf-10:wf:one", { parentAgentId: "wf-10" });
  started("batch-1", { taskType: "subagent_batch" });
  updated("batch-1", "idle", { taskType: "subagent_batch" });
  // background work and tool heartbeats
  b.act(
    "task.started",
    "bg",
    { taskId: "bg-5", agentKind: "background", taskType: "local_bash" },
    { turn: T1 },
  );
  b.act("tool.progress", "hb", { taskId: "a-running", toolName: "Read" }, { turn: T1 });
  b.act("task.started", "no id", { agentKind: "agent" }, { turn: T1 });
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return {
    name: "agents-lifecycle",
    thread: b.thread,
    contexts: single(),
  };
}

function agentsDead(): Scenario {
  const s = agentsLifecycle();
  const thread = clone(s.thread);
  thread.id = "syn-agents-dead";
  thread.session = { ...thread.session, status: "stopped", activeTurnId: null };
  return { name: "agents-dead-session", thread, contexts: single() };
}

function agentsMany(): Scenario {
  const b = new ThreadBuilder("syn-agents-many");
  b.user("A fleet", { id: "u1" });
  for (let i = 0; i < 130; i += 1) {
    const taskId = `fleet-${String(i).padStart(3, "0")}`;
    b.act("task.started", "start", { taskId, agentKind: "agent", title: taskId }, { turn: T1 });
    if (i % 3 === 0)
      b.act(
        "task.completed",
        "done",
        { taskId, agentKind: "agent", status: "completed", summary: "ok" },
        { turn: T1 },
      );
    else if (i % 7 === 0)
      b.act("task.updated", "idle", { taskId, agentKind: "agent", status: "idle" }, { turn: T1 });
  }
  b.latestTurn(T1, "running", { started: 1 });
  b.session("running", T1);
  return { name: "agents-many", thread: b.thread, contexts: single() };
}

function diffTrees(): Scenario {
  const b = new ThreadBuilder("syn-diff-trees");
  b.user("Change lots of files", { id: "u1" });
  b.assistant("Changed.", T1, { id: "a1" });
  const f = (path: string, additions: number, deletions: number, kind = "modified") => ({
    path,
    kind,
    additions,
    deletions,
  });
  b.checkpoint(T1, 1, "a1", [
    f("src/components/chat/MessagesTimeline.tsx", 10, 2),
    f("src/components/chat/MessagesTimeline.logic.ts", 30, 4),
    f("src/components/ui/button.tsx", 1, 1),
    f("src/lib/a/b/c/deep.ts", 5, 0, "added"),
    f("src\\win\\path.ts", 2, 2),
    f("docs/File10.md", 1, 0),
    f("docs/file2.md", 1, 0),
    f("docs/File1.md", 1, 0),
    f("docs/Readme.md", 3, 3),
    f("README.md", 0, 9, "deleted"),
    f("zeta.txt", 0, 0),
    f("a-b/c_d/e.ts", 1, 1),
    f("a.b/x.ts", 1, 1),
    f("/abs/leading/slash.ts", 4, 4),
  ]);
  b.latestTurn(T1, "completed", { started: 1, completed: 5, assistantMessageId: "a1" });
  b.session("ready");
  return { name: "diff-trees", thread: b.thread, contexts: single() };
}

function folds(): Scenario {
  const b = new ThreadBuilder("syn-folds");
  // turn 1: commentary, tools, final answer, trailing single tool
  b.user("First", { id: "u1", n: 0 });
  b.assistant("Looking.", T1, { id: "a1-c", n: 1 });
  b.tool("command_execution", T1, {
    id: "f1c1",
    title: "Ran command",
    data: { item: { command: "ls" } },
  });
  b.reasoning("hmm", T1, { id: "f1r" });
  b.assistant("Final one.", T1, { id: "a1", n: 10, end: 12 });
  b.tool("command_execution", T1, {
    id: "f1c2",
    title: "Ran command",
    data: { item: { command: "git log" } },
  });
  // turn 2: interrupted by the user
  b.user("Second", { id: "u2", n: 20 });
  b.assistant("Partial thought.", T2, { id: "a2-c", n: 21 });
  b.tool("command_execution", T2, {
    id: "f2c1",
    title: "Ran command",
    data: { item: { command: "sleep 100" } },
    finalStatus: "stopped",
  });
  // turn 3: trailing group of two tools after the answer, one of which failed
  b.user("Third", { id: "u3", n: 40 });
  b.tool("command_execution", T3, {
    id: "f3c1",
    title: "Ran command",
    data: { item: { command: "make" } },
  });
  b.assistant("Answer three.", T3, { id: "a3", n: 45 });
  b.tool("command_execution", T3, {
    id: "f3c2",
    title: "Ran command",
    data: { item: { command: "make test" } },
    finalStatus: "failed",
  });
  b.tool("command_execution", T3, {
    id: "f3c3",
    title: "Ran command",
    data: { item: { command: "make lint" } },
  });
  b.checkpoint(T3, 3, "a3", [{ path: "Makefile", kind: "modified", additions: 1, deletions: 1 }]);
  b.latestTurn(T3, "completed", { started: 40, completed: 60, assistantMessageId: "a3" });
  b.session("ready");
  return {
    name: "folds",
    thread: b.thread,
    contexts: [
      ...single(),
      { variant: "rollback", context: ctx({ supportsConversationRollback: true }) },
      { variant: "open-all", context: ctx({ expandedTurnIds: [T1, T2, T3] }) },
    ],
  };
}

function foldsInterrupted(): Scenario {
  const b = new ThreadBuilder("syn-folds-interrupted");
  b.user("Second", { id: "u2", n: 20 });
  b.assistant("Partial thought.", T2, { id: "a2-c", n: 21 });
  b.tool("command_execution", T2, {
    id: "f2c1",
    title: "Ran command",
    data: { item: { command: "sleep 100" } },
    finalStatus: "stopped",
  });
  b.assistant("Cut short.", T2, { id: "a2", n: 30 });
  b.latestTurn(T2, "interrupted", { started: 20, completed: 31, assistantMessageId: "a2" });
  b.session("interrupted");
  return { name: "folds-interrupted", thread: b.thread, contexts: single() };
}

function steer(): Scenario {
  // a promptless provider restart: two provider turns after one user message while working
  const b = new ThreadBuilder("syn-steer");
  b.user("Do the thing", { id: "u1", n: 0 });
  b.assistant("First attempt", T1, { id: "a1", n: 2 });
  b.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "ls" } },
  });
  b.assistant("Second attempt", T2, { id: "a2", n: 10 });
  b.tool("command_execution", T2, {
    id: "c2",
    title: "Ran command",
    data: { item: { command: "pwd" } },
    kinds: ["started"],
  });
  b.latestTurn(T2, "running", { started: 9 });
  b.session("running", T2);
  return { name: "steer", thread: b.thread, contexts: single() };
}

function sequences(): Scenario {
  // provider sequence numbers override timestamps; ties fall back to lifecycle rank then id
  const b = new ThreadBuilder("syn-sequences");
  b.user("Order me", { id: "u1" });
  b.act(
    "tool.completed",
    "Ran command",
    {
      itemType: "command_execution",
      toolCallId: "s1",
      status: "completed",
      title: "Ran command",
      data: { item: { command: "echo one" } },
    },
    { turn: T1, tone: "tool", n: 5, sequence: 3 },
  );
  b.act(
    "tool.started",
    "Ran command started",
    {
      itemType: "command_execution",
      toolCallId: "s1",
      status: "inProgress",
      title: "Ran command",
      data: { item: { command: "echo one" } },
    },
    { turn: T1, tone: "tool", n: 6, sequence: 2 },
  );
  b.act(
    "tool.updated",
    "Tool updated",
    { itemType: "command_execution", toolCallId: "s2", data: {} },
    { turn: T1, tone: "tool", n: 4 },
  );
  b.act(
    "tool.completed",
    "Ran command",
    {
      itemType: "command_execution",
      toolCallId: "s2",
      status: "completed",
      title: "Ran command",
      data: { item: { command: "echo two" } },
    },
    { turn: T1, tone: "tool", n: 4, id: "z-late" },
  );
  b.act(
    "tool.started",
    "Ran command started",
    {
      itemType: "command_execution",
      toolCallId: "s2",
      status: "inProgress",
      title: "Ran command",
      data: { item: { command: "echo two" } },
    },
    { turn: T1, tone: "tool", n: 4, id: "a-early" },
  );
  b.act("runtime.warning", "same time warning", { message: "w" }, { turn: T1, n: 4, id: "m-mid" });
  b.assistant("Ordered.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 1, completed: 20, assistantMessageId: "a1" });
  b.session("ready");
  return {
    name: "sequences",
    thread: b.thread,
    contexts: [...single(), { variant: "open", context: ctx({ expandedTurnIds: [T1] }) }],
  };
}

function attachments(): Scenario {
  const b = new ThreadBuilder("syn-attachments");
  b.user("See this", {
    id: "u1",
    attachments: [
      { type: "image", id: "img1", name: "shot.png", mimeType: "image/png", sizeBytes: 100 },
      { type: "file", id: "f1", name: "notes.txt", mimeType: "text/plain", sizeBytes: 10 },
    ],
  });
  b.assistant("Seen.", T1, { id: "a1" });
  b.latestTurn(T1, "completed", { started: 1, completed: 3, assistantMessageId: "a1" });
  b.session("ready");
  return { name: "attachments", thread: b.thread, contexts: single() };
}

function emptyAndErrors(): Scenario {
  const b = new ThreadBuilder("syn-empty");
  b.latestTurn("t-none", "error", { started: null, completed: null });
  b.session("error");
  return { name: "empty-thread", thread: b.thread, contexts: single() };
}

function errorTurn(): Scenario {
  const e = new ThreadBuilder("syn-error-turn");
  e.user("Crash please", { id: "u1" });
  e.act(
    "runtime.error",
    "Runtime error",
    { message: "Runtime error" },
    { turn: T1, tone: "error" },
  );
  e.act(
    "provider.turn.start.failed",
    "Provider failed",
    { detail: "boom" },
    { turn: T1, tone: "error" },
  );
  e.tool("command_execution", T1, {
    id: "c1",
    title: "Ran command",
    data: { item: { command: "x" } },
    finalStatus: "failed",
  });
  e.latestTurn(T1, "error", { started: 1, completed: 4 });
  e.session("error");
  return {
    name: "error-turn",
    thread: e.thread,
    contexts: [...single(), { variant: "working", context: ctx({ isWorking: true }) }],
  };
}

export function syntheticScenarios(): Scenario[] {
  return [
    basicConversation(),
    commandTools(),
    mixedTools(),
    approvals(),
    userInput(),
    userInputQuestions(),
    plans(),
    plansRunning(),
    compaction(),
    revert(),
    worktreeSetup(),
    streaming(),
    streamingTools(),
    streamingToolFailed(),
    subagents(),
    subagentsSettled(),
    agentsLifecycle(),
    agentsDead(),
    agentsMany(),
    diffTrees(),
    folds(),
    foldsInterrupted(),
    steer(),
    sequences(),
    attachments(),
    emptyAndErrors(),
    errorTurn(),
  ];
}
