#!/usr/bin/env bash
# Rebuilds apps/macos/Vendor/GhosttyKit/GhosttyKit.xcframework (macOS arm64 only) from the same
# Ghostty fork revision as the iOS framework in apps/mobile/modules/t3-terminal.
#
#   apps/macos/scripts/build-libghostty-macos.sh [--work-dir DIR] [--arch universal|native]
#
# Zig and the Ghostty clone live under the work dir (default ~/.cache/t3code/ghostty-macos);
# nothing is installed globally. Xcode's Metal toolchain must be installed; if `metal` fails run
# `xcodebuild -downloadComponent MetalToolchain`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/Vendor/GhosttyKit"

GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/Yash-Singh1/ghostty.git}"
# Keep in sync with apps/mobile/modules/t3-terminal/Vendor/libghostty/VERSION.
GHOSTTY_REVISION="${GHOSTTY_REVISION:-cf8edc23f3a6a87a96e41a90013e89e987d34980}"
GHOSTTY_ZIG_VERSION="${GHOSTTY_ZIG_VERSION:-0.16.0}"
WORK_DIR="${GHOSTTY_WORK_DIR:-${HOME}/.cache/t3code/ghostty-macos}"
ARCH="native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

log() { printf '[libghostty-macos] %s\n' "$*"; }
die() { printf '[libghostty-macos] error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

for cmd in git curl tar xcodebuild xcrun lipo; do require_cmd "$cmd"; done
mkdir -p "${WORK_DIR}"

# Zig ${GHOSTTY_ZIG_VERSION}, downloaded into the work dir.
zig_dir="${WORK_DIR}/tools/zig-${GHOSTTY_ZIG_VERSION}"
zig="${zig_dir}/zig"
if [[ ! -x "${zig}" ]]; then
  case "$(uname -m)" in
    arm64) zig_arch=aarch64 ;;
    x86_64) zig_arch=x86_64 ;;
    *) die "unsupported host architecture: $(uname -m)" ;;
  esac
  mkdir -p "${zig_dir}"
  log "downloading Zig ${GHOSTTY_ZIG_VERSION}"
  curl -fsSL "https://ziglang.org/download/${GHOSTTY_ZIG_VERSION}/zig-${zig_arch}-macos-${GHOSTTY_ZIG_VERSION}.tar.xz" \
    | tar -xJ --strip-components=1 -C "${zig_dir}"
fi

src="${WORK_DIR}/ghostty"
if [[ ! -d "${src}/.git" ]]; then
  log "cloning ${GHOSTTY_REPO}"
  git clone --filter=blob:none "${GHOSTTY_REPO}" "${src}"
fi
git -C "${src}" fetch --quiet origin "${GHOSTTY_REVISION}" 2>/dev/null || true
git -C "${src}" checkout --quiet "${GHOSTTY_REVISION}"
[[ "$(git -C "${src}" rev-parse HEAD)" == "${GHOSTTY_REVISION}" ]] || die "revision mismatch"
log "Ghostty ${GHOSTTY_REVISION}, Zig $("${zig}" version)"

# `universal` also builds the iOS slices upstream's xcframework step wants; only the macOS slice is
# kept. `native` builds the host architecture only (faster, arm64 on Apple silicon).
(
  cd "${src}"
  rm -rf macos/GhosttyKit.xcframework
  PATH="${zig_dir}:${PATH}" "${zig}" build \
    -Dapp-runtime=none \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Demit-exe=false \
    -Demit-docs=false \
    -Demit-webdata=false \
    -Demit-helpgen=false \
    -Demit-terminfo=false \
    -Demit-termcap=false \
    -Demit-themes=false \
    -Doptimize=ReleaseFast \
    -Dstrip \
    -Dxcframework-target="${ARCH}"
)

built="${src}/macos/GhosttyKit.xcframework"
slice="$(find "${built}" -maxdepth 1 -type d -name 'macos-*' | head -n1)"
[[ -n "${slice}" ]] || die "no macOS slice in ${built}"
lib="$(find "${slice}" -maxdepth 1 -name '*.a' | head -n1)"
[[ -f "${lib}" ]] || die "missing macOS archive in ${slice}"

stage="${WORK_DIR}/stage"
rm -rf "${stage}"
mkdir -p "${stage}"
cp "${lib}" "${stage}/libghostty.a"
cp -R "${slice}/Headers" "${stage}/Headers"
xcrun strip -S -x "${stage}/libghostty.a"
# Kestrel ships Apple silicon only: keep the vendored binary at half the size.
if [[ "$(lipo -archs "${stage}/libghostty.a")" != "arm64" ]]; then
  lipo -thin arm64 "${stage}/libghostty.a" -output "${stage}/libghostty-arm64.a"
  mv "${stage}/libghostty-arm64.a" "${stage}/libghostty.a"
fi
sed -i '' -e 's/[[:space:]]*$//' "${stage}/Headers/ghostty.h"

rm -rf "${VENDOR_DIR}/GhosttyKit.xcframework"
xcodebuild -create-xcframework \
  -library "${stage}/libghostty.a" -headers "${stage}/Headers" \
  -output "${VENDOR_DIR}/GhosttyKit.xcframework"
printf '%s\n' "${GHOSTTY_REVISION}" > "${VENDOR_DIR}/VERSION"

log "slices: $(lipo -archs "${stage}/libghostty.a")"
log "size: $(du -sh "${VENDOR_DIR}/GhosttyKit.xcframework" | cut -f1)"
log "done"
