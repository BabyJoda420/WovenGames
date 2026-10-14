#!/bin/bash
# Packages a finished engine build (scripts/build-all.sh) as a WovenGames release:
#
#   wovengames-engine-<version>/
#     release.json             version, runner id, where the installer fetches D3DMetal
#     runner/                  the Wine runner WITHOUT Apple's D3DMetal (lib/external,
#                              lib/renderers/d3dmetal): `woven install` downloads it on the
#                              user's Mac, so we never redistribute Apple's files
#     support/                 the Steam hook (wovengames.dylib) and its helpers
#     signatures/  compat/     hook signatures, known-good per-game settings
#     valve-packages.manifest  what `woven install` fetches from Valve's CDN (never shipped)
#
# Output: release/wovengames-engine-<version>.tar.xz (+ .sha256) in the repo root.
#
# Usage: scripts/package-release.sh [version] [runner-id]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$(cd "$ROOT" && pwd -P)/.." && pwd -P)"   # physical: ROOT may be the cache symlink
VERSION="${1:-$(cat "$REPO/VERSION")}"
ID="${2:-selfbuilt-cx26.3-r1}"
RUNNER="$ROOT/dist/runners/$ID"
NP="$ROOT/notproton"
NAME="wovengames-engine-$VERSION"
OUT="$REPO/release"
STAGE="$ROOT/build/release-stage/$NAME"

# The D3DMetal source (assemble-runner.sh fetches the same file); the installer verifies it.
GPTK_URL=https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz
GPTK_SHA=d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e

need() { [ -e "$1" ] || { echo "missing $1 (run scripts/build-all.sh)" >&2; exit 1; }; }
need "$RUNNER/runner.json"
need "$NP/out/wovengames.dylib"
need "$ROOT/build/helpers/pe-d3d"

rm -rf "$STAGE" && mkdir -p "$STAGE/support" "$OUT"
ditto "$RUNNER" "$STAGE/runner"
# Apple's files stay out of the release
rm -rf "$STAGE/runner/lib/external" "$STAGE/runner/lib/renderers/d3dmetal"

cp "$NP/out/wovengames.dylib" "$STAGE/support/wovengames.dylib"
for f in overlay-shim.dylib iconmaker appinfo; do cp "$NP/out/$f" "$STAGE/support/$f"; done
for f in pe-d3d syshud; do cp "$ROOT/build/helpers/$f" "$STAGE/support/$f"; done
sed -n 's/.*_VERSION[^"]*"\([^"]*\)".*/\1/p' "$NP/dylib/version.h" | head -1 > "$STAGE/support/dylib.version"
mkdir -p "$STAGE/signatures" "$STAGE/compat"
cp "$NP"/signatures/macos.arm64/*.json "$STAGE/signatures/"
cp "$REPO"/compat/*.env "$REPO"/compat/*.json "$STAGE/compat/" 2>/dev/null || true
# kept in NotProton's (unbuilt) app tree, where upstream maintains it
cp "$NP/app/Sources/NotProtonApp/Resources/valve-packages.manifest" "$STAGE/valve-packages.manifest"

cat > "$STAGE/release.json" <<EOF
{
  "version": "$VERSION",
  "runner": "$ID",
  "commit": "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "d3dmetal": { "url": "$GPTK_URL", "sha256": "$GPTK_SHA" }
}
EOF

# Nothing of Valve's or Apple's may slip in.
if find "$STAGE" \( -name 'steamclient*.dll' -o -name 'tier0_s64.dll' -o -name 'vstdlib_s64.dll' -o -name 'D3DMetal*' -o -name 'libd3dshared*' \) | grep -q .; then
    find "$STAGE" \( -name 'steamclient*.dll' -o -name 'tier0_s64.dll' -o -name 'vstdlib_s64.dll' -o -name 'D3DMetal*' -o -name 'libd3dshared*' \) >&2
    echo "Valve or Apple files in the release stage" >&2; exit 1
fi

tar -C "$(dirname "$STAGE")" -cJf "$OUT/$NAME.tar.xz" "$NAME"
(cd "$OUT" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
du -h "$OUT/$NAME.tar.xz"
echo "release: $OUT/$NAME.tar.xz"
