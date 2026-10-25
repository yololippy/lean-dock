#!/bin/bash
set -euo pipefail
LEAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LEAN_ROOT"
swift build -c release --product LeanDock
LEAN_BIN_DIR="$(swift build -c release --show-bin-path)"
LEAN_APP="$LEAN_ROOT/dist/LeanDock.app"
mkdir -p "$LEAN_APP/Contents/MacOS" "$LEAN_APP/Contents/Resources"
cp "$LEAN_BIN_DIR/LeanDock" "$LEAN_APP/Contents/MacOS/LeanDock.new"
mv -f "$LEAN_APP/Contents/MacOS/LeanDock.new" "$LEAN_APP/Contents/MacOS/LeanDock"
cp "$LEAN_ROOT/Resources/Info.plist" "$LEAN_APP/Contents/Info.plist"
cp "$LEAN_ROOT/THIRD_PARTY_NOTICES.md" "$LEAN_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
for LEAN_BUNDLE in "$LEAN_BIN_DIR"/LeanDock_*.bundle; do
    if [[ -d "$LEAN_BUNDLE" ]]; then
        ditto "$LEAN_BUNDLE" "$LEAN_APP/Contents/Resources/$(basename "$LEAN_BUNDLE")"
    fi
done
swift "$LEAN_ROOT/Scripts/make-icon.swift" "$LEAN_ROOT/dist/LeanDock.iconset"
iconutil -c icns "$LEAN_ROOT/dist/LeanDock.iconset" -o "$LEAN_APP/Contents/Resources/LeanDock.icns"
codesign --force --deep --sign - "$LEAN_APP"
printf 'Built: %s\n' "$LEAN_APP"
