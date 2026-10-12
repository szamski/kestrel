// Rich-text document model oracle: markdown -> Tiptap JSON (normalized by ProseMirror), the
// serialized value and run table, and every cursor conversion at every offset.
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";
import type { Sources } from "./lib.ts";

const webRequire = createRequire(join(repoRoot, "apps", "web", "package.json"));
// Resolve with the ESM entry the web sources themselves load, so Tiptap sees one module instance.
const esm = async (name: string) =>
  import(
    pathToFileURL(webRequire.resolve(name, { paths: [join(repoRoot, "apps/web")] })).href
  ).catch(() => import(name));

export async function richDocCases(s: Sources, texts: string[]) {
  const core = await import("@tiptap/core");
  const starter = (await import("@tiptap/starter-kit")).default;
  const { Node: ProseMirrorNode } = await import("@tiptap/pm/model");
  void esm;
  const { Node, getSchemaByResolvedExtensions, resolveExtensions } = core;
  const {
    buildDocJson,
    serializeEditorDoc,
    ComposerCodeExtension,
    ComposerCodeBlockExtension,
    ComposerBlockExtensions,
    ComposerListExtensions,
    ComposerTaskListExtension,
    ComposerTaskItemExtension,
  } = s.richDoc;

  const stubAtom = (name: string, attrs: Record<string, { default: unknown }>) =>
    Node.create({ name, group: "inline", inline: true, atom: true, addAttributes: () => attrs });
  const atoms = [
    stubAtom("composer-mention", { path: { default: "" }, source: { default: "" } }),
    stubAtom("composer-skill", {
      skillName: { default: "" },
      skillLabel: { default: "" },
      skillDescription: { default: null },
    }),
    stubAtom("composer-citation", {
      citation: { default: null },
      source: { default: "" },
      citeKey: { default: "" },
    }),
    stubAtom("composer-context-reference", {
      kind: { default: "" },
      contextId: { default: "" },
      label: { default: "" },
      source: { default: "" },
    }),
  ];
  const base = {
    blockquote: false,
    bulletList: false,
    codeBlock: false,
    heading: false,
    horizontalRule: false,
    listItem: false,
    orderedList: false,
    dropcursor: false,
    gapcursor: false,
    trailingNode: false,
  };
  // Mirrors the extension lists of ComposerPromptEditorTiptap: rich mode has every block
  // (fences, quotes, rules, headings, lists, tasks); plain mode has marks off and no blocks.
  const richSchema = getSchemaByResolvedExtensions(
    resolveExtensions([
      starter.configure({ ...base, code: false }),
      ComposerCodeExtension,
      ComposerCodeBlockExtension,
      ...ComposerBlockExtensions,
      ...ComposerListExtensions,
      ComposerTaskListExtension,
      ComposerTaskItemExtension,
      ...atoms,
    ]),
  );
  const plainSchema = getSchemaByResolvedExtensions(
    resolveExtensions([
      starter.configure({ ...base, bold: false, italic: false, strike: false, code: false }),
      ...atoms,
    ]),
  );

  const cases: Array<{ input: unknown; output: unknown }> = [];
  const range = (n: number) => Array.from({ length: n }, (_, i) => i);
  // citeKey is a random per-chip key; the Swift side has no equivalent.
  const strip = (node: any): any => {
    if (Array.isArray(node)) return node.map(strip);
    if (node && typeof node === "object") {
      const { citeKey: _citeKey, ...rest } = node;
      return Object.fromEntries(Object.entries(rest).map(([key, value]) => [key, strip(value)]));
    }
    return node;
  };
  for (const text of texts) {
    for (const styling of [true, false]) {
      const json = buildDocJson(text, (name: string) => ({ label: name, description: null }), {
        styling,
      });
      const doc = ProseMirrorNode.fromJSON(styling ? richSchema : plainSchema, json);
      doc.check();
      const map = serializeEditorDoc(doc);
      const collapsedLength =
        map.runs.length === 0
          ? 0
          : map.runs[map.runs.length - 1].collapsedStart +
            map.runs[map.runs.length - 1].collapsedLen;
      cases.push({
        input: { text, styling },
        output: {
          doc: strip(doc.toJSON()),
          value: map.value,
          docLength: map.docLength,
          contextIds: map.contextIds,
          runs: map.runs.map(({ pmPos: _pmPos, ...run }: any) => run),
          flatToCollapsed: range(map.docLength + 2).map((o) => s.richDoc.flatToCollapsed(map, o)),
          flatToMarkdown: range(map.docLength + 2).map((o) => s.richDoc.flatToMarkdown(map, o)),
          collapsedToFlat: range(collapsedLength + 3).map((o) => s.richDoc.collapsedToFlat(map, o)),
        },
      });
    }
  }
  return cases;
}
