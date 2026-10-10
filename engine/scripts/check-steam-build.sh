#!/bin/bash
# Checks whether the Steam hook works on a macOS Steam client build, without running Steam:
# downloads the build's client libraries from Valve's CDN (each package checked against the
# manifest's SHA-256), lays them out in a throwaway home, and resolves every hook signature
# against them with notproton's anchorcheck, which uses the hook's own resolver.
#
# Usage: scripts/check-steam-build.sh [public|publicbeta]     (default: public)
# Prints a summary and one JSON line: {"build":..., "channel":..., "resolved":..., ...}
# Exit status: 0 when every signature resolves, 1 when some do not, 2 on errors.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NP="$ROOT/notproton"
CHANNEL="${1:-public}"
CDN=https://client-update.akamai.steamstatic.com
case "$CHANNEL" in
    public) MANIFEST_NAME=steam_client_osx ;;
    publicbeta) MANIFEST_NAME=steam_client_publicbeta_osx ;;
    *) echo "channel must be public or publicbeta" >&2; exit 2 ;;
esac
# steamclient.dylib, steamui.dylib and the libraries they load
PACKAGES="bins_osx bins_client_osx bins_codecs_osx bins_misc_osx bins_hardware_osx sdl3_osx breakpad_osx"

WORK="${WOVEN_BUILD_ROOT:-$HOME/Library/Caches/WovenGames/engine}/steam-check/$CHANNEL"
DL="${WOVEN_BUILD_ROOT:-$HOME/Library/Caches/WovenGames/engine}/downloads/steam-client"
mkdir -p "$WORK" "$DL"
curl -fsS --max-time 60 -o "$WORK/manifest.txt" "$CDN/$MANIFEST_NAME" || { echo "could not fetch the $CHANNEL manifest" >&2; exit 2; }

# "<file> <sha256>" for each wanted package (the package's own entry, not regional variants)
entries="$(python3 -I - "$WORK/manifest.txt" $PACKAGES <<'EOF'
import re, sys
text = open(sys.argv[1]).read()
tokens = re.findall(r'"((?:[^"\\]|\\.)*)"|([{}])', text)
def parse(i):
    obj = {}
    while i < len(tokens):
        s, brace = tokens[i]
        if brace == "}": return obj, i + 1
        key = s; i += 1
        s2, brace2 = tokens[i]
        if brace2 == "{":
            val, i = parse(i + 1)
        else:
            val, i = s2, i + 1
        obj.setdefault(key, val)
    return obj, i
root, _ = parse(0)
osx = root.get("osx", {})
print("version", osx.get("version", "0"))
for name in sys.argv[2:]:
    p = osx.get(name)
    if not isinstance(p, dict) or "file" not in p:
        sys.exit("manifest has no package " + name)
    print(p["file"], p["sha2"])
EOF
)"
BUILD="$(echo "$entries" | awk '$1=="version"{print $2}')"
echo "Steam $CHANNEL build $BUILD"

MACOS="$WORK/home/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
rm -rf "$WORK/home" && mkdir -p "$MACOS"
while read -r file sha; do
    [ "$file" = version ] && continue
    out="$DL/$file"
    if [ ! -f "$out" ] || ! echo "$sha  $out" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl -fsS --max-time 600 -o "$out.part" "$CDN/$file"
        echo "$sha  $out.part" | shasum -a 256 -c - >/dev/null || { echo "hash mismatch: $file" >&2; rm -f "$out.part"; exit 2; }
        mv "$out.part" "$out"
    fi
    unzip -q -o "$out" -d "$MACOS"
done <<< "$entries"

make -s -C "$NP" out/anchorcheck >/dev/null
report="$WORK/anchorcheck.txt"
# anchorcheck reads the signature databases relative to the notproton tree and loads
# steamclient.dylib/steamui.dylib from $HOME's Steam bundle
(cd "$NP" && HOME="$WORK/home" ./out/anchorcheck > "$report" 2>&1) || true

# The hook uses the newest signature database; its block is the last one in the report.
newest="$(ls "$NP"/signatures/macos.arm64/*.json | sed 's|.*/||; s|\.json$||' | sort -n | tail -1)"
summary="$(awk -v db="$newest.json" 'index($0, db) {f=1} f && /anchors resolved/ {print; exit}' "$report")"
resolved="$(echo "$summary" | sed -nE 's/^ *([0-9]+) anchors resolved.*/\1/p')"
unresolved="$(echo "$summary" | sed -nE 's/.* ([0-9]+) unresolved.*/\1/p')"
if [ -z "$resolved" ]; then
    tail -20 "$report" >&2
    echo "anchorcheck gave no result for $newest.json (see $report)" >&2
    exit 2
fi
grep -E "unresolved$|MISSING|not found" "$report" | grep -v "anchors resolved" | sed 's/^/  /' || true
verified=false; [ "$unresolved" = 0 ] && verified=true
echo "signatures ($newest.json): $resolved resolved, $unresolved unresolved"
printf '{"build": %s, "channel": "%s", "resolved": %s, "unresolved": %s, "verified": %s, "signatures": "%s", "checked": "%s"}\n' \
    "$BUILD" "$CHANNEL" "$resolved" "$unresolved" "$verified" "$newest" "$(date -u +%Y-%m-%d)"
[ "$verified" = true ]
