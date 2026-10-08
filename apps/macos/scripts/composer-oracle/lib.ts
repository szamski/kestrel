// Loads the real web/shared composer sources by file URL, so the Swift port is compared against
// the code that ships. apps/web uses bundler-style extensionless imports and the `~/` alias;
// resolve both for node.
import { createRequire, registerHooks } from "node:module";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { repoRoot, macosRoot } from "../lib/load.ts";

const webSrc = join(repoRoot, "apps", "web", "src");
// Several composer modules import components (.tsx) and re-use value-style imports of types.
// The workspace root ships the native TypeScript 7 compiler (no JS API); a 6.x copy sits in the store.
const pnpmStore = join(repoRoot, "node_modules", ".pnpm");
const tsDir = readdirSync(pnpmStore).find((name) => /^typescript@6\./.test(name));
if (!tsDir) throw new Error("typescript 6.x JS compiler not found in node_modules/.pnpm");
const ts = createRequire(join(pnpmStore, tsDir, "node_modules", "typescript", "package.json"))(
  "typescript",
);

registerHooks({
  load(url, context, nextLoad) {
    // Full TypeScript transpile (not node's strip-only mode) so type-only named imports are elided.
    if (
      (url.endsWith(".tsx") || url.endsWith(".ts")) &&
      !url.includes("/node_modules/") &&
      !url.endsWith(".d.ts")
    ) {
      const source = readFileSync(fileURLToPath(url), "utf8");
      const { outputText } = ts.transpileModule(source, {
        compilerOptions: {
          module: ts.ModuleKind.ESNext,
          target: ts.ScriptTarget.ES2022,
          jsx: ts.JsxEmit.ReactJSX,
        },
      });
      // Vite injects `import.meta.env`; an empty object is what the unit tests see too.
      return {
        format: "module",
        source: `import.meta.env ??= {};\n${outputText}`,
        shortCircuit: true,
      };
    }
    if (/\.(css|svg|png|woff2?)(\?.*)?$/.test(url))
      return { format: "module", source: "export default {};", shortCircuit: true };
    return nextLoad(url, context);
  },
});

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith("~/")) {
      return resolveWithSuffixes(
        pathToFileURL(join(webSrc, specifier.slice(2))).href,
        context,
        nextResolve,
      );
    }
    try {
      return nextResolve(specifier, context);
    } catch (error: any) {
      if (!/^\.{1,2}\//.test(specifier)) {
        // Bare packages that only apps/web depends on (tiptap) resolve from there.
        return nextResolve(specifier, {
          ...context,
          parentURL: pathToFileURL(join(webSrc, "index.ts")).href,
        });
      }
      return resolveWithSuffixes(specifier, context, nextResolve, error);
    }
  },
});

function resolveWithSuffixes(
  specifier: string,
  context: any,
  nextResolve: any,
  original?: unknown,
) {
  for (const suffix of ["", ".ts", ".tsx", "/index.ts"]) {
    try {
      return nextResolve(specifier + suffix, context);
    } catch {}
  }
  throw original ?? new Error(`Cannot resolve ${specifier}`);
}

const imp = (path: string) => import(pathToFileURL(join(repoRoot, path)).href);

export const oracleRoot = join(
  macosRoot,
  "T3Kit",
  "Tests",
  "T3ComposerTests",
  "Fixtures",
  "oracle",
);

export async function loadSources() {
  const web = "apps/web/src/";
  const shared = "packages/shared/src/";
  const [
    logic,
    mentions,
    richDoc,
    richText,
    listContinuation,
    trigger,
    inlineTokens,
    contextRefs,
    citations,
    clipboard,
    libRefs,
    textPaste,
    inlineTokenPaste,
    inlineChip,
    promptHistory,
    submission,
    model,
  ] = await Promise.all([
    imp(web + "composer-logic.ts"),
    imp(web + "composer-editor-mentions.ts"),
    imp(web + "composer-rich-text-doc.ts"),
    imp(web + "composer-rich-text.ts"),
    imp(web + "composer-list-continuation.ts"),
    imp(shared + "composerTrigger.ts"),
    imp(shared + "composerInlineTokens.ts"),
    imp(shared + "composerContextReferences.ts"),
    imp(shared + "assistantCitations.ts"),
    imp(shared + "composerContextClipboard.ts"),
    imp(web + "lib/composerContextReferences.ts"),
    imp("packages/client-runtime/src/textPaste.ts"),
    imp(web + "components/composerInlineTokenPaste.ts"),
    imp(web + "components/composerInlineChip.ts"),
    imp(web + "components/chat/composerPromptHistory.ts"),
    imp(web + "components/chat/composerSubmission.ts"),
    imp(shared + "model.ts"),
  ]);
  return {
    logic,
    mentions,
    richDoc,
    richText,
    listContinuation,
    trigger,
    inlineTokens,
    contextRefs,
    citations,
    clipboard,
    libRefs,
    textPaste,
    inlineTokenPaste,
    inlineChip,
    promptHistory,
    submission,
    model,
  };
}
export type Sources = Awaited<ReturnType<typeof loadSources>>;
