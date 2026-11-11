//! User-safety settings: the first-launch safety notice and Reduced Motion.
//!
//! Persistence: `dirs::config_dir()/abstrakt-deck/settings.json` — app-level
//! settings, kept separate from `preset.json` (which holds visual parameters
//! the user saves/loads explicitly and which Random/Party modes reroll).

use serde::{Deserialize, Serialize};

/// Rate multiplier applied to rotation, zoom, camera and animation clocks
/// while Reduced Motion is on.
pub const REDUCED_MOTION_SCALE: f32 = 0.25;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AppSettings {
    /// The user has dismissed the startup safety notice at least once.
    #[serde(default)]
    pub safety_notice_acknowledged: bool,
    /// Explicit user choice. `None` = never chosen → follow the OS preference.
    #[serde(default)]
    pub reduced_motion: Option<bool>,
}

impl AppSettings {
    fn path() -> Option<std::path::PathBuf> {
        let mut p = dirs::config_dir()?;
        p.push("abstrakt-deck");
        p.push("settings.json");
        Some(p)
    }

    /// Missing or unreadable file → defaults (notice not yet acknowledged).
    pub fn load() -> Self {
        let Some(path) = Self::path() else { return Self::default() };
        match std::fs::read_to_string(&path) {
            Ok(json) => serde_json::from_str(&json).unwrap_or_else(|e| {
                log::warn!("settings.json unreadable ({e}) — using defaults");
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) {
        let Some(path) = Self::path() else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match serde_json::to_string_pretty(self) {
            Ok(json) => {
                if let Err(e) = std::fs::write(&path, json) {
                    log::warn!("could not write {}: {e}", path.display());
                }
            }
            Err(e) => log::warn!("could not serialize settings: {e}"),
        }
    }

    /// The user's explicit choice wins; otherwise follow the OS.
    pub fn effective_reduced_motion(&self) -> bool {
        self.reduced_motion.unwrap_or_else(os_prefers_reduced_motion)
    }
}

/// Windows: true when Settings › Accessibility › Visual effects ›
/// "Animation effects" is off (SPI_GETCLIENTAREAANIMATION == FALSE).
#[cfg(windows)]
pub fn os_prefers_reduced_motion() -> bool {
    use windows::Win32::Foundation::BOOL;
    use windows::Win32::UI::WindowsAndMessaging::{
        SystemParametersInfoW, SPI_GETCLIENTAREAANIMATION, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
    };
    let mut enabled = BOOL(1);
    // SAFETY: SPI_GETCLIENTAREAANIMATION writes a single BOOL to pvParam.
    let ok = unsafe {
        SystemParametersInfoW(
            SPI_GETCLIENTAREAANIMATION,
            0,
            Some(&mut enabled as *mut BOOL as *mut core::ffi::c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    };
    match ok {
        Ok(()) => !enabled.as_bool(),
        Err(e) => {
            log::warn!("SPI_GETCLIENTAREAANIMATION failed: {e}");
            false
        }
    }
}

#[cfg(not(windows))]
pub fn os_prefers_reduced_motion() -> bool {
    false
}

/// A time base that can run slower than wall-clock without jumping.
///
/// `time(wall) = wall * scale + offset`. Changing the scale re-solves the
/// offset so the output is continuous. With scale 1 and offset 0 (the
/// default) `time(wall) == wall` exactly, so default rendering is unchanged.
#[derive(Debug, Clone, Copy)]
pub struct MotionClock {
    scale: f32,
    offset: f32,
}

impl Default for MotionClock {
    fn default() -> Self { Self { scale: 1.0, offset: 0.0 } }
}

impl MotionClock {
    pub fn time(&self, wall: f32) -> f32 {
        wall * self.scale + self.offset
    }

    pub fn scale(&self) -> f32 { self.scale }

    pub fn set_scale(&mut self, wall: f32, scale: f32) {
        let now = self.time(wall);
        self.scale = scale;
        if scale == 1.0 && (now - wall).abs() < f32::EPSILON {
            self.offset = 0.0;
        } else {
            self.offset = now - wall * scale;
        }
    }
}

/// Asymmetric one-pole smoother (separate attack / release time constants).
pub fn smooth_envelope(prev: f32, target: f32, dt: f32, attack_s: f32, release_s: f32) -> f32 {
    let tau = if target > prev { attack_s } else { release_s };
    let a = 1.0 - (-dt / tau).exp();
    prev + (target - prev) * a
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn motion_clock_default_is_identity() {
        let c = MotionClock::default();
        for w in [0.0_f32, 0.016, 1.5, 123.456, 599.9] {
            assert_eq!(c.time(w), w);
        }
    }

    #[test]
    fn motion_clock_is_continuous_across_scale_change() {
        let mut c = MotionClock::default();
        let before = c.time(10.0);
        c.set_scale(10.0, REDUCED_MOTION_SCALE);
        assert!((c.time(10.0) - before).abs() < 1e-4);
        // Advances at the reduced rate afterwards.
        assert!((c.time(14.0) - (before + 1.0)).abs() < 1e-4);
        let mid = c.time(20.0);
        c.set_scale(20.0, 1.0);
        assert!((c.time(20.0) - mid).abs() < 1e-4);
        assert!((c.time(21.0) - (mid + 1.0)).abs() < 1e-4);
    }

    #[test]
    fn settings_roundtrip_and_defaults() {
        let s: AppSettings = serde_json::from_str("{}").unwrap();
        assert!(!s.safety_notice_acknowledged);
        assert_eq!(s.reduced_motion, None);
        let s2 = AppSettings { safety_notice_acknowledged: true, reduced_motion: Some(true) };
        let back: AppSettings = serde_json::from_str(&serde_json::to_string(&s2).unwrap()).unwrap();
        assert!(back.safety_notice_acknowledged);
        assert_eq!(back.reduced_motion, Some(true));
    }
}
