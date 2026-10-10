#!/bin/bash
# Builds WovenGames.app (the SwiftUI app, with the woven CLI inside) into cli/.build/.
#
# Usage: cli/scripts/build-app.sh [--open]
set -euo pipefail

CLI="$(cd "$(dirname "$0")/.." && pwd)"
APP="$CLI/.build/WovenGames.app"
VERSION="$(cat "$CLI/../VERSION")"

# Stale Command Line Tools cannot build SwiftUI's Observation code; use an installed Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)" -lt 14 ] 2>/dev/null; then
    for x in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
        [ -d "$x/Contents/Developer" ] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
    done
fi

swift build --package-path "$CLI" -c release --product WovenGames
swift build --package-path "$CLI" -c release --product woven
BIN="$(swift build --package-path "$CLI" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WovenGames" "$APP/Contents/MacOS/WovenGames"
cp "$BIN/woven" "$APP/Contents/Resources/woven"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WovenGames</string>
    <key>CFBundleDisplayName</key><string>WovenGames</string>
    <key>CFBundleIdentifier</key><string>io.github.babyjoda420.wovengames</string>
    <key>CFBundleExecutable</key><string>WovenGames</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0. Built on NotProton and steamplay-mac.</string>
</dict>
</plist>
EOF

codesign -f -s - "$APP/Contents/Resources/woven"
codesign -f -s - "$APP"
echo "built $APP"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0
