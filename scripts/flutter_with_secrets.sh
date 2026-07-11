#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
export TANUKI_PROJECT_ROOT="$PROJECT_ROOT"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

clean_stale_linux_cmake_cache() {
  [ -d "$PROJECT_ROOT/build/linux/x64" ] || return 0
  for cache_dir in "$PROJECT_ROOT"/build/linux/x64/debug "$PROJECT_ROOT"/build/linux/x64/profile "$PROJECT_ROOT"/build/linux/x64/release; do
    cache_file="$cache_dir/CMakeCache.txt"
    [ -f "$cache_file" ] || continue

    missing_include="$(
      sed -n 's/^WEBKIT_INCLUDE_DIRS:INTERNAL=//p' "$cache_file" |
        tr ';' '\n' |
        while IFS= read -r include_dir; do
          case "$include_dir" in
            /*)
              if [ ! -d "$include_dir" ]; then
                printf '%s\n' "$include_dir"
                break
              fi
              ;;
          esac
        done
    )"
    if [ -n "$missing_include" ]; then
      printf 'Removing stale Linux CMake cache with missing WebKit include path: %s\n' "$missing_include" >&2
      rm -rf "$cache_dir"
      continue
    fi

    cache_source_dir="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" | tail -n 1)"
    if [ -n "$cache_source_dir" ] && [ "$cache_source_dir" != "$PROJECT_ROOT/linux" ]; then
      printf 'Removing stale Linux CMake cache from old project path: %s\n' "$cache_source_dir" >&2
      rm -rf "$cache_dir"
    fi
  done
}

. "$PROJECT_ROOT/scripts/load_flutter_secrets.sh"

case "${1:-}" in
  run|build|test)
    FLUTTER_DART_DEFINES="$(tanuki_flutter_dart_defines)"
    ;;
  *)
    FLUTTER_DART_DEFINES=""
    ;;
esac

case "${1:-}" in
  run|build)
    case " $* " in
      *" linux "*|*" -d linux "*|*" --device-id linux "*)
        clean_stale_linux_cmake_cache
        if command -v pkg-config >/dev/null 2>&1 &&
          ! pkg-config --exists webkit2gtk-4.1 2>/dev/null &&
          ! pkg-config --exists webkit2gtk-4.2 2>/dev/null &&
          ! pkg-config --exists webkit2gtk-4.3 2>/dev/null; then
          printf 'Missing Linux WebKit development package. Install it with: sudo apt install -y libwebkit2gtk-4.1-dev libsoup-3.0-dev\n' >&2
        fi
        ;;
    esac
    ;;
esac

# shellcheck disable=SC2086
exec "$FLUTTER_BIN" "$@" $FLUTTER_DART_DEFINES
