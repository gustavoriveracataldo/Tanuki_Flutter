#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
SOURCE_ROOT="$(pwd)"

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.codex/sdks/flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.codex/sdks/flutter/bin/flutter"
fi

FLUTTER_BIN_PATH="$(command -v "$FLUTTER_BIN" 2>/dev/null || printf '%s' "$FLUTTER_BIN")"
FLUTTER_SDK="$(cd "$(dirname "$FLUTTER_BIN_PATH")/.." && pwd)"

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

export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$SOURCE_ROOT/.gradle-user-home}"
mkdir -p "$GRADLE_USER_HOME"

LEGACY_LOCAL_PROPERTIES="${TANUKI_LEGACY_LOCAL_PROPERTIES:-$SOURCE_ROOT/../toonami-tv-pwa/android-tv-shell/local.properties}"

legacy_property_name() {
  case "$1" in
    TMDB_BEARER_TOKEN) printf '%s' "tmdbBearerToken" ;;
    TMDB_API_KEY) printf '%s' "tmdbApiKey" ;;
    FANART_API_KEY) printf '%s' "fanartApiKey" ;;
    SIMKL_CLIENT_ID) printf '%s' "simklClientId" ;;
    MYANIMELIST_CLIENT_ID) printf '%s' "myAnimeListClientId" ;;
    MYANIMELIST_CLIENT_SECRET) printf '%s' "myAnimeListClientSecret" ;;
    *) printf '%s' "" ;;
  esac
}

legacy_property_value() {
  key="$(legacy_property_name "$1")"
  if [ -z "$key" ] || [ ! -f "$LEGACY_LOCAL_PROPERTIES" ]; then
    return 0
  fi
  sed -n "s/^$key[[:space:]]*=[[:space:]]*//p" "$LEGACY_LOCAL_PROPERTIES" | tail -n 1
}

if [ ! -d android ]; then
  "$FLUTTER_BIN" create --platforms=android .
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

FLUTTER_DART_DEFINES=""
for key in TMDB_BEARER_TOKEN TMDB_API_KEY FANART_API_KEY SIMKL_CLIENT_ID MYANIMELIST_CLIENT_ID MYANIMELIST_CLIENT_SECRET; do
  value="$(eval "printf '%s' \"\${$key:-}\"")"
  if [ -z "$value" ]; then
    value="$(legacy_property_value "$key")"
  fi
  if [ -n "$value" ]; then
    FLUTTER_DART_DEFINES="$FLUTTER_DART_DEFINES --dart-define=$key=$value"
  fi
done

if [ ! -x android/gradlew ]; then
  BUILD_ROOT="${TANUKI_ANDROID_BUILD_ROOT:-$HOME/.codex/build-work/tanuki_android_build}"
  rm -rf "$BUILD_ROOT"
  mkdir -p "$BUILD_ROOT"
  tar \
    --exclude='./build' \
    --exclude='./.dart_tool' \
    --exclude='./.gradle' \
    --exclude='./.gradle-user-home' \
    -cf - . | (cd "$BUILD_ROOT" && tar -xf -)
  chmod +x "$BUILD_ROOT/android/gradlew"
  write_android_local_properties "$BUILD_ROOT"
  AAPT2_OVERRIDE="$(find_android_aapt2)"
  if [ -n "$AAPT2_OVERRIDE" ]; then
    printf '\nandroid.aapt2FromMavenOverride=%s\n' "$AAPT2_OVERRIDE" >> "$BUILD_ROOT/android/gradle.properties"
  fi
  cd "$BUILD_ROOT"
else
  BUILD_ROOT="$SOURCE_ROOT"
  write_android_local_properties "$BUILD_ROOT"
fi

"$FLUTTER_BIN" pub get
# shellcheck disable=SC2086
"$FLUTTER_BIN" build apk --release $FLUTTER_DART_DEFINES

if [ "$BUILD_ROOT" != "$SOURCE_ROOT" ]; then
  mkdir -p "$SOURCE_ROOT/build/app/outputs/flutter-apk"
  cp -f "$BUILD_ROOT/build/app/outputs/flutter-apk/"*.apk "$SOURCE_ROOT/build/app/outputs/flutter-apk/"
fi
