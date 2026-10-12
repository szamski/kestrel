// Inputs shared by every oracle group: drafts with chips, emoji and surrogate pairs, CRLF, nested
// lists, every trigger (including currency symbols), paste cases and legacy references.
import type { Sources } from "./lib.ts";

export const SELECTOR = "p:nth-child(2)";

export function citations(s: Sources) {
  const base = {
    version: 1,
    environmentId: "env-1",
    threadId: "thread/with slash",
    messageId: "msg:1 (a)",
    text: "Quote with *markup*, [brackets], émoji 😀 & symbols? #1",
    start: 3,
    end: 41,
    prefix: "before ",
    suffix: " after",
  };
  const withComment = { ...base, comment: "Please check this + that" };
  const multiline = { ...base, text: "line one\nline two\ttabbed", prefix: "", suffix: "" };
  return { base, withComment, multiline, all: [base, withComment, multiline] };
}

export function chipSamples(s: Sources) {
  const c = citations(s);
  return {
    image: "![shot.png](t3-context://v1/image/image_abc123)",
    file: "[notes.md](t3-context://v1/file/file_notes)",
    terminal: "[Terminal 1 lines 3-4](t3-context://v1/terminal/terminal_1)",
    review: "[#42](t3-context://v1/review-comment/review-comment_42)",
    preview: "[Make it blue](t3-context://v1/preview-annotation/preview-annotation_a)",
    unknownKind: "[Thing](t3-context://v1/future-kind/ctx-1)",
    citation: s.citations.serializeAssistantCitation(c.base),
    citationComment: s.citations.serializeAssistantCitation(c.withComment),
    fileLink: "[main.ts](src/main.ts)",
    fileLinkEncoded: "[my file (1).ts](src/my%20file%20%281%29.ts)",
    quotedMention: '@"my dir/a b.ts"',
    mention: "@src/lib/util.ts",
    skill: "$frontend-design",
  };
}

/** Drafts used by segmentation, cursor maps, trigger detection and the rich document model. */
export function drafts(s: Sources): string[] {
  const k = chipSamples(s);
  return [
    "",
    " ",
    "\n",
    "hello",
    "hello world",
    "  leading and trailing  ",
    "a\nb",
    "a\r\nb",
    "line1\n\nline3\n",
    "\n\ntrailing newlines\n\n",
    "tab\tseparated\ttext",
    // mentions, skills, currency
    `Look at ${k.mention} and ${k.quotedMention} please`,
    `${k.mention} `,
    `${k.mention}`,
    `see ${k.fileLink} now`,
    `see ${k.fileLinkEncoded} now`,
    `[a.ts](a.ts) [b.ts](b.ts) `,
    "@scope/package and @org/name/sub path",
    '@ alone and @@double and @"unterminated',
    "email me at a@b.com now",
    `use ${k.skill} please`,
    "use $a1 and $x:y and $_bad and $-bad ",
    "prices $20 $20k $100M $1e6 $3 and $5x ",
    "€skill £skill ¥skill ₹skill ₿skill 𑿝skill ",
    "Use €my-skill for €20 please",
    "$ alone $1 $999 $12abc $abc12 end",
    // chips
    `hi ${k.image} there`,
    `${k.image}${k.file}`,
    `${k.terminal} then ${k.review} then ${k.preview}`,
    `${k.unknownKind} and ${k.file}`,
    `quote ${k.citation} and ${k.citationComment} end`,
    `${k.citation}`,
    `@unfinished ${k.file}`,
    `@ab[x](t3-context://v1/file/f1) `,
    `[bad label](t3-context://v2/file/f1) [bad](t3-context://v1/File/f1/extra) [ok](t3-context://v1/file/F_1)`,
    `![i](t3-context://v1/image/i1) ![j](t3-context://v1/file/j1)`,
    // emoji and surrogate pairs
    "😀 @a.ts x",
    "👍🏽 **bold** 🧑‍💻",
    `a😀b ${k.skill} 😀`,
    `😀${k.image}😀`,
    "日本語 **太字** と `コード`",
    // inline styling
    "**bold** and *it* and ~~s~~ and `code`",
    "***both*** and **a *b* c**",
    "__u__ and _i_ and snake_case_word and 2 * 3 * 4",
    "*unclosed and **unclosed and ~~unclosed and `unclosed",
    "`a\nb` ``x`` `` `y` ``",
    "\\*escaped\\* and \\**x**",
    "**bold with trailing space **and more",
    `**see ${k.image} here** and *${k.file}*`,
    `**${k.mention} **`,
    "**bold**text *a*b ~~x~~y",
    "~single~ and ~~~triple~~~",
    "**a** **b** *c* *d*",
    "*a **b** c*",
    "**a *b ** c*",
    "`code **not bold**` **bold `code` bold**",
    // task lists
    "- [ ] a\n- [x] b\n  - [ ] nested\n    - [X] deep\n- [ ] c",
    "- [ ]\n",
    "- [ ]",
    "- [ ]x",
    "- [ ]  two",
    "-\t[ ]\ttab",
    "  - [ ] indented first\n- [ ] second",
    "text\n- [ ] a\ntext\n- [x] b",
    `- [ ] with ${k.image} chip\n- [x] **bold** item`,
    "- [ ] a\n    - [ ] deep\n  - [ ] shallow\n- [ ] top",
    "  - [ ] a\n - [ ] b",
    // plain lists and other markdown that stays literal
    "- a\n  - b\n1. x\n2) y\n+ z\n* w",
    "# heading\n> quote\n```js\ncode\n```",
    "1. one\n2. two\n3.",
    "- \n- x",
    "09. nine\n99999999999999999999. big",
    " nbsp start emspace",
    "x".repeat(60),
  ];
}

/**
 * Drafts for the rich document's block syntax: fences, quotes, headings, rules and plain lists.
 * Only the rich document model reads them (its blocks decide the run table and the editor storage).
 */
export function blockDrafts(s: Sources): string[] {
  const k = chipSamples(s);
  return [
    // fences
    "```js\ncode\n```",
    "```\n```",
    "```",
    "```js",
    "```js\n",
    "~~~\nx\n~~~",
    "````\n```\ninner\n```\n````",
    "```\na\n\nb\n```\ntext after",
    "```js\nunclosed\nline",
    "text\n```py\nx = 1\n```\nmore",
    "```a`b\ncode",
    " ```indented\nx\n ```",
    "``` ts  \nx\n```  ",
    "```\n**not bold** and - [ ] not a task\n```",
    "```\none\n```\n```\ntwo\n```",
    "```js\nlet a = 1;\n```\n```py\nb = 2\n```\n> quote",
    `\`\`\`\nsee ${k.file} and ${k.mention} here\n\`\`\``,
    `\`\`\`${k.skill}\nbody\n\`\`\``,
    "```\r\ncode\r\n```\r\nafter",
    "```\n\n```",
    "``\nnot a fence\n``",
    // quotes
    "> quote",
    ">quote",
    ">",
    "> ",
    "> a\n> b",
    "> a\n>  b\n> c",
    ">\n> x",
    "> **bold** and `code` and *it*",
    "> - not a list\n> 1. nor this",
    "> > nested",
    "> a\n\n> b",
    `> ${k.mention} hi ${k.image}`,
    "text\n> quote\ntext",
    "> a\r\n> b",
    // headings
    "# h1",
    "###### h6",
    "####### seven",
    "#nospace",
    "#1234 pr reference",
    "#\ttab",
    "# ",
    "#",
    "## **bold** head",
    "# a\ntext\n## b",
    `# ${k.file} and ${k.skill}`,
    "#  two spaces  ",
    "# closing ##",
    // rules
    "---",
    "***",
    "___",
    "- - -",
    "* * *",
    "text\n---\ntext",
    "a\n---",
    "---\n",
    "--",
    "---x",
    "- a\n---\n- b",
    "***bold***",
    "---\n---",
    "- [ ] a\n---\n- [ ] b",
    "> quote\n---\n# head",
    // lists
    "- a\n* b",
    "1. a\n1) b",
    "- a\n  1. b\n  2. c\n- d",
    "- a\n- [ ] t\n- b",
    "- [ ] a\n- b",
    "10. ten\n 11. eleven",
    "- a\n\n- b",
    "   - three spaces",
    "- a\n    - deep\n  - shallow\n- top",
    "* [ ] star task\n+ [x] plus task",
    "- [ ]x\n- [x]y",
    "- a **bold** `c` item\n2. b ~~s~~",
    `- ${k.file}\n- ${k.image} chip`,
    "- a\n```\ncode\n```\n- b",
    "- a\n# head\n- b",
    "0. zero\n1. one",
  ];
}

/** Drafts the editor answers with verbatim (`literalText`): Markdown and context tokens stay text. */
export function literalDrafts(s: Sources): string[] {
  const k = chipSamples(s);
  return [
    "",
    "plain",
    "- [X] done $my-skill ",
    "Use @README",
    `see ${k.file} and ${k.image}`,
    "**bold** `code` # heading\n> quote\n```js\nx\n```",
    "a\n\nb\n",
    "  - [ ] task\n1. one",
    "😀 $skill 😀",
  ];
}

/** Lines whose list behavior matters. */
export function listDrafts(s: Sources): string[] {
  const k = chipSamples(s);
  return [
    "- item",
    "- ",
    "-",
    "- item\n- second",
    "1. one",
    "9. nine",
    "09. padded",
    "1) paren",
    "99999999999999999999. overflow",
    "9007199254740991. max safe",
    "- [ ] task",
    "- [x] done",
    "- [X] done",
    "- [ ] ",
    "- [ ]",
    "  - nested",
    "\t- tab nested",
    "* star",
    "+ plus",
    "plain line",
    "plain\n- list after",
    `- with chip ${k.file} tail`,
    `- ${k.image}`,
    "text before\n1. a\n2. b\ntext after",
    "-  two spaces",
    "-\tTab sep",
    "1.\tTab",
    "- [ ]x",
    "---",
    "-item",
    "",
    "\n- a",
  ];
}

export const PASTE_TEXTS = {
  small: "hello",
  atThreshold: "a".repeat(32 * 1024),
  belowThreshold: "a".repeat(32 * 1024 - 1),
  multibyte: "é".repeat(16 * 1024),
  multibyteBelow: "é".repeat(16 * 1024 - 1),
  emoji: "😀".repeat(8 * 1024),
};
