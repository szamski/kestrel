#!/bin/sh
# Compiles the pure file-surface logic with its assertions and runs them (no Xcode, no app).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/file-logic-checks"
mkdir -p "$out"
cp "$here/FileLogicChecks.swift" "$out/main.swift"
swiftc -o "$out/run" "$here/../App/Sources/Files/FileLogic.swift" "$out/main.swift"
"$out/run"
