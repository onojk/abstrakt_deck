// jewel_slice.wgsl — writes one strip of the jewel ring texture.
//
// Ring texture is cross × len; the pass is scissored to rows [head, head+rows).
// Every time-varying term uses absolute row time t = t0 + local, never the
// ring index, so the wrap is seamless.
//
// ALL DEPTH IS ILLUSION: a height field h(u,t) is built from 2D pattern
// functions; its finite-difference normal drives lighting, fake environment
// reflection, fresnel, thin-film iridescence, cavity AO and glints. No
// geometry, depth buffer or raymarching anywhere.

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

const PI:  f32 = 3.14159265359;
const TAU: f32 = 6.28318530718;

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4<f32> {
    let x = f32((vid << 1u) & 2u);
    let y = f32(vid & 2u);
    return vec4<f32>(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
}

// ── Hashing (integer, so precision holds at large t) ────────────────────────

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn hash2i(c: vec2<i32>, seed: f32) -> f32 {
    let h = pcg(bitcast<u32>(c.x) ^ pcg(bitcast<u32>(c.y) ^ pcg(u32(seed))));
    return f32(h) / 4294967295.0;
}
fn hash2v(c: vec2<i32>, seed: f32) -> vec2<f32> {
    return vec2<f32>(hash2i(c, seed), hash2i(c + vec2<i32>(7919, 104729), seed));
}
fn cell_of(p: vec2<f32>) -> vec2<i32> { return vec2<i32>(floor(p)); }

fn rot2(a: f32) -> mat2x2<f32> {
    let c = cos(a); let s = sin(a);
    return mat2x2<f32>(c, s, -s, c);
}

// Value noise + fbm.
fn vnoise(p: vec2<f32>, seed: f32) -> f32 {
    let i = cell_of(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash2i(i, seed);
    let b = hash2i(i + vec2<i32>(1, 0), seed);
    let c = hash2i(i + vec2<i32>(0, 1), seed);
    let d = hash2i(i + vec2<i32>(1, 1), seed);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
fn fbm(p: vec2<f32>, seed: f32) -> f32 {
    var s = 0.0; var a = 0.5; var q = p;
    for (var i = 0; i < 3; i = i + 1) {
        s = s + a * vnoise(q, seed + f32(i) * 17.0);
        q = q * 2.03 + vec2<f32>(5.2, 1.3);
        a = a * 0.5;
    }
    return s;
}

// ── Palettes: a + b*cos(2π(c*x + d)) ────────────────────────────────────────

fn palette(x: f32, idx: i32) -> vec3<f32> {
    var a = vec3<f32>(0.5); var b = vec3<f32>(0.5);
    var c = vec3<f32>(1.0); var d = vec3<f32>(0.0, 0.33, 0.67);
    switch idx {
        case 1: { // candy
            a = vec3<f32>(0.80, 0.50, 0.65); b = vec3<f32>(0.25, 0.40, 0.30);
            c = vec3<f32>(1.0, 1.0, 1.0);    d = vec3<f32>(0.00, 0.15, 0.30); }
        case 2: { // aurora
            a = vec3<f32>(0.20, 0.50, 0.45); b = vec3<f32>(0.25, 0.45, 0.40);
            c = vec3<f32>(1.0, 1.0, 1.0);    d = vec3<f32>(0.30, 0.50, 0.70); }
        case 3: { // sunset chrome
            a = vec3<f32>(0.55, 0.40, 0.35); b = vec3<f32>(0.45, 0.35, 0.30);
            c = vec3<f32>(1.0, 1.0, 0.5);    d = vec3<f32>(0.00, 0.10, 0.20); }
        case 4: { // toxic
            a = vec3<f32>(0.40, 0.60, 0.20); b = vec3<f32>(0.45, 0.45, 0.40);
            c = vec3<f32>(2.0, 1.0, 1.0);    d = vec3<f32>(0.50, 0.20, 0.25); }
        case 5: { // pastel
            a = vec3<f32>(0.80, 0.78, 0.82); b = vec3<f32>(0.20, 0.20, 0.20);
            c = vec3<f32>(1.0, 1.0, 1.0);    d = vec3<f32>(0.00, 0.33, 0.67); }
        case 6: { // jewel-tone
            a = vec3<f32>(0.35, 0.22, 0.40); b = vec3<f32>(0.35, 0.30, 0.40);
            c = vec3<f32>(1.0, 1.0, 1.0);    d = vec3<f32>(0.00, 0.60, 0.30); }
        case 7: { // holo
            a = vec3<f32>(0.60, 0.60, 0.70); b = vec3<f32>(0.40, 0.40, 0.35);
            c = vec3<f32>(1.0, 1.0, 1.0);    d = vec3<f32>(0.00, 0.10, 0.20); }
        default: {} // rainbow
    }
    return clamp(a + b * cos(TAU * (c * x + d)), vec3<f32>(0.0), vec3<f32>(1.0));
}

// ── Pattern families → (height, colour id) ──────────────────────────────────
// p is in pattern units (1 = one cell). tb is absolute time in body widths,
// used only for the per-cell "turn" (spin) term.

fn cell_spin(c: vec2<i32>, seed: f32, tb: f32) -> f32 {
    let h = hash2i(c, seed + 3.0);
    let dir = select(-1.0, 1.0, h > 0.5);
    return h * TAU + S.w_turn * S.spin_rate * tb * dir;
}

// a. FACETED GEMS — Worley F1/F2: bevel from F2-F1, star-cut facets and a
//    per-cell planar tilt; the facets and tilt spin per cell (turn).
fn fam_gems(p: vec2<f32>, seed: f32, tb: f32) -> vec2<f32> {
    let ip = cell_of(p);
    var f1 = 9.0; var f2 = 9.0;
    var best = vec2<i32>(0); var best_c = vec2<f32>(0.0);
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let c = ip + vec2<i32>(i, j);
            let o = vec2<f32>(c) + 0.15 + 0.7 * hash2v(c, seed);
            let d = length(p - o);
            if d < f1 { f2 = f1; f1 = d; best = c; best_c = o; }
            else if d < f2 { f2 = d; }
        }
    }
    let local = rot2(cell_spin(best, seed, tb)) * (p - best_c);
    let bevel = clamp((f2 - f1) * 2.2, 0.0, 1.0);
    let nf = 5.0 + floor(hash2i(best, seed + 9.0) * 4.0);
    let star = abs(cos(atan2(local.y, local.x) * nf * 0.5)) * length(local);
    let tilt = (hash2v(best, seed + 5.0) - 0.5) * 0.6;
    let h = bevel * 0.85 - star * 0.35 + dot(tilt, local);
    return vec2<f32>(h, hash2i(best, seed + 1.0));
}

// b. SNAKE SCALES — offset rows along t, overlapping domed scales with a
//    central ridge; the scale nearer the head overlaps the one behind it.
fn fam_scales(p: vec2<f32>, seed: f32, tb: f32) -> vec2<f32> {
    let q = vec2<f32>(p.x, p.y * 1.25);
    let row = i32(floor(q.y));
    var best_h = -1.0; var best_id = 0.0; var best_row = -100000;
    for (var dj = -1; dj <= 1; dj = dj + 1) {
        let r = row + dj;
        let off = select(0.0, 0.5, (r & 1) == 1);
        let col = i32(floor(q.x - off));
        for (var di = -1; di <= 1; di = di + 1) {
            let c = vec2<i32>(col + di, r);
            let centre = vec2<f32>(f32(c.x) + off + 0.5, f32(r) + 0.15);
            var lp = q - centre;
            lp = rot2(0.25 * sin(cell_spin(c, seed, tb))) * lp;
            // Teardrop: wider toward the tail (−y), rounded at the head.
            let e = vec2<f32>(lp.x * (1.0 + 0.35 * clamp(lp.y, 0.0, 1.0)), lp.y * 0.95);
            let d = length(e) / 0.78;
            if d < 1.0 && (r > best_row || (r == best_row && d < 1.0)) {
                let dome  = sqrt(max(1.0 - d * d, 0.0));
                let ridge = exp(-lp.x * lp.x * 60.0) * 0.18 * smoothstep(-0.6, 0.4, lp.y);
                best_h = dome * 0.8 + ridge;
                best_id = hash2i(c, seed + 1.0) * 0.25 + f32(r & 7) * 0.02;
                best_row = r;
            }
        }
    }
    return vec2<f32>(max(best_h, 0.0), best_id);
}

fn family_height(p: vec2<f32>, seed: f32, tb: f32) -> vec2<f32> {
    switch i32(S.family) {
        case 1:  { return fam_scales(p, seed, tb); }
        default: { return fam_gems(p, seed, tb); }
    }
}

// Height with seed morph: blends seed_a → seed_b across rows.
fn height_at(p: vec2<f32>, tb: f32, m: f32) -> vec2<f32> {
    if m <= 0.0 { return family_height(p, S.seed_a, tb); }
    if m >= 1.0 { return family_height(p, S.seed_b, tb); }
    let a = family_height(p, S.seed_a, tb);
    let b = family_height(p, S.seed_b, tb);
    return vec2<f32>(mix(a.x, b.x, m), select(a.y, b.y, m > 0.5));
}

// ── Fake environment: analytic 3-band sky, no cubemap ──────────────────────
fn sky(r: vec3<f32>, pal: i32, tb: f32) -> vec3<f32> {
    let y = r.y * 0.5 + 0.5;
    let horizon = palette(0.15 + tb * 0.01, pal);
    let zenith  = palette(0.55 + tb * 0.01, pal) * 1.2;
    let ground  = palette(0.85, pal) * 0.15;
    var c = mix(ground, horizon, smoothstep(0.25, 0.5, y));
    c = mix(c, zenith, smoothstep(0.5, 0.95, y));
    // Bright softbox streak — reads as studio chrome.
    c = c + vec3<f32>(1.0) * smoothstep(0.92, 0.99, 1.0 - abs(r.x - 0.35)) * smoothstep(0.4, 0.8, y);
    return c;
}

@fragment
fn fs_main(@builtin(position) frag: vec4<f32>) -> @location(0) vec4<f32> {
    let row   = floor(frag.y);
    let local = (row - S.head_row + S.len_px) % S.len_px;
    let t_row = S.t0 + local;                 // absolute row time
    let u     = frag.x / S.cross_px;          // [0,1) across the body
    let tb    = t_row / S.cross_px;           // time in body widths
    let pal   = i32(S.palette);

    // Morph factor for this row.
    let m = smoothstep(0.0, 1.0, clamp((local - S.morph_start) / S.morph_len, 0.0, 1.0));
    let mm = select(m, 1.0, S.seed_a == S.seed_b);

    // Pattern-space coordinate.
    let p  = vec2<f32>(u, tb) * S.scale;
    let px = S.scale / S.cross_px;            // one texel in pattern units

    // Height + central-difference normal (4 taps) + Laplacian cavity.
    let c0 = height_at(p, tb, mm);
    let hx1 = height_at(p + vec2<f32>(px, 0.0), tb, mm).x;
    let hx0 = height_at(p - vec2<f32>(px, 0.0), tb, mm).x;
    let hy1 = height_at(p + vec2<f32>(0.0, px), tb, mm).x;
    let hy0 = height_at(p - vec2<f32>(0.0, px), tb, mm).x;
    let k = S.depth * 0.6 / (2.0 * px);   // slope → normal tilt
    var n = normalize(vec3<f32>(-(hx1 - hx0) * k, -(hy1 - hy0) * k, 1.0));
    let lap = (hx1 + hx0 + hy1 + hy0 - 4.0 * c0.x);
    let ao = clamp(1.0 - max(lap, 0.0) * 18.0 * S.depth, 0.35, 1.0)
           * mix(0.55, 1.0, smoothstep(0.0, 0.35, c0.x));

    let v = vec3<f32>(0.0, 0.0, 1.0);
    let base = palette(c0.y + c0.x * 0.25, pal);

    // Two lights: key orbits slowly, fill fixed opposite.
    let la = S.light_angle;
    let l1 = normalize(vec3<f32>(cos(la) * 0.7, sin(la) * 0.7, 0.75));
    let l2 = normalize(vec3<f32>(-0.5, -0.6, 0.6));
    let diff = max(dot(n, l1), 0.0) * 0.85 + max(dot(n, l2), 0.0) * 0.3;
    let shin = mix(12.0, 160.0, S.gloss);
    let h1 = normalize(l1 + v);
    let h2 = normalize(l2 + v);
    let spec = pow(max(dot(n, h1), 0.0), shin) + 0.4 * pow(max(dot(n, h2), 0.0), shin);

    // Fake environment reflection.
    let r = reflect(-v, n);
    let env = sky(r, pal, tb);

    // Fresnel rim.
    let ndv = clamp(n.z, 0.0, 1.0);
    let fres = pow(1.0 - ndv, 3.0);

    // Thin-film iridescence (holographic shimmer).
    let thick = S.irid * (1.0 + S.irid_kick);
    let film = palette(ndv * (1.5 + 2.0 * thick) + tb * 0.07 + c0.y, 7);

    var col = base * (0.18 + diff) * ao;
    col = mix(col, env * mix(base, vec3<f32>(1.0), 0.5), 0.25 + 0.45 * S.gloss * (0.4 + 0.6 * fres));
    col = col + film * fres * thick * 0.9;
    col = mix(col, col * film * 1.6, thick * 0.25);
    col = col + vec3<f32>(spec) * S.gloss * 0.9;

    // Glints: sparse hashed sparkles where the surface faces the key light.
    let gp = vec2<f32>(u, tb) * vec2<f32>(S.cross_px, S.cross_px) / 3.0;
    let gc = cell_of(gp);
    let gh = hash2i(gc, S.seed_a + 77.0);
    let gdens = 0.04 * S.glints;
    if gh < gdens && spec > 0.15 {
        let tw = 0.5 + 0.5 * sin(tb * 40.0 + gh * 600.0);
        let gd = length(fract(gp) - 0.5);
        col = col + vec3<f32>(1.0) * smoothstep(0.5, 0.0, gd) * tw * 2.0;
    }

    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
