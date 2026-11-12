//! Jewel skins — procedural "2.5D" skins streamed into a ring texture one
//! slice at a time and sampled by the Skin painter in place of a loaded image.
//!
//! All depth is illusion: every 3D look is UV distortion + shading on the 2D
//! slice. See docs/jewel-skins-recon.md.
//!
//! Ring layout: the ring texture is `cross × len` (cross-body × time). Each
//! frame the slice writer renders only the rows `[head, head+rows)` (scissor
//! clamped, wrapping), then `head` advances. The painter blit samples the ring
//! at `(painter.v, fract(painter.u + head/len))`, so the newest rows enter at
//! the painter's u = 1 edge — the snake's head.

use bytemuck::{Pod, Zeroable};

/// Where the Skin painter gets its texels from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum SkinSource {
    /// A loaded image skin (File → Open Skin…, Qbist). Unchanged legacy path.
    #[default]
    Image,
    /// Procedural jewel skin generated on the GPU.
    Jewel,
}

/// Absolute row counters wrap here before being handed to the GPU as f32,
/// keeping per-row precision below half a texel. At 240 rows/s this is a
/// single invisible-ish re-seed every ~2.4 h.
const T_WRAP: u64 = 1 << 21;

// ── Parameters ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum JewelFamily {
    #[default]
    FacetedGems,
    SnakeScales,
    CandyBlobs,
    ChromeRibbons,
    PastelPrimitives,
    WovenBraid,
}

impl JewelFamily {
    pub const ALL: [JewelFamily; 6] = [
        JewelFamily::FacetedGems,
        JewelFamily::SnakeScales,
        JewelFamily::CandyBlobs,
        JewelFamily::ChromeRibbons,
        JewelFamily::PastelPrimitives,
        JewelFamily::WovenBraid,
    ];
    pub fn name(self) -> &'static str {
        match self {
            JewelFamily::FacetedGems      => "Faceted gems",
            JewelFamily::SnakeScales      => "Snake scales",
            JewelFamily::CandyBlobs       => "Glossy candy",
            JewelFamily::ChromeRibbons    => "Chrome ribbons",
            JewelFamily::PastelPrimitives => "Pastel primitives",
            JewelFamily::WovenBraid       => "Woven braid",
        }
    }
    fn index(self) -> f32 {
        Self::ALL.iter().position(|f| *f == self).unwrap_or(0) as f32
    }
    pub fn from_name(s: &str) -> Option<Self> {
        let s = s.to_ascii_lowercase();
        Self::ALL.iter().copied().find(|f| {
            let n = f.name().to_ascii_lowercase();
            n == s || n.split(' ').any(|w| w == s)
        })
    }
}

pub const PALETTE_NAMES: [&str; 8] = [
    "Rainbow", "Candy", "Aurora", "Sunset chrome",
    "Toxic", "Pastel", "Jewel-tone", "Holo",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum MotionMode {
    Slither,
    Roll,
    Churn,
    /// Roll + turn + churn (+ a little slither). The "Churn" preset default.
    #[default]
    All,
}

impl MotionMode {
    pub const ALL: [MotionMode; 4] = [MotionMode::Slither, MotionMode::Roll, MotionMode::Churn, MotionMode::All];
    pub fn name(self) -> &'static str {
        match self {
            MotionMode::Slither => "Slither",
            MotionMode::Roll    => "Roll",
            MotionMode::Churn   => "Churn",
            MotionMode::All     => "All",
        }
    }
    /// (slither, roll, turn, churn) weights.
    fn weights(self) -> [f32; 4] {
        match self {
            MotionMode::Slither => [1.0, 0.0, 0.0, 0.0],
            MotionMode::Roll    => [0.0, 1.0, 0.3, 0.0],
            MotionMode::Churn   => [0.0, 0.0, 0.6, 1.0],
            MotionMode::All     => [0.35, 1.0, 1.0, 0.6],
        }
    }
}

/// Ring length relative to the painter width ("ring memory").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum RingMemory {
    Half,
    #[default]
    One,
    Double,
}

impl RingMemory {
    pub const ALL: [RingMemory; 3] = [RingMemory::Half, RingMemory::One, RingMemory::Double];
    pub fn name(self) -> &'static str {
        match self { RingMemory::Half => "½× (short)", RingMemory::One => "1×", RingMemory::Double => "2× (long)" }
    }
    fn len_for(self, painter_w: u32) -> u32 {
        match self { RingMemory::Half => painter_w / 2, RingMemory::One => painter_w, RingMemory::Double => painter_w * 2 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct JewelSkinParams {
    pub family:          JewelFamily,
    pub palette:         u32,
    pub seed:            u32,
    /// Cells across the body.
    pub scale:           f32,
    /// Bump depth (normal strength).
    pub depth:           f32,
    pub gloss:           f32,
    pub iridescence:     f32,
    pub warp:            f32,
    pub slices_per_sec:  f32,
    pub slice_rows:      u32,
    pub motion:          MotionMode,
    pub slither_amp:     f32,
    pub slither_freq:    f32,
    pub roll_speed:      f32,
    pub roll_bands:      u32,
    pub spin_rate:       f32,
    pub churn:           f32,
    pub taper:           f32,
    pub glints:          f32,
    pub morph_slices:    u32,
    pub morph_on_onset:  bool,
    /// Master audio-reactivity scalar (0 = static).
    pub audio_amount:    f32,
    pub ring_memory:     RingMemory,
    // Contrast halos (adaptive underlay): big shapes get an opposite-tone
    // outline; shapes below `halo_size_min` (pattern units) get none.
    pub halo_on:         bool,
    pub halo_size_min:   f32,
    /// Width as a fraction of shape size, clamped to [w_min, w_max] px.
    pub halo_k:          f32,
    pub halo_w_min:      f32,
    pub halo_w_max:      f32,
    pub halo_keyline:    bool,
    /// Edge softness in px.
    pub halo_soft:       f32,
    pub halo_light:      [f32; 3],
    pub halo_dark:       [f32; 3],
}

impl Default for JewelSkinParams {
    /// The "Churn" preset: snake scales, holo palette, 2 counter-rotating
    /// roll bands + per-cell turn + moderate curl churn.
    fn default() -> Self {
        Self {
            family:         JewelFamily::SnakeScales,
            palette:        7,
            seed:           0x5EED_1234,
            scale:          6.0,
            depth:          1.0,
            gloss:          0.7,
            iridescence:    0.6,
            warp:           0.35,
            slices_per_sec: 15.0,
            slice_rows:     12,
            motion:         MotionMode::All,
            slither_amp:    0.08,
            slither_freq:   0.6,
            roll_speed:     0.5,
            roll_bands:     2,
            spin_rate:      0.6,
            churn:          0.5,
            taper:          0.0,
            glints:         0.5,
            morph_slices:   96,
            morph_on_onset: true,
            audio_amount:   1.0,
            ring_memory:    RingMemory::One,
            halo_on:        true,
            halo_size_min:  0.3,
            halo_k:         0.12,
            halo_w_min:     1.0,
            halo_w_max:     4.0,
            halo_keyline:   false,
            halo_soft:      0.75,
            halo_light:     [0.97, 0.96, 0.92],
            halo_dark:      [0.04, 0.03, 0.06],
        }
    }
}

impl JewelSkinParams {
    pub fn randomize(&mut self, rng: &mut impl rand::Rng) {
        self.family      = JewelFamily::ALL[rng.gen_range(0..JewelFamily::ALL.len())];
        self.palette     = rng.gen_range(0..PALETTE_NAMES.len() as u32);
        self.seed        = rng.gen();
        self.scale       = rng.gen_range(3.0..10.0);
        self.depth       = rng.gen_range(0.6..1.6);
        self.gloss       = rng.gen_range(0.4..1.0);
        self.iridescence = rng.gen_range(0.2..1.0);
        self.warp        = rng.gen_range(0.1..0.7);
        self.motion      = MotionMode::ALL[rng.gen_range(0..MotionMode::ALL.len())];
    }
}

/// Per-frame audio drive. Live and export fill this from their own analysers.
#[derive(Debug, Clone, Copy, Default)]
pub struct JewelAudio {
    pub bass: f32,
    pub mid:  f32,
    pub high: f32,
    /// Beat envelope (1 on beat, decays).
    pub beat: f32,
    /// Tempo/PLL phase in [0,1) when locked.
    pub beat_phase: Option<f32>,
    /// A strong onset happened this frame.
    pub big_onset: bool,
}

// ── GPU uniform layouts (flat f32, see CLAUDE.md) ─────────────────────────────

#[repr(C)]
#[derive(Debug, Clone, Copy, Pod, Zeroable)]
struct SliceUniforms {
    // v0
    cross_px: f32, len_px: f32, head_row: f32, t0: f32,
    // v1
    family: f32, palette: f32, seed_a: f32, seed_b: f32,
    // v2
    morph_start: f32, morph_len: f32, scale: f32, depth: f32,
    // v3
    gloss: f32, irid: f32, warp: f32, glints: f32,
    // v4: motion weights
    w_slither: f32, w_roll: f32, w_turn: f32, w_churn: f32,
    // v5
    slither_amp: f32, slither_freq: f32, slither_phase: f32, roll_bands: f32,
    // v6 (roll phase integrated on the CPU so audio speed changes never jump)
    roll_phase: f32, roll_dir_flip: f32, spin_rate: f32, churn: f32,
    // v7
    taper: f32, vortex_kick: f32, light_angle: f32, irid_kick: f32,
    // v8..v11: contrast halos
    halo_on: f32, halo_size_min: f32, halo_k: f32, halo_w_min: f32,
    halo_w_max: f32, halo_keyline: f32, halo_soft: f32, halo_kick: f32,
    halo_light: [f32; 3], _h0: f32,
    halo_dark: [f32; 3], _h1: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Pod, Zeroable)]
struct BlitUniforms {
    offset: f32,
    _p0: f32, _p1: f32, _p2: f32,
}

// ── Pipelines (created once) ─────────────────────────────────────────────────

pub struct JewelPipelines {
    slice_bgl:  wgpu::BindGroupLayout,
    slice_pipeline: wgpu::RenderPipeline,
    blit_bgl:   wgpu::BindGroupLayout,
    pub blit_pipeline: wgpu::RenderPipeline,
    ring_sampler: wgpu::Sampler,
}

const RING_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

fn uniform_bgl(device: &wgpu::Device, label: &str, vis: wgpu::ShaderStages) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some(label),
        entries: &[wgpu::BindGroupLayoutEntry {
            binding: 0,
            visibility: vis,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }],
    })
}

impl JewelPipelines {
    /// `skin_bgl` = texture + filtering sampler (group 0 of the skin painter);
    /// `harmony_bgl` = applied-harmony uniform (group 1).
    pub fn new(
        device: &wgpu::Device,
        skin_bgl: &wgpu::BindGroupLayout,
        harmony_bgl: &wgpu::BindGroupLayout,
        painter_format: wgpu::TextureFormat,
    ) -> Self {
        let slice_bgl = uniform_bgl(device, "Jewel slice BGL", wgpu::ShaderStages::FRAGMENT);
        let blit_bgl  = uniform_bgl(device, "Jewel blit BGL",  wgpu::ShaderStages::FRAGMENT);

        let slice_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Jewel slice shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/jewel_slice.wgsl").into()),
        });
        let slice_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Jewel slice pipeline"),
            layout: Some(&device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None, bind_group_layouts: &[&slice_bgl], push_constant_ranges: &[],
            })),
            vertex: wgpu::VertexState {
                module: &slice_shader, entry_point: "vs_main",
                buffers: &[], compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &slice_shader, entry_point: "fs_main",
                targets: &[Some(wgpu::ColorTargetState {
                    format: RING_FORMAT,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Jewel painter shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shaders/painter_jewel.wgsl").into()),
        });
        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Jewel painter pipeline"),
            layout: Some(&device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[skin_bgl, harmony_bgl, &blit_bgl],
                push_constant_ranges: &[],
            })),
            vertex: wgpu::VertexState {
                module: &blit_shader, entry_point: "vs_main",
                buffers: &[], compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader, entry_point: "fs_main",
                targets: &[Some(wgpu::ColorTargetState {
                    format: painter_format,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let ring_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Jewel ring sampler"),
            address_mode_u: wgpu::AddressMode::Repeat,
            address_mode_v: wgpu::AddressMode::Repeat,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::FilterMode::Nearest,
            ..Default::default()
        });

        Self { slice_bgl, slice_pipeline, blit_bgl, blit_pipeline, ring_sampler }
    }
}

// ── One stream = one ring texture ────────────────────────────────────────────

struct Morph {
    seed_from: u32,
    seed_to:   u32,
    /// Absolute row at which the blend starts.
    start_row: u64,
    len_rows:  u32,
}

pub struct JewelStream {
    pub cross: u32,
    pub len:   u32,
    ring_tex: wgpu::Texture,
    ring_view: wgpu::TextureView,
    pub sample_bg: wgpu::BindGroup,
    slice_buf: wgpu::Buffer,
    slice_bg:  wgpu::BindGroup,
    blit_buf:  wgpu::Buffer,
    pub blit_bg: wgpu::BindGroup,

    head:      u32,
    row_accum: f64,
    /// Absolute row index of the row at `head` (= rows written so far).
    abs_row:   u64,
    filled:    bool,

    // Motion integrators (CPU-side so speed changes are always continuous).
    roll_phase:    f64,
    slither_phase: f64,
    light_angle:   f64,
    vortex_kick:   f32,
    irid_kick:     f32,
    roll_flip:     f32,

    /// Seed currently committed (end state of the last morph).
    seed_current: u32,
    morph:        Option<Morph>,
    rng_state:    u64,
}

impl JewelStream {
    pub fn new(
        device: &wgpu::Device,
        pipes: &JewelPipelines,
        skin_bgl: &wgpu::BindGroupLayout,
        painter_w: u32,
        painter_h: u32,
        params: &JewelSkinParams,
    ) -> Self {
        let cross = painter_h.max(16);
        let len = params.ring_memory.len_for(painter_w).clamp(256, 16384);
        let ring_tex = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Jewel ring texture"),
            size: wgpu::Extent3d { width: cross, height: len, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: RING_FORMAT,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let ring_view = ring_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let sample_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Jewel ring sample BG"),
            layout: skin_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&ring_view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&pipes.ring_sampler) },
            ],
        });
        let slice_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Jewel slice uniforms"),
            size: std::mem::size_of::<SliceUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let slice_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Jewel slice BG"),
            layout: &pipes.slice_bgl,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: slice_buf.as_entire_binding() }],
        });
        let blit_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Jewel blit uniforms"),
            size: std::mem::size_of::<BlitUniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let blit_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Jewel blit BG"),
            layout: &pipes.blit_bgl,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: blit_buf.as_entire_binding() }],
        });
        log::info!("[jewel] ring {cross}×{len} ({:.1} MiB)", (cross * len * 4) as f32 / 1048576.0);
        Self {
            cross, len,
            ring_tex, ring_view, sample_bg,
            slice_buf, slice_bg, blit_buf, blit_bg,
            head: 0, row_accum: 0.0, abs_row: 0, filled: false,
            roll_phase: 0.0, slither_phase: 0.0, light_angle: 0.0,
            vortex_kick: 0.0, irid_kick: 0.0, roll_flip: 1.0,
            seed_current: params.seed,
            morph: None,
            rng_state: params.seed as u64 ^ 0x9E37_79B9_7F4A_7C15,
        }
    }

    /// True when this stream was built for different dims than requested.
    pub fn matches(&self, painter_w: u32, painter_h: u32, params: &JewelSkinParams) -> bool {
        self.cross == painter_h.max(16)
            && self.len == params.ring_memory.len_for(painter_w).clamp(256, 16384)
    }

    /// Debug: read the whole ring back and save it as a PNG, rotated so the
    /// time axis runs left→right like the painter strip (oldest at the left).
    /// Blocks on the GPU; never called on the normal render path.
    pub fn dump_png(&self, device: &wgpu::Device, queue: &wgpu::Queue, path: &std::path::Path) -> Result<(), String> {
        let bpr = (self.cross * 4).div_ceil(256) * 256;
        let buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Jewel dump"),
            size: (bpr * self.len) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut enc = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("Jewel dump") });
        enc.copy_texture_to_buffer(
            self.ring_tex.as_image_copy(),
            wgpu::ImageCopyBuffer {
                buffer: &buf,
                layout: wgpu::ImageDataLayout { offset: 0, bytes_per_row: Some(bpr), rows_per_image: Some(self.len) },
            },
            wgpu::Extent3d { width: self.cross, height: self.len, depth_or_array_layers: 1 },
        );
        queue.submit(Some(enc.finish()));
        let slice = buf.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        device.poll(wgpu::Maintain::Wait);
        let data = slice.get_mapped_range();
        let mut img = image::RgbaImage::new(self.len, self.cross);
        for ring_y in 0..self.len {
            // Column 0 = oldest row (at head).
            let x = (ring_y + self.len - self.head) % self.len;
            for c in 0..self.cross {
                let o = (ring_y * bpr + c * 4) as usize;
                img.put_pixel(x, c, image::Rgba([data[o], data[o + 1], data[o + 2], 255]));
            }
        }
        drop(data);
        buf.unmap();
        img.save(path).map_err(|e| e.to_string())
    }

    /// Force a full refill on the next tick (e.g. after a big param change).
    pub fn invalidate(&mut self) { self.filled = false; }

    fn next_rand(&mut self) -> u32 {
        // xorshift64*
        let mut x = self.rng_state;
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        self.rng_state = x;
        (x.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 32) as u32
    }

    /// Start a morph from the current seed to `to` over `len_rows` rows,
    /// beginning at the next row written. A morph in progress is committed
    /// to its target first so the body never jumps.
    pub fn start_morph(&mut self, to: u32, len_rows: u32) {
        if let Some(m) = self.morph.take() {
            self.seed_current = m.seed_to;
        }
        self.morph = Some(Morph {
            seed_from: self.seed_current,
            seed_to: to,
            start_row: self.abs_row,
            len_rows: len_rows.max(1),
        });
    }

    pub fn morph_to_random(&mut self, len_rows: u32) {
        let s = self.next_rand();
        self.start_morph(s, len_rows);
    }

    /// Advance by `dt` seconds and encode the slice pass that writes the new
    /// rows. Deterministic in `dt`: export calls it with `1/fps`.
    pub fn tick(
        &mut self,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        pipes: &JewelPipelines,
        params: &JewelSkinParams,
        audio: &JewelAudio,
        dt: f32,
    ) {
        let dt = dt.max(0.0) as f64;
        let amt = params.audio_amount.max(0.0);

        // Seed edits from the UI arrive as a morph, not a cut.
        let target_seed = self.morph.as_ref().map_or(self.seed_current, |m| m.seed_to);
        if params.seed != target_seed && self.filled {
            self.start_morph(params.seed, params.morph_slices.max(1) * params.slice_rows.max(1));
        } else if !self.filled {
            self.seed_current = params.seed;
            self.morph = None;
        }

        // ── Audio → modulation (Stage 6) ─────────────────────────────────────
        let bass = audio.bass.clamp(0.0, 2.0) * amt;
        let mid  = audio.mid.clamp(0.0, 2.0)  * amt;
        let high = audio.high.clamp(0.0, 2.0) * amt;
        let beat = audio.beat.clamp(0.0, 1.0) * amt;

        // Envelopes driven by onsets / beats; decay ≈ ADSR release.
        self.vortex_kick = (self.vortex_kick * (-4.0 * dt as f32).exp()).max(beat);
        self.irid_kick   = (self.irid_kick   * (-3.0 * dt as f32).exp()).max(high * 0.8);
        if audio.big_onset && amt > 0.0 {
            if params.morph_on_onset && self.filled {
                let len = params.morph_slices.max(1) * params.slice_rows.max(1);
                self.morph_to_random(len);
            }
            self.roll_flip = -self.roll_flip;
        }

        let speed_mod = 1.0 + 0.8 * bass as f64;
        let rows_per_sec = (params.slices_per_sec.max(0.0) as f64)
            * params.slice_rows.max(1) as f64
            * speed_mod;

        // Integrate motion phases in seconds (continuous under speed changes).
        self.roll_phase    += dt * params.roll_speed as f64 * (1.0 + 1.2 * bass as f64) * self.roll_flip as f64;
        self.light_angle   -= dt * 0.25;
        self.slither_phase = match audio.beat_phase {
            // PLL-locked: one wiggle per beat.
            Some(p) if amt > 0.0 => p as f64,
            _ => self.slither_phase + dt * params.slither_freq as f64,
        };

        // ── Rows to write this frame ─────────────────────────────────────────
        let (start_head, rows) = if !self.filled {
            self.filled = true;
            self.head = 0;
            self.row_accum = 0.0;
            (0u32, self.len)
        } else {
            self.row_accum += rows_per_sec * dt;
            let r = (self.row_accum.floor() as u64).min(self.len as u64) as u32;
            self.row_accum -= r as f64;
            if self.row_accum > self.len as f64 { self.row_accum = 0.0; }
            (self.head, r)
        };

        // Retire a finished morph.
        if let Some(m) = &self.morph {
            if self.abs_row >= m.start_row + m.len_rows as u64 {
                self.seed_current = m.seed_to;
                self.morph = None;
            }
        }

        if rows > 0 {
            let w = params.motion.weights();
            let (seed_a, seed_b, morph_start, morph_len) = match &self.morph {
                Some(m) => (
                    m.seed_from, m.seed_to,
                    m.start_row as f64 - self.abs_row as f64,
                    m.len_rows as f32,
                ),
                None => (self.seed_current, self.seed_current, -1.0, 1.0),
            };
            let u = SliceUniforms {
                cross_px: self.cross as f32,
                len_px:   self.len as f32,
                head_row: start_head as f32,
                t0:       (self.abs_row % T_WRAP) as f32,
                family:   params.family.index(),
                palette:  params.palette.min(PALETTE_NAMES.len() as u32 - 1) as f32,
                // Seeds go through f32: keep them within the exact-integer range.
                seed_a:   (seed_a & 0xFFFF) as f32,
                seed_b:   (seed_b & 0xFFFF) as f32,
                morph_start: morph_start as f32,
                morph_len,
                scale:    params.scale.max(0.5),
                depth:    params.depth * (1.0 + 0.3 * mid),
                gloss:    params.gloss,
                irid:     params.iridescence,
                warp:     params.warp * (1.0 + 0.8 * mid),
                glints:   params.glints * (1.0 + 1.5 * high),
                w_slither: w[0],
                w_roll:    w[1],
                w_turn:    w[2],
                w_churn:   w[3],
                slither_amp:   params.slither_amp * (1.0 + 1.5 * bass),
                slither_freq:  params.slither_freq,
                slither_phase: (self.slither_phase.rem_euclid(1.0)) as f32,
                roll_bands:    params.roll_bands.clamp(1, 4) as f32,
                roll_phase:    self.roll_phase.rem_euclid(64.0) as f32,
                roll_dir_flip: self.roll_flip,
                spin_rate:     params.spin_rate * (1.0 + 1.0 * mid),
                churn:         params.churn * (1.0 + 0.8 * bass),
                taper:         params.taper,
                vortex_kick:   self.vortex_kick,
                light_angle:   self.light_angle.rem_euclid(std::f64::consts::TAU) as f32,
                irid_kick:     self.irid_kick,
                halo_on:       if params.halo_on { 1.0 } else { 0.0 },
                halo_size_min: params.halo_size_min.max(0.0),
                halo_k:        params.halo_k.max(0.0),
                halo_w_min:    params.halo_w_min.max(0.0),
                halo_w_max:    params.halo_w_max.max(params.halo_w_min),
                halo_keyline:  if params.halo_keyline { 1.0 } else { 0.0 },
                halo_soft:     params.halo_soft,
                // Beat → +20% width pulse (decays with the vortex envelope).
                halo_kick:     self.vortex_kick,
                halo_light:    params.halo_light,
                _h0: 0.0,
                halo_dark:     params.halo_dark,
                _h1: 0.0,
            };
            queue.write_buffer(&self.slice_buf, 0, bytemuck::bytes_of(&u));

            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Jewel slice pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.ring_view,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
                })],
                depth_stencil_attachment: None,
                occlusion_query_set: None,
                timestamp_writes: None,
            });
            pass.set_pipeline(&pipes.slice_pipeline);
            pass.set_bind_group(0, &self.slice_bg, &[]);
            // Strip [head, head+rows) — split in two at the ring wrap.
            let first = rows.min(self.len - start_head);
            pass.set_scissor_rect(0, start_head, self.cross, first);
            pass.draw(0..3, 0..1);
            if first < rows {
                pass.set_scissor_rect(0, 0, self.cross, rows - first);
                pass.draw(0..3, 0..1);
            }
            drop(pass);

            self.head = (start_head + rows) % self.len;
            self.abs_row += rows as u64;
        }

        let b = BlitUniforms {
            offset: self.head as f32 / self.len as f32,
            _p0: 0.0, _p1: 0.0, _p2: 0.0,
        };
        queue.write_buffer(&self.blit_buf, 0, bytemuck::bytes_of(&b));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slice_uniforms_are_whole_vec4s() {
        assert_eq!(std::mem::size_of::<SliceUniforms>() % 16, 0);
        assert_eq!(std::mem::size_of::<SliceUniforms>(), 12 * 16);
        assert_eq!(std::mem::size_of::<BlitUniforms>(), 16);
    }

    #[test]
    fn family_names_round_trip() {
        for f in JewelFamily::ALL {
            assert_eq!(JewelFamily::from_name(f.name()), Some(f));
        }
        assert_eq!(JewelFamily::from_name("snake"), Some(JewelFamily::SnakeScales));
    }

    #[test]
    fn params_deserialize_from_empty_object() {
        let p: JewelSkinParams = serde_json::from_str("{}").unwrap();
        assert_eq!(p, JewelSkinParams::default());
    }
}
