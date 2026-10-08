// Builds wire-shaped sample JSON for a generated type, straight from the model.
// The TS codec is the oracle: samples it rejects are dropped, the rest are
// decoded and re-encoded by Effect and replayed through the Swift types.
import type { Field, IR, TypeDef, Wire } from "./ir.ts";

export type Mode = "minimal" | "full" | "nulls";

interface State {
  mode: Mode;
  idx: number;
  /** Largest union fan-out seen, so callers know how many indices cover everything. */
  maxFanOut: number;
}

export function makeSampler(types: Map<string, TypeDef>) {
  const pick = (st: State, n: number, depth: number) => {
    st.maxFanOut = Math.max(st.maxFanOut, n);
    return depth > 4 ? 0 : st.idx % n;
  };

  function string(key: string): string {
    if (/url$/i.test(key)) return "https://example.com/a";
    if (/day$/i.test(key)) return "2026-01-01";
    if (/^mimeType$/.test(key)) return "image/png";
    if (/path$/i.test(key)) return "/tmp/sample.png";
    if (/email/i.test(key)) return "a@example.com";
    if (/cwd|root|dir/i.test(key)) return "/tmp/sample";
    return "sample";
  }

  function ir(i: IR, key: string, st: State, depth: number): any {
    switch (i.k) {
      case "string":
        return string(key);
      case "int":
        return Math.max(1, Math.ceil(i.min ?? 1));
      case "double":
        return Math.max(0.5, i.min ?? 0.5);
      case "bool":
        return true;
      case "json":
        return { a: [1, "b", null] };
      case "void":
        return null;
      case "never":
        return null;
      case "empty":
        return {};
      case "iso":
        return "2026-01-01T00:00:00.000Z";
      case "literal":
        return i.value;
      case "array": {
        if (depth > 6) return [];
        const one = wire(i.elem, key, st, depth + 1);
        return i.lossy && st.mode === "full" ? [one, 12345] : [one];
      }
      case "record":
        return depth > 6 ? {} : { k1: wire(i.value, key, st, depth + 1) };
      case "option":
        return { _tag: "Some", value: wire(i.inner, key, st, depth + 1) };
      case "ref":
        return def(types.get(i.name)!, key, st, depth + 1);
    }
  }

  function wire(w: Wire, key: string, st: State, depth: number): any {
    if (w.nullable && st.mode === "nulls") return null;
    return ir(w.ir, key, st, depth);
  }

  function field(f: Field, st: State, depth: number, out: Record<string, any>) {
    // A key is mandatory unless it may be absent on the wire (optional key, default, omitted-on-encode).
    const mandatory = !f.hasDefault && (f.encode === "always" || f.encode === "nullNil");
    if (!mandatory && (st.mode === "minimal" || depth > 6)) return;
    if (f.encode === "never" && st.mode !== "full") return;
    const absent = f.wire.nullable && (st.mode === "nulls" || (mandatory && st.mode === "minimal"));
    out[f.key] = absent
      ? f.wire.ir.k === "option"
        ? { _tag: "None" }
        : null
      : wire(f.wire, f.key, st, depth);
  }

  function def(d: TypeDef, key: string, st: State, depth: number): any {
    switch (d.kind) {
      case "brand":
        return d.raw === "int" ? 1 : d.name === "UsageDay" ? "2026-01-01" : "id-1";
      case "enum": {
        const n = d.cases.length;
        st.maxFanOut = Math.max(st.maxFanOut, n);
        return d.cases[st.idx % n]!.raw;
      }
      case "struct": {
        const out: Record<string, any> = {};
        for (const c of d.consts) out[c.key] = c.value;
        for (const f of d.fields) field(f, st, depth, out);
        return out;
      }
      case "union": {
        const n = d.variants.length;
        let k = pick(st, n, depth);
        if (depth > 4) {
          // Break recursion with the variant that has the fewest fields.
          const size = (v: (typeof d.variants)[number]) =>
            v.ref ? (types.get(v.ref) as any).fields.length : 0;
          k = d.variants.reduce((best, v, i) => (size(v) < size(d.variants[best]!) ? i : best), 0);
        }
        const v = d.variants[k]!;
        if (!v.ref) return { [d.disc]: v.values[0] };
        return def(types.get(v.ref)!, key, st, depth + 1);
      }
      case "untagged": {
        const n = d.members.length;
        return wire(d.members[pick(st, n, depth)]!.wire, key, st, depth + 1);
      }
    }
  }

  /**
   * Samples for one type. A union root gets one sample per variant (nested unions rotate
   * with it); anything else gets two index values. `nulls` fills every nullable with null.
   */
  function samples(name: string) {
    const root = types.get(name)!;
    const fan =
      root.kind === "union"
        ? root.variants.length
        : root.kind === "untagged"
          ? root.members.length
          : 2;
    const out: { mode: Mode; idx: number; input: unknown }[] = [];
    for (const mode of ["minimal", "full", "nulls"] as Mode[]) {
      for (let idx = 0; idx < (mode === "nulls" ? 1 : fan); idx++) {
        out.push({ mode, idx, input: def(root, "", { mode, idx, maxFanOut: 1 }, 0) });
      }
    }
    return out;
  }

  return { samples };
}
