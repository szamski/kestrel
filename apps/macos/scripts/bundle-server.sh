#!/usr/bin/env bash
# Builds the self-contained `t3` server archive for this Mac and copies it into a built Kestrel app, so
# Release builds can run their own local server (Contents/Resources/t3/t3, the same tree
# scripts/build-cli-archive.ts produces: t3, client/, resource-monitor/, node_modules/).
#
# Usage: apps/macos/scripts/bundle-server.sh "<path to built T3 Code.app>" [work-dir]
#
# Opt-in and manual on purpose: it is not an Xcode Run Script phase (it needs the network for the Node SEA
# runtime, Rust, and several minutes), so a plain Release build stays fast. Run it after every Release build,
# BEFORE the app is signed/notarized for distribution (the archive contents are ad-hoc signed here, or with
# $T3CODE_CLI_MAC_SIGN_IDENTITY; re-sign the app afterwards with `codesign --force --deep`).
#
# Requirements:
#   - Node >= 25.7 on PATH for `node --build-sea` (system Homebrew node is v26; the repo's vp node 24 is too old).
#     `vp pack` itself downloads the exact SEA runtime (SEA_NODE_VERSION in apps/server/vite.config.ts).
#   - `vp` (Vite+), `cargo` (resource monitor), network access.
set -euo pipefail

app="${1:?usage: bundle-server.sh <path to T3 Code.app> [work-dir]}"
work="${2:-${TMPDIR:-/tmp}/kestrel-server-archive}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
arch="$(uname -m)"; [ "$arch" = "x86_64" ] && arch="x64"
rust_target="aarch64-apple-darwin"; [ "$arch" = "x64" ] && rust_target="x86_64-apple-darwin"
version="$(node -p "require('$repo/apps/server/package.json').version")"

[ -d "$app/Contents" ] || { echo "not an app bundle: $app" >&2; exit 1; }
# Homebrew node first: the repo's vp shim resolves to the engines version (24), which lacks --build-sea.
export PATH="/opt/homebrew/bin:$PATH"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>25||(a===25&&b>=7)?0:1)' \
  || { echo "Node >= 25.7 required for --build-sea (found $(node --version))" >&2; exit 1; }

cd "$repo"
mkdir -p "$work/resource-monitor/darwin-$arch" "$work/out"

echo "[bundle-server] web client + server bundle"
vp run --filter t3 build
echo "[bundle-server] resource monitor"
cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml --target "$rust_target"
cp "native/resource-monitor/target/$rust_target/release/t3-resource-monitor" "$work/resource-monitor/darwin-$arch/"
echo "[bundle-server] single executable"
VP_NODE_VERSION="${VP_NODE_VERSION:-26.8.2}" node apps/server/scripts/cli.ts build-exe --verbose
echo "[bundle-server] archive"
node scripts/build-cli-archive.ts --platform mac --arch "$arch" --version "$version" \
  --resource-monitor-dir "$work/resource-monitor" --output-dir "$work/out"

archive="$work/out/t3-$version-darwin-$arch.tar.gz"
dest="$app/Contents/Resources/t3"
rm -rf "$dest" "$work/extract"; mkdir -p "$dest" "$work/extract"
tar -xzf "$archive" -C "$work/extract"
# The archive has one top-level directory; its contents become Resources/t3.
cp -R "$work/extract"/*/. "$dest/"
"$dest/t3" --version
echo "[bundle-server] bundled $(du -sh "$dest" | cut -f1) into $dest"
