//! Jewel skins — procedural "2.5D" skins streamed into a ring texture one
//! slice at a time and sampled by the Skin painter in place of a loaded image.
//!
//! All depth is illusion: every 3D look is UV distortion + shading on the 2D
//! slice. See docs/jewel-skins-recon.md.

/// Where the Skin painter gets its texels from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum SkinSource {
    /// A loaded image skin (File → Open Skin…, Qbist). Unchanged legacy path.
    #[default]
    Image,
    /// Procedural jewel skin generated on the GPU.
    Jewel,
}
