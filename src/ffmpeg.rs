//! Locating and spawning the ffmpeg binary.
//!
//! Lookup order: an `ffmpeg` executable sitting next to our own executable
//! (the Windows MSIX bundles one there), then plain `ffmpeg` resolved via PATH
//! (the normal case on Linux, where it comes from the distro).

use std::path::PathBuf;
use std::process::Command;

#[cfg(target_os = "windows")]
const FFMPEG_EXE: &str = "ffmpeg.exe";
#[cfg(not(target_os = "windows"))]
const FFMPEG_EXE: &str = "ffmpeg";

/// The bundled ffmpeg next to the running executable, if present.
fn bundled() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let candidate = exe.parent()?.join(FFMPEG_EXE);
    candidate.is_file().then_some(candidate)
}

/// A `Command` for ffmpeg, preferring the bundled binary.
pub fn command() -> Command {
    let program = bundled().unwrap_or_else(|| PathBuf::from(FFMPEG_EXE));
    log::info!("ffmpeg: using {}", program.display());
    #[allow(unused_mut)]
    let mut cmd = Command::new(program);
    #[cfg(target_os = "windows")]
    {
        // Don't flash a console window when spawned from the GUI process.
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// Hint appended to "failed to spawn ffmpeg" errors.
pub fn install_hint() -> &'static str {
    if cfg!(target_os = "windows") {
        "ffmpeg.exe was not found next to abstrakt-deck.exe or on PATH"
    } else {
        "is ffmpeg installed? `sudo apt install ffmpeg`"
    }
}
