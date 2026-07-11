$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

& "$PSScriptRoot\build_windows.ps1"

$DistDir = if ($env:DIST_DIR) { $env:DIST_DIR } else { Join-Path $ProjectRoot "dist" }
$VersionLine = Select-String -Path (Join-Path $ProjectRoot "pubspec.yaml") -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if ($null -eq $VersionLine) {
  throw "Unable to read version from pubspec.yaml"
}
$VersionName = $VersionLine.Matches[0].Groups[1].Value.Split('+')[0]
$ZipPath = Join-Path $DistDir "tanuki-windows-x64-v$VersionName.zip"

$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $ReleaseDir "Tanuki.exe"))) {
  $BuildRoot = Join-Path $ProjectRoot "build\windows"
  $Executable = if (Test-Path $BuildRoot) {
    Get-ChildItem -Path $BuildRoot -Filter "Tanuki.exe" -Recurse -File |
      Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
      Select-Object -First 1
  } else {
    $null
  }
  if ($null -eq $Executable) {
    throw "Windows release executable not found under $BuildRoot"
  }
  $ReleaseDir = $Executable.DirectoryName
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
if (Test-Path $ZipPath) {
  Remove-Item $ZipPath -Force
}

Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $ZipPath

Write-Host ""
Write-Host "Release artifact:"
Write-Host "  $ZipPath"
