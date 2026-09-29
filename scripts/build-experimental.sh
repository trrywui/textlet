#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$PROJECT_DIR/build/Textlet Rows.app}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
xcrun swiftc -module-name Textlet -D ROW_RENDERER -D TEXTLET_EXPERIMENTAL -O -whole-module-optimization -target x86_64-apple-macosx14.0 \
  -module-cache-path "$PROJECT_DIR/build/module-cache" \
  -framework AppKit -framework QuartzCore "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Tests/*.swift \
  -o "$APP_PATH/Contents/MacOS/textlet-rows"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.textlet.rows-experiment' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Textlet 实验版' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Textlet 实验版' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable textlet-rows' "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
