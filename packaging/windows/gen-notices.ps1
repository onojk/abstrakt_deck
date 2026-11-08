<#
.SYNOPSIS
  Regenerate packaging\windows\Licenses\RUST-CRATE-LICENSES.txt.

.DESCRIPTION
  Runs cargo-about over the crates compiled into the Windows exe
  (about.toml: x86_64-pc-windows-msvc, no build/dev deps) using the
  plain-text template about.hbs, then inserts the Ubuntu Font Licence text
  that cargo-about cannot attach itself (see about.toml).

  Re-run whenever Cargo.lock changes, and commit the result.

  Needs: cargo-about with the CLI feature, and the vendored crates:
    cargo install cargo-about --locked --features cli   (run outside the repo)
    cargo vendor --locked vendor                        (if vendor\ is missing)

  Run from the repo root:
    powershell -ExecutionPolicy Bypass -File packaging\windows\gen-notices.ps1
#>
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = Resolve-Path (Join-Path $Here '..\..')
$Out  = Join-Path $Here 'Licenses\RUST-CRATE-LICENSES.txt'
$UflSha256 = '2f0015108d68627bd788d313f529c21ff4da2c2c42a5e1f3883acc83480f9002'

Push-Location $Root
try {
    # cargo-about logs warnings to stderr; don't let PS 5.1 treat them as errors.
    $ErrorActionPreference = 'Continue'
    cargo about generate --frozen --fail -c (Join-Path $Here 'about.toml') (Join-Path $Here 'about.hbs') -o $Out 2>&1 |
        ForEach-Object { "$_" -replace '\x1b\[[0-9;]*m', '' } |
        Where-Object { $_ -match 'WARN|ERROR' -and $_ -notmatch 'LicenseRef-UFL-1.0 has no license file' } |
        ForEach-Object { Write-Warning $_ }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "cargo about failed ($code)" }

    # Locate epaint_default_fonts' UFL.txt via cargo metadata.
    $meta = cargo metadata --frozen --format-version 1 | ConvertFrom-Json
    $pkg  = $meta.packages | Where-Object name -eq 'epaint_default_fonts' | Select-Object -First 1
    $ufl  = Join-Path (Split-Path $pkg.manifest_path) 'fonts\UFL.txt'
    if ((Get-FileHash $ufl -Algorithm SHA256).Hash.ToLower() -ne $UflSha256) {
        throw "$ufl changed; review it and update `$UflSha256 in gen-notices.ps1"
    }
} finally { Pop-Location }

# Replace the body of the "LicenseRef-UFL-1.0" section (from the blank line
# after its "Used by" list up to the next separator) with the real text.
$lines = [IO.File]::ReadAllLines($Out)
$start = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l -like 'LicenseRef-UFL-1.0 (*' })
if ($start -lt 0) { throw 'UFL section not found in generated notices' }
$lines[$start] = 'Ubuntu Font Licence 1.0 (LicenseRef-UFL-1.0)'
$body = $start + 1
while ($lines[$body] -ne '') { $body++ }          # skip "Used by:" list
$end = $body + 1
while ($end -lt $lines.Length -and $lines[$end] -notmatch '^-{80}$') { $end++ }
$result = @($lines[0..$body]) + [IO.File]::ReadAllLines($ufl) + @('', '') + @($lines[$end..($lines.Length - 1)])
# Overview line for the same licence.
$result = $result | ForEach-Object { $_ -replace 'crate\(s\): LicenseRef-UFL-1.0$', 'crate(s): Ubuntu Font Licence 1.0' }
[IO.File]::WriteAllText($Out, (($result -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $Out"
