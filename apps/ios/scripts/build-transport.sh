#!/bin/sh
set -eu
OPENBOT_NATIVE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
if [ -n "${BUN_BINARY:-}" ]; then
  OPENBOT_NATIVE_BUN=$BUN_BINARY
elif command -v bun >/dev/null 2>&1; then
  OPENBOT_NATIVE_BUN=$(command -v bun)
else
  OPENBOT_NATIVE_BUN="$OPENBOT_NATIVE_ROOT/.openbot-build/native-ios/tooling/node_modules/.bin/bun"
fi
if [ ! -x "$OPENBOT_NATIVE_BUN" ]; then
  echo 'Bun 1.4.2 is required. See apps/ios/README.md.' >&2
  exit 1
fi
cd "$OPENBOT_NATIVE_ROOT"
"$OPENBOT_NATIVE_BUN" apps/ios/Transport/build.ts
