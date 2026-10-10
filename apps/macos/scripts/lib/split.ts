// Splits the protocol-1 model (frozen-v1/) from the current one: which V1 types are shared with
// the current contracts and which are V1's own. Used by the generator and the reference oracle.
import { emitType } from "./swift.ts";
import type { Wire } from "./ir.ts";
import { buildModel } from "./model.ts";

export async function buildBoth() {
  const current = await buildModel("current");
  const frozen = await buildModel("v1");
  const { builder, roots } = current;
  const reach = builder.reachable(roots);
  // A V1 type identical to the current one (same Swift text, and so are all its
  // dependencies) is shared: V1 code refers to it by its plain name. Everything
  // else is emitted inside `extension V1`, where it shadows the current name.
  const v1Builder = frozen.builder;
  // Anonymous enums are named after whichever field met them first, so the same value set can carry
  // different names in the two models; fold V1's into the current one (cases are identical).
  const enumSig = (d: any) => d.cases.map((c: any) => c.raw).join("\u0000");
  const currentEnums = new Map<string, string | null>();
  for (const n of reach) {
    const d = builder.types.get(n)!;
    if (d.kind === "enum") currentEnums.set(enumSig(d), currentEnums.has(enumSig(d)) ? null : n);
  }
  const foldEnums = new Map<string, string>();
  for (const [n, d] of v1Builder.types) {
    const twin = d.kind === "enum" ? currentEnums.get(enumSig(d)) : undefined;
    if (twin && twin !== n) foldEnums.set(n, twin);
  }
  // Several current enums can share one value set; a same-named struct's same-named field says which.
  const enumRef = (w: Wire): string | undefined => {
    const ir = w.ir;
    return ir.k === "ref"
      ? ir.name
      : ir.k === "array"
        ? enumRef(ir.elem)
        : ir.k === "option"
          ? enumRef(ir.inner)
          : undefined;
  };
  for (const [n, d] of v1Builder.types) {
    const cur = builder.types.get(n);
    if (d.kind !== "struct" || cur?.kind !== "struct") continue;
    for (const f of d.fields) {
      const a = enumRef(f.wire);
      const b = enumRef(cur.fields.find((g) => g.key === f.key)?.wire ?? f.wire);
      const da = a ? v1Builder.types.get(a) : undefined;
      const db = b ? builder.types.get(b) : undefined;
      if (
        a &&
        b &&
        da?.kind === "enum" &&
        db?.kind === "enum" &&
        enumSig(da) === enumSig(db) &&
        a !== b
      )
        foldEnums.set(a, b);
    }
  }
  v1Builder.renameTypes(foldEnums);
  const renameWire = (w: Wire | null) => {
    const ir = w?.ir;
    if (!ir) return;
    if (ir.k === "ref") ir.name = foldEnums.get(ir.name) ?? ir.name;
    else if (ir.k === "array") renameWire(ir.elem);
    else if (ir.k === "record") renameWire(ir.value);
    else if (ir.k === "option") renameWire(ir.inner);
  };
  for (const r of frozen.rpcs) [r.payload, r.success].forEach(renameWire);
  for (const h of frozen.https) [h.params, h.query, h.payload, h.success].forEach(renameWire);
  frozen.roots.forEach(renameWire);
  const v1Reach = v1Builder.reachable(frozen.roots);
  for (const n of [...v1Reach]) if (!v1Builder.types.has(n)) v1Reach.delete(n);
  const sameAsCurrent = (name: string) =>
    reach.has(name) && emitType(v1Builder.types.get(name)!) === emitType(builder.types.get(name)!);
  const v1Own = new Set([...v1Reach].filter((n) => !sameAsCurrent(n)));
  for (let grew = true; grew;) {
    grew = false;
    for (const n of v1Reach)
      if (!v1Own.has(n) && v1Builder.depsOf(n).some((d) => v1Own.has(d))) {
        v1Own.add(n);
        grew = true;
      }
  }
  return { current, frozen, reach, v1Reach, v1Own };
}
