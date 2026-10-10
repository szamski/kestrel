// Stands in for `effect/Schema` while the generator loads the contracts. Effect
// 4.0.1 erased `Schema.brand` at runtime (same AST, type-level only), but the
// generator needs brands to emit `ThreadId`, `ProviderInstanceId`, ... as
// distinct Swift types. This brand adds the marker the IR reads (`brands` on the
// last check), like earlier Effect builds did. Never imported by shipped code.
import * as Schema from "SCHEMA_URL";

export * from "SCHEMA_URL";

export function brand(identifier: string) {
  return (schema: any) => {
    const previous: string[] = schema.ast.checks?.at(-1)?.annotations?.brands ?? [];
    return schema.check(Schema.makeFilter(() => true, { brands: [...previous, identifier] }));
  };
}
