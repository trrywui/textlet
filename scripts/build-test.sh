#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/Textlet-Test.app" >&2
  exit 64
fi

APP_PATH="$1"
case "$APP_PATH" in
  /*.app) ;;
  *) echo "Test app path must be an absolute .app path: $APP_PATH" >&2; exit 64 ;;
esac

rm -rf -- "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.trrywui.textlet.tests" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Textlet Tests" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Textlet Tests" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable textlet-tests" "$APP_PATH/Contents/Info.plist"

xcrun swiftc -module-name TextletTests -D ROW_RENDERER -D TEXTLET_TESTING -O -whole-module-optimization -target x86_64-apple-macosx14.0 \
  -module-cache-path "$(dirname "$APP_PATH")/module-cache" \
  -framework AppKit -framework QuartzCore -framework UniformTypeIdentifiers "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Tests/*.swift \
  -o "$APP_PATH/Contents/MacOS/textlet-tests"

codesign --force --sign - "$APP_PATH"
printf 'Built temporary test app: %s\n' "$APP_PATH"
