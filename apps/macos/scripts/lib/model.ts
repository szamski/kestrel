// Builds the full generator model: schema roots (RPCs, HTTP API, extra
// exports) -> Builder IR. No Swift text is produced here.
import { Builder, type Wire } from "./ir.ts";
import { loadContracts, loadFrozenV1, loadModuleExports, loadRuntime } from "./load.ts";
import { pascal, typeName } from "./names.ts";

/** Exports that must be generated even when no RPC reaches them (brief, section 2). */
const EXTRA_ROOTS = [
  "ServerConfig",
  "ServerSettings",
  "ClientSettingsSchema",
  "OrchestrationV2DomainEvent",
  "OrchestrationV2Command",
  "OrchestrationV2ShellSnapshot",
  "OrchestrationV2ShellStreamItem",
  "OrchestrationV2ThreadStreamItem",
  "OrchestrationV2ThreadDetailSnapshot",
  "OrchestrationV2ThreadBoundedSnapshot",
  "OrchestrationV2ThreadHistoryPage",
  "OrchestrationV2ThreadProjection",
  "ExecutionEnvironmentDescriptor",
];
/**
 * Structs the contracts reuse inside forward-compatible wrappers (`Schema.toType` rebuilds the
 * nested AST, so it no longer matches the export by identity). Their rebuilt copies fold back into
 * the export, which keeps these Swift names (and the code using them) stable. Other nested
 * structs keep their positional names, e.g. `ServerConfigProvidersItem`.
 */
const NESTED_EXPORTS = [
  "KeybindingShortcut",
  "PullRequestContextMetadata",
  "ElementContextDetails",
  "ElementContextRecord",
  "FileContextRecord",
  "ImageContextRecord",
  "MentionContextRecord",
  "SkillContextRecord",
  "TerminalContextRecord",
  "ModelCapabilities",
  "ProviderAuthMethod",
  "ProviderOptionChoice",
  "RemoteOpenTarget",
  "ServerProviderContinuation",
  "ServerProviderSlashCommandInput",
  "UsageSource",
  "UsageSourceFingerprint",
];
/** Protocol 1 (frozen-v1/): the orchestration surface only; everything else is shared with the current types. */
const V1_EXTRA_ROOTS = [
  "OrchestrationEvent",
  "ClientOrchestrationCommand",
  "OrchestrationShellStreamItem",
  "OrchestrationThreadStreamItem",
  "OrchestrationShellSnapshot",
  "OrchestrationThreadDetailSnapshot",
  "OrchestrationReadModel",
];

export interface RpcModel {
  tag: string;
  fn: string;
  isStream: boolean;
  payload: Wire;
  success: Wire;
  /** Name of the generated failure type (union of tagged errors), or null for `Never`. */
  failure: string | null;
}
export interface HttpModel {
  group: string;
  name: string;
  method: string;
  path: string;
  params: Wire | null;
  query: Wire | null;
  payload: Wire | null;
  payloadContentType: string | null;
  success: Wire;
  failure: string | null;
  errorStatuses: Record<string, number>;
}

/** `v1` models only the frozen protocol-1 orchestration RPCs, HTTP group and roots, resolving shared leaf schemas against the current contracts. */
export async function buildModel(variant: "current" | "v1" = "current") {
  const v1 = variant === "v1";
  const rt = await loadRuntime();
  const contracts = v1 ? await loadFrozenV1() : await loadContracts();
  const modules = await loadModuleExports(v1);
  const { S } = rt;

  // ---- export names -> codec ASTs ------------------------------------------------
  const sources = new Map<string, string>();
  for (const [m, { source }] of modules) sources.set(m, source);
  const defining = (name: string): string => {
    const hits = [...modules.entries()].filter(([, { ns }]) => name in ns).map(([m]) => m);
    const own = hits.find((m) =>
      new RegExp(`export (?:const|class|function) ${name}\\b`).test(sources.get(m)!),
    );
    return own ?? hits[0] ?? "";
  };
  const codecOf = (schema: any) => S.toCodecJson(schema).ast;
  const candidates = new Map<any, string[]>();
  const moduleByName = new Map<string, string>();
  for (const [mod, { ns }] of modules) {
    for (const [name, value] of Object.entries<any>(ns)) {
      if (!S.isSchema(value)) continue;
      const tag = value.ast._tag;
      if (
        tag === "String" ||
        tag === "Number" ||
        tag === "Boolean" ||
        tag === "Unknown" ||
        tag === "Arrays"
      )
        continue;
      let ast: any;
      try {
        ast = codecOf(value);
      } catch {
        continue;
      }
      const list = candidates.get(ast) ?? [];
      if (!list.includes(name)) list.push(name);
      candidates.set(ast, list);
      if (!moduleByName.has(name)) moduleByName.set(name, defining(name) || mod);
    }
  }
  // `export const B = A.check(...)` shares A's codec AST; the original keeps the name.
  const isAlias = (n: string, list: string[]) => {
    const m = new RegExp(`export const ${n}\\s*=\\s*(\\w+)\\b`).exec(
      sources.get(moduleByName.get(n) ?? "") ?? "",
    );
    return m !== null && m[1] !== n && list.includes(m[1]!);
  };
  const exportNames = new Map<any, string>();
  for (const [ast, list] of candidates) {
    const rank = (n: string) =>
      [isAlias(n, list) ? 1 : 0, /Schema$/.test(n) ? 1 : 0, n.length, n] as const;
    list.sort((a, b) => {
      const ra = rank(a);
      const rb = rank(b);
      return ra[0] - rb[0] || ra[1] - rb[1] || ra[2] - rb[2] || (ra[3] < rb[3] ? -1 : 1);
    });
    exportNames.set(ast, list[0]!);
  }
  const moduleOfType = new Map<string, string>();
  for (const [n, m] of moduleByName) moduleOfType.set(typeName(n), m);

  // ---- IsoDateTime keys (the schema is a bare Schema.String, so scan the source) --
  const isoKeys = new Set<string>();
  const isoRe = /^\s*(\w+):\s*(?:Schema\.\w+\(\s*)*IsoDateTime\b/;
  for (const src of sources.values())
    for (const line of src.split("\n")) {
      const m = isoRe.exec(line);
      if (m) isoKeys.add(m[1]!);
    }

  const builder = new Builder(
    rt,
    exportNames,
    (n) => moduleOfType.get(n) ?? "",
    isoKeys,
    NESTED_EXPORTS,
  );
  const roots: Wire[] = [];
  const track = (w: Wire) => (roots.push(w), w);

  // ---- RPC group -------------------------------------------------------------------
  const failureFor = (schema: any, hint: string): string | null => {
    const ast = codecOf(schema);
    if (ast._tag === "Never") return null;
    const w = track(builder.root(ast, hint, "rpc"));
    if (w.ir.k !== "ref") throw new Error(`Failure of ${hint} is not a tagged type`);
    const name = builder.asFailure(w.ir.name, hint);
    track({ ir: { k: "ref", name }, nullable: false });
    return name;
  };
  const rpcs: RpcModel[] = [];
  const group: any[] = v1 ? contracts.V1_RPCS : [...contracts.WsRpcGroup.requests.values()];
  for (const rpc of group) {
    const tag: string = rpc._tag;
    const base = pascal(tag);
    const isStream = !!rpc.successSchema.success;
    const payload = track(builder.root(codecOf(rpc.payloadSchema), `${base}Payload`, "rpc"));
    const successSchema = isStream ? rpc.successSchema.success : rpc.successSchema;
    const success = track(
      builder.root(codecOf(successSchema), isStream ? `${base}Item` : `${base}Success`, "rpc"),
    );
    const errSchema = isStream ? rpc.successSchema.error : rpc.errorSchema;
    const failure = failureFor(errSchema, `${base}Failure`);
    rpcs.push({ tag, fn: tag, isStream, payload, success, failure });
  }

  // ---- HTTP API ----------------------------------------------------------------------
  const https: HttpModel[] = [];
  const groups: Record<string, any> = v1
    ? { orchestration: contracts.V1_HTTP_GROUP }
    : (contracts.EnvironmentHttpApi as any).groups;
  for (const [group, g] of Object.entries<any>(groups)) {
    // Server-side OAuth endpoints for external MCP agents; they return untagged
    // RFC 6749 errors and are never called by a client.
    if (group === "mcpOAuth") continue;
    for (const [name, e] of Object.entries<any>(g.endpoints)) {
      const hint = `Http${pascal(group)}${pascal(name)}`;
      const wireOf = (schema: any, suffix: string, encoded: boolean): Wire =>
        track(
          builder.root(
            encoded ? S.toEncoded(schema).ast : codecOf(schema),
            `${hint}${suffix}`,
            "environmentHttp",
          ),
        );
      const params = e.params ? wireOf(e.params, "Params", true) : null;
      let query = e.query ? wireOf(e.query, "Query", true) : null;
      let payload: Wire | null = null;
      let payloadContentType: string | null = null;
      if (e.payload && e.payload.size > 0) {
        const [contentType, entry] = [...e.payload.entries()][0] as [string, any];
        const schema = entry.schemas[0];
        if (e.method === "GET") query = wireOf(schema, "Query", true);
        else {
          payloadContentType = contentType;
          payload = wireOf(schema, "Payload", contentType !== "application/json");
        }
      }
      const successEntry = [...(e.success ?? [])][0] as any;
      const success = successEntry
        ? wireOf(successEntry.schema ?? successEntry, "Success", false)
        : track({ ir: { k: "void" }, nullable: false });
      const errs = [...(e.error ?? [])].map((x: any) => x.schema ?? x);
      const errorStatuses: Record<string, number> = {};
      for (const x of errs) {
        const status = x.ast.annotations?.httpApiStatus;
        if (typeof status === "number")
          errorStatuses[x.ast.annotations.identifier ?? x.name] = status;
      }
      const failure = errs.length > 0 ? failureFor(S.Union(errs), `${hint}Failure`) : null;
      https.push({
        group,
        name,
        method: e.method,
        path: e.path,
        params,
        query,
        payload,
        payloadContentType,
        success,
        failure,
        errorStatuses,
      });
    }
  }

  // ---- extra roots ---------------------------------------------------------------------
  const extras: string[] = [];
  for (const name of v1 ? V1_EXTRA_ROOTS : EXTRA_ROOTS) {
    const schema = (contracts as any)[name];
    if (!schema || !S.isSchema(schema))
      throw new Error(`Extra root ${name} is not an exported schema`);
    track(builder.root(codecOf(schema), name, moduleByName.get(name) ?? "rpc"));
    extras.push(name);
  }

  builder.breakCycles();
  return { builder, rpcs, https, roots, extras, rt };
}
