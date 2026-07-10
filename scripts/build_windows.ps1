$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$FlutterBin = if ($env:FLUTTER_BIN) { $env:FLUTTER_BIN } else { "flutter" }

if (-not (Test-Path "windows")) {
  & $FlutterBin create --platforms=windows .
}

function Get-LocalSecretName {
  param([string]$Key)
  switch ($Key) {
    "TMDB_BEARER_TOKEN" { "localTmdbBearerToken" }
    "TMDB_API_KEY" { "localTmdbApiKey" }
    "FANART_API_KEY" { "localFanartApiKey" }
    "SIMKL_CLIENT_ID" { "localSimklClientId" }
    "MYANIMELIST_CLIENT_ID" { "localMyAnimeListClientId" }
    "MYANIMELIST_CLIENT_SECRET" { "localMyAnimeListClientSecret" }
    default { "" }
  }
}

function Get-LocalSecret {
  param([string]$Key)
  $SecretName = Get-LocalSecretName $Key
  $SecretsPath = if ($env:TANUKI_LOCAL_SECRETS) {
    $env:TANUKI_LOCAL_SECRETS
  } else {
    Join-Path $ProjectRoot "lib\src\local_secrets.dart"
  }
  if ([string]::IsNullOrWhiteSpace($SecretName) -or -not (Test-Path $SecretsPath)) {
    return ""
  }
  $Content = Get-Content -Raw -Path $SecretsPath
  $Pattern = "const\s+$SecretName\s*=\s*`"([^`"]*)`"\s*;"
  if ($Content -match $Pattern) {
    return $Matches[1]
  }
  return ""
}

$DartDefines = @()
foreach ($Key in @("TMDB_BEARER_TOKEN", "TMDB_API_KEY", "FANART_API_KEY", "SIMKL_CLIENT_ID", "MYANIMELIST_CLIENT_ID", "MYANIMELIST_CLIENT_SECRET")) {
  $Value = [Environment]::GetEnvironmentVariable($Key)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = Get-LocalSecret $Key
  }
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $DartDefines += "--dart-define=$Key=$Value"
  }
}

& $FlutterBin pub get
& $FlutterBin build windows --release @DartDefines
