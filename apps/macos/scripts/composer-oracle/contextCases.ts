// Chip labels, pull-request chips, attachment records and `#` menu matching.
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";

type Case = { group: string; input: unknown; output: unknown };
const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

export async function contextCases(): Promise<Case[]> {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  const records = await imp("apps/web/src/lib/composerContextRecords.ts");
  const terminal = await imp("apps/web/src/lib/terminalContext.ts");
  const prLogic = await imp("apps/web/src/components/pullRequest/pullRequestDetail.logic.ts");
  const prList = await imp("apps/web/src/components/pullRequest/pullRequestList.logic.ts");
  const prMatches = await imp("packages/shared/src/composerPullRequestMatches.ts");

  const review = (extra: Record<string, unknown>) => ({
    id: "c1",
    sectionId: "s",
    sectionTitle: "Section",
    filePath: "src/a.ts",
    startIndex: 0,
    endIndex: 3,
    rangeLabel: "+12",
    text: "t",
    diff: "d",
    ...extra,
  });
  const pr = (state: string, isDraft: boolean) => ({
    number: 7,
    title: "Fix it",
    url: "https://x/7",
    headBranch: "a",
    baseBranch: "main",
    state,
    isDraft,
  });
  const comments = [
    review({}),
    review({ rangeLabel: "-3 to -5" }),
    review({ rangeLabel: "+3 to +9" }),
    review({ rangeLabel: "+3 to -9" }),
    review({ rangeLabel: "L4" }),
    review({ rangeLabel: "x", filePath: "C:\\dir\\file.ts" }),
    review({ filePath: "PR #42", sectionId: "pull-request:42", diff: "" }),
    review({ filePath: "PR #42", sectionId: "other", diff: "" }),
    review({ filePath: "PR #42", sectionId: "pull-request:42", diff: "d" }),
    review({ filePath: "PR #x", sectionId: "pull-request:42", diff: "" }),
    review({ pullRequest: pr("open", false) }),
    review({ pullRequest: pr("open", true) }),
    review({ pullRequest: pr("merged", false) }),
    review({ pullRequest: pr("closed", true) }),
  ];
  for (const comment of comments) {
    add(
      "reviewLabels",
      { comment },
      {
        label: records.reviewCommentContextLabel(comment),
        isPullRequest: records.isPullRequestSummaryContext(comment),
        state: records.pullRequestContextDisplayState(comment),
        kindLabel: records.pullRequestContextKindLabel(comment),
      },
    );
  }
  for (const [comment, pageTitle] of [
    ["  Make   it blue ", null],
    ["", "Title"],
    ["   ", "  "],
    ["x".repeat(60), null],
    ["é".repeat(60), "t"],
    ["", null],
  ] as const) {
    add(
      "previewLabel",
      { comment, pageTitle },
      records.previewAnnotationContextLabel({ comment, pageTitle: pageTitle ?? undefined }),
    );
  }
  for (const [label, lineStart, lineEnd] of [
    ["Terminal 1", 3, 4],
    ["T", 5, 5],
  ] as const)
    add(
      "terminalLabel",
      { label, lineStart, lineEnd },
      terminal.formatTerminalContextLabel({ terminalLabel: label, lineStart, lineEnd }),
    );
  for (const text of ["", "\n\nabc\n\n", "a\r\nb\r\n", "\r\n\r\nx", "  keep  ", "\n \n"])
    add("terminalText", { text }, terminal.normalizeTerminalContextText(text));

  for (const metadata of [
    pr("open", false),
    {
      ...pr("merged", false),
      title: "  multi\nline   title  ",
      url: "https://x/" + "u".repeat(1100),
    },
    { ...pr("open", true), number: 123, headBranch: "feat/a b" },
  ]) {
    const context = prLogic.buildPullRequestReferenceContext(metadata);
    add("pullRequestRecord", { metadata }, records.reviewCommentContextRecord(context));
  }

  const attachments = [
    { type: "image", id: "img 1", name: "shot.png", mimeType: "image/png", sizeBytes: 100 },
    {
      type: "file",
      id: "file-2",
      name: "notes [draft].md",
      mimeType: "text/markdown",
      sizeBytes: 5,
    },
    { type: "image", id: "Weird:ID/3", name: "", mimeType: "image/webp", sizeBytes: 1 },
  ];
  for (const attachment of attachments) {
    add(
      "attachmentRecord",
      { attachment, attachmentId: "server-1" },
      {
        record: records.attachmentContextRecord({ attachment, attachmentId: "server-1" }),
        reference:
          attachment.type === "image"
            ? records.imageContextReference(attachment)
            : records.fileContextReference(attachment),
      },
    );
  }

  // `#` menu
  const entry = (n: number, extra: Record<string, unknown> = {}) => ({
    number: n,
    projectId: "p1",
    repository: "Org/Repo",
    title: `Title ${n}`,
    url: `https://x/${n}`,
    state: "open",
    isDraft: false,
    headBranch: `branch-${n}`,
    baseBranch: "main",
    updatedAt: `2026-01-${String(10 + (n % 20)).padStart(2, "0")}T00:00:00Z`,
    author: { login: n % 2 ? "alice" : "bob" },
    ...extra,
  });
  const entries = [
    entry(1),
    entry(12),
    entry(123),
    entry(21),
    entry(121, { title: "welcome wizard fix" }),
    entry(5, { repository: "other/repo" }),
    entry(6, { projectId: "p2" }),
    entry(12, { title: "dupe" }),
    entry(31, { headBranch: "wizard-welcome" }),
    entry(40, { author: { login: "carol" } }),
  ];
  for (const query of ["", "1", "12", "121", "9", "99"]) {
    const matches = prMatches.filterComposerPullRequestMatches({
      entries,
      projectId: "p1",
      repository: " org/repo ",
      query,
      limit: 12,
    });
    add(
      "pullRequestNumeric",
      { query },
      matches.map((m: any) => `${m.number}:${m.title}`),
    );
  }
  for (const query of [
    "",
    "welcome",
    "wizard welcome",
    "alice",
    "branch-3",
    "title",
    "org/repo",
    "#12",
    "12",
    "zzz",
    "wizard",
  ]) {
    add(
      "pullRequestRank",
      { query },
      {
        ranked: prList
          .rankPullRequestMatches(entries, query)
          .map((m: any) => `${m.number}:${m.title}`),
        matches: entries.map((m: any) => prList.matchesPullRequestQuery(m, query)),
        scores: entries.map((m: any) => prList.scorePullRequestMatch(m, query)),
      },
    );
  }
  return out;
}
