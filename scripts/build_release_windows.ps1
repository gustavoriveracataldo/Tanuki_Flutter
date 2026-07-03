$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

& "$PSScriptRoot\build_windows.ps1"

$DistDir = if ($env:DIST_DIR) { $env:DIST_DIR } else { Join-Path $ProjectRoot "dist" }
$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
$ZipPath = Join-Path $DistDir "tanuki-windows-x64-release.zip"

if (-not (Test-Path (Join-Path $ReleaseDir "Tanuki.exe"))) {
  throw "Windows release executable not found: $ReleaseDir\Tanuki.exe"
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
if (Test-Path $ZipPath) {
  Remove-Item $ZipPath -Force
}

Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $ZipPath

Write-Host ""
Write-Host "Release artifact:"
Write-Host "  $ZipPath"
