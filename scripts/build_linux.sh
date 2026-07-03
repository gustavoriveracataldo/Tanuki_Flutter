#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

if [ ! -d linux ]; then
  "$FLUTTER_BIN" create --platforms=linux .
fi

FLUTTER_DART_DEFINES=""
for key in TMDB_BEARER_TOKEN TMDB_API_KEY FANART_API_KEY SIMKL_CLIENT_ID MYANIMELIST_CLIENT_ID MYANIMELIST_CLIENT_SECRET; do
  value="$(eval "printf '%s' \"\${$key:-}\"")"
  if [ -n "$value" ]; then
    FLUTTER_DART_DEFINES="$FLUTTER_DART_DEFINES --dart-define=$key=$value"
  fi
done

"$FLUTTER_BIN" pub get
# shellcheck disable=SC2086
"$FLUTTER_BIN" build linux --release $FLUTTER_DART_DEFINES
