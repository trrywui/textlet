#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/RowRenderer.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -whole-module-optimization -target x86_64-apple-macosx14.0 \
  -module-cache-path "${TMPDIR:-/tmp}/textlet-swift-module-cache" \
  -framework AppKit -framework CoreText -framework QuartzCore \
  "$ROOT"/Experiments/RowRenderer/*.swift -o "$APP/Contents/MacOS/row-renderer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>row-renderer</string>
<key>CFBundleIdentifier</key><string>local.textlet.row-renderer-experiment</string>
<key>CFBundleName</key><string>Textlet 绘制实验</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
