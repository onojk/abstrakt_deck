// Build script. Only does anything for Windows MSVC targets: embeds the
// application manifest (PerMonitorV2 DPI awareness, Windows 10+ supportedOS,
// asInvoker) into abstrakt-deck.exe using link.exe flags, so no extra crates
// are needed. On Linux and other targets it is a no-op.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if os != "windows" || env != "msvc" {
        return;
    }

    let manifest = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("packaging")
        .join("windows")
        .join("abstrakt-deck.exe.manifest");
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rustc-link-arg-bins=/MANIFEST:EMBED");
    println!("cargo:rustc-link-arg-bins=/MANIFESTINPUT:{}", manifest.display());
}
