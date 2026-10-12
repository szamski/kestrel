// Import this first in a frozen oracle. Frozen oracles check Swift code that serves orchestration
// protocol 1 against the web/client-runtime sources that existed before upstream moved to V2, so
// they must read those sources from the pre-merge Kestrel tip, not from this checkout:
//   - a git worktree of FROZEN_COMMIT (default <tmp>/kestrel-frozen-v1, override T3_FROZEN_V1_DIR),
//   - with its own node_modules from the offline pnpm store (the base pins effect rc.115; this
//     checkout has 4.0.1, which moved `effect/unstable/*`).
// The script itself runs unchanged from this checkout, only T3_ORACLE_SOURCE_ROOT differs
// (see lib/load.ts); fixtures are written in place, so `git diff --exit-code <fixtures>` is the check.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Kestrel tip before merge 578899daf (upstream t3code main, orchestration V2). Not de251fc29: that
// is the upstream merge base and predates apps/macos.
const FROZEN_COMMIT = "da938cb76279f147470aa110770099bf23c66dfc";

if (!process.env.T3_ORACLE_SOURCE_ROOT) {
  const repo = join(import.meta.dirname, "..", "..", "..", "..");
  const worktree = process.env.T3_FROZEN_V1_DIR ?? join(tmpdir(), "kestrel-frozen-v1");
  const run = (command: string, args: string[], cwd: string) =>
    spawnSync(command, args, { cwd, encoding: "utf8", stdio: ["ignore", "inherit", "inherit"] });
  const guard = (reason: string): never => {
    console.error(
      `frozen oracle: ${reason}\n` +
        `This oracle is frozen: regenerate it from ${FROZEN_COMMIT}:\n` +
        `  git worktree add --detach ${worktree} ${FROZEN_COMMIT}\n` +
        `  (cd ${worktree} && pnpm install --offline --frozen-lockfile --ignore-scripts)\n` +
        `  T3_FROZEN_V1_DIR=${worktree} node ${process.argv[1]}`,
    );
    process.exit(2);
  };

  if (!existsSync(join(worktree, ".git"))) {
    if (existsSync(worktree)) guard(`${worktree} exists but is not a git worktree`);
    if (run("git", ["worktree", "add", "--detach", worktree, FROZEN_COMMIT], repo).status !== 0)
      guard(`could not create the worktree at ${worktree}`);
  }
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: worktree, encoding: "utf8" });
  if (head.stdout.trim() !== FROZEN_COMMIT) guard(`${worktree} is not at the frozen commit`);
  if (!existsSync(join(worktree, "node_modules", ".modules.yaml"))) {
    const install = ["install", "--offline", "--frozen-lockfile", "--ignore-scripts"];
    if (run("pnpm", install, worktree).status !== 0) guard("pnpm install in the worktree failed");
  }

  const child = spawnSync(
    process.execPath,
    [...process.execArgv, process.argv[1]!, ...process.argv.slice(2)],
    { stdio: "inherit", env: { ...process.env, T3_ORACLE_SOURCE_ROOT: worktree } },
  );
  process.exit(child.status ?? 1);
}
