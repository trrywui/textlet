#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/textlet-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
xcrun swift -module-cache-path "${TMPDIR:-/tmp}/textlet-swift-module-cache" \
  "$PROJECT_DIR/scripts/icon.swift" "$ICON_WORK/AppIcon.iconset"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$PROJECT_DIR/AppIcon.icns"
printf 'Built: %s\n' "$PROJECT_DIR/AppIcon.icns"
