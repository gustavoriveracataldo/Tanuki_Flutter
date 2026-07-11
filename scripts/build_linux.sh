#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
export TANUKI_PROJECT_ROOT="$PROJECT_ROOT"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

if [ ! -d linux ]; then
  "$FLUTTER_BIN" create --platforms=linux .
fi

remove_stale_linux_cache() {
  cache_dir="$1"
  cache_file="$cache_dir/CMakeCache.txt"
  [ -f "$cache_file" ] || return 0

  current_source_dir="$PROJECT_ROOT/linux"
  cache_source_dir="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache_file" | tail -n 1)"
  if [ -n "$cache_source_dir" ] && [ "$cache_source_dir" != "$current_source_dir" ]; then
    printf 'Linux CMake cache points to an old project path:\n'
    printf '  old: %s\n' "$cache_source_dir"
    printf '  now: %s\n' "$current_source_dir"
    printf 'Removing stale Linux build cache...\n'
    rm -rf "$cache_dir"
    return 0
  fi

  if grep -q '^MEDIA_KIT_LIBS_AVAILABLE:BOOL=OFF$' "$cache_file"; then
    printf 'Linux CMake cache has media_kit native libs disabled.\n'
    printf 'Removing stale Linux build cache...\n'
    rm -rf "$cache_dir"
    return 0
  fi

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
    printf 'Linux CMake cache references a missing WebKit include path: %s\n' "$missing_include"
    printf 'Removing stale Linux build cache...\n'
    rm -rf "$cache_dir"
  fi
}

LINUX_RELEASE_DIR="$PROJECT_ROOT/build/linux/x64/release"
remove_stale_linux_cache "$LINUX_RELEASE_DIR"

ensure_linux_build_deps() {
  if [ "${TANUKI_SKIP_MEDIA_KIT_DEPS:-0}" = "1" ]; then
    printf 'Skipping automatic Linux dependency installation.\n'
    return
  fi

  if [ ! -f /etc/os-release ]; then
    return
  fi

  . /etc/os-release

  case "$ID" in
    ubuntu|debian|linuxmint|pop|raspbian)
      ;;
    *)
      return
      ;;
  esac

  packages=""
  if ! pkg-config --exists mpv 2>/dev/null; then
    packages="$packages libmpv-dev"
  fi
  if ! pkg-config --exists libvlc 2>/dev/null; then
    packages="$packages libvlc-dev vlc"
  fi
  if ! pkg-config --exists epoxy 2>/dev/null; then
    packages="$packages libepoxy-dev"
  fi
  if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    packages="$packages libgtk-3-dev"
  fi
  if ! pkg-config --exists webkit2gtk-4.1 2>/dev/null &&
     ! pkg-config --exists webkit2gtk-4.2 2>/dev/null &&
     ! pkg-config --exists webkit2gtk-4.3 2>/dev/null; then
    packages="$packages libwebkit2gtk-4.1-dev"
  fi
  if ! pkg-config --exists libsoup-3.0 2>/dev/null; then
    packages="$packages libsoup-3.0-dev"
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    packages="$packages cmake"
  fi
  if ! command -v ninja >/dev/null 2>&1; then
    packages="$packages ninja-build"
  fi

  if [ -z "$packages" ]; then
    return
  fi

  printf 'Installing missing Linux build dependencies:%s\n' "$packages"
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
  else
    printf 'Unable to install Linux build dependencies automatically because apt-get is not available.\n'
    printf 'Please install: %s\n' "$packages"
  fi
}

ensure_linux_build_deps

. "$PROJECT_ROOT/scripts/load_flutter_secrets.sh"
FLUTTER_DART_DEFINES="$(tanuki_flutter_dart_defines)"

"$FLUTTER_BIN" pub get
# shellcheck disable=SC2086
"$FLUTTER_BIN" build linux --release $FLUTTER_DART_DEFINES
