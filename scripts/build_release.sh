#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
BUILD_ANDROID=1
BUILD_LINUX=1

for arg in "$@"; do
  case "$arg" in
    --skip-android)
      BUILD_ANDROID=0
      ;;
    --skip-linux)
      BUILD_LINUX=0
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: sh scripts/build_release.sh [--skip-android] [--skip-linux]

Builds release artifacts and copies packaged outputs to dist/.

Outputs:
  dist/tanuki-android-release.apk
  dist/tanuki-linux-x64-release.tar.gz
USAGE
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$DIST_DIR"

if [ "$BUILD_ANDROID" = 1 ]; then
  sh scripts/build_android.sh
  APK_PATH="$PROJECT_ROOT/build/app/outputs/flutter-apk/app-release.apk"
  if [ ! -f "$APK_PATH" ]; then
    printf 'Android APK not found: %s\n' "$APK_PATH" >&2
    exit 1
  fi
  cp -f "$APK_PATH" "$DIST_DIR/tanuki-android-release.apk"
fi

if [ "$BUILD_LINUX" = 1 ]; then
  sh scripts/build_linux.sh
  LINUX_BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
  if [ ! -f "$LINUX_BUNDLE/tanuki" ]; then
    printf 'Linux bundle not found: %s\n' "$LINUX_BUNDLE" >&2
    exit 1
  fi
  tar -czf "$DIST_DIR/tanuki-linux-x64-release.tar.gz" -C "$LINUX_BUNDLE" .
fi

printf '\nRelease artifacts:\n'
if [ "$BUILD_ANDROID" = 1 ]; then
  printf '  %s\n' "$DIST_DIR/tanuki-android-release.apk"
fi
if [ "$BUILD_LINUX" = 1 ]; then
  printf '  %s\n' "$DIST_DIR/tanuki-linux-x64-release.tar.gz"
fi
printf '\nWindows release must be built on Windows:\n'
printf '  powershell -ExecutionPolicy Bypass -File scripts\\build_release_windows.ps1\n'
