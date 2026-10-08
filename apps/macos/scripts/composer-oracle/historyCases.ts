// Prompt recall, prompt validation and the outgoing-prompt helpers.
import type { Sources } from "./lib.ts";
import { chipSamples, citations } from "./corpus.ts";

type Case = { group: string; input: unknown; output: unknown };

export function historyCases(s: Sources): Case[] {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  const k = chipSamples(s);
  const h = s.promptHistory;

  const recallTexts = [
    "plain prompt",
    "  padded  ",
    "Ultrathink:\nthink hard",
    'text\n\n<review_comment id="1">\nbody\n</review_comment>',
    "text\n<review_comment>a</review_comment>\n<review_comment>b</review_comment>",
    "typed <review_comment>keep</review_comment> middle\n\n<review_comment>tail</review_comment>",
    "<review_comment>only</review_comment>",
    "do it\n\n<terminal_context>\n- Terminal 1 lines 12-13:\n  12 | a\n  13 | b\n</terminal_context>",
    "see @terminal-1:12-13 now\n\n<terminal_context>\n- Terminal 1 lines 12-13:\n  12 | a\n</terminal_context>",
    "keep @terminal-1:4-12 but drop @terminal-1:4\n<terminal_context>\n- Terminal 1 line 4:\n  4 | x\n</terminal_context>",
    "msg\n<element_context>\n- div.card:\n  html\n</element_context>",
    "msg\n<preview_annotation>\nId: a\nPage: x\n</preview_annotation>",
    "msg\n<preview_annotation>\n</preview_annotation>",
    "msg\n<terminal_context>\nno headers\n</terminal_context>",
    `with chip ${k.image} and ${k.terminal} end`,
    `${k.file}`,
    `trailing ${k.file} `,
    h.ATTACHMENT_ONLY_BOOTSTRAP_PROMPT,
    `PLEASE IMPLEMENT THIS PLAN:\n# Plan`,
    "",
    "   ",
  ];
  for (const text of recallTexts) add("recallable", { text }, h.recallableComposerPrompt(text));

  const messageSets: Array<Array<{ id: string; role: string; text: string }>> = [
    [],
    [{ id: "a", role: "assistant", text: "hi" }],
    [
      { id: "1", role: "user", text: "one" },
      { id: "2", role: "assistant", text: "x" },
      { id: "3", role: "user", text: "two" },
    ],
    [
      { id: "1", role: "user", text: "same" },
      { id: "2", role: "user", text: "same" },
      { id: "3", role: "user", text: "other" },
      { id: "4", role: "user", text: "same" },
    ],
    [
      { id: "1", role: "user", text: h.ATTACHMENT_ONLY_BOOTSTRAP_PROMPT },
      { id: "2", role: "user", text: "real" },
    ],
  ];
  for (const messages of messageSets) {
    const entries = h.buildComposerPromptHistoryEntries(messages);
    add("historyEntries", { messages }, entries);
    const positions: Array<{ entryId: string; recalled: string } | null> = [
      null,
      ...entries.map((e: any) => ({ entryId: e.id, recalled: e.prompt })),
      { entryId: "gone", recalled: entries[0]?.prompt ?? "none" },
    ];
    for (const position of positions)
      for (const currentPrompt of ["", "typed", ...entries.map((e: any) => e.prompt)])
        for (const direction of ["backward", "forward"]) {
          const input = { entries, position, currentPrompt, direction };
          add("historyStep", input, h.stepComposerPromptHistory(input));
        }
  }

  // validation
  const c = citations(s);
  const big = (n: number) => "x".repeat(n);
  const cite = (text: string, comment?: string) =>
    s.citations.serializeAssistantCitation({ ...c.base, text, ...(comment ? { comment } : {}) });
  const prompts: Array<{ name: string; prompt: string }> = [
    { name: "small", prompt: "hello" },
    { name: "exact", prompt: big(120_000) },
    { name: "over1", prompt: big(120_001) },
    { name: "over2", prompt: big(120_002) },
    { name: "over1234", prompt: big(121_234) },
    { name: "padded", prompt: `  ${big(120_000)}  ` },
    { name: "cite", prompt: `hi ${cite("quote <b> & more")}` },
    { name: "citeComment", prompt: `hi ${cite("quote", 'my "comment"\nline')}` },
    { name: "citeTwice", prompt: `${cite("a")} and ${cite("a")} and ${cite("b")}` },
    { name: "citeBig", prompt: "" },
  ];
  // Large prompts are described rather than stored: `parts` is a list of [text, repeatCount].
  const described = (prompt: string): Array<[string, number]> => [[prompt, 1]];
  const bigParts: Record<string, Array<[string, number]>> = {};
  for (const { name, prompt } of prompts) {
    const parts: Array<[string, number]> =
      prompt.length > 1000 && /^ *x+ *$/.test(prompt)
        ? [
            [prompt.match(/^ */)![0], 1],
            ["x", prompt.trim().length],
            [prompt.match(/ *$/)![0], 1],
          ]
        : name === "citeBig"
          ? [
              ["x", 110_000],
              [cite("x".repeat(7000), "y".repeat(1000)), 1],
              [cite("x".repeat(7000) + "y", "c"), 1],
            ]
          : described(prompt);
    bigParts[name] = parts;
    const rebuilt = parts.map(([text, count]) => text.repeat(count)).join("");
    const actualPrompt = name === "citeBig" ? rebuilt : prompt;
    add(
      "promptValidation",
      { name, parts },
      {
        message: s.submission.getComposerPromptLengthValidationMessage(actualPrompt),
        expanded: s.citations.expandAssistantCitationsForProvider(actualPrompt.trim()).length,
      },
    );
  }
  for (const [prompt, effort] of [
    ["hello", "ultrathink"],
    ["/deploy.prod now", "ultrathink"],
    ["/home/theo/app.ts", "ultrathink"],
    ["/plugin:skill x", "ultrathink"],
    ["Ultrathink:\nx", "ultrathink"],
    ["  ", "ultrathink"],
    ["hello", "high"],
    ["hello", null],
    ["/a", "ultrathink"],
    ["/", "ultrathink"],
    ["//x", "ultrathink"],
  ] as const) {
    add("effortPrefix", { prompt, effort }, s.model.applyClaudePromptEffortPrefix(prompt, effort));
  }
  for (const text of [
    "ultrathink about this",
    "Ultrathink",
    "xultrathink",
    "ultrathinkx",
    "no",
    "think ULTRATHINK!",
    "_ultrathink_",
    "ultra think",
    "",
  ]) {
    add("ultrathink", { text }, s.model.isClaudeUltrathinkPrompt(text));
  }
  return out;
}
