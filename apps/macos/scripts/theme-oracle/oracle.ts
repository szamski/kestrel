// Prints the web implementation's answers for the Swift T3Theme tests (Tests/T3ThemeTests/Fixtures/oracle.json).
//   bun apps/macos/scripts/theme-oracle/oracle.ts > apps/macos/T3Kit/Tests/T3ThemeTests/Fixtures/oracle.json
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import {
  createVividThemeColors,
  GROVE_THEME,
  serializeThemeFile,
  themeColorToHex,
  toCanonicalThemeColor,
  updateThemeColorFamily,
} from "../../../web/src/themePalette.ts";
import { parseVsCodeThemeFile } from "../../../web/src/vscodeThemeImport.ts";

const { parse } = createRequire(import.meta.url)(
  "../../../web/node_modules/jsonc-parser",
) as typeof import("jsonc-parser");
const fixtures = new URL("../../T3Kit/Tests/T3ThemeTests/Fixtures/", import.meta.url);
const sample = parse(readFileSync(new URL("sample-vscode-theme.json", fixtures), "utf8"), [], {
  allowTrailingComma: true,
});

const vividInputs = [
  { appearance: "dark", canvas: "#1a1b26", accent: "#7aa2f7" },
  { appearance: "light", canvas: "#fbf1c7", accent: "#d65d0e" },
  { appearance: "dark", canvas: "#0b1e14", accent: "#2ecc71" },
] as const;
const colorInputs = [
  "#1b4ed8",
  "#f0f",
  "#12345678",
  "rgb(30 144 255 / 0.5)",
  "hsl(210 50% 40%)",
  "oklch(62% 0.2 280)",
  "oklch(0.7 0.4 150)",
  "white",
];
const grove = serializeThemeFile(GROVE_THEME);
const standardAccentUpdate = updateThemeColorFamily(
  "dark",
  createVividThemeColors("dark", "#1a1b26", "#7aa2f7"),
  "accent",
  "#e0af68",
);

console.log(
  JSON.stringify(
    {
      vivid: vividInputs.map((input) => ({
        ...input,
        colors: createVividThemeColors(input.appearance, input.canvas, input.accent),
      })),
      canonical: colorInputs.map((input) => ({
        input,
        canonical: toCanonicalThemeColor(input),
        hex: themeColorToHex(input),
      })),
      vscode: { serialized: serializeThemeFile(parseVsCodeThemeFile(sample)) },
      grove,
      updateAccent: standardAccentUpdate,
    },
    null,
    1,
  ),
);
