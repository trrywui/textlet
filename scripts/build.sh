#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/build/Textlet.app}"
case "$APP_PATH" in
  *.app) ;;
  *) echo "Build output must be an .app path: $APP_PATH" >&2; exit 64 ;;
esac
rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
xcrun swiftc -module-name Textlet -D ROW_RENDERER -O -whole-module-optimization -target x86_64-apple-macosx14.0 \
  -module-cache-path "$PROJECT_DIR/build/module-cache" \
  -framework AppKit -framework QuartzCore -framework UniformTypeIdentifiers "$PROJECT_DIR"/Sources/*.swift \
  -o "$APP_PATH/Contents/MacOS/textlet"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
if [ ! -f "$PROJECT_DIR/AppIcon.icns" ]; then
  bash "$PROJECT_DIR/scripts/build-icon.sh"
fi
cp "$PROJECT_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
# Let Launch Services notice updated document claims when an existing bundle is rebuilt.
touch "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
