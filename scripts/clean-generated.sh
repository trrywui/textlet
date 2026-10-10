#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

remove_app() {
  local app_path="$1"
  if [ ! -e "$app_path" ]; then return; fi
  "$LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
  rm -rf -- "$app_path"
  printf 'Removed generated app: %s\n' "$app_path"
}

remove_app "$PROJECT_DIR/build/Textlet.app"
remove_app "$PROJECT_DIR/build/Textlet-Test.app"
remove_app "$PROJECT_DIR/build/Textlet Rows.app"
remove_app "$PROJECT_DIR/build/RowRenderer.app"

if [ -d "$PROJECT_DIR/build/module-cache" ]; then
  rm -rf -- "$PROJECT_DIR/build/module-cache"
  printf 'Removed generated cache: %s\n' "$PROJECT_DIR/build/module-cache"
fi

rmdir "$PROJECT_DIR/build" 2>/dev/null || true
