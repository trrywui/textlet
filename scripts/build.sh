#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/build/Textlet.app}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
xcrun swiftc -module-name Textlet -O -whole-module-optimization -target x86_64-apple-macosx14.0 \
  -module-cache-path "${TMPDIR:-/tmp}/textlet-swift-module-cache" \
  -framework AppKit "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Tests/*.swift \
  -o "$APP_PATH/Contents/MacOS/textlet"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
if [ ! -f "$PROJECT_DIR/AppIcon.icns" ]; then
  bash "$PROJECT_DIR/scripts/build-icon.sh"
fi
cp "$PROJECT_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
