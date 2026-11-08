<#
.SYNOPSIS
  Download the pinned ffmpeg build used by the Windows package and verify it.

.DESCRIPTION
  Fetches gyan.dev's static GPL "essentials" build of ffmpeg 7.1.1 (win64,
  includes libx264) from its versioned GitHub release, checks the zip against
  the SHA-256 recorded below, and extracts ffmpeg.exe, ffprobe.exe, LICENSE
  and README.txt into packaging\windows\vendor\ffmpeg\ (gitignored).

  Safe to re-run: a cached zip with the right hash is reused.

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\fetch-ffmpeg.ps1

.NOTES
  The hash was recorded on 2026-11-08 from the first download. Neither
  gyan.dev nor GitHub publishes a checksum for this 2025 release asset, so
  it pins "the bytes we tested with" rather than an upstream-signed value.
  To bump the version: change $Version, set $Sha256 to "", run once, review
  the printed hash, and paste it in.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on PS 5.1

$Version = '7.1.1'
$Url     = "https://github.com/GyanD/codexffmpeg/releases/download/$Version/ffmpeg-$Version-essentials_build.zip"
$Sha256  = '04861D3339C5EBE38B56C19A15CF2C0CC97F5DE4FA8910E4D47E5E6404E4A2D4'

$Dest    = Join-Path $PSScriptRoot 'vendor\ffmpeg'
$Zip     = Join-Path $Dest "ffmpeg-$Version-essentials_build.zip"
New-Item -ItemType Directory -Force $Dest | Out-Null

function Test-ZipHash {
    if (-not (Test-Path $Zip)) { return $false }
    return (Get-FileHash $Zip -Algorithm SHA256).Hash -eq $Sha256
}

if (Test-ZipHash) {
    Write-Host "Using cached $Zip"
} else {
    Write-Host "Downloading $Url"
    Invoke-WebRequest $Url -OutFile $Zip -UseBasicParsing
    $actual = (Get-FileHash $Zip -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        Remove-Item $Zip -Force
        throw "SHA-256 mismatch for ffmpeg $Version.`n  expected $Sha256`n  actual   $actual"
    }
}
Write-Host "SHA-256 OK ($Sha256)"

# Extract only the files we ship / test with.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$wanted = @{
    'bin/ffmpeg.exe'  = 'ffmpeg.exe'
    'bin/ffprobe.exe' = 'ffprobe.exe'
    'LICENSE'         = 'LICENSE.txt'
    'README.txt'      = 'README.txt'
}
$archive = [IO.Compression.ZipFile]::OpenRead($Zip)
try {
    foreach ($entry in $archive.Entries) {
        $rel = $entry.FullName -replace '^[^/]+/', ''   # strip top-level folder
        if ($wanted.ContainsKey($rel)) {
            $out = Join-Path $Dest $wanted[$rel]
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
            Write-Host "  extracted $($wanted[$rel])"
        }
    }
} finally {
    $archive.Dispose()
}

& (Join-Path $Dest 'ffmpeg.exe') -hide_banner -version | Select-Object -First 1
Write-Host "ffmpeg $Version ready in $Dest"
