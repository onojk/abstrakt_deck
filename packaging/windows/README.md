# Windows / Microsoft Store packaging

Builds `abstrakt-deck_<version>_x64.msix` for the Microsoft Store
(Store ID 9NR8XFDVFN48, Package Family Name
`ONOJK123Art.AbstraktDeck_mz8ydyxn3nck0`).

Run everything from the repo root in a normal (non-admin) PowerShell unless
noted. If PowerShell refuses to run scripts, prefix each command with
`powershell -ExecutionPolicy Bypass -File`.

## One-time setup

- Rust stable (`x86_64-pc-windows-msvc`), Visual Studio Build Tools (C++),
  Windows SDK 10.0.26100 (provides `makeappx`, `makepri`, `signtool`,
  `appcert`).
- `cargo vendor --locked vendor` — the repo's `.cargo/config.toml` builds
  from vendored crates (needed for the Debian build), so `vendor\` must exist.

## Host the FFmpeg source (once per ffmpeg version, before submitting)

The package ships a GPLv3 ffmpeg.exe, and `Licenses\THIRD-PARTY-NOTICES.txt`
tells users they can get its source at
`https://onojk123.com/abstrakt-deck/ffmpeg-7.1.1.tar.xz`. Make that URL live:

1. ```powershell
   packaging\windows\fetch-ffmpeg-source.ps1
   ```
   Downloads the official `ffmpeg-7.1.1.tar.xz` (the n7.1.1 tag, commit
   db69d06eee, which is what gyan.dev's build was made from) plus its `.asc`
   signature into `packaging\windows\vendor\ffmpeg-src\` and checks the
   SHA-256 recorded in the script.
2. Optional signature check (Git Bash has `gpg`):
   ```bash
   curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0xFCF986EA15E6E293A5644F10B4322F04D67658D8" | gpg --import
   gpg --verify packaging/windows/vendor/ffmpeg-src/ffmpeg-7.1.1.tar.xz.asc packaging/windows/vendor/ffmpeg-src/ffmpeg-7.1.1.tar.xz
   ```
   Expect `Good signature from "FFmpeg release signing key"` and primary key
   fingerprint `FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`.
3. Upload `ffmpeg-7.1.1.tar.xz` (and the `.asc`) to
   `onojk123.com/abstrakt-deck/`, then check the URL downloads.

If you change the ffmpeg version in `fetch-ffmpeg.ps1`, update
`fetch-ffmpeg-source.ps1` and the URL in `Licenses\THIRD-PARTY-NOTICES.txt`
to match.

## Build

```powershell
packaging\windows\build-msix.ps1            # unsigned .msix for Store upload
packaging\windows\build-msix.ps1 -Sign      # + .testsigned.msix for local install
```

Output in `packaging\windows\out\` (gitignored):

| File | Use |
|---|---|
| `abstrakt-deck_0.1.9.0_x64.msix` | **Upload this to Partner Center.** Unsigned; the Store signs it. |
| `abstrakt-deck_0.1.9.0_x64.testsigned.msix` | Install on your own PC for testing. |

The script fetches ffmpeg on first run (`fetch-ffmpeg.ps1`, pinned 7.1.1
with a recorded SHA-256).

## Version bump

Edit `Version="0.1.9.0"` in `AppxManifest.xml` (the fourth number must stay
0 for Store packages). Optionally also `version` in
`abstrakt-deck.exe.manifest`.

## Local test install

1. Create the test certificate once (no admin):
   ```powershell
   New-SelfSignedCertificate -Type Custom -Subject "CN=F29DE742-E5CC-4535-991B-F77A540F906D" -KeyUsage DigitalSignature -FriendlyName "AbstraktDeck test" -CertStoreLocation Cert:\CurrentUser\My -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
   ```
   Then export its public half:
   `Get-ChildItem Cert:\CurrentUser\My | ? Subject -eq "CN=F29DE742-E5CC-4535-991B-F77A540F906D" | Export-Certificate -FilePath packaging\windows\out\AbstraktDeck-test.cer`
2. Trust it, **in an administrator PowerShell**, once per PC:
   `Import-Certificate -FilePath C:\dev\abstrakt_deck\packaging\windows\out\AbstraktDeck-test.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople`
3. `build-msix.ps1 -Sign`, then
   `Add-AppxPackage packaging\windows\out\abstrakt-deck_0.1.9.0_x64.testsigned.msix`
4. Launch "Abstrakt Deck" from Start. Uninstall with
   `Get-AppxPackage *AbstraktDeck* | Remove-AppxPackage`.

No `.pfx` is ever exported; signtool signs from the certificate store.
`*.pfx` is gitignored anyway.

## Windows App Certification Kit (administrator PowerShell)

```powershell
& "C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe" reset
& "C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe" test -appxpackagepath "C:\dev\abstrakt_deck\packaging\windows\out\abstrakt-deck_0.1.9.0_x64.testsigned.msix" -reportoutputpath "C:\dev\abstrakt_deck\packaging\windows\out\wack-report.xml"
```

Known result: **"Blocked executables" (optional) fails** and can be ignored
for Store submission. It only applies to Windows S mode and flags strings
such as `cmd.exe` that Rust's standard library and ffmpeg contain.

## Other files

| File | Purpose |
|---|---|
| `AppxManifest.xml` | Package identity (from Partner Center — don't change), visuals, capabilities. |
| `abstrakt-deck.exe.manifest` | Embedded in the exe by `build.rs`: PerMonitorV2 DPI awareness, Windows 10+. |
| `make-assets.ps1` → `Assets\` | Logo PNGs generated from `flatpak\io.github.onojk.abstrakt_deck.png`. |
| `Licenses\` | Shipped inside the package: app MIT license, ffmpeg GPL notice, Rust crate licenses. |
| `gen-notices.ps1`, `about.toml`, `about.hbs` | Regenerate `Licenses\RUST-CRATE-LICENSES.txt` with cargo-about after `Cargo.lock` changes. |
| `fetch-ffmpeg.ps1` | Downloads + verifies the pinned ffmpeg into `vendor\ffmpeg\` (gitignored). |
| `store/` | Store listing draft, privacy-policy draft, and 1920x1080 screenshots for Partner Center. |
| `fetch-ffmpeg-source.ps1` | Downloads + verifies the matching FFmpeg source tarball into `vendor\ffmpeg-src\` for hosting. |
