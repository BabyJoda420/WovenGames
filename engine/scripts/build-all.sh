#!/bin/bash
# Builds everything from scratch: x86_64 host libraries, the patched Wine runner, the Steam
# bridge, the NotProton fork, and assembles dist/runners/<id>. Nothing here touches Steam;
# installing is scripts/install.sh.
#
# Usage: scripts/build-all.sh [runner-id]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:-selfbuilt-cx26.3-r1}"

# WovenGames: autoconf and Wine's build break on paths with spaces. In that case keep the
# bulky work dirs in a space-free cache (outside the repo), and re-run through a space-free
# symlink to the engine dir so every script below sees a ROOT without spaces.
WORKROOT="${WOVEN_BUILD_ROOT:-$HOME/Library/Caches/WovenGames/engine}"
if [[ "$ROOT" == *" "* ]]; then
    [[ "$WORKROOT" != *" "* ]] || { echo "WOVEN_BUILD_ROOT must not contain spaces" >&2; exit 1; }
    for d in build dist downloads sources src; do
        mkdir -p "$WORKROOT/$d"
        if [ ! -L "$ROOT/$d" ]; then
            [ ! -e "$ROOT/$d" ] || { echo "$ROOT/$d exists; move it into $WORKROOT/$d" >&2; exit 1; }
            ln -s "$WORKROOT/$d" "$ROOT/$d"
        fi
    done
    ln -sfn "$ROOT" "$WORKROOT/root"
    exec "$WORKROOT/root/scripts/build-all.sh" "$@"
fi

LOGS="$ROOT/build/logs"
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$*"; }
run() { # name command...
    local name="$1"; shift
    if ! "$@" > "$LOGS/$name.log" 2>&1; then
        echo "failed: $name (see build/logs/$name.log)" >&2
        tail -20 "$LOGS/$name.log" >&2
        exit 1
    fi
}

step "checking prerequisites"
[ "$(uname -m)" = arm64 ] || { echo "Apple Silicon only" >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "install the Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
# WovenGames: stale Command Line Tools (an SDK older than the 14.0 deployment target) break the
# build. Without touching xcode-select, prefer an installed Xcode whose SDK is new enough.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)" -lt 14 ] 2>/dev/null; then
    for x in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
        if [ -d "$x/Contents/Developer" ] && [ "$(DEVELOPER_DIR="$x/Contents/Developer" xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)" -ge 14 ] 2>/dev/null; then
            export DEVELOPER_DIR="$x/Contents/Developer"; break
        fi
    done
fi
echo "toolchain: $(clang --version | head -1), SDK $(xcrun --show-sdk-version)"
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "install Rosetta 2: softwareupdate --install-rosetta" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required (https://brew.sh)" >&2; exit 1; }
missing=""
for f in mingw-w64 bison flex meson ninja ccache cmake pkgconf autoconf llvm lld nasm freetype; do
    brew list --versions "$f" >/dev/null 2>&1 || missing="$missing $f"
done
[ -z "$missing" ] || { echo "brew install$missing" >&2; exit 1; }
# WovenGames: notproton/ is vendored at the repo root; engine/notproton is a symlink to it.
[ -f "$ROOT/notproton/Makefile" ] || { echo "notproton submodule missing (expected the vendored ../notproton tree)" >&2; exit 1; }

# WovenGames: sources first; build-deps.sh builds gmp/gnutls/freetype from the CrossOver drop.
step "Wine sources (CrossOver 26.3.0 + patches/series + lsteamclient)"
[ -d "$ROOT/src/wine/.git" ] || run prepare "$ROOT/scripts/prepare-wine-src.sh"

step "x86_64 host libraries (gmp, nettle, gnutls, freetype, SDL2, MoltenVK, FFmpeg)"
# WovenGames: build-deps.sh rebuilds every library from scratch; skip it once it has finished.
if [ -f "$ROOT/build/deps/.complete" ]; then echo "(already built; delete build/deps/.complete to rebuild)"
else run deps "$ROOT/scripts/build-deps.sh"; fi

step "Wine (native tools, then the x86_64 runner build; this is the long one)"
run wine "$ROOT/scripts/build-wine.sh"

step "steam.exe shim (stock wine-11.15 tree)"
run shim "$ROOT/scripts/build-steam-shim.sh"

step "Valve's Windows Steam DLLs (Valve CDN, hash-checked)"
run valve "$ROOT/scripts/fetch-valve-bridge.sh"

step "Steam hook (NotProton fork): Dobby, wovengames.dylib, overlay shim, helpers"
[ -f "$ROOT/notproton/vendor/dobby/CMakeLists.txt" ] || {
    git clone -q --no-checkout https://github.com/jmpews/Dobby.git "$ROOT/notproton/vendor/dobby"
    git -C "$ROOT/notproton/vendor/dobby" checkout -q 5dfc8546954ce3b3198132ab13fddb89ee92cdd7
}
[ -f "$ROOT/notproton/build/dobby/libdobby.a" ] || run dobby make -C "$ROOT/notproton" dobby
run notproton make -C "$ROOT/notproton" out/wovengames.dylib overlay-shim iconmaker appinfo
mkdir -p "$ROOT/build/helpers"
clang -O2 -mmacosx-version-min=14.0 -o "$ROOT/build/helpers/pe-d3d" "$ROOT/notproton/helpers/pe-d3d.c"
swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework IOKit \
    -o "$ROOT/build/helpers/syshud" "$ROOT/notproton/helpers/syshud.swift"

step "assembling runner $ID (Mono, Gecko, DXMT, D3DMetal)"
run assemble "$ROOT/scripts/assemble-runner.sh" "$ID"

printf '\nDone: %s\nNext: woven setup && woven steam patch\n' "$ROOT/dist/runners/$ID"
