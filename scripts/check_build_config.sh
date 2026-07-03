#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"

CHECK_ANDROID=1
CHECK_LINUX=1
RUN_PUB_GET=1

for arg in "$@"; do
  case "$arg" in
    --skip-android)
      CHECK_ANDROID=0
      ;;
    --skip-linux)
      CHECK_LINUX=0
      ;;
    --no-pub-get)
      RUN_PUB_GET=0
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: sh scripts/check_build_config.sh [--skip-android] [--skip-linux] [--no-pub-get]

Runs build configuration checks without generating release artifacts.

Checks:
  - flutter pub get
  - Android Gradle configuration and assembleRelease dry-run
  - Linux CMake configure
USAGE
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

FLUTTER_BIN_PATH="$(command -v "$FLUTTER_BIN" 2>/dev/null || printf '%s' "$FLUTTER_BIN")"
FLUTTER_SDK="$(cd "$(dirname "$FLUTTER_BIN_PATH")/.." && pwd)"

if [ "$RUN_PUB_GET" = 1 ]; then
  "$FLUTTER_BIN" pub get
fi

if [ "$CHECK_ANDROID" = 1 ]; then
  if [ ! -d android ]; then
    printf 'Android folder not found. Run: %s create --platforms=android .\n' "$FLUTTER_BIN" >&2
    exit 1
  fi

  if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d "$HOME/.codex/android-sdk" ]; then
    export ANDROID_HOME="$HOME/.codex/android-sdk"
    export ANDROID_SDK_ROOT="$HOME/.codex/android-sdk"
  fi
  if [ -z "${ANDROID_HOME:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
  fi
  if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -n "${ANDROID_HOME:-}" ]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
  fi
  if [ -z "${ANDROID_HOME:-}" ] && [ -f android/local.properties ]; then
    LOCAL_ANDROID_SDK="$(sed -n 's/^sdk.dir=//p' android/local.properties | tail -n 1)"
    if [ -n "$LOCAL_ANDROID_SDK" ]; then
      export ANDROID_HOME="$LOCAL_ANDROID_SDK"
      export ANDROID_SDK_ROOT="$LOCAL_ANDROID_SDK"
    fi
  fi

  if [ -z "${JAVA_HOME:-}" ] && [ -x "$HOME/.codex/sdks/jdk/bin/java" ]; then
    export JAVA_HOME="$HOME/.codex/sdks/jdk"
    export PATH="$JAVA_HOME/bin:$PATH"
  fi

  write_android_local_properties() {
    target_root="$1"
    target_properties="$target_root/android/local.properties"
    [ -d "$target_root/android" ] || return 0
    old_build_mode="$(sed -n 's/^flutter.buildMode=//p' "$target_properties" 2>/dev/null | tail -n 1)"
    old_version_name="$(sed -n 's/^flutter.versionName=//p' "$target_properties" 2>/dev/null | tail -n 1)"
    old_version_code="$(sed -n 's/^flutter.versionCode=//p' "$target_properties" 2>/dev/null | tail -n 1)"
    {
      printf 'flutter.sdk=%s\n' "$FLUTTER_SDK"
      if [ -n "${ANDROID_HOME:-}" ]; then
        printf 'sdk.dir=%s\n' "$ANDROID_HOME"
      fi
      printf 'flutter.buildMode=%s\n' "${old_build_mode:-release}"
      printf 'flutter.versionName=%s\n' "${old_version_name:-1.0.0}"
      printf 'flutter.versionCode=%s\n' "${old_version_code:-1}"
    } > "$target_properties"
  }

  find_android_aapt2() {
    found_aapt2=""
    if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/build-tools" ]; then
      for build_tools_dir in "$ANDROID_HOME"/build-tools/*; do
        if [ -x "$build_tools_dir/aapt2" ]; then
          found_aapt2="$build_tools_dir/aapt2"
        fi
      done
    fi
    printf '%s' "$found_aapt2"
  }

  ANDROID_CHECK_ROOT="${TANUKI_ANDROID_CHECK_ROOT:-$HOME/.codex/build-work/tanuki_android_build_config_check}"
  rm -rf "$ANDROID_CHECK_ROOT"
  mkdir -p "$ANDROID_CHECK_ROOT"
  tar \
    --exclude='./build' \
    --exclude='./.dart_tool' \
    --exclude='./.gradle' \
    --exclude='./.gradle-user-home' \
    -cf - . | (cd "$ANDROID_CHECK_ROOT" && tar -xf -)
  chmod +x "$ANDROID_CHECK_ROOT/android/gradlew"
  write_android_local_properties "$ANDROID_CHECK_ROOT"

  AAPT2_OVERRIDE="$(find_android_aapt2)"
  if [ -n "$AAPT2_OVERRIDE" ]; then
    printf '\nandroid.aapt2FromMavenOverride=%s\n' "$AAPT2_OVERRIDE" >> "$ANDROID_CHECK_ROOT/android/gradle.properties"
  fi

  (
    cd "$ANDROID_CHECK_ROOT/android"
    ./gradlew help --no-daemon
    ./gradlew :app:assembleRelease --dry-run --no-daemon
  )
fi

if [ "$CHECK_LINUX" = 1 ]; then
  if [ ! -d linux ]; then
    printf 'Linux folder not found. Run: %s create --platforms=linux .\n' "$FLUTTER_BIN" >&2
    exit 1
  fi
  if ! command -v cmake >/dev/null 2>&1; then
    printf 'cmake not found. Install CMake before building Linux.\n' >&2
    exit 1
  fi

  LINUX_CHECK_ROOT="${TANUKI_LINUX_CHECK_ROOT:-${TMPDIR:-/tmp}/tanuki_linux_cmake_check}"
  rm -rf "$LINUX_CHECK_ROOT"
  cmake -S "$PROJECT_ROOT/linux" -B "$LINUX_CHECK_ROOT" -DCMAKE_BUILD_TYPE=Release
fi

printf '\nBuild configuration checks passed. No release artifacts were generated.\n'
