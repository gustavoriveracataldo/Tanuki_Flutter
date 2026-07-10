#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
export TANUKI_PROJECT_ROOT="$PROJECT_ROOT"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

. "$PROJECT_ROOT/scripts/load_flutter_secrets.sh"

case "${1:-}" in
  run|build|test)
    FLUTTER_DART_DEFINES="$(tanuki_flutter_dart_defines)"
    ;;
  *)
    FLUTTER_DART_DEFINES=""
    ;;
esac

# shellcheck disable=SC2086
exec "$FLUTTER_BIN" "$@" $FLUTTER_DART_DEFINES
