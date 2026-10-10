// Orchestration protocol 1 (T3 Code <= 0.0.x servers that predate protocol
// negotiation). Upstream deleted these schemas when orchestration V2 landed, so
// `orchestration.ts` is the verbatim copy from de251fc29 (the merge base of the
// V2 merge) with only its relative imports pointed at the live contracts.
// This file re-declares the V1 RPC and HTTP endpoints that used them; the
// generator emits the result into T3Contracts/GeneratedV1 (namespace `V1`).
// Frozen: do not update to follow upstream.
import * as Schema from "effect/Schema";
import * as Rpc from "effect/rpc/Rpc";
import * as HttpApiEndpoint from "effect/http-api/HttpApiEndpoint";
import * as HttpApiGroup from "effect/http-api/HttpApiGroup";
import { ThreadId, TrimmedNonEmptyString } from "../../../../packages/contracts/src/baseSchemas.ts";
import { EnvironmentAuthorizationError } from "../../../../packages/contracts/src/auth.ts";
import {
  EnvironmentInternalError,
  EnvironmentRequestInvalidError,
  EnvironmentResourceNotFoundError,
  EnvironmentScopeRequiredError,
} from "../../../../packages/contracts/src/environmentHttp.ts";
import * as V1 from "./orchestration.ts";

export * from "./orchestration.ts";

const authz = EnvironmentAuthorizationError;
const rpc = (
  tag: string,
  spec: { input: Schema.Top; output: Schema.Top },
  error: Schema.Top,
  stream = false,
) =>
  Rpc.make(tag, {
    payload: spec.input,
    success: spec.output,
    error: Schema.Union([error, authz]),
    ...(stream ? { stream: true } : {}),
  } as any);

const S = V1.OrchestrationRpcSchemas;
const M = V1.ORCHESTRATION_WS_METHODS;

/** The eight `orchestration.*` RPCs of protocol 1, in their original order. */
export const V1_RPCS = [
  rpc(M.dispatchCommand, S.dispatchCommand, V1.OrchestrationDispatchCommandError),
  rpc(M.getWorkflowScript, S.getWorkflowScript, V1.OrchestrationGetWorkflowScriptError),
  rpc(M.getTurnDiff, S.getTurnDiff, V1.OrchestrationGetTurnDiffError),
  rpc(M.getFullThreadDiff, S.getFullThreadDiff, V1.OrchestrationGetFullThreadDiffError),
  rpc(M.searchThreads, S.searchThreads, V1.OrchestrationSearchThreadsError),
  rpc(M.getArchivedShellSnapshot, S.getArchivedShellSnapshot, V1.OrchestrationGetSnapshotError),
  rpc(M.subscribeShell, S.subscribeShell, V1.OrchestrationGetSnapshotError, true),
  rpc(M.subscribeThread, S.subscribeThread, V1.OrchestrationGetSnapshotError, true),
] as any[];

const snapshotErrors = [EnvironmentScopeRequiredError, EnvironmentInternalError] as const;
const threadSnapshotErrors = [
  EnvironmentScopeRequiredError,
  EnvironmentResourceNotFoundError,
  EnvironmentInternalError,
] as const;
const dispatchErrors = [
  EnvironmentRequestInvalidError,
  EnvironmentScopeRequiredError,
  EnvironmentInternalError,
] as const;

// Query-string window for windowed thread snapshots (GET payloads encode to strings).
const threadSnapshotQuery = {
  reasoningMessages: Schema.optional(Schema.Literal("true")),
  turnLimit: Schema.optional(
    Schema.FiniteFromString.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)),
  ),
  beforeCursor: Schema.optional(TrimmedNonEmptyString),
};

/** The `orchestration` HTTP group of protocol 1 (snapshot, shell, thread, dispatch). */
export const V1_HTTP_GROUP: any = HttpApiGroup.make("orchestration")
  .add(
    HttpApiEndpoint.get("snapshot", "/api/orchestration/snapshot", {
      success: V1.OrchestrationReadModel,
      error: snapshotErrors,
    }),
  )
  .add(
    HttpApiEndpoint.get("shellSnapshot", "/api/orchestration/shell", {
      success: V1.OrchestrationShellSnapshot,
      error: snapshotErrors,
    }),
  )
  .add(
    HttpApiEndpoint.get("threadSnapshot", "/api/orchestration/threads/:threadId", {
      params: Schema.Struct({ threadId: ThreadId }),
      payload: threadSnapshotQuery,
      success: V1.OrchestrationThreadDetailSnapshot,
      error: threadSnapshotErrors,
    }),
  )
  .add(
    HttpApiEndpoint.post("dispatch", "/api/orchestration/dispatch", {
      payload: V1.ClientOrchestrationCommand,
      success: V1.DispatchResult,
      error: dispatchErrors,
    }),
  );
