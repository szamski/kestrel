// Walks Effect schema ASTs (the JSON codec form, i.e. what really crosses the
// wire) and builds a small language-neutral model that lib/swift.ts prints.
//
// Rule of thumb: the Type-side AST decides the shape (names, brands, unions);
// the encoding chain only contributes wire facts that change how a key is
// read or written (missing-key defaults, encode-omit behaviour, tolerant
// decoding). Declarations (Option, DateTime.Utc, tagged-error classes, Duration)
// have no JSON shape of their own, so their encoded side is used instead.
// Anything unrecognised throws, so the generator never guesses silently.
import { camel, ident, pascal, typeName } from "./names.ts";

export type IR =
  | { k: "string" | "bool" | "json" | "void" | "never" | "empty" | "iso" }
  /** `min` is the smallest value the schema's checks allow; only used to build valid samples. */
  | { k: "int" | "double"; min?: number }
  | { k: "ref"; name: string }
  | { k: "array"; elem: Wire; lossy: boolean }
  | { k: "record"; value: Wire }
  | { k: "option"; inner: Wire }
  | { k: "literal"; value: string | number | boolean };
export interface Wire {
  ir: IR;
  nullable: boolean;
}
export interface Resolved {
  wire: Wire;
  /** The union carried `Undefined` (key may be missing). */
  undef: boolean;
  /** Wire side is `Unknown`: a value this build cannot decode is dropped, not fatal. */
  lenient: boolean;
}
export type EncodeMode = "always" | "omitNil" | "nullNil" | "never";
export interface Field {
  key: string;
  id: string;
  wire: Wire;
  optional: boolean;
  /** Optional key whose value may also be an explicit null (`T??` in Swift). */
  tri: boolean;
  hasDefault: boolean;
  default?: unknown;
  encode: EncodeMode;
  lenient: boolean;
}
export interface Const {
  key: string;
  value: string | number | boolean;
}
export interface StructDef {
  kind: "struct";
  name: string;
  module: string;
  fields: Field[];
  consts: Const[];
  isError: boolean;
}
export interface EnumDef {
  kind: "enum";
  name: string;
  module: string;
  cases: { raw: string; id: string }[];
}
export interface BrandDef {
  kind: "brand";
  name: string;
  module: string;
  raw: "string" | "int";
}
export interface Variant {
  values: string[];
  id: string;
  /** Struct carrying the payload; null for a variant with nothing but its discriminator. */
  ref: string | null;
  /** Chosen when the discriminator key is absent on the wire (legacy default variant). */
  missingOk: boolean;
}
export interface UnionDef {
  kind: "union";
  name: string;
  module: string;
  disc: string;
  variants: Variant[];
  /** Member without a literal discriminator; tried for tags no variant claims. */
  fallback: { id: string; ref: string } | null;
  indirect: boolean;
  isError: boolean;
}
export interface UntaggedDef {
  kind: "untagged";
  name: string;
  module: string;
  members: { id: string; wire: Wire }[];
}
export type TypeDef = StructDef | EnumDef | BrandDef | UnionDef | UntaggedDef;

export interface RuntimeApi {
  S: any;
  E: any;
  O: any;
  /** `effect/SchemaGetter`: getters are run through `G.run(getter, input, options)`. */
  G: any;
}

const ann = (ast: any) =>
  ast.checks?.length ? ast.checks[ast.checks.length - 1].annotations : ast.annotations;
const lastTo = (ast: any) => ast.encoding[ast.encoding.length - 1].to;
const checkList = (ast: any): any[] =>
  (ast.checks ?? []).flatMap((c: any) => (c.checks ? [c, ...checkList(c)] : [c]));
const isIntCheck = (c: any) =>
  String(c.annotations?.representation?.id ?? "").endsWith("isInt") ||
  c.annotations?.expected === "an integer";

/** Lower bound implied by a number's checks, read from their (stable) `expected` text. */
function minimumOf(checks: any[], isInt: boolean): number | undefined {
  let min: number | undefined;
  for (const c of checks) {
    const text = String(c.annotations?.expected ?? "");
    const num = "(-?\\d+(?:\\.\\d+)?)";
    const between = new RegExp(`between ${num} and`).exec(text);
    const gte = new RegExp(`greater than or equal to ${num}`).exec(text);
    const gt = new RegExp(`greater than ${num}`).exec(text);
    const found = between
      ? Number(between[1])
      : gte
        ? Number(gte[1])
        : gt
          ? Number(gt[1]) + (isInt ? 1 : 0.5)
          : undefined;
    if (found !== undefined && (min === undefined || found > min)) min = found;
  }
  return min;
}

export class Builder {
  types = new Map<string, TypeDef>();
  readonly memo = new Map<any, Resolved>();
  readonly enumBySig = new Map<string, string>();
  readonly jsonFallbacks: string[] = [];
  readonly untagged: string[] = [];
  /** Struct name -> struct reached via Suspend (needs indirection check). */
  readonly suspended = new Set<string>();

  private rt: RuntimeApi;
  private exportNames: Map<any, string>;
  private moduleOf: (name: string) => string;
  private isoKeys: Set<string>;
  private ids = new Map<any, number>();
  /** Union identity = its (non-null) member ASTs; the same union reached via Suspend or `optional()` is one type. */
  private unionByMembers = new Map<string, Resolved>();
  private exportUnionNames = new Map<string, string>();
  /** structKey -> exported struct AST, for nested copies the codec rebuilt (e.g. via `Schema.toType`). */
  private exportStructs = new Map<string, any>();
  /** Exports whose rebuilt nested copies are folded back into them (see model.ts `NESTED_EXPORTS`). */
  private twinNames: Set<string>;

  constructor(
    rt: RuntimeApi,
    exportNames: Map<any, string>,
    moduleOf: (name: string) => string,
    isoKeys: Set<string>,
    twinNames: Iterable<string> = [],
  ) {
    this.rt = rt;
    this.twinNames = new Set(twinNames);
    this.exportNames = exportNames;
    this.moduleOf = moduleOf;
    this.isoKeys = isoKeys;
    // Unions reached through Suspend or `optional()` are rebuilt by the codec, so an exported
    // union is recognised by the shape of its members (props + literals), unless two collide.
    const ambiguous = new Set<string>();
    for (const [ast, name] of [...exportNames].sort((a, b) => (a[1] < b[1] ? -1 : 1))) {
      if (ast._tag !== "Union") continue;
      const rest = this.flatten(ast, false).filter(
        (m) => !["Null", "Undefined", "Never"].includes(m._tag),
      );
      if (rest.length < 2) continue;
      const key = this.shapeKey(rest);
      if (this.exportUnionNames.has(key)) ambiguous.add(key);
      else this.exportUnionNames.set(key, name);
    }
    for (const key of ambiguous) this.exportUnionNames.delete(key);
    const ambiguousStructs = new Set<string>();
    for (const [ast, name] of [...exportNames].sort((a, b) => (a[1] < b[1] ? -1 : 1))) {
      if (!this.twinNames.has(name)) continue;
      if (ast._tag !== "Objects" || ast.encoding || ast.propertySignatures.length === 0) continue;
      const key = this.structKey(ast, 0);
      if (this.exportStructs.has(key)) ambiguousStructs.add(key);
      else this.exportStructs.set(key, ast);
    }
    for (const key of ambiguousStructs) this.exportStructs.delete(key);
  }

  /** Deep structural identity (fields, optionality, literals, checks, brands); two ASTs with one key decode the same. */
  private structKey(ast: any, depth: number): string {
    if (depth > 8) return ast._tag;
    const sub = (a: any) => this.structKey(a, depth + 1);
    const checks = (ast.checks ?? [])
      .map((c: any) => c.annotations?.brands?.join("+") ?? c.annotations?.expected ?? "?")
      .join(";");
    // Encodings are left out: `Schema.toType` copies drop them, and the Swift type is the same.
    const head = `${ast._tag}${checks ? `[${checks}]` : ""}`;
    switch (ast._tag) {
      case "Objects":
        return `${head}{${ast.propertySignatures
          .map(
            (p: any) => `${String(p.name)}${p.type.context?.isOptional ? "?" : ""}:${sub(p.type)}`,
          )
          .sort()
          .join(",")}|${ast.indexSignatures.map((i: any) => sub(i.type)).join(",")}}`;
      case "Union":
        return `${head}(${ast.types.map(sub).sort().join("|")})`;
      case "Arrays":
        return `${head}(${ast.elements.map(sub).join(",")};${ast.rest.map(sub).join(",")})`;
      case "Literal":
        return `${head}${JSON.stringify(ast.literal)}`;
      case "Suspend":
        return head;
      default:
        return head;
    }
  }

  private shapeKey(members: any[]): string {
    const one = (m: any): string => {
      const o = m._tag === "Declaration" && m.encoding ? m.encoding[0].to : m;
      if (o._tag !== "Objects") return o._tag;
      return o.propertySignatures
        .map((p: any) => {
          const lits = this.litValues(p.type);
          return `${String(p.name)}${p.type.context?.isOptional ? "?" : ""}${lits ? `=${lits.join("/")}` : ""}`;
        })
        .sort()
        .join(",");
    };
    return members.map(one).sort().join("|");
  }

  /**
   * The literal-valued properties of a struct. A struct-level `decodeTo` that changes these crosses
   * the wire in its encoded shape; one that does not (e.g. ModelSelection's legacy `provider` key) is
   * only a lenient reader, and the Type side stays the contract.
   */
  private literalShape(objects: any): string {
    return objects.propertySignatures
      .flatMap((p: any) => {
        const lits = this.litValues(p.type);
        return lits ? [`${String(p.name)}=${lits.join("/")}`] : [];
      })
      .sort()
      .join(",");
  }

  private memberKey(members: any[]): string {
    return members
      .map((m) => {
        if (!this.ids.has(m)) this.ids.set(m, this.ids.size + 1);
        return this.ids.get(m)!;
      })
      .sort((a, b) => a - b)
      .join(",");
  }

  // ---- naming ---------------------------------------------------------------

  private reserve(base: string): string {
    const clean = typeName(base);
    let name = clean;
    for (let n = 2; this.types.has(name); n++) name = `${clean}${n}`;
    return name;
  }

  private nameFor(ast: any, hint: string, members?: any[]): { name: string; named: boolean } {
    const exported =
      this.exportNames.get(ast) ??
      (members ? this.exportUnionNames.get(this.shapeKey(members)) : undefined);
    if (exported) return { name: this.reserve(exported), named: true };
    const id = ann(ast)?.identifier;
    if (typeof id === "string" && id.length > 0) return { name: this.reserve(id), named: true };
    return { name: this.reserve(hint), named: false };
  }

  private moduleFor(name: string, fallback: string): string {
    return this.moduleOf(name) || fallback;
  }

  // ---- entry points -----------------------------------------------------------

  root(ast: any, hint: string, mod: string): Wire {
    return this.resolve(ast, typeName(hint), mod).wire;
  }

  resolve(ast: any, hint: string, mod: string): Resolved {
    const memo = this.memo.get(ast);
    if (memo) return memo;
    const lenient = !!ast.encoding && ast._tag !== "Unknown" && lastTo(ast)._tag === "Unknown";
    const r = this.shape(ast, hint, mod);
    return lenient ? { ...r, lenient: true } : r;
  }

  private plain(ir: IR, extra: Partial<Resolved> & { nullable?: boolean } = {}): Resolved {
    return {
      wire: { ir, nullable: extra.nullable ?? false },
      undef: extra.undef ?? false,
      lenient: false,
    };
  }

  private refTo(name: string, nullable = false, undef = false): Resolved {
    return this.plain({ k: "ref", name }, { nullable, undef });
  }

  // ---- node dispatch ----------------------------------------------------------

  /**
   * A union whose codec rewrites member shapes on the wire (e.g. ProjectIconOverride encodes a
   * `monogram` as a `lucide` icon with `monogramText`): the wire form is the contract, not the Type.
   */
  private wireUnion(ast: any): any | null {
    if (ast._tag !== "Union" || !ast.encoding) return null;
    const e = ast.encoding[0].to;
    if (e._tag !== "Union") return null;
    const tm = this.flatten(ast, false);
    const em = this.flatten(e, false);
    if (em.some((m: any) => m._tag === "Undefined") || !em.every((m: any) => m._tag === "Objects"))
      return null;
    return tm.every((m: any) => m._tag === "Objects") && this.shapeKey(tm) !== this.shapeKey(em)
      ? e
      : null;
  }

  private shape(ast: any, hint: string, mod: string): Resolved {
    const wireForm = this.wireUnion(ast);
    if (wireForm) {
      const name = this.exportNames.get(ast);
      if (name) this.exportNames.set(wireForm, name);
      const r = this.resolve(wireForm, hint, mod);
      this.memo.set(ast, r);
      return r;
    }
    switch (ast._tag) {
      case "String": {
        const brand = this.brandOf(ast);
        return brand ? this.brand(brand, "string", mod) : this.plain({ k: "string" });
      }
      case "Number": {
        const checks = checkList(ast);
        const isInt = checks.some(isIntCheck);
        const brand = this.brandOf(ast);
        if (brand) return this.brand(brand, isInt ? "int" : "double", mod);
        const min = minimumOf(checks, isInt);
        return this.plain({ k: isInt ? "int" : "double", ...(min === undefined ? {} : { min }) });
      }
      case "Boolean":
        return this.plain({ k: "bool" });
      case "Null":
        return this.plain({ k: "json" }, { nullable: true });
      case "Undefined":
        return this.plain({ k: "json" }, { undef: true });
      case "Void":
        return this.plain({ k: "void" });
      case "Never":
        return this.plain({ k: "never" });
      case "Unknown":
      case "Any":
      case "ObjectKeyword":
        this.jsonFallbacks.push(hint);
        return this.plain({ k: "json" });
      case "TemplateLiteral":
        return this.plain({ k: "string" });
      case "Literal":
        return this.literal(ast, hint, mod);
      case "Union":
        return this.union(ast, hint, mod);
      case "Arrays":
        return this.array(ast, hint, mod);
      case "Objects":
        return this.objects(ast, hint, mod);
      case "Suspend": {
        const r = this.resolve(ast.thunk(), hint, mod);
        if (r.wire.ir.k === "ref") this.suspended.add(r.wire.ir.name);
        return r;
      }
      case "Declaration":
        return this.declaration(ast, hint, mod);
      default:
        throw new Error(`Unsupported schema node ${ast._tag} at ${hint}`);
    }
  }

  private brandOf(ast: any): string | undefined {
    const brands: string[] | undefined = ann(ast)?.brands;
    return brands && brands.length > 0 ? brands[brands.length - 1] : undefined;
  }

  private brand(brandName: string, raw: "string" | "int" | "double", mod: string): Resolved {
    if (raw === "double")
      throw new Error(`Brand ${brandName} over a non-integer number is not supported`);
    const name = typeName(brandName);
    const existing = this.types.get(name);
    if (existing) {
      if (existing.kind !== "brand" || existing.raw !== raw)
        throw new Error(`Brand ${brandName} collides with another type`);
    } else {
      this.types.set(name, { kind: "brand", name, module: this.moduleFor(brandName, mod), raw });
    }
    return this.refTo(name);
  }

  private literal(ast: any, hint: string, mod: string): Resolved {
    const v = ast.literal;
    if (typeof v === "string" && this.exportNames.has(ast))
      return this.enumFrom(ast, [v], hint, mod, false, false);
    if (typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean") {
      throw new Error(`Unsupported literal ${String(v)} at ${hint}`);
    }
    return this.plain({ k: "literal", value: v });
  }

  // ---- unions -------------------------------------------------------------------

  /** Nested plain unions merge into their parent, except named ones (so `optional(Named)` keeps its type). */
  private flatten(ast: any, keepNamed: boolean, top = true): any[] {
    if (ast._tag !== "Union") return [ast];
    if (
      keepNamed &&
      !top &&
      (this.exportNames.has(ast) || typeof ann(ast)?.identifier === "string")
    )
      return [ast];
    return ast.types.flatMap((t: any) => this.flatten(t, keepNamed, false));
  }

  private union(ast: any, hint: string, mod: string): Resolved {
    let nullable = false;
    let undef = false;
    let rest: any[] = [];
    const classify = (members: any[]) => {
      nullable = false;
      undef = false;
      rest = [];
      for (const m of members) {
        if (m._tag === "Null") nullable = true;
        else if (m._tag === "Undefined") undef = true;
        else if (m._tag !== "Never") rest.push(m);
      }
    };
    classify(this.flatten(ast, true));
    if (rest.length !== 1) classify(this.flatten(ast, false));
    const done = (r: Resolved): Resolved => ({
      ...r,
      wire: { ir: r.wire.ir, nullable: nullable || r.wire.nullable },
      undef: undef || r.undef,
    });
    if (rest.length === 0) return done(this.plain({ k: "json" }));
    const key = rest.length > 1 ? this.memberKey(rest) : "";
    const shared = key ? this.unionByMembers.get(key) : undefined;
    if (shared) return done(shared);
    if (rest.length === 1) return done(this.resolve(rest[0], hint, mod));
    if (rest.every((m) => m._tag === "Literal")) {
      const kinds = new Set(rest.map((m) => typeof m.literal));
      if (kinds.size === 1 && kinds.has("boolean")) return done(this.plain({ k: "bool" }));
      if (kinds.size === 1 && kinds.has("string")) {
        return done(
          this.enumFrom(
            ast,
            rest.map((m) => m.literal),
            hint,
            mod,
            nullable,
            undef,
          ),
        );
      }
      // ponytail: closed numeric sets (e.g. zoom levels) stay plain numbers; add an enum if a client needs the set.
      if (kinds.size === 1 && kinds.has("number")) {
        return done(
          this.plain({ k: rest.every((m) => Number.isInteger(m.literal)) ? "int" : "double" }),
        );
      }
      throw new Error(`Unsupported literal union at ${hint}`);
    }
    const open = (m: any) =>
      (m._tag === "String" && !this.brandOf(m)) || m._tag === "TemplateLiteral";
    const lits = rest.filter((m) => m._tag === "Literal" && typeof m.literal === "string");
    if (lits.length > 0 && rest.every((m) => lits.includes(m) || open(m))) {
      // Known literals plus an open string (e.g. `extension.${string}`): the enum's `unknown` case carries the rest.
      return done(
        this.enumFrom(
          ast,
          lits.map((m) => m.literal),
          hint,
          mod,
          nullable,
          undef,
        ),
      );
    }
    const tagged = this.tagged(ast, rest, hint, mod, nullable, undef);
    if (tagged) return tagged;
    return this.untaggedUnion(ast, rest, hint, mod, nullable, undef);
  }

  private enumFrom(
    ast: any,
    values: string[],
    hint: string,
    mod: string,
    nullable: boolean,
    undef: boolean,
  ): Resolved {
    const named = this.exportNames.has(ast) || typeof ann(ast)?.identifier === "string";
    values = [...new Set(values)];
    const sig = values.join("\u0000");
    if (!named) {
      const shared = this.enumBySig.get(sig);
      if (shared) return this.refTo(shared, nullable, undef);
    }
    const { name } = this.nameFor(ast, hint);
    const used = new Set<string>(["unknown"]);
    const cases = values.map((raw) => {
      let id = ident(raw);
      if (id === "none" || id === "some" || id === "unknown") id = `${id}Value`;
      const base = id;
      for (let n = 2; used.has(id); n++) id = `${base}${n}`;
      used.add(id);
      return { raw, id };
    });
    this.types.set(name, { kind: "enum", name, module: this.moduleFor(name, mod), cases });
    if (!named) this.enumBySig.set(sig, name);
    const r = this.refTo(name, nullable, undef);
    this.memo.set(ast, r);
    return r;
  }

  /** Property list of an object-shaped union member (plain struct, or a class declaration). */
  private view(m: any): { props: any[]; ast: any } | null {
    if (m._tag === "Objects" && m.indexSignatures.length === 0)
      return { props: m.propertySignatures, ast: m };
    if (m._tag === "Declaration" && m.encoding) {
      const e = m.encoding[0].to;
      if (e._tag === "Objects") return { props: e.propertySignatures, ast: e };
    }
    return null;
  }

  private litValues(t: any): string[] | null {
    if (t._tag === "Literal") return typeof t.literal === "string" ? [t.literal] : null;
    if (
      t._tag === "Union" &&
      t.types.every((x: any) => x._tag === "Literal" && typeof x.literal === "string")
    ) {
      return t.types.map((x: any) => x.literal);
    }
    return null;
  }

  private tagged(
    ast: any,
    members: any[],
    hint: string,
    mod: string,
    nullable: boolean,
    undef: boolean,
  ): Resolved | null {
    const views = members.map((m) => this.view(m));
    if (views.some((v) => v === null)) return null;
    // key -> per-member literal values (members lacking a literal for that key are absent)
    const byKey = new Map<string, Map<number, { values: string[]; missingOk: boolean }>>();
    views.forEach((v, i) => {
      for (const p of v!.props) {
        const values = this.litValues(p.type);
        if (!values) continue;
        const key = String(p.name);
        const missingOk =
          !!p.type.context?.isOptional ||
          (!!p.type.encoding && !!lastTo(p.type).context?.isOptional);
        if (!byKey.has(key)) byKey.set(key, new Map());
        byKey.get(key)!.set(i, { values, missingOk });
      }
    });
    const priority = ["_tag", "type", "kind", "tag"];
    let best: { key: string; score: number } | null = null;
    for (const [key, per] of byKey) {
      const all = [...per.values()].flatMap((x) => x.values);
      if (per.size < 2 || members.length - per.size > 1) continue;
      if (new Set(all).size !== all.length) continue;
      if ([...per.values()].filter((x) => x.missingOk).length > 1) continue;
      const pr = priority.indexOf(key);
      const score = per.size * 100 - (pr < 0 ? 50 : pr);
      if (!best || score > best.score || (score === best.score && key < best.key))
        best = { key, score };
    }
    if (!best) return null;
    const disc = best.key;
    const per = byKey.get(disc)!;

    const { name } = this.nameFor(ast, hint, members);
    const def: UnionDef = {
      kind: "union",
      name,
      module: this.moduleFor(name, mod),
      disc,
      variants: [],
      fallback: null,
      indirect: false,
      isError: false,
    };
    this.types.set(name, def);
    const result = this.refTo(name);
    this.memo.set(ast, this.refTo(name, nullable, undef));
    this.unionByMembers.set(this.memberKey(members), result);

    const usedIds = new Set<string>(["unknown", "other"]);
    const uniqueId = (raw: string) => {
      let id = camel(raw);
      if (/^(none|some)$/.test(id)) id = `${id}Value`;
      const base = id;
      for (let n = 2; usedIds.has(id); n++) id = `${base}${n}`;
      usedIds.add(id);
      return id;
    };
    let allErrors = true;
    const structOf = (m: any, memberHint: string) => {
      const r = this.resolve(m, memberHint, mod);
      const ref = r.wire.ir.k === "ref" ? r.wire.ir.name : null;
      const sd = ref ? this.types.get(ref) : undefined;
      if (!ref || !sd || sd.kind !== "struct")
        throw new Error(`Union member at ${hint} did not resolve to a struct`);
      if (!sd.isError) allErrors = false;
      return { ref, sd };
    };
    members.forEach((m, i) => {
      const entry = per.get(i);
      if (!entry) {
        const { ref } = structOf(m, `${name}Other`);
        def.fallback = { id: "other", ref };
        return;
      }
      const { ref, sd } = structOf(m, `${name}${pascal(entry.values[0]!)}`);
      def.variants.push({
        values: entry.values,
        id: uniqueId(entry.values[0]!),
        ref,
        missingOk: entry.missingOk,
      });
    });
    def.isError = allErrors;
    return this.refTo(name, nullable, undef);
  }

  private untaggedUnion(
    ast: any,
    members: any[],
    hint: string,
    mod: string,
    nullable: boolean,
    undef: boolean,
  ): Resolved {
    const wires: { wire: Wire; sig: string }[] = [];
    members.forEach((m, i) => {
      const r = this.resolve(m, `${hint}Option${i + 1}`, mod);
      const sig = JSON.stringify(r.wire);
      if (!wires.some((w) => w.sig === sig)) wires.push({ wire: r.wire, sig });
    });
    if (wires.length === 1)
      return this.plain(wires[0]!.wire.ir, {
        nullable: nullable || wires[0]!.wire.nullable,
        undef,
      });
    const isStringy = (w: Wire) => {
      if (w.ir.k === "string") return true;
      const d = w.ir.k === "ref" ? this.types.get(w.ir.name) : undefined;
      return d?.kind === "brand" && d.raw === "string";
    };
    // Several string-valued ids that share one wire shape (e.g. ProjectId | ThreadId) are one string.
    if (wires.every((w) => isStringy(w.wire) && !w.wire.nullable))
      return this.plain({ k: "string" }, { nullable, undef });
    const { name } = this.nameFor(ast, hint, members);
    const used = new Set<string>(["unknown"]);
    const memberIds = wires.map((w) => {
      const ir = w.wire.ir;
      // `Union` member types usually extend the union's own name; keep only the distinguishing tail.
      const tail =
        ir.k === "ref" && ir.name.startsWith(name) && ir.name.length > name.length
          ? ir.name.slice(name.length)
          : null;
      let id: string = tail
        ? camel(tail)
        : ir.k === "ref"
          ? camel(ir.name)
          : ir.k === "literal"
            ? "literal"
            : ir.k;
      const base = id;
      for (let n = 2; used.has(id); n++) id = `${base}${n}`;
      used.add(id);
      return id;
    });
    this.types.set(name, {
      kind: "untagged",
      name,
      module: this.moduleFor(name, mod),
      members: wires.map((w, i) => ({ id: memberIds[i]!, wire: w.wire })),
    });
    this.untagged.push(name);
    this.unionByMembers.set(this.memberKey(members), this.refTo(name));
    const r = this.refTo(name, nullable, undef);
    this.memo.set(ast, r);
    return r;
  }

  // ---- arrays / objects ---------------------------------------------------------

  private array(ast: any, hint: string, mod: string): Resolved {
    if (ast.elements.length > 0 || ast.rest.length !== 1)
      throw new Error(`Tuples are not supported (${hint})`);
    const wireSide = ast.encoding ? lastTo(ast) : null;
    // ForwardCompatibleArray: elements that fail to decode are dropped. The wire side is an array of
    // `Unknown` (earlier Effect builds) or of `Element | undefined` with a catchDecoding chain.
    const lenient = (e: any) =>
      e._tag === "Unknown" ||
      (e._tag === "Union" && !!e.encoding && e.types.some((t: any) => t._tag === "Undefined"));
    const lossy =
      !!wireSide &&
      wireSide._tag === "Arrays" &&
      wireSide.rest.length === 1 &&
      lenient(wireSide.rest[0]);
    const el = this.resolve(ast.rest[0], `${hint}Item`, mod);
    return this.plain({ k: "array", elem: el.wire, lossy });
  }

  private objects(ast: any, hint: string, mod: string): Resolved {
    // A struct-level `decodeTo` (e.g. `{kind: "background_task", work: "subagent"}` decoding to
    // `{kind: "subagent"}`) crosses the wire in its encoded shape, which is what Swift must read and write.
    const wire = ast.encoding?.[0]?.to;
    const shapeAst =
      wire?._tag === "Objects" &&
      wire.indexSignatures.length === 0 &&
      wire.propertySignatures.length > 0 &&
      this.literalShape(wire) !== this.literalShape(ast)
        ? wire
        : ast;
    const props: any[] = shapeAst.propertySignatures;
    const idx: any[] = shapeAst.indexSignatures;
    if (props.length === 0 && idx.length === 0) return this.plain({ k: "empty" });
    if (props.length === 0 && idx.length === 1) {
      const v = this.resolve(idx[0].type, `${hint}Value`, mod);
      return this.plain({ k: "record", value: v.wire });
    }
    if (idx.length > 0) throw new Error(`Struct with index signature is not supported (${hint})`);
    if (!this.exportNames.has(ast) && typeof ann(ast)?.identifier !== "string") {
      const twin = this.exportStructs.get(this.structKey(ast, 0));
      if (twin && twin !== ast) return this.resolve(twin, hint, mod);
    }
    const { name } = this.nameFor(ast, hint);
    return this.struct(ast, shapeAst, name, mod, false);
  }

  /** `keyAst` is what later lookups use; `shapeAst` supplies the properties. */
  private struct(
    keyAst: any,
    shapeAst: any,
    name: string,
    mod: string,
    isClass: boolean,
  ): Resolved {
    const def: StructDef = {
      kind: "struct",
      name,
      module: this.moduleFor(name, mod),
      fields: [],
      consts: [],
      isError: isClass,
    };
    this.types.set(name, def);
    const r = this.refTo(name);
    this.memo.set(keyAst, r);
    const seen = new Set<string>();
    for (const p of shapeAst.propertySignatures) {
      const key = String(p.name);
      const f = this.field(p, name, def.module);
      let id = f.kind === "const" ? ident(key) : f.field.id;
      const base = id;
      for (let n = 2; seen.has(id); n++) id = `${base}${n}`;
      seen.add(id);
      if (f.kind === "const") def.consts.push({ key, value: f.value });
      else def.fields.push({ ...f.field, id });
    }
    if (isClass) def.isError = def.consts.some((c) => c.key === "_tag");
    return r;
  }

  private declaration(ast: any, hint: string, mod: string): Resolved {
    const expected = ann(ast)?.expected;
    if (expected === "DateTime.Utc") return this.plain({ k: "iso" });
    if (expected === "Option" && ast.encoding) {
      const inner = this.rt.S.toCodecJson(this.rt.S.make(ast.typeParameters[0])).ast;
      return this.plain({ k: "option", inner: this.resolve(inner, `${hint}Value`, mod).wire });
    }
    if (ast.encoding) {
      const e = ast.encoding[0].to;
      if (
        e._tag === "Objects" &&
        e.indexSignatures.length === 0 &&
        e.propertySignatures.length > 0
      ) {
        const { name } = this.nameFor(ast, hint);
        return this.struct(ast, e, name, mod, true);
      }
      return this.resolve(e, hint, mod);
    }
    throw new Error(`Unsupported declaration ${String(expected)} at ${hint}`);
  }

  // ---- fields ---------------------------------------------------------------------

  private runGetter(getter: any, input: any): { some: true; value: any } | { some: false } | null {
    try {
      const out = this.rt.E.runSync(this.rt.G.run(getter, input, {}));
      return this.rt.O.isSome(out) ? { some: true, value: out.value } : { some: false };
    } catch {
      return null;
    }
  }

  private field(
    p: any,
    parent: string,
    mod: string,
  ): { kind: "const"; value: string | number | boolean } | { kind: "field"; field: Field } {
    const key = String(p.name);
    const t = p.type;
    const typeOptional = !!t.context?.isOptional;
    const encs: any[] | undefined = t.encoding;
    const wireOptional = encs ? !!lastTo(t).context?.isOptional : typeOptional;
    const r = this.resolve(t, `${parent}${pascal(key)}`, mod);

    let hasDefault = false;
    let dflt: unknown;
    let encode: EncodeMode | "omitNull" = "always";
    // A default on an already-optional type (`optional(X).pipe(withDecodingDefault(..))`) still fills the key on decode.
    if (encs && wireOptional) {
      for (let i = encs.length - 1; i >= 0; i--) {
        const d = this.runGetter(encs[i].transformation.decode, this.rt.O.none());
        if (d?.some) {
          hasDefault = true;
          dflt = d.value;
          if (JSON.stringify(dflt) === undefined)
            throw new Error(`Non-JSON default for ${parent}.${key}`);
          const nul = this.runGetter(encs[i].transformation.encode, this.rt.O.some(null));
          const val = this.runGetter(encs[i].transformation.encode, this.rt.O.some("x"));
          if (nul && !nul.some && val && !val.some) encode = "never";
          else if (nul && !nul.some) encode = "omitNull";
          break;
        }
      }
    }

    const keyOptional = typeOptional && !hasDefault;
    const ir = r.wire.ir;
    // Required single literal with no default: a constant of the type, not stored.
    if (ir.k === "literal" && !typeOptional && !hasDefault && !r.undef && !r.wire.nullable) {
      return { kind: "const", value: ir.value };
    }

    let wire = r.wire;
    if (ir.k === "string" && this.isoKeys.has(key)) wire = { ...wire, ir: { k: "iso" } };
    if (ir.k === "option") {
      if (typeOptional) throw new Error(`Optional Option field ${parent}.${key} is not supported`);
      wire = { ir, nullable: true };
    }

    const optional = keyOptional || (r.undef && !hasDefault);
    const nullable = wire.nullable;
    const tri = keyOptional && nullable && ir.k !== "option";
    let mode: EncodeMode;
    if (encode === "never") mode = "never";
    else if (optional) mode = "omitNil";
    else if (nullable) mode = encode === "omitNull" ? "omitNil" : "nullNil";
    else mode = "always";

    return {
      kind: "field",
      field: {
        key,
        id: ident(key),
        wire,
        optional: optional || nullable,
        tri,
        hasDefault,
        default: dflt,
        encode: mode,
        lenient: r.lenient,
      },
    };
  }

  /** A failure is always a tagged union; a lone error struct gets a one-case wrapper. */
  asFailure(refName: string, hint: string): string {
    const d = this.types.get(refName)!;
    if (d.kind === "union") return refName;
    if (d.kind !== "struct") throw new Error(`Failure ${hint} is not a tagged error`);
    const tag = d.consts.find((c) => c.key === "_tag");
    if (!tag) throw new Error(`Failure ${hint} has no _tag`);
    const name = this.reserve(`${hint}Wrapper`);
    this.types.set(name, {
      kind: "union",
      name,
      module: d.module,
      disc: "_tag",
      variants: [
        {
          values: [String(tag.value)],
          id: camel(String(tag.value)),
          ref: refName,
          missingOk: false,
        },
      ],
      fallback: null,
      indirect: false,
      isError: true,
    });
    return name;
  }

  // ---- post passes ------------------------------------------------------------------

  /** One schema AST per generated type, so the TS oracle can decode/encode samples of it. */
  astByType(): Map<string, any> {
    const out = new Map<string, any>();
    for (const [ast, r] of this.memo) {
      if (r.wire.ir.k === "ref" && !r.wire.nullable && !out.has(r.wire.ir.name))
        out.set(r.wire.ir.name, ast);
    }
    return out;
  }

  /**
   * Points every reference to `from` at `to` and drops `from`. Used to fold the protocol-1 model's
   * anonymous enums into same-valued current ones, whose names only differ by discovery order.
   */
  renameTypes(rename: Map<string, string>): void {
    const wire = (w: Wire | null | undefined) => w && ir(w.ir);
    const ir = (x: IR): void => {
      if (x.k === "ref") x.name = rename.get(x.name) ?? x.name;
      else if (x.k === "array") wire(x.elem);
      else if (x.k === "record") wire(x.value);
      else if (x.k === "option") wire(x.inner);
    };
    for (const from of rename.keys()) this.types.delete(from);
    for (const d of this.types.values()) {
      if (d.kind === "struct") d.fields.forEach((f) => wire(f.wire));
      else if (d.kind === "union") {
        for (const v of d.variants) if (v.ref) v.ref = rename.get(v.ref) ?? v.ref;
        if (d.fallback) d.fallback.ref = rename.get(d.fallback.ref) ?? d.fallback.ref;
      } else if (d.kind === "untagged") d.members.forEach((m) => wire(m.wire));
    }
  }

  /** Names of the types `name` refers to directly. */
  depsOf(name: string): string[] {
    const out: string[] = [];
    const visitIr = (ir: IR) => {
      if (ir.k === "ref") out.push(ir.name);
      else if (ir.k === "array") visitIr(ir.elem.ir);
      else if (ir.k === "record") visitIr(ir.value.ir);
      else if (ir.k === "option") visitIr(ir.inner.ir);
    };
    const d = this.types.get(name);
    if (!d) return out; // folded into another model's type (see renameTypes)
    if (d.kind === "struct") d.fields.forEach((f) => visitIr(f.wire.ir));
    else if (d.kind === "union") {
      d.variants.forEach((v) => v.ref && out.push(v.ref));
      if (d.fallback) out.push(d.fallback.ref);
    } else if (d.kind === "untagged") d.members.forEach((m) => visitIr(m.wire.ir));
    return out;
  }

  /** Types reachable from `roots`; used to drop variant structs folded into payload-less cases. */
  reachable(roots: Iterable<Wire>): Set<string> {
    const seen = new Set<string>();
    const visitName = (name: string) => {
      if (seen.has(name)) return;
      seen.add(name);
      this.depsOf(name).forEach(visitName);
    };
    for (const w of roots) {
      const ir = w.ir;
      // Roots may be wrapped (array/record/option) around refs, like fields.
      const stack: IR[] = [ir];
      while (stack.length) {
        const x = stack.pop()!;
        if (x.k === "ref") visitName(x.name);
        else if (x.k === "array") stack.push(x.elem.ir);
        else if (x.k === "record") stack.push(x.value.ir);
        else if (x.k === "option") stack.push(x.inner.ir);
      }
    }
    return seen;
  }

  /**
   * Swift value types cannot contain themselves. Unions reached through Suspend
   * become `indirect`; any other direct cycle is a generator error.
   */
  breakCycles(): void {
    // A variant whose struct has no stored fields is just its discriminator. Decided here, not
    // at creation, because a recursive struct is still empty while its union is being built.
    for (const d of this.types.values()) {
      if (d.kind !== "union") continue;
      for (const v of d.variants) {
        const sd = v.ref ? this.types.get(v.ref) : undefined;
        if (sd?.kind === "struct" && sd.fields.length === 0) v.ref = null;
      }
    }
    for (const name of this.suspended) {
      const d = this.types.get(name);
      if (d?.kind === "union") d.indirect = true;
    }
    const edges = (name: string): string[] => {
      const d = this.types.get(name)!;
      const direct = (w: Wire): string[] =>
        w.ir.k === "ref" ? [w.ir.name] : w.ir.k === "option" ? direct(w.ir.inner) : [];
      if (d.kind === "struct") return d.fields.flatMap((f) => direct(f.wire));
      if (d.kind === "union")
        return d.indirect
          ? []
          : [
              ...d.variants.flatMap((v) => (v.ref ? [v.ref] : [])),
              ...(d.fallback ? [d.fallback.ref] : []),
            ];
      if (d.kind === "untagged") return d.members.flatMap((m) => direct(m.wire));
      return [];
    };
    const state = new Map<string, 1 | 2>();
    const visit = (n: string, path: string[]) => {
      if (state.get(n) === 2) return;
      if (state.get(n) === 1)
        throw new Error(`Recursive value type cycle: ${[...path, n].join(" -> ")}`);
      state.set(n, 1);
      for (const e of edges(n)) visit(e, [...path, n]);
      state.set(n, 2);
    };
    for (const n of [...this.types.keys()].sort()) visit(n, []);
  }
}
