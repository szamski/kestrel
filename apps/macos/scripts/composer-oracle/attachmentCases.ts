// Attachment classification, limits and upload state.
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";

type Case = { group: string; input: unknown; output: unknown };
const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

export async function attachmentCases(): Promise<Case[]> {
  const out: Case[] = [];
  const add = (group: string, input: unknown, output: unknown) =>
    out.push({ group, input, output });
  const files = await imp("apps/web/src/components/chat/composerAttachmentFiles.ts");
  const state = await imp("apps/web/src/lib/attachmentUploadState.ts");
  const compression = await imp("apps/web/src/lib/imageCompression.ts");
  const video = await imp("packages/shared/src/video.ts");
  const attachments = await imp("packages/client-runtime/src/state/attachments.ts");
  const contracts = await imp("packages/contracts/src/index.ts");
  const draftStore = await imp("apps/web/src/composerDraftStore.ts");

  const names = [
    "photo.jpg",
    "PHOTO.JPEG",
    "a.png",
    "b.webp",
    "c.gif",
    "d.heic",
    "D.HEIF",
    "e.tiff",
    "noext",
    ".hidden",
    "clip.mp4",
    "clip.MOV",
    "doc.pdf",
    "archive.tar.gz",
    "a.b.c.png",
    "",
  ];
  const types = [
    "",
    "application/octet-stream",
    "image/png",
    "image/heic",
    "image/HEIF",
    "image/tiff",
    "image/svg+xml",
    "video/mp4",
    "video/quicktime; codecs=x",
    "text/plain",
    "binary/octet-stream",
    "application/pdf",
    "IMAGE/JPEG",
  ];
  for (const name of names)
    for (const type of types) {
      add(
        "attachmentClassify",
        { name, type },
        {
          kind: files.classifyComposerAttachmentFile({ name, type }),
          inferred: files.inferImageMimeTypeFromName(name),
          heic: compression.isHeicImageFile({ name, type }),
          video: video.videoMimeType({ name, mimeType: type }),
        },
      );
    }
  const pasteCases = [
    { files: [{ name: "a.png", type: "image/png" }], plainText: "x" },
    { files: [{ name: "a.pdf", type: "application/pdf" }], plainText: "" },
    { files: [{ name: "a.pdf", type: "application/pdf" }], plainText: "text" },
    { files: [], plainText: "" },
    { files: [{ name: "a.tiff", type: "image/tiff" }], plainText: "" },
    {
      files: [
        { name: "a.pdf", type: "application/pdf" },
        { name: "b.jpg", type: "" },
      ],
      plainText: "t",
    },
  ];
  for (const input of pasteCases)
    add("attachmentPaste", input, files.shouldHandleComposerAttachmentPaste(input));
  for (const attachmentUploadsCapabilityKnown of [false, true])
    for (const supportsAttachmentUploads of [false, true])
      for (const maxFileAttachmentBytes of [null, 1024, 5 * 1024 * 1024, 80 * 1024 * 1024]) {
        const capabilities = {
          attachmentUploadsCapabilityKnown,
          supportsAttachmentUploads,
          maxFileAttachmentBytes,
        };
        for (const list of [
          [],
          [{ name: "a.txt", sizeBytes: 10 }],
          [
            { name: "big.bin", sizeBytes: 6 * 1024 * 1024 },
            { name: "ok", sizeBytes: 1 },
          ],
          [{ name: "x", sizeBytes: 2048 }],
        ]) {
          add(
            "attachmentLimits",
            { capabilities, files: list },
            {
              staging: files.fileAttachmentStagingLimit(capabilities),
              reason: files.fileAttachmentCapabilityBlockReason({ ...capabilities, files: list }),
            },
          );
        }
      }
  for (const bytes of [
    0, 1, 1023, 1024, 1025, 1536, 1048575, 1048576, 1310720, 1572864, 2621440, 5242880, 52428800,
    1153434,
  ])
    add("attachmentSize", { bytes }, attachments.formatAttachmentSize(bytes));
  for (const [name, bytes] of [
    ["a.txt", 1],
    ["a.txt", 1024],
    ["a.txt", 1048576],
    ["a.txt", 5242880],
    ["a.txt", 1500000],
    ["a.txt", 2048],
    ["a.txt", 1536],
    ["it's", 0],
  ] as const)
    add(
      "attachmentTooLarge",
      { name, bytes },
      attachments.fileAttachmentTooLargeMessage(name, bytes),
    );
  for (const bytes of [10, 50 * 1024 * 1024, 100 * 1024 * 1024])
    add("attachmentClamp", { bytes }, attachments.clampFileAttachmentUploadBytes(bytes));
  const limitCases = [
    { attachments: [] },
    {
      attachments: Array.from({ length: 101 }, () => ({
        type: "file",
        mimeType: "text/plain",
        sizeBytes: 1,
      })),
    },
    {
      attachments: Array.from({ length: 100 }, () => ({
        type: "file",
        mimeType: "text/plain",
        sizeBytes: 1,
      })),
    },
    {
      attachments: [
        { type: "image", mimeType: "image/png", sizeBytes: 80 * 1024 * 1024 },
        { type: "image", mimeType: "image/png", sizeBytes: 1 },
      ],
    },
    { attachments: [{ type: "file", mimeType: "image/png", sizeBytes: 80 * 1024 * 1024 + 1 }] },
    { attachments: [{ type: "file", mimeType: "application/pdf", sizeBytes: 90 * 1024 * 1024 }] },
  ];
  for (const input of limitCases)
    add(
      "attachmentProviderLimit",
      {
        count: input.attachments.length,
        first: input.attachments[0] ?? null,
        second: input.attachments[1] ?? null,
        all: input.attachments.length > 2 ? input.attachments[0] : null,
      },
      contracts.getProviderAttachmentLimitError(input.attachments) ?? null,
    );
  const uploadCases: Array<Record<string, any>> = [
    {},
    { a: { status: "ready", environmentId: "e", attachmentId: "x" } },
    { a: { status: "failed", environmentId: "e", reason: "r" } },
    { a: { status: "uploading", environmentId: "e", progress: 0.5 } },
    { a: { status: "ready", environmentId: "other", attachmentId: "x" } },
    {
      a: { status: "failed", environmentId: "e", reason: "r" },
      b: { status: "failed", environmentId: "e", reason: "r" },
    },
    {
      a: { status: "ready", environmentId: "e", attachmentId: "x" },
      b: { status: "uploading", environmentId: "e", progress: 0.1 },
    },
  ];
  for (const uploadsByImageId of uploadCases)
    for (const imageIds of [[], ["a"], ["a", "b"], ["a", "b", "c"]]) {
      add(
        "attachmentUploadBlock",
        { uploads: uploadsByImageId, imageIds },
        state.attachmentUploadBlockReason({ imageIds, uploadsByImageId, environmentId: "e" }),
      );
    }
  for (const progress of [0, 0.5, 0.999, 1, 1.5, -1, Number.NaN, 0.123456])
    add(
      "attachmentProgress",
      { progress: Number.isNaN(progress) ? "nan" : progress },
      state.formatAttachmentUploadProgress(progress),
    );
  const marker = (name: string, mimeType: string, sizeBytes: number) => ({
    name,
    mimeType,
    sizeBytes,
  });
  for (const [m, f] of [
    [marker("a.mp4", "", 5), marker("a.mp4", "video/mp4", 5)],
    [marker("a.mp4", "application/octet-stream", 5), marker("a.mp4", "video/mp4", 5)],
    [marker("a.txt", "", 5), marker("a.txt", "text/plain", 5)],
    [marker("a.mp4", "video/mp4", 5), marker("a.mp4", "video/mp4", 5)],
    [marker("a.mp4", "video/mp4", 5), marker("b.mp4", "video/mp4", 5)],
    [marker("a.mp4", "", 5), marker("a.mp4", "video/mp4", 6)],
    [marker("a.bin", "", 5), marker("a.bin", "video/mp4", 5)],
  ] as const)
    add(
      "attachmentReattach",
      { marker: m, file: f },
      draftStore.composerFileMatchesReattachMarker(m, f),
    );
  return out;
}
