#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/textlet-tests.XXXXXX)"
TEST_APP="$TEST_ROOT/Textlet-Test.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
  if [ -d "$TEST_APP" ]; then
    "$LSREGISTER" -u "$TEST_APP" >/dev/null 2>&1 || true
  fi
  case "$TEST_ROOT" in
    /private/tmp/textlet-tests.*) rm -rf -- "$TEST_ROOT" ;;
    *) echo "Refusing to remove unexpected test path: $TEST_ROOT" >&2; return 1 ;;
  esac
}
trap cleanup EXIT INT TERM

"$PROJECT_DIR/scripts/build-test.sh" "$TEST_APP"
"$TEST_APP/Contents/MacOS/textlet-tests" --self-test
"$TEST_APP/Contents/MacOS/textlet-tests" --syntax-test
echo "Temporary tests passed; test app and temporary directory will be removed."
