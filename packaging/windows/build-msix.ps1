<#
.SYNOPSIS
  Build the Abstrakt Deck MSIX package.

.DESCRIPTION
  1. cargo build --release
  2. fetch the pinned ffmpeg if needed (fetch-ffmpeg.ps1)
  3. stage exe + ffmpeg.exe + manifest + Assets + license files
  4. makepri  -> resources.pri (lets Windows pick scale/targetsize logos)
  5. makeappx -> packaging\windows\out\abstrakt-deck_<ver>_x64.msix  (UNSIGNED;
     this is the file to upload to Partner Center, the Store signs it)
  6. with -Sign: also writes ..._x64.testsigned.msix, signed with the local
     test certificate (subject = the Publisher in AppxManifest.xml), for
     installing on this PC.

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\build-msix.ps1 [-Sign] [-SkipCargo]
#>
param(
    [switch]$Sign,
    [switch]$SkipCargo
)
$ErrorActionPreference = 'Stop'

$Here  = $PSScriptRoot
$Root  = Resolve-Path (Join-Path $Here '..\..')
$Out   = Join-Path $Here 'out'
$Stage = Join-Path $Out 'stage'

# --- Windows SDK tools (newest installed version) -------------------------
$sdkBin = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory |
    Where-Object { $_.Name -match '^10\.' -and (Test-Path (Join-Path $_.FullName 'x64\makeappx.exe')) } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdkBin) { throw 'Windows SDK not found (need makeappx.exe). Install with: winget install Microsoft.WindowsSDK.10.0.26100' }
$tools    = Join-Path $sdkBin.FullName 'x64'
$makeappx = Join-Path $tools 'makeappx.exe'
$makepri  = Join-Path $tools 'makepri.exe'
$signtool = Join-Path $tools 'signtool.exe'
Write-Host "Windows SDK tools: $tools"

# --- Version / publisher from the manifest --------------------------------
$manifestSrc = Join-Path $Here 'AppxManifest.xml'
[xml]$mx   = Get-Content $manifestSrc
$version   = $mx.Package.Identity.Version
$publisher = $mx.Package.Identity.Publisher
$msix      = Join-Path $Out "abstrakt-deck_${version}_x64.msix"
$msixTest  = Join-Path $Out "abstrakt-deck_${version}_x64.testsigned.msix"

# --- 1. Build ---------------------------------------------------------------
if (-not $SkipCargo) {
    Push-Location $Root
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}
$exe = Join-Path $Root 'target\release\abstrakt-deck.exe'
if (-not (Test-Path $exe)) { throw "Missing $exe" }

# --- 2. ffmpeg --------------------------------------------------------------
$ffDir = Join-Path $Here 'vendor\ffmpeg'
if (-not (Test-Path (Join-Path $ffDir 'ffmpeg.exe'))) {
    & (Join-Path $Here 'fetch-ffmpeg.ps1')
}

# --- 3. Stage ---------------------------------------------------------------
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force $Stage, (Join-Path $Stage 'Licenses') | Out-Null
Copy-Item $exe                           $Stage
Copy-Item (Join-Path $ffDir 'ffmpeg.exe') $Stage
Copy-Item $manifestSrc                   (Join-Path $Stage 'AppxManifest.xml')
Copy-Item (Join-Path $Here 'Assets')     $Stage -Recurse
Copy-Item (Join-Path $Here 'Licenses\*') (Join-Path $Stage 'Licenses') -Recurse
Copy-Item (Join-Path $ffDir 'LICENSE.txt') (Join-Path $Stage 'Licenses\ffmpeg-LICENSE.txt')
Copy-Item (Join-Path $ffDir 'README.txt')  (Join-Path $Stage 'Licenses\ffmpeg-build-README.txt')
# (All visualizer images/fonts/skins are compiled into the exe via include_bytes!.)

# --- 4. resources.pri -------------------------------------------------------
$priConfig = Join-Path $Out 'priconfig.xml'
& $makepri createconfig /cf $priConfig /dq en-US /pv 10.0.0 /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed ($LASTEXITCODE)" }
# Default config splits scale/language variants into resources.scale-*.pri
# for resource packs in an .msixbundle. We ship a single .msix, so keep every
# variant in the one resources.pri.
[xml]$pc = Get-Content $priConfig
$split = $pc.SelectSingleNode('/resources/packaging')
if ($split) { [void]$split.ParentNode.RemoveChild($split); $pc.Save($priConfig) }
& $makepri new /pr $Stage /cf $priConfig /mn (Join-Path $Stage 'AppxManifest.xml') /of (Join-Path $Stage 'resources.pri') /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri new failed ($LASTEXITCODE)" }

# --- 5. Pack (unsigned, for Store upload) -----------------------------------
& $makeappx pack /o /h SHA256 /d $Stage /p $msix | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed ($LASTEXITCODE)" }
Write-Host "Unsigned package (upload this to Partner Center): $msix"

# --- 6. Test-signed copy ----------------------------------------------------
if ($Sign) {
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) { throw "No code-signing cert with subject '$publisher' in Cert:\CurrentUser\My. See packaging\windows\README.md." }
    Copy-Item $msix $msixTest -Force
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msixTest
    if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }
    Write-Host "Test-signed package (local install only): $msixTest"
}
