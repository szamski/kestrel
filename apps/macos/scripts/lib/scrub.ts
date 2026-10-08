// Schema-aware redaction for committed fixtures. Structure, ids (branded
// strings), enums, literals, numbers, booleans and timestamps survive; every
// other string (titles, message text, paths, URLs, commands, emails, ...) is
// replaced by a placeholder. Arrays are capped so fixtures stay small.
import type { IR, StructDef, TypeDef, Wire } from "./ir.ts";

const PLACEHOLDER = "redacted";
const MAX_ITEMS = 25;
const identKey = /^[A-Za-z_][A-Za-z0-9_]{0,39}$/;
const uuidKey = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Plain-string fields that act as enums (activity kind, message role, ...) keep their token value. */
const ENUM_KEYS = new Set([
  "kind",
  "type",
  "role",
  "status",
  "state",
  "tone",
  "decision",
  "severity",
  "level",
  "stage",
  "phase",
]);
const token = /^[A-Za-z][A-Za-z0-9_.:-]{0,47}$/;
const enumish = (key: string, v: unknown) =>
  ENUM_KEYS.has(key) && typeof v === "string" && token.test(v);

export function makeScrubber(types: Map<string, TypeDef>) {
  let counter = 0;
  const safeKey = (k: string) => (identKey.test(k) || uuidKey.test(k) ? k : `key-${++counter}`);

  function generic(v: any): any {
    if (typeof v === "string") return PLACEHOLDER;
    if (Array.isArray(v)) return v.slice(0, MAX_ITEMS).map(generic);
    if (v && typeof v === "object") {
      return Object.fromEntries(Object.entries(v).map(([k, x]) => [safeKey(k), generic(x)]));
    }
    return v;
  }

  function struct(def: StructDef, obj: any): any {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return generic(obj);
    const out: Record<string, any> = {};
    for (const [k, v] of Object.entries(obj)) {
      const f = def.fields.find((x) => x.key === k);
      if (f) out[k] = f.wire.ir.k === "string" && enumish(k, v) ? v : wire(f.wire, v);
      else if (def.consts.some((c) => c.key === k)) out[k] = v;
      else out[safeKey(k)] = generic(v);
    }
    return out;
  }

  function ir(i: IR, v: any): any {
    if (v === null || v === undefined) return v;
    switch (i.k) {
      case "string":
        return typeof v === "string" ? PLACEHOLDER : v;
      case "json":
        return generic(v);
      case "array":
        return Array.isArray(v) ? v.slice(0, MAX_ITEMS).map((x) => wire(i.elem, x)) : generic(v);
      case "record":
        return typeof v === "object" && !Array.isArray(v)
          ? Object.fromEntries(
              Object.entries(v)
                .slice(0, MAX_ITEMS)
                .map(([k, x]) => [safeKey(k), wire(i.value, x)]),
            )
          : generic(v);
      case "option":
        return v && typeof v === "object" && "value" in v
          ? { ...v, value: wire(i.inner, v.value) }
          : v;
      case "ref":
        return ref(types.get(i.name)!, v);
      default:
        return v; // iso, int, double, bool, literal, empty, void, never
    }
  }

  function ref(def: TypeDef, v: any): any {
    switch (def.kind) {
      case "brand":
      case "enum":
        return v;
      case "struct":
        return struct(def, v);
      case "union": {
        const tag = v && typeof v === "object" ? v[def.disc] : undefined;
        const variant =
          def.variants.find((x) => x.values.includes(tag)) ??
          (tag === undefined ? def.variants.find((x) => x.missingOk) : undefined);
        const target = variant ? variant.ref : def.fallback?.ref;
        if (variant && !variant.ref) return v;
        if (!target) return generic(v);
        const sd = types.get(target)!;
        return sd.kind === "struct" ? struct(sd, v) : generic(v);
      }
      case "untagged":
        return generic(v);
    }
  }

  function wire(w: Wire, v: any): any {
    return ir(w.ir, v);
  }

  return { wire, generic };
}
