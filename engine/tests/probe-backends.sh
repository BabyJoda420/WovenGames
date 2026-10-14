#!/bin/bash
# M1 acceptance test: runs tests/d3dprobe.c in a throwaway prefix under each graphics backend of
# a built runner, with the same environment the compat tool's run script sets per backend:
#   wined3d   D3D11            (Wine's own, OpenGL)
#   dxmt      D3D11            (DXMT, Metal)
#   d3dmetal  D3D11 and D3D12  (Apple D3DMetal)
#
# Usage: tests/probe-backends.sh [runner-dir]   (default: dist/runners/selfbuilt-cx26.3-r1)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${1:-$ROOT/dist/runners/selfbuilt-cx26.3-r1}"
WINE="$RUNNER/bin/wine"
WORK="${WOVEN_BUILD_ROOT:-$HOME/Library/Developer/WovenGames/engine}/probe"
EXE="$WORK/d3dprobe.exe"

[ -x "$WINE" ] || { echo "no runner at $RUNNER (run scripts/build-all.sh)" >&2; exit 1; }
mkdir -p "$WORK"
x86_64-w64-mingw32-gcc -O2 -o "$EXE" "$ROOT/tests/d3dprobe.c" -ld3d11 -ldxgi -ld3d12 -lole32 -luuid \
    || { echo "could not build d3dprobe.exe" >&2; exit 1; }

export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all WINEARCH=win64
rm -rf "$WINEPREFIX"
echo "creating prefix (first boot takes a minute)..."
"$WINE" wineboot -u >"$WORK/wineboot.log" 2>&1 || { echo "wineboot failed, see $WORK/wineboot.log" >&2; exit 1; }
"$RUNNER/bin/wineserver" -w 2>/dev/null || true

failures=0
probe() { # name api env...
    local name="$1" api="$2"; shift 2
    printf '\n=== %s (D3D%s) ===\n' "$name" "$api"
    if env "$@" "$WINE" "$EXE" "$api"; then echo "PASS $name d3d$api"
    else echo "FAIL $name d3d$api"; failures=$((failures + 1)); fi
}

probe wined3d 11
probe dxmt 11 WINEDLLPATH_PREPEND="$RUNNER/lib/renderers/dxmt"
for api in 11 12; do
    probe d3dmetal "$api" WINEDLLPATH_PREPEND="$RUNNER/lib/renderers/d3dmetal" \
        CX_APPLEGPTK_LIBD3DSHARED_PATH="$RUNNER/lib/external/libd3dshared.dylib"
done
"$RUNNER/bin/wineserver" -k 2>/dev/null || true

printf '\n%s\n' "$([ "$failures" = 0 ] && echo "all backends passed" || echo "$failures probe(s) failed")"
exit "$failures"
