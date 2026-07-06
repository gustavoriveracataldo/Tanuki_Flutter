#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

if [ ! -d linux ]; then
  "$FLUTTER_BIN" create --platforms=linux .
fi

LINUX_RELEASE_DIR="$PROJECT_ROOT/build/linux/x64/release"
CMAKE_CACHE="$LINUX_RELEASE_DIR/CMakeCache.txt"
if [ -f "$CMAKE_CACHE" ]; then
  CURRENT_SOURCE_DIR="$PROJECT_ROOT/linux"
  CACHE_SOURCE_DIR="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CMAKE_CACHE" | tail -n 1)"
  if [ -n "$CACHE_SOURCE_DIR" ] && [ "$CACHE_SOURCE_DIR" != "$CURRENT_SOURCE_DIR" ]; then
    printf 'Linux CMake cache points to an old project path:\n'
    printf '  old: %s\n' "$CACHE_SOURCE_DIR"
    printf '  now: %s\n' "$CURRENT_SOURCE_DIR"
    printf 'Removing stale Linux build cache...\n'
    rm -rf "$LINUX_RELEASE_DIR"
  fi
fi

if [ -f "$CMAKE_CACHE" ] && grep -q '^MEDIA_KIT_LIBS_AVAILABLE:BOOL=OFF$' "$CMAKE_CACHE"; then
  printf 'Linux CMake cache has media_kit native libs disabled.\n'
  printf 'Removing stale Linux build cache...\n'
  rm -rf "$LINUX_RELEASE_DIR"
fi

ensure_linux_media_kit_build_deps() {
  if [ "${TANUKI_SKIP_MEDIA_KIT_DEPS:-0}" = "1" ]; then
    printf 'Skipping automatic Linux media_kit dependency installation.\n'
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
  if ! pkg-config --exists epoxy 2>/dev/null; then
    packages="$packages libepoxy-dev"
  fi
  if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    packages="$packages libgtk-3-dev"
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
    printf 'Unable to install Linux media_kit dependencies automatically because apt-get is not available.\n'
    printf 'Please install: %s\n' "$packages"
  fi
}

ensure_linux_media_kit_build_deps

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
