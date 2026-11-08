<#
.SYNOPSIS
  Download the FFmpeg source matching the bundled ffmpeg.exe, for hosting.

.DESCRIPTION
  The bundled ffmpeg.exe (fetch-ffmpeg.ps1) is gyan.dev's 7.1.1 build of
  FFmpeg commit db69d06eee, which is the official n7.1.1 release tag. This
  script downloads the official ffmpeg-7.1.1.tar.xz release tarball and its
  .asc signature into packaging\windows\vendor\ffmpeg-src\ (gitignored) and
  checks the tarball's SHA-256. Upload the .tar.xz (and optionally the .asc)
  to https://onojk123.com/abstrakt-deck/ — the in-package notice
  (Licenses\THIRD-PARTY-NOTICES.txt) points there.

  Recorded 2026-11-08 after verifying the .asc against the FFmpeg release
  signing key, fingerprint FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8.

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\fetch-ffmpeg-source.ps1
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Version = '7.1.1'
$Base    = "https://ffmpeg.org/releases/ffmpeg-$Version.tar.xz"
$Sha256  = '733984395E0DBBE5C046ABDA2DC49A5544E7E0E1E2366BBA849222AE9E3A03B1'

$Dest = Join-Path $PSScriptRoot 'vendor\ffmpeg-src'
New-Item -ItemType Directory -Force $Dest | Out-Null
$Tar  = Join-Path $Dest "ffmpeg-$Version.tar.xz"

if (-not (Test-Path $Tar) -or (Get-FileHash $Tar -Algorithm SHA256).Hash -ne $Sha256) {
    Write-Host "Downloading $Base"
    Invoke-WebRequest $Base -OutFile $Tar -UseBasicParsing
}
Invoke-WebRequest "$Base.asc" -OutFile "$Tar.asc" -UseBasicParsing

$actual = (Get-FileHash $Tar -Algorithm SHA256).Hash
if ($actual -ne $Sha256) {
    throw "SHA-256 mismatch for $Tar`n  expected $Sha256`n  actual   $actual"
}
Write-Host "SHA-256 OK ($Sha256)"
Write-Host "Ready to upload:"
Write-Host "  $Tar"
Write-Host "  $Tar.asc"
