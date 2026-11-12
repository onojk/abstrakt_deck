// jewel_slice.wgsl — writes one strip of the jewel ring texture.
// Ring texture is cross × len; the pass is scissored to rows [head, head+rows).
// Every time-varying term uses absolute row time t = t0 + local, never the
// ring index, so the wrap is seamless.

struct Slice {
    cross_px: f32, len_px: f32, head_row: f32, t0: f32,
    family: f32, palette: f32, seed_a: f32, seed_b: f32,
    morph_start: f32, morph_len: f32, scale: f32, depth: f32,
    gloss: f32, irid: f32, warp: f32, glints: f32,
    w_slither: f32, w_roll: f32, w_turn: f32, w_churn: f32,
    slither_amp: f32, slither_freq: f32, slither_phase: f32, roll_bands: f32,
    roll_phase: f32, roll_dir_flip: f32, spin_rate: f32, churn: f32,
    taper: f32, vortex_kick: f32, light_angle: f32, irid_kick: f32,
};
@group(0) @binding(0) var<uniform> S: Slice;

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
    let x = f32((vid << 1u) & 2u);
    let y = f32(vid & 2u);
    return vec4<f32>(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let row   = floor(frag.y);
    let local = (row - S.head_row + S.len_px) % S.len_px;
    let t_row = S.t0 + local;                 // absolute row time
    let u     = frag.x / S.cross_px;          // [0,1) across the body
    let tb    = t_row / S.cross_px;           // time in body widths
    // Stage 2 test pattern: diagonal hue stripes keyed on absolute time.
    let k = fract(u * 3.0 + tb * 0.5);
    let hue = fract(tb * 0.05);
    let c = 0.5 + 0.5 * cos(6.28318 * (vec3<f32>(hue) + vec3<f32>(0.0, 0.33, 0.67)));
    return vec4<f32>(c * (0.4 + 0.6 * step(0.5, k)), 1.0);
}
