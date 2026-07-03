$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$FlutterBin = if ($env:FLUTTER_BIN) { $env:FLUTTER_BIN } else { "flutter" }

if (-not (Test-Path "windows")) {
  & $FlutterBin create --platforms=windows .
}

$DartDefines = @()
foreach ($Key in @("TMDB_BEARER_TOKEN", "TMDB_API_KEY", "FANART_API_KEY", "SIMKL_CLIENT_ID", "MYANIMELIST_CLIENT_ID", "MYANIMELIST_CLIENT_SECRET")) {
  $Value = [Environment]::GetEnvironmentVariable($Key)
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $DartDefines += "--dart-define=$Key=$Value"
  }
}

& $FlutterBin pub get
& $FlutterBin build windows --release @DartDefines
