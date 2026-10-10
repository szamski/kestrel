// Prints the Swift table of the T3 MCP tool inventory (T3Kit/Sources/T3Timeline/V2/T3McpTools.swift)
// from packages/shared/src/t3McpToolPresentation.ts:  node scripts/timeline-oracle/gen-t3-tools.ts
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repoRoot } from "../lib/load.ts";

const m: any = await import(
  pathToFileURL(join(repoRoot, "packages/shared/src/t3McpToolPresentation.ts")).href
);
const q = (s: string) => JSON.stringify(s);
for (const name of m.T3_MCP_TOOL_NAMES as Set<string>) {
  const d = m.resolveT3McpToolDefinition(name);
  const icon = d.icon.replace(/-(\w)/g, (_: string, c: string) => c.toUpperCase());
  console.log(
    `  ${q(name)}: T3McpToolDefinition(displayName: ${q(d.displayName)}, labels: (${d.labels.map(q).join(", ")}), icon: .${icon}, summaryAction: ${q(d.summaryAction)}),`,
  );
}
