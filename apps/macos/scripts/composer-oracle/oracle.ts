// Differential oracle for the Swift composer core.
//
//   node apps/macos/scripts/composer-oracle/oracle.ts           # regenerate the committed fixtures
//   node apps/macos/scripts/composer-oracle/oracle.ts --check   # regenerate to a temp dir, exit 1 on any diff
//
// Runs the real TypeScript composer functions (apps/web/src/composer-*.ts, packages/shared) on a
// corpus and writes `expected/<group>.json`: an array of `{ input, output }` cases. The Swift tests
// in T3ComposerTests replay every input through T3Composer and compare the encoded outputs.
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadSources, oracleRoot } from "./lib.ts";
import { chipSamples, citations, drafts, listDrafts, PASTE_TEXTS } from "./corpus.ts";
import { richDocCases } from "./richDoc.ts";
import { stateMachineCases } from "./stateMachines.ts";
import { historyCases } from "./historyCases.ts";
import { modelCases } from "./modelCases.ts";
import { layoutCases } from "./layoutCases.ts";
import { contextCases } from "./contextCases.ts";
import { attachmentCases } from "./attachmentCases.ts";

const s = await loadSources();
// Cases are generated into a staging dir and only copied over the fixtures once every group
// succeeded, so a failing run never leaves the committed fixtures half-deleted.
const check = process.argv.includes("--check");
const committedDir = join(oracleRoot, "expected");
const outDir = mkdtempSync(join(tmpdir(), "composer-oracle-"));

const groups: Record<string, Array<{ input: unknown; output: unknown }>> = {};
const add = (group: string, input: unknown, output: unknown) =>
  (groups[group] ??= []).push({ input, output });
const range = (n: number) => Array.from({ length: n }, (_, i) => i);

const texts = drafts(s);

// --- segmentation and inline tokens ---------------------------------------------------------
const segmentJson = (segment: any) =>
  segment.type === "citation" ? { ...segment, citation: segment.citation } : segment;
for (const text of texts) {
  add("segments", { text }, s.mentions.splitPromptIntoComposerSegments(text).map(segmentJson));
  add("inlineTokens", { text }, s.inlineTokens.collectComposerInlineTokens(text));
  add(
    "promptTokens",
    { text },
    s.mentions.collectComposerPromptInlineTokens(text).map(({ image: _image, ...t }: any) => t),
  );
  add(
    "selectionBoundary",
    { text, start: 0, end: text.length },
    s.mentions.selectionTouchesMentionBoundary(text, 0, text.length),
  );
  for (const [start, end] of [
    [1, 2],
    [2, 5],
    [0, 1],
    [3, 4],
  ]) {
    add(
      "selectionBoundary",
      { text, start, end },
      s.mentions.selectionTouchesMentionBoundary(text, start, end),
    );
  }
}
add(
  "inlineTokens",
  { text: "@a.ts", preserve: true },
  s.inlineTokens.collectComposerInlineTokens("@a.ts", {
    preserveTrailingFrom: [{ type: "mention", value: "a.ts", source: "@a.ts", start: 0, end: 5 }],
  }),
);
add(
  "inlineTokens",
  { text: "x @a.ts", preserve: true },
  s.inlineTokens.collectComposerInlineTokens("x @a.ts", {
    preserveTrailingFrom: [{ type: "mention", value: "a.ts", source: "@a.ts", start: 2, end: 7 }],
  }),
);

// --- cursor spaces and triggers --------------------------------------------------------------
const cursorTexts = texts.filter((t) => t.length <= 140);
for (const text of cursorTexts) {
  const length = text.length;
  for (const cursor of range(length + 3)) {
    add(
      "triggers",
      { text, cursor },
      {
        web: s.logic.detectComposerTrigger(text, cursor),
        shared: s.trigger.detectComposerTrigger(text, cursor),
      },
    );
    add(
      "cursors",
      { text, cursor },
      {
        expand: s.logic.expandCollapsedComposerCursor(text, cursor),
        collapse: s.logic.collapseExpandedComposerCursor(text, cursor),
        clamp: s.logic.clampCollapsedComposerCursor(text, cursor),
        adjacentLeft: s.logic.isCollapsedCursorAdjacentToInlineToken(text, cursor, "left"),
        adjacentRight: s.logic.isCollapsedCursorAdjacentToInlineToken(text, cursor, "right"),
      },
    );
  }
  add("promptEnd", { text }, s.logic.composerStateAtPromptEnd(text));
}
for (const text of [
  "/",
  "/plan",
  "/model",
  "/Model",
  "/model gpt",
  "/model  gpt 5 ",
  "/model\t",
  "/model ",
  "/modelx foo",
  "/model a\rb",
  "/default",
  "/PLAN",
  " /plan",
  "/plan x",
  "hi\n/pl",
  "/a b",
  "#",
  "#12",
  "#a-b_c",
  "#-x",
  "#12 ",
  "x #12",
  "#é1",
  "#٣",
  "$",
  "$a",
  "€x",
  "¥",
  "𑿝abc",
  "@",
  "@a",
  "a@b",
  "text $20",
  "text @src/x",
  "\n@x",
  "\n/x",
]) {
  for (const cursor of range(text.length + 1)) {
    add(
      "triggers",
      { text, cursor },
      {
        web: s.logic.detectComposerTrigger(text, cursor),
        shared: s.trigger.detectComposerTrigger(text, cursor),
      },
    );
  }
}
for (const text of [
  "/plan",
  "/default",
  " /plan \n",
  "/PLAN",
  "/Default",
  "/model",
  "plan",
  "/plan x",
  "",
  "/plan ",
]) {
  add("slashCommand", { text }, s.logic.parseStandaloneComposerSlashCommand(text));
}
for (const [text, start, end, replacement] of [
  ["hello", 1, 3, "XY"],
  ["hello", 9, 12, "!"],
  ["hello", 3, 1, "-"],
  ["", 0, 0, "a"],
  ["a😀b", 1, 3, "x"],
] as const) {
  add(
    "replaceTextRange",
    { text, start, end, replacement },
    s.logic.replaceTextRange(text, start, end, replacement),
  );
}

// --- submit intent --------------------------------------------------------------------------
for (const isMobileViewport of [false, true])
  for (const shiftKey of [false, true])
    for (const modifierKey of [false, true])
      for (const isDraftThread of [false, true])
        for (const isRunning of [false, true])
          for (const sendShortcut of [undefined, "enter", "mod-enter-multiline", "mod-enter"])
            for (const prompt of ["", "one line", "two\nlines", "cr\rline"]) {
              const input = {
                isMobileViewport,
                shiftKey,
                modifierKey,
                isDraftThread,
                isRunning,
                sendShortcut,
                prompt,
              };
              // Upstream now resolves Enter through the keybinding table instead of flags. The fixture
              // input keeps the old flag shape: modifierKey is Cmd on macOS, default keybindings.
              const { shiftKey: shift, modifierKey: mod, ...rest } = input;
              add(
                "submitIntent",
                input,
                s.logic.composerSubmissionIntentForKey({
                  ...rest,
                  event: {
                    key: "Enter",
                    metaKey: mod,
                    ctrlKey: false,
                    altKey: false,
                    shiftKey: shift,
                  },
                  keybindings: s.keybindings.DEFAULT_RESOLVED_KEYBINDINGS,
                  platform: "MacIntel",
                }),
              );
            }

// --- list continuation -----------------------------------------------------------------------
for (const text of listDrafts(s)) {
  for (const cursor of range(text.length + 2)) {
    add("listEnter", { text, cursor }, s.listContinuation.listContinuationForEnter(text, cursor));
    add(
      "listTab",
      { text, start: cursor, end: cursor },
      s.listContinuation.listIndentForTab(text, cursor, cursor),
    );
  }
  add(
    "listTab",
    { text, start: 0, end: Math.min(2, text.length) },
    s.listContinuation.listIndentForTab(text, 0, Math.min(2, text.length)),
  );
}

// --- context references ---------------------------------------------------------------------
const k = chipSamples(s);
const refs = s.contextRefs;
const libRefs = s.libRefs;
for (const text of texts) {
  add("contextCollect", { text }, refs.collectComposerContextReferences(text));
  add(
    "contextReplace",
    { text },
    refs.replaceComposerContextReferences(
      text,
      (o: any) => `<${o.kind}:${o.contextId}:${o.label}:${o.image}>`,
    ),
  );
  add(
    "contextIds",
    { text },
    {
      ids: libRefs.collectInlineContextIds(text),
      stripped: libRefs.stripInlineContextReferences(text),
    },
  );
}
for (const href of [
  "t3-context://v1/image/abc",
  "t3-context://v1/image/ABC_-9",
  "t3-context://v1/Image/abc",
  "t3-context://v1/1image/abc",
  "t3-context://v1/image/abc/extra",
  "t3-context://v1/image",
  "t3-context://v1/",
  "t3-context://v2/image/abc",
  "http://x",
  "t3-context://v1/a-b/" + "x".repeat(128),
  "t3-context://v1/a-b/" + "x".repeat(129),
  "t3-context://v1/" + "k".repeat(40) + "/a",
  "t3-context://v1/" + "k".repeat(41) + "/a",
  "t3-context://v1/image/a b",
  "t3-context://v1/image/é",
  "t3-context://v1/image/",
]) {
  add("contextHref", { href }, refs.parseComposerContextHref(href));
}
for (const [label, kind] of [
  ["hello", "file"],
  ["a [b] c", "file"],
  ["  spaced   out  ", "terminal"],
  ["", "image"],
  ["   ", "skill"],
  ["line\nbreak\r\nx", "file"],
  ["back\\slash", "file"],
  ["x".repeat(250), "file"],
  ["tab\there", "file"],
  ["émoji 😀 end", "file"],
  ["a b c", "file"],
  ["😀".repeat(120), "file"],
] as const) {
  add("contextLabel", { label, kind }, refs.sanitizeComposerContextLabel(label, kind));
  add(
    "contextFormat",
    { kind, contextId: "ctx_1", label },
    refs.formatComposerContextReference({ kind, contextId: "ctx_1", label }),
  );
}
for (const id of [
  "abc",
  "ABC_def-1",
  "pull-request-finding:42",
  "file-comment-123-4",
  "a b c",
  "",
  "---",
  "é",
  "x".repeat(200),
  "terminal_1",
  "a/b\\c",
  "😀",
  "ctx:💥:x",
]) {
  add(
    "contextIdFold",
    { id },
    {
      id: libRefs.toComposerContextId(id),
      scopedTerminal: libRefs.toKindScopedComposerContextId("terminal", id),
      producerTerminal: libRefs.producerIdFromComposerContextId("terminal", id),
      producerImage: libRefs.producerIdFromComposerContextId("image", `image_${id}`),
    },
  );
}
const sampleRef = { kind: "terminal", contextId: "terminal_x", label: "Terminal 1 lines 1-2" };
const imageRef = { kind: "image", contextId: "image_y", label: "pic.png" };
for (const [prompt, cursor] of [
  ["", 0],
  ["hello", 5],
  ["hello", 3],
  ["hello ", 6],
  ["hello\n", 6],
  ["a b", 1],
  ["a😀b", 3],
  ["x", 0],
  ["x", 9],
] as const) {
  add(
    "contextInsert",
    { prompt, cursor, reference: sampleRef },
    libRefs.insertInlineContextReference(prompt, cursor, sampleRef),
  );
  add(
    "contextInsert",
    { prompt, cursor, reference: imageRef },
    libRefs.insertInlineContextReference(prompt, cursor, imageRef),
  );
  add(
    "contextReplacement",
    {
      prompt,
      start: cursor,
      end: Math.min(prompt.length, cursor + 2),
      references: [sampleRef, imageRef],
    },
    libRefs.inlineContextReferenceReplacement(
      prompt,
      { start: cursor, end: Math.min(prompt.length, cursor + 2) },
      [sampleRef, imageRef],
    ),
  );
}
const withTerminal = `before ${libRefs.formatInlineContextReference(sampleRef)} after`;
const onlyChip = libRefs.formatInlineContextReference(sampleRef);
const doubled = `${onlyChip} ${onlyChip}`;
for (const prompt of [
  withTerminal,
  onlyChip,
  doubled,
  `${onlyChip}x`,
  `x${onlyChip}`,
  `text ${onlyChip}`,
  `${onlyChip} `,
  "none",
]) {
  add(
    "contextRemove",
    { prompt, contextId: "terminal_x" },
    libRefs.removeInlineContextReference(prompt, "terminal_x"),
  );
}
add(
  "contextEnsure",
  { prompt: "hello", references: [sampleRef, imageRef, sampleRef] },
  libRefs.ensureInlineContextReferences("hello", [sampleRef, imageRef, sampleRef]),
);
add(
  "contextEnsure",
  { prompt: withTerminal, references: [sampleRef, imageRef] },
  libRefs.ensureInlineContextReferences(withTerminal, [sampleRef, imageRef]),
);
add(
  "contextAppend",
  { prompt: "hello", reference: sampleRef },
  libRefs.appendInlineContextReference("hello", sampleRef),
);
add(
  "contextAppend",
  { prompt: "", reference: sampleRef },
  libRefs.appendInlineContextReference("", sampleRef),
);

// --- citations -----------------------------------------------------------------------------
const cit = citations(s);
const cs = s.citations;
for (const citation of cit.all) {
  const href = cs.formatAssistantCitationHref(citation);
  add(
    "citationFormat",
    { citation },
    {
      href,
      serialized: cs.serializeAssistantCitation(citation),
      parsed: cs.parseAssistantCitationHref(href),
    },
  );
}
for (const comment of ["", "  ", "  hi  ", "new comment", "😀 & <b>"]) {
  add(
    "citationComment",
    { citation: cit.withComment, comment },
    {
      next: cs.withAssistantCitationComment(cit.withComment, comment),
      composer: s.logic.formatAssistantCitationForComposer(cit.base, comment),
    },
  );
}
const goodHref = cs.formatAssistantCitationHref(cit.base);
const goodQuery = goodHref.slice(goodHref.indexOf("?"));
for (const href of [
  goodHref,
  goodHref + "#frag",
  goodHref + "#",
  goodHref.replace("start=3", "start=x"),
  goodHref.replace("end=41", "end=3"),
  goodHref.replace("end=41", "end=9007199254740992"),
  goodHref + "&extra=1",
  goodHref.replace("&suffix=", "&suffix2="),
  goodHref + "&text=dup",
  goodHref + "&comment=a&comment=b",
  goodHref + "&comment=",
  goodHref.replace("t3-citation://v1/env-1/", "t3-citation://v1/%20env%20/"),
  goodHref.replace("thread%2Fwith%20slash", "bad%zz"),
  "t3-citation://v1/a/b" + goodQuery,
  "t3-citation://v1/a/b/c/d" + goodQuery,
  "t3-citation://v1/a/b/c",
  "t3-citation://v2/a/b/c" + goodQuery,
  "t3-citation://v1/a/b/c" + goodQuery.replace(/text=[^&]*/, "text="),
  "t3-citation://v1/a/b/c" + goodQuery.replace(/text=[^&]*/, "text=%20%20"),
  "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=&suffix=",
  "t3-citation://v1/a/b/c?text=x+y%2Bz&start=0&end=1&prefix=&suffix=",
  "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=" + "p".repeat(33) + "&suffix=",
  "t3-citation://v1/a/b/c?text=x&start=0&end=1&prefix=" + "p".repeat(32) + "&suffix=",
  "t3-citation://v1/%C3%A9/b/c?text=%F0%9F%98%80&start=0&end=1&prefix=&suffix=",
  "t3-citation://v1/%C0%AF/b/c?text=x&start=0&end=1&prefix=&suffix=",
  "t3-citation://v1/" + "e".repeat(513) + "/b/c?text=x&start=0&end=1&prefix=&suffix=",
  "http://nope",
]) {
  add("citationParse", { href }, cs.parseAssistantCitationHref(href));
}
const citText = `before ${k.citation} middle ${k.citationComment} end [Assistant quote](t3-citation://v1/bad) tail`;
for (const text of [citText, k.citation, "none", `${k.citation}${k.citation}`]) {
  add(
    "citationText",
    { text },
    {
      collect: cs.collectAssistantCitations(text),
      plain: cs.assistantCitationsToPlainText(text),
      rendered: cs.renderAssistantCitationsAsText(text),
    },
  );
}

// --- paste rules ----------------------------------------------------------------------------
for (const [name, text] of Object.entries(PASTE_TEXTS)) {
  for (const canAttach of [true, false])
    for (const bypassAutoAttachment of [false, true])
      for (const wouldExceedInputLimit of [false, true]) {
        const input = { name, text, canAttach, bypassAutoAttachment, wouldExceedInputLimit };
        add(
          "pasteDisposition",
          {
            ...input,
            text: undefined,
            repeat: [text.length > 0 ? [...text][0] : "", [...text].length],
          },
          s.textPaste.pastedTextDisposition({
            text,
            canAttach,
            bypassAutoAttachment,
            wouldExceedInputLimit,
          }),
        );
      }
}
add(
  "pasteDisposition",
  {
    name: "empty",
    text: "",
    repeat: ["", 0],
    canAttach: true,
    bypassAutoAttachment: false,
    wouldExceedInputLimit: true,
  },
  s.textPaste.pastedTextDisposition({ text: "", canAttach: true, wouldExceedInputLimit: true }),
);
for (const existing of [
  [],
  ["pasted-text.txt"],
  ["Pasted-Text.TXT", "pasted-text-2.txt"],
  ["pasted-text-2.txt"],
  ["a.txt", "pasted-text.txt", "pasted-text-2.txt", "pasted-text-3.txt"],
]) {
  add("pasteFileName", { existing }, s.textPaste.nextPastedTextFileName(existing));
}
for (const [value, start, end, text] of [
  ["hello", 1, 3, "XY"],
  ["hello", 0, 0, "😀"],
  ["", 0, 0, ""],
  ["abc", 5, 9, "d"],
  ["abc", 2, 1, "-"],
] as const) {
  add(
    "pasteReplace",
    { value, start, end, text },
    s.textPaste.replaceTextSelection({ value, selection: { start, end }, text }),
  );
}
for (const [valueLength, start, end, textLength, maxLength] of [
  [10, 0, 0, 5, 14],
  [10, 0, 0, 5, 15],
  [10, 2, 8, 100, 104],
  [10, 2, 8, 100, 103],
  [0, 0, 0, 0, 0],
  [5, 9, 12, 1, 5],
] as const) {
  add(
    "pasteLimit",
    { valueLength, start, end, textLength, maxLength },
    s.textPaste.wouldTextPasteExceedLimit({
      valueLength,
      selection: { start, end },
      textLength,
      maxLength,
    }),
  );
}

// --- clipboard fragments --------------------------------------------------------------------
const records = clipboardRecords();
const fragment = {
  version: 1,
  source: { environmentId: "env-1", threadId: "thread-1", messageId: "msg-1" },
  records,
};
const clip = s.clipboard;
const rawFragment = clip.encodeComposerContextFragment(fragment);
add("clipboardDecode", { raw: rawFragment }, clip.decodeComposerContextFragment(rawFragment));
for (const raw of [
  null,
  "",
  "not json",
  "{}",
  JSON.stringify({ version: 2, source: { environmentId: "e" }, records: [] }),
  JSON.stringify({ version: 1, source: { environmentId: " " }, records: [] }),
  JSON.stringify({ version: 1, source: { environmentId: " e " }, records: [] }),
  JSON.stringify({
    version: 1,
    source: { environmentId: "e" },
    records: [{ nonsense: 1 }, records[0], 5],
  }),
  JSON.stringify({ version: 1, source: { environmentId: "e", threadId: "" }, records: [] }),
  JSON.stringify({
    version: 1,
    source: { environmentId: "e" },
    records: Array.from({ length: 201 }, () => records[0]),
  }),
  JSON.stringify({
    version: 1,
    source: { environmentId: "e" },
    records: Array.from({ length: 200 }, () => records[0]),
  }),
]) {
  add("clipboardDecode", { raw }, clip.decodeComposerContextFragment(raw));
}
const html = clip.encodeComposerContextClipboardHtml("a < b & c > d", rawFragment);
add(
  "clipboardHtml",
  { text: "a < b & c > d", fragment: rawFragment },
  { html, decoded: clip.decodeComposerContextClipboardHtml(html) },
);
const html2 = clip.encodeComposerContextClipboardHtml("x", rawFragment, "<p>rich</p>");
add(
  "clipboardHtml",
  { text: "x", fragment: rawFragment, html: "<p>rich</p>" },
  { html: html2, decoded: clip.decodeComposerContextClipboardHtml(html2) },
);
for (const bad of [
  null,
  "",
  "<div>none</div>",
  '<div data-t3-context-fragment="%7Bnot">x</div>',
  "<div data-t3-context-fragment='%E0%A4%A'>x</div>",
]) {
  add(
    "clipboardHtml",
    { html: bad, decodeOnly: true },
    { decoded: clip.decodeComposerContextClipboardHtml(bad as any) },
  );
}
const pastedText = `${k.image} text ${k.terminal} ${k.preview}`;
const pasteCases: Array<[string, string | null, string | null]> = [
  [pastedText, rawFragment, null],
  [pastedText, null, html],
  [`only ${k.terminal}`, rawFragment, null],
  ["no chips", rawFragment, null],
  [pastedText, "garbage", html],
  [pastedText, null, null],
];
for (const [text, fragmentRaw, htmlRaw] of pasteCases) {
  const data = {
    getData: (type: string) =>
      type === "text/plain" ? text : type === "text/html" ? (htmlRaw ?? "") : (fragmentRaw ?? ""),
  };
  const read = s.inlineTokenPaste.readPastedComposerContext(data);
  const imported = s.inlineTokenPaste.importPastedComposerText(
    data,
    (frag: any) => new Map(frag.records.map((r: any) => [r.contextId, `${r.contextId}_x`])),
  );
  const importedNone = s.inlineTokenPaste.importPastedComposerText(data, () => new Map());
  const plain = s.inlineTokenPaste.importPastedComposerText(data);
  add(
    "clipboardRead",
    { text, fragment: fragmentRaw, html: htmlRaw },
    { read, imported, importedNone, plain },
  );
}
add(
  "attachmentName",
  { name: "short.txt" },
  s.inlineChip.middleTruncateAttachmentName("short.txt"),
);
for (const [name, max] of [
  ["a-very-long-attachment-name-with-extension.final.png", 36],
  ["abcdefghij", 5],
  ["abc", 0],
  ["abc", 1],
  ["😀😀😀😀😀😀😀😀", 4],
  ["abcdefghijklmnopqrstuvwxyz0123456789", 20],
  ["abcdefghijklmnopqrstuvwxyz", 17],
] as const) {
  add("attachmentName", { name, max }, s.inlineChip.middleTruncateAttachmentName(name, max));
}

// --- file links (what `@` inserts) -------------------------------------------------------------
for (const path of [
  "src/main.ts",
  "a b/c d.ts",
  "dir (1)/file[2].md",
  "ünï/çödé.ts",
  "back\\slash\\file.txt",
  "x#y?z.ts",
  "100%/done.ts",
  "😀/emoji.png",
  "/abs/path/to/file",
  "plain",
  "trailing/",
  "weird'quote\"s/a*b.ts",
  "~/home/@scope/pkg",
]) {
  const link = s.trigger.serializeComposerFileLink(path);
  add(
    "fileLink",
    { path },
    { link, tokens: s.inlineTokens.collectComposerInlineTokens(`${link} `) },
  );
}

// --- rich document model ---------------------------------------------------------------------
for (const c of await richDocCases(s, texts)) add("richDoc", c.input, c.output);

for (const c of historyCases(s)) add(c.group, c.input, c.output);
for (const c of await modelCases(s)) add(c.group, c.input, c.output);
for (const c of await layoutCases()) add(c.group, c.input, c.output);
for (const c of await contextCases()) add(c.group, c.input, c.output);
for (const c of await attachmentCases()) add(c.group, c.input, c.output);

// --- state machines ---------------------------------------------------------------------------
for (const c of await stateMachineCases(s)) add(c.group, c.input, c.output);

for (const [group, cases] of Object.entries(groups)) {
  writeFileSync(join(outDir, `${group}.json`), JSON.stringify(cases) + "\n");
}
if (check) {
  const have = new Set(readdirSync(committedDir));
  const diffs: string[] = [];
  for (const [group, cases] of Object.entries(groups)) {
    const file = `${group}.json`;
    if (!have.delete(file)) diffs.push(`new group ${group}`);
    else if (
      readFileSync(join(committedDir, file), "utf8") !== readFileSync(join(outDir, file), "utf8")
    )
      diffs.push(`changed ${group}`);
  }
  for (const file of have) diffs.push(`stale ${file}`);
  rmSync(outDir, { recursive: true, force: true });
  if (diffs.length) {
    console.error(`composer oracle --check: fixtures differ\n${diffs.join("\n")}`);
    process.exit(1);
  }
  console.log("composer oracle --check: fixtures match");
  process.exit(0);
}
rmSync(committedDir, { recursive: true, force: true });
mkdirSync(committedDir, { recursive: true });
for (const file of readdirSync(outDir))
  writeFileSync(join(committedDir, file), readFileSync(join(outDir, file)));
rmSync(outDir, { recursive: true, force: true });
const summary = Object.entries(groups)
  .map(([name, cases]) => `${name}=${cases.length}`)
  .join(" ");
console.log(
  `composer oracle: ${Object.keys(groups).length} groups, ${Object.values(groups).reduce((n, c) => n + c.length, 0)} cases\n${summary}`,
);

function clipboardRecords() {
  const base = (kind: string, id: string, label: string) => ({
    version: 1,
    contextId: id,
    kind,
    label,
  });
  return [
    {
      ...base("image", "image_abc123", "shot.png"),
      attachmentId: "att-1",
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: 123,
    },
    {
      ...base("file", "file_notes", "notes.md"),
      attachmentId: "att-2",
      name: "notes.md",
      mimeType: "text/markdown",
      sizeBytes: 45,
    },
    {
      ...base("terminal", "terminal_1", "Terminal 1 lines 3-4"),
      terminalId: "t1",
      terminalLabel: "Terminal 1",
      lineStart: 3,
      lineEnd: 4,
      text: "a\nb",
    },
    {
      ...base("review-comment", "review-comment_42", "#42"),
      sectionId: "pull-request:42",
      sectionTitle: "PR",
      filePath: "PR #42",
      startIndex: 0,
      endIndex: 0,
      rangeLabel: "PR",
      text: "",
      diff: "",
      pullRequest: {
        number: 42,
        title: "Fix",
        url: "https://x/42",
        headBranch: "a",
        baseBranch: "main",
        state: "open",
        isDraft: false,
      },
    },
    {
      ...base("preview-annotation", "preview-annotation_a", "Make it blue"),
      annotationId: "a",
      pageUrl: "https://example.com",
      pageTitle: null,
      comment: "blue",
      targetSummary: "1 selected element",
      styleChanges: ["color: red → blue"],
      screenshotContextId: "image_shot",
    },
    {
      ...base("image", "image_shot", "shot"),
      attachmentId: "att-3",
      name: "shot",
      mimeType: "image/png",
      sizeBytes: 1,
    },
    { ...base("mention", "mention_1", "a.ts"), path: "src/a.ts" },
    { ...base("skill", "skill_1", "frontend"), name: "frontend" },
    { version: 1, contextId: "future-1", kind: "future-kind", label: "Future", payload: { a: 1 } },
  ];
}
