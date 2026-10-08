// Records raw, read-only server payloads for contract tests. The output contains
// private conversation data: it must stay under /private/tmp (the default) and
// is turned into committed fixtures only by sanitize-fixtures.ts.
//
//   node apps/macos/scripts/record-fixtures.ts [--base-url URL] [--token-file PATH] [--out DIR] [--listen-ms N]
//
// Only GET endpoints and read-only RPCs are used. No command is ever dispatched.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ARTIFACT = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78";
const arg = (name: string, fallback: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1]! : fallback;
};
const baseUrl = arg("base-url", "http://localhost:13773");
const tokenFile = arg("token-file", `${ARTIFACT}/devserver/dev-token`);
const out = arg("out", `${ARTIFACT}/stageA-contracts/tmp/raw`);
const listenMs = Number(arg("listen-ms", "3000"));
if (!out.startsWith("/private/tmp/"))
  throw new Error("Refusing to write raw recordings outside /private/tmp");

mkdirSync(join(out, "threads"), { recursive: true });
mkdirSync(join(out, "rpc"), { recursive: true });
const save = (file: string, value: unknown) =>
  writeFileSync(join(out, file), JSON.stringify(value));

// ---- auth (the token is never printed or stored) -------------------------------------------
const bootstrap = readFileSync(tokenFile, "utf8").trim();
const tokenResponse = await fetch(`${baseUrl}/oauth/token`, {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: bootstrap,
    subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
  }),
});
if (!tokenResponse.ok) throw new Error(`token exchange failed: ${tokenResponse.status}`);
const tokenBody: any = await tokenResponse.json();
save(
  "token-response-shape.json",
  Object.fromEntries(
    Object.entries(tokenBody).map(([k, v]) => [
      k,
      typeof v === "string" && k.includes("token") ? "<redacted>" : v,
    ]),
  ),
);
const bearer = { authorization: `Bearer ${tokenBody.access_token}` };

const get = async (path: string) => {
  const r = await fetch(`${baseUrl}${path}`, { headers: bearer });
  if (!r.ok) throw new Error(`GET ${path} -> ${r.status}`);
  return r.json();
};

// ---- HTTP -----------------------------------------------------------------------------------------
save("descriptor.json", await get("/.well-known/t3/environment"));
const shell: any = await get("/api/orchestration/shell");
save("shell.json", shell);
save("session.json", await get("/api/auth/session"));
const threads: any[] = shell.threads ?? [];
for (const t of threads)
  save(`threads/${t.id}.json`, await get(`/api/orchestration/threads/${t.id}`));
console.log(`http: shell + ${threads.length} thread snapshots`);

// ---- WebSocket RPC (JSON serialization, one request per connection call) --------------------------
const ticket: any = await (
  await fetch(`${baseUrl}/api/auth/websocket-ticket`, { method: "POST", headers: bearer })
).json();
const wsUrl = `${baseUrl.replace(/^http/, "ws")}/ws?wsTicket=${encodeURIComponent(ticket.ticket)}`;

async function rpc(tag: string, payload: unknown, file: string, stream: boolean) {
  const ws = new WebSocket(wsUrl);
  const messages: unknown[] = [];
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error(`websocket failed for ${tag}`));
  });
  const done = new Promise<void>((resolve) => {
    ws.onmessage = (ev) => {
      const parsed = JSON.parse(String(ev.data));
      for (const m of Array.isArray(parsed) ? parsed : [parsed]) {
        if (m._tag === "Ping") continue;
        messages.push(m);
        if (m._tag === "Chunk") ws.send(JSON.stringify({ _tag: "Ack", requestId: m.requestId }));
        if (m._tag === "Exit") resolve();
      }
    };
  });
  ws.send(JSON.stringify({ _tag: "Request", id: "1", tag, payload, headers: [] }));
  await Promise.race([done, new Promise((r) => setTimeout(r, stream ? listenMs : 15000))]);
  if (stream) ws.send(JSON.stringify({ _tag: "Interrupt", requestId: "1", interruptors: [] }));
  ws.close();
  save(`rpc/${file}.json`, messages);
  const chunks = messages.filter((m: any) => m._tag === "Chunk").length;
  console.log(`rpc ${tag}: ${messages.length} messages (${chunks} chunks)`);
}

await rpc("server.getConfig", {}, "server.getConfig", false);
await rpc("server.getSettings", {}, "server.getSettings", false);
await rpc("subscribeServerConfig", {}, "subscribeServerConfig", true);
await rpc("orchestration.subscribeShell", {}, "orchestration.subscribeShell", true);
await rpc(
  "orchestration.getArchivedShellSnapshot",
  {},
  "orchestration.getArchivedShellSnapshot",
  false,
);
// A handful of threads, spread by size, so the chunk samples are diverse.
const bySize = threads.slice().sort((a, b) => (a.messageCount ?? 0) - (b.messageCount ?? 0));
const picks = [0, 0.25, 0.5, 0.75, 1]
  .map((q) => bySize[Math.min(bySize.length - 1, Math.floor(q * bySize.length))])
  .filter(Boolean);
for (const [i, t] of picks.entries()) {
  await rpc(
    "orchestration.subscribeThread",
    { threadId: t.id, reasoningMessages: true },
    `orchestration.subscribeThread-${i}`,
    true,
  );
}
// Catch-up replays (afterSequence) are the only way to get event frames without dispatching commands.
const replayFrom = Math.max(0, shell.snapshotSequence - 400);
await rpc(
  "orchestration.subscribeShell",
  { afterSequence: replayFrom, requestCompletionMarker: true },
  "orchestration.subscribeShell-replay",
  true,
);
for (const [i, t] of picks.entries()) {
  const snap: any = JSON.parse(readFileSync(join(out, "threads", `${t.id}.json`), "utf8"));
  await rpc(
    "orchestration.subscribeThread",
    {
      threadId: t.id,
      reasoningMessages: true,
      afterSequence: Math.max(0, snap.snapshotSequence - 400),
      requestCompletionMarker: true,
    },
    `orchestration.subscribeThread-replay-${i}`,
    true,
  );
}
// Wider replay over every thread, for the opt-in corpus decode test.
for (const t of threads) {
  const snap: any = JSON.parse(readFileSync(join(out, "threads", `${t.id}.json`), "utf8"));
  await rpc(
    "orchestration.subscribeThread",
    {
      threadId: t.id,
      reasoningMessages: true,
      afterSequence: Math.max(0, snap.snapshotSequence - 1500),
    },
    `orchestration.subscribeThread-replayall-${t.id}`,
    true,
  );
}
console.log("done");
