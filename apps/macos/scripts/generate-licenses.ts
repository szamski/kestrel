// @effect-diagnostics nodeBuiltinImport:off - This is a build-time filesystem script.
//
// Writes apps/macos/App/Resources/third-party-licenses.json, the manifest behind Settings > Open-source licenses.
//
//   node apps/macos/scripts/generate-licenses.ts           write the manifest
//   node apps/macos/scripts/generate-licenses.ts --check   fail when the written manifest is stale
//
// The npm part is the repo's own generator (scripts/lib/third-party-licenses.ts, see docs/internals/open-source-licenses.md)
// over the web and server packages: that is the client and server Kestrel bundles in Release builds. The native part
// is T3Kit's resolved Swift packages (license files read from their SwiftPM checkouts), the embedded highlight.js and
// GhosttyKit. The first run downloads the pinned SPDX license templates into the gitignored .generated/ cache, like the
// strict web build does.

import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { generateThirdPartyLicenseManifest } from "../../../scripts/lib/third-party-licenses.ts";
import type { ThirdPartyLicenseEntry } from "../../../scripts/lib/third-party-licenses.ts";

const here = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const macos = NodePath.resolve(here, "..");
const repo = NodePath.resolve(macos, "../..");
const output = NodePath.join(macos, "App/Resources/third-party-licenses.json");
const BUNDLE = "macos";

/** SPDX expression and project page of every Swift package T3Kit resolves; a new pin must be added here on purpose. */
const SWIFT_PACKAGES: Record<string, { license: string; sourceUrl: string }> = {
  "clerk-ios": { license: "MIT", sourceUrl: "https://github.com/clerk/clerk-ios" },
  // LICENSE bundles the notices of the code Sparkle vendors (BSD-2-Clause, Zlib, MIT).
  sparkle: {
    license: "MIT AND BSD-2-Clause AND Zlib",
    sourceUrl: "https://github.com/sparkle-project/Sparkle",
  },
  nuke: { license: "MIT", sourceUrl: "https://github.com/kean/Nuke" },
  phonenumberkit: { license: "MIT", sourceUrl: "https://github.com/marmelroy/PhoneNumberKit" },
  // COPYING bundles the notices of cmark-gfm and the code it vendors.
  "swift-cmark": {
    license: "BSD-2-Clause AND MIT",
    sourceUrl: "https://github.com/swiftlang/swift-cmark",
  },
  "swift-markdown": {
    license: "Apache-2.0 WITH Swift-exception",
    sourceUrl: "https://github.com/swiftlang/swift-markdown",
  },
};

function read(path: string): string {
  return NodeFS.readFileSync(path, "utf8").replace(/\r\n/g, "\n").trim();
}

/** Checkout roots in order of preference: an explicit override, the package's own build, then Xcode's DerivedData. */
function checkoutRoots(): string[] {
  const roots: string[] = [];
  if (process.env.KESTREL_SWIFTPM_CHECKOUTS) roots.push(process.env.KESTREL_SWIFTPM_CHECKOUTS);
  roots.push(NodePath.join(macos, "T3Kit/.build/checkouts"));
  const derived = NodePath.join(NodeOS.homedir(), "Library/Developer/Xcode/DerivedData");
  if (NodeFS.existsSync(derived)) {
    for (const name of NodeFS.readdirSync(derived).filter((entry) => entry.startsWith("T3Code-"))) {
      roots.push(NodePath.join(derived, name, "SourcePackages/checkouts"));
    }
  }
  return roots.filter((root) => NodeFS.existsSync(root));
}

function findCheckout(roots: string[], identity: string): string | null {
  for (const root of roots) {
    const name = NodeFS.readdirSync(root).find((entry) => entry.toLowerCase() === identity);
    if (name) return NodePath.join(root, name);
  }
  return null;
}

type ResolvedPin = { identity: string; state: { version?: string; revision?: string } };

/** T3Kit's pins plus the app project's pins (Sparkle), deduplicated by identity. */
function resolvedPins(): ResolvedPin[] {
  const files = [
    NodePath.join(macos, "T3Kit/Package.resolved"),
    NodePath.join(
      macos,
      "T3Code.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ),
  ];
  const pins = new Map<string, ResolvedPin>();
  for (const file of files) {
    const resolved = JSON.parse(read(file)) as { pins: ResolvedPin[] };
    for (const pin of resolved.pins) if (!pins.has(pin.identity)) pins.set(pin.identity, pin);
  }
  return [...pins.values()];
}

function swiftPackageEntries(): ThirdPartyLicenseEntry[] {
  const roots = checkoutRoots();
  return resolvedPins().map((pin) => {
    const known = SWIFT_PACKAGES[pin.identity];
    if (!known)
      throw new Error(
        `Package.resolved pins ${pin.identity}; add its license to SWIFT_PACKAGES in generate-licenses.ts.`,
      );
    const checkout = findCheckout(roots, pin.identity);
    if (!checkout) {
      throw new Error(
        `No SwiftPM checkout of ${pin.identity}. Run \`swift package resolve\` in apps/macos/T3Kit or build the app once.`,
      );
    }
    const files = NodeFS.readdirSync(checkout)
      .filter((file) => /^(licen[sc]e|copying|notice)(\.(txt|md))?$/i.test(file))
      .sort();
    if (files.length === 0) throw new Error(`${pin.identity} ships no license file.`);
    return {
      bundles: [BUNDLE],
      kind: "package",
      license: known.license,
      name: pin.identity,
      noticeText: files.map((file) => read(NodePath.join(checkout, file))).join("\n\n"),
      sourceUrl: known.sourceUrl,
      version: pin.state.version ?? pin.state.revision?.slice(0, 12) ?? null,
    };
  });
}

function bundledEntries(): ThirdPartyLicenseEntry[] {
  const highlightSource = read(
    NodePath.join(macos, "T3Kit/Sources/T3Markdown/Highlight/HighlightJSSource.swift"),
  );
  const highlightVersion = /Highlight\.js v(\d+\.\d+\.\d+)/.exec(highlightSource)?.[1];
  if (!highlightVersion)
    throw new Error("HighlightJSSource.swift no longer names its Highlight.js version.");
  const spdx = JSON.parse(
    read(NodePath.join(repo, ".generated/third-party-licenses/spdx/v3.28.0/BSD-3-Clause.json")),
  ) as { licenseText: string };
  const bsd = spdx.licenseText
    .replace(
      /^Copyright \(c\) <year> <owner>\.?/,
      "Copyright (c) 2006, Ivan Sagalaev.\nAll rights reserved.",
    )
    .trim();

  const ghosttyDirectory = NodePath.join(macos, "Vendor/GhosttyKit");
  const revision = read(NodePath.join(ghosttyDirectory, "VERSION"));

  return [
    {
      bundles: [BUNDLE],
      kind: "custom",
      license: "BSD-3-Clause",
      name: "highlight.js",
      noticeText: `Embedded in T3Markdown for syntax highlighting.\n\n${bsd}`,
      sourceUrl: "https://github.com/highlightjs/highlight.js",
      version: highlightVersion,
    },
    {
      bundles: [BUNDLE],
      kind: "custom",
      license: "MIT",
      name: "GhosttyKit",
      noticeText: read(NodePath.join(ghosttyDirectory, "THIRD_PARTY_NOTICES.md")),
      sourceUrl: "https://github.com/ghostty-org/ghostty",
      version: revision.slice(0, 12),
    },
  ];
}

async function build(): Promise<string> {
  const npm = await generateThirdPartyLicenseManifest({
    configFile: NodePath.join(repo, "third-party-licenses.config.json"),
    packageManifests: [
      { bundle: "web", path: NodePath.join(repo, "apps/web/package.json") },
      { bundle: "server", path: NodePath.join(repo, "apps/server/package.json") },
    ],
  });
  const entries = [...npm.entries, ...swiftPackageEntries(), ...bundledEntries()].sort(
    (left, right) =>
      left.name.localeCompare(right.name) ||
      (left.version ?? "").localeCompare(right.version ?? ""),
  );
  const seen = new Set<string>();
  for (const entry of entries) {
    const key = JSON.stringify([entry.kind, entry.name, entry.version]);
    if (seen.has(key)) throw new Error(`Duplicate notice: ${entry.name}@${entry.version ?? ""}`);
    seen.add(key);
    if (!entry.license || !entry.noticeText.trim())
      throw new Error(`${entry.name} has no license or notice text.`);
  }
  return `${JSON.stringify({ schemaVersion: 1, entries })}\n`;
}

const generated = await build();
if (process.argv.includes("--check")) {
  const current = NodeFS.existsSync(output) ? NodeFS.readFileSync(output, "utf8") : null;
  if (current !== generated) {
    console.error(
      "third-party-licenses.json is stale. Run: node apps/macos/scripts/generate-licenses.ts",
    );
    process.exit(1);
  }
  console.log(
    `third-party-licenses.json is current (${JSON.parse(generated).entries.length} notices).`,
  );
} else {
  NodeFS.mkdirSync(NodePath.dirname(output), { recursive: true });
  NodeFS.writeFileSync(output, generated);
  console.log(
    `Wrote ${NodePath.relative(repo, output)} (${JSON.parse(generated).entries.length} notices).`,
  );
}
