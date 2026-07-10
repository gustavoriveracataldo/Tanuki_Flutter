#!/usr/bin/env sh

tanuki_secret_keys() {
  printf '%s\n' \
    TMDB_BEARER_TOKEN \
    TMDB_API_KEY \
    FANART_API_KEY \
    SIMKL_CLIENT_ID \
    MYANIMELIST_CLIENT_ID \
    MYANIMELIST_CLIENT_SECRET
}

tanuki_local_secret_name() {
  case "$1" in
    TMDB_BEARER_TOKEN) printf '%s' "localTmdbBearerToken" ;;
    TMDB_API_KEY) printf '%s' "localTmdbApiKey" ;;
    FANART_API_KEY) printf '%s' "localFanartApiKey" ;;
    SIMKL_CLIENT_ID) printf '%s' "localSimklClientId" ;;
    MYANIMELIST_CLIENT_ID) printf '%s' "localMyAnimeListClientId" ;;
    MYANIMELIST_CLIENT_SECRET) printf '%s' "localMyAnimeListClientSecret" ;;
    *) printf '%s' "" ;;
  esac
}

tanuki_legacy_property_name() {
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

tanuki_read_local_secret() {
  secret_name="$(tanuki_local_secret_name "$1")"
  project_root="${TANUKI_PROJECT_ROOT:-$(pwd)}"
  secrets_file="${TANUKI_LOCAL_SECRETS:-$project_root/lib/src/local_secrets.dart}"
  if [ -z "$secret_name" ] || [ ! -f "$secrets_file" ]; then
    return 0
  fi
  awk -v name="$secret_name" '
    $0 ~ "const[[:space:]]+" name "[[:space:]]*=" {
      capture = 1
      line = $0
      if ($0 ~ /;/) {
        capture = 0
        sub(/^.*=[[:space:]]*"/, "", line)
        sub(/";[[:space:]]*$/, "", line)
        print line
        exit
      }
      next
    }
    capture {
      line = line $0
      if ($0 ~ /;/) {
        capture = 0
        sub(/^.*=[[:space:]]*"/, "", line)
        sub(/";[[:space:]]*$/, "", line)
        print line
        exit
      }
    }
  ' "$secrets_file"
}

tanuki_read_legacy_property() {
  key="$(tanuki_legacy_property_name "$1")"
  project_root="${TANUKI_PROJECT_ROOT:-$(pwd)}"
  legacy_file="${TANUKI_LEGACY_LOCAL_PROPERTIES:-$project_root/../toonami-tv-pwa/android-tv-shell/local.properties}"
  if [ -z "$key" ] || [ ! -f "$legacy_file" ]; then
    return 0
  fi
  sed -n "s/^$key[[:space:]]*=[[:space:]]*//p" "$legacy_file" | tail -n 1
}

tanuki_flutter_dart_defines() {
  defines=""
  for key in $(tanuki_secret_keys); do
    value="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -z "$value" ]; then
      value="$(tanuki_read_local_secret "$key")"
    fi
    if [ -z "$value" ]; then
      value="$(tanuki_read_legacy_property "$key")"
    fi
    if [ -n "$value" ]; then
      defines="$defines --dart-define=$key=$value"
    fi
  done
  printf '%s' "$defines"
}
