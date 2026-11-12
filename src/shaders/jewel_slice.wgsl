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
    // Contrast halos (adaptive underlay)
    halo_on: f32, halo_size_min: f32, halo_k: f32, halo_w_min: f32,
    halo_w_max: f32, halo_keyline: f32, halo_soft: f32, halo_kick: f32,
    halo_light_r: f32, halo_light_g: f32, halo_light_b: f32, _h0: f32,
    halo_dark_r: f32, halo_dark_g: f32, halo_dark_b: f32, _h1: f32,
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

// ── Pattern families ────────────────────────────────────────────────────────
// p is in pattern units (1 ≈ one cell). tb is absolute time in body widths.
//
// Each family returns a Pat:
//   h      height of the top surface at p
//   id     colour id of the top shape (palette coordinate)
//   d      signed distance to the top shape's boundary (<0 inside, pattern units)
//   size   top shape size (inradius / radius, pattern units); 0 = background
//   nd     distance OUTSIDE the nearest halo-casting shape that sits ABOVE the
//          top shape (≥0; 1e3 = none). Halos are underlays: they paint just
//          outside the casting shape, over whatever is below it.
//   nid    that shape's colour id
//   nsize  that shape's size
struct Pat {
    h: f32, id: f32, d: f32, size: f32,
    nd: f32, nid: f32, nsize: f32,
};

const NONE: f32 = 1000.0;
const BG_ID: f32 = -1.0;

fn pat_bg() -> Pat { return Pat(0.0, BG_ID, NONE, 0.0, NONE, 0.0, 0.0); }

fn cell_spin(c: vec2<i32>, seed: f32, tb: f32) -> f32 {
    let h = hash2i(c, seed + 3.0);
    let dir = select(-1.0, 1.0, h > 0.5);
    return h * TAU + S.w_turn * S.spin_rate * tb * dir;
}
fn zorder(c: vec2<i32>, seed: f32) -> f32 { return hash2i(c, seed + 11.0); }

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// a. FACETED GEMS — Worley F1/F2: bevel from F2-F1, star-cut facets and a
//    per-cell planar tilt; facets and tilt spin per cell (turn).
fn voronoi_site(c: vec2<i32>, seed: f32) -> vec2<f32> {
    return vec2<f32>(c) + 0.15 + 0.7 * hash2v(c, seed);
}
fn fam_gems(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let ip = cell_of(p);
    var f1 = 9.0; var f2 = 9.0;
    var a = vec2<i32>(0); var b = vec2<i32>(0);
    var ac = vec2<f32>(0.0); var bc = vec2<f32>(0.0);
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let c = ip + vec2<i32>(i, j);
            let o = voronoi_site(c, seed);
            let d = length(p - o);
            if d < f1 { f2 = f1; b = a; bc = ac; f1 = d; a = c; ac = o; }
            else if d < f2 { f2 = d; b = c; bc = o; }
        }
    }
    // Exact distance to the A|B bisector.
    let ab = bc - ac;
    let e = max(dot(p - 0.5 * (ac + bc), -normalize(ab)), 0.0);
    // Inradius of A ≈ half the distance to its nearest neighbouring site.
    var near = 9.0;
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            if i == 0 && j == 0 { continue; }
            near = min(near, length(voronoi_site(a + vec2<i32>(i, j), seed) - ac));
        }
    }
    let local = rot2(cell_spin(a, seed, tb)) * (p - ac);
    let bevel = clamp((f2 - f1) * 2.2, 0.0, 1.0);
    let nf = 5.0 + floor(hash2i(a, seed + 9.0) * 4.0);
    let star = abs(cos(atan2(local.y, local.x) * nf * 0.5)) * length(local);
    let tilt = rot2(cell_spin(a, seed, tb)) * ((hash2v(a, seed + 5.0) - 0.5) * 0.6);
    let h = bevel * 0.85 - star * 0.35 + dot(tilt, p - ac);
    var r = Pat(h, hash2i(a, seed + 1.0), -e, 0.5 * near, NONE, 0.0, 0.0);
    if zorder(b, seed) > zorder(a, seed) {
        r.nd = e; r.nid = hash2i(b, seed + 1.0); r.nsize = 0.5 * near;
    }
    return r;
}

// b. SNAKE SCALES — offset rows along t, overlapping teardrop domes with a
//    central ridge; the scale nearer the head overlaps the one behind it.
fn fam_scales(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let q = vec2<f32>(p.x, p.y * 1.25);
    let row = i32(floor(q.y));
    var r = pat_bg();
    var best_row = -100000;
    var cand_nd = NONE; var cand_id = 0.0; var cand_row = -100000;
    for (var dj = -1; dj <= 2; dj = dj + 1) {
        let rr = row + dj;
        let off = select(0.0, 0.5, (rr & 1) == 1);
        let col = i32(floor(q.x - off));
        for (var di = -1; di <= 1; di = di + 1) {
            let c = vec2<i32>(col + di, rr);
            let centre = vec2<f32>(f32(c.x) + off + 0.5, f32(rr) + 0.15);
            let lp = rot2(0.25 * sin(cell_spin(c, seed, tb))) * (q - centre);
            let e = vec2<f32>(lp.x * (1.0 + 0.35 * clamp(lp.y, 0.0, 1.0)), lp.y * 0.95);
            let rad = 0.78;
            let sd = length(e) - rad;          // signed distance (approx)
            let id = hash2i(c, seed + 1.0) * 0.25 + f32(rr & 7) * 0.02;
            if sd < 0.0 && rr > best_row {
                let d = length(e) / rad;
                let dome  = sqrt(max(1.0 - d * d, 0.0));
                let ridge = exp(-lp.x * lp.x * 60.0) * 0.18 * smoothstep(-0.6, 0.4, lp.y);
                r.h = dome * 0.8 + ridge;
                r.id = id; r.d = sd; r.size = rad * 0.8;
                best_row = rr;
            } else if sd >= 0.0 && sd < cand_nd {
                cand_nd = sd; cand_id = id; cand_row = rr;
            }
        }
    }
    // Only a scale lying ABOVE (nearer the head than) the top one casts.
    if cand_row > best_row {
        r.nd = cand_nd; r.nid = cand_id; r.nsize = 0.78 * 0.8;
    }
    return r;
}

// c. GLOSSY CANDY BLOBS — smooth-min union of drifting metaballs.
fn fam_candy(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let ip = cell_of(p);
    var du = 9.0;
    var nearest = 9.0; var nid = 0.0; var nrad = 0.3;
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let c = ip + vec2<i32>(i, j);
            let hv = hash2v(c, seed);
            let ph = hv * TAU + vec2<f32>(tb * 0.9, tb * 0.7);
            let o = vec2<f32>(c) + 0.5 + 0.3 * vec2<f32>(sin(ph.x), cos(ph.y));
            let rad = 0.18 + 0.22 * hash2i(c, seed + 2.0);
            let sd = length(p - o) - rad;
            du = smin(du, sd, 0.22);
            if sd < nearest { nearest = sd; nid = hash2i(c, seed + 1.0); nrad = rad; }
        }
    }
    if du >= 0.0 {
        var r = pat_bg();
        r.nd = du; r.nid = nid; r.nsize = nrad;
        return r;
    }
    let dome = sqrt(clamp(-du / 0.32, 0.0, 1.0));
    return Pat(dome, nid, du, nrad, NONE, 0.0, 0.0);
}

// d. CHROME RIBBONS — fbm domain-warped sine bands, sharp highs.
fn fam_ribbons(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let w = vec2<f32>(fbm(p * 0.35 + vec2<f32>(0.0, tb * 0.05), seed),
                      fbm(p * 0.35 + vec2<f32>(4.1, 1.7), seed + 5.0)) - 0.5;
    let q = p + w * (1.2 + 3.0 * S.warp);
    let s = q.x * 0.9 + 0.35 * sin(q.y * 0.6 + seed * 0.01);
    let band = i32(floor(s));
    let f = fract(s) - 0.5;
    let half = 0.36;
    let sd = (abs(f) - half) / 0.9;            // back to pattern units (approx)
    let id = hash2i(vec2<i32>(band, 0), seed + 1.0);
    if sd >= 0.0 {
        var r = pat_bg();
        r.nd = sd; r.nid = id; r.nsize = half / 0.9;
        return r;
    }
    let x = abs(f) / half;
    let h = pow(max(1.0 - x * x, 0.0), 0.35) * (0.8 + 0.2 * sin(q.y * 2.0 + f32(band)));
    return Pat(h, id, sd, half / 0.9, NONE, 0.0, 0.0);
}

// e. PASTEL PRIMITIVES — 2D SDF circle / rounded box / triangle / ring given
//    height by a smooth profile, stacked with z-order by hash.
fn sd_box(p: vec2<f32>, b: vec2<f32>, rr: f32) -> f32 {
    let q = abs(p) - b + rr;
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - rr;
}
fn sd_tri(p0: vec2<f32>, r: f32) -> f32 {
    let k = sqrt(3.0);
    var p = p0;
    p.x = abs(p.x) - r;
    p.y = p.y + r / k;
    if p.x + k * p.y > 0.0 { p = vec2<f32>(p.x - k * p.y, -k * p.x - p.y) / 2.0; }
    p.x = p.x - clamp(p.x, -2.0 * r, 0.0);
    return -length(p) * sign(p.y);
}
fn prim_sd(kind: i32, lp: vec2<f32>, rad: f32) -> f32 {
    switch kind {
        case 1:  { return sd_box(lp, vec2<f32>(rad, rad * 0.75), rad * 0.3); }
        case 2:  { return sd_tri(lp, rad) - rad * 0.08; }
        case 3:  { return abs(length(lp) - rad * 0.7) - rad * 0.28; }
        default: { return length(lp) - rad; }
    }
}
fn fam_pastel(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let ip = cell_of(p);
    var r = pat_bg();
    var top_z = -1.0;
    var best_nd = NONE; var best_nid = 0.0; var best_ns = 0.0; var best_nz = -1.0;
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let c = ip + vec2<i32>(i, j);
            let o = vec2<f32>(c) + 0.2 + 0.6 * hash2v(c, seed);
            let kind = i32(hash2i(c, seed + 4.0) * 4.0);
            let rad = 0.22 + 0.32 * hash2i(c, seed + 2.0);
            let lp = rot2(cell_spin(c, seed, tb)) * (p - o);
            let sd = prim_sd(kind, lp, rad);
            let z = zorder(c, seed);
            let id = hash2i(c, seed + 1.0);
            if sd < 0.0 && z > top_z {
                top_z = z;
                let prof = smoothstep(0.0, 0.12 + rad * 0.35, -sd);
                r = Pat(prof * 0.6 + z * 0.35, id, sd, rad, NONE, 0.0, 0.0);
            } else if sd >= 0.0 {
                // Candidate halo caster; resolved against top_z after the loop.
                if sd < best_nd || (z > best_nz && sd < best_nd + 0.05) {
                    best_nd = sd; best_nid = id; best_ns = rad; best_nz = z;
                }
            }
        }
    }
    if best_nz > top_z {
        r.nd = best_nd; r.nid = best_nid; r.nsize = best_ns;
    }
    return r;
}

// f. WOVEN / BRAID — two diagonal strand sets with alternating over/under.
fn fam_woven(p0: vec2<f32>, seed: f32, tb: f32) -> Pat {
    let p = p0 * 0.8;
    let s1 = p.x + p.y;
    let s2 = p.x - p.y;
    let k1 = floor(s1); let k2 = floor(s2);
    let a1 = abs(fract(s1) - 0.5);
    let a2 = abs(fract(s2) - 0.5);
    let half = 0.34;
    // Over/under wave: strand 1 rises where strand 2 dips, alternating.
    let par = select(-1.0, 1.0, (i32(k1) + i32(k2)) % 2 == 0);
    let w1 = 0.5 + 0.5 * par * cos(PI * fract(s2) * 2.0 - PI);
    let w2 = 1.0 - w1;
    let t1 = sqrt(max(1.0 - (a1 / half) * (a1 / half), 0.0));
    let t2 = sqrt(max(1.0 - (a2 / half) * (a2 / half), 0.0));
    let h1 = select(-1.0, t1 * (0.55 + 0.45 * w1), a1 < half);
    let h2 = select(-1.0, t2 * (0.55 + 0.45 * w2), a2 < half);
    let sc = 0.8 * 1.41421;                     // strand coords → pattern units
    let id1 = hash2i(vec2<i32>(i32(k1), 1), seed + 1.0);
    let id2 = hash2i(vec2<i32>(i32(k2), 2), seed + 1.0);
    if h1 < 0.0 && h2 < 0.0 {
        var r = pat_bg();
        let d1 = (a1 - half) / sc; let d2 = (a2 - half) / sc;
        if d1 < d2 { r.nd = d1; r.nid = id1; } else { r.nd = d2; r.nid = id2; }
        r.nsize = half / sc;
        return r;
    }
    if h1 >= h2 {
        var r = Pat(h1, id1, (a1 - half) / sc, half / sc, NONE, 0.0, 0.0);
        if w2 > w1 && a2 >= half { r.nd = (a2 - half) / sc; r.nid = id2; r.nsize = half / sc; }
        return r;
    }
    var r = Pat(h2, id2, (a2 - half) / sc, half / sc, NONE, 0.0, 0.0);
    if w1 > w2 && a1 >= half { r.nd = (a1 - half) / sc; r.nid = id1; r.nsize = half / sc; }
    return r;
}

fn family_pat(p: vec2<f32>, seed: f32, tb: f32) -> Pat {
    switch i32(S.family) {
        case 1:  { return fam_scales(p, seed, tb); }
        case 2:  { return fam_candy(p, seed, tb); }
        case 3:  { return fam_ribbons(p, seed, tb); }
        case 4:  { return fam_pastel(p, seed, tb); }
        case 5:  { return fam_woven(p, seed, tb); }
        default: { return fam_gems(p, seed, tb); }
    }
}

// Seed morph: heights blend seed_a → seed_b across rows; shape identity
// (id/d/halo) switches at the midpoint. Done in fs_main's tap loop so
// family_pat has exactly ONE call site (keeps driver compile time sane).

// ── Motion: domain warp (stage 5) ───────────────────────────────────────────
struct Warped {
    p: vec2<f32>,
    // Cylinder (roll) normal frame: n_cyl = (sin θ, 0, cos θ).
    sin_th: f32,
    cos_th: f32,
};
// Every term is a function of absolute body-time tb (never ring index), so
// the warp field is continuous across the ring wrap and the swirl reads as
// one fluid body carried forward slice by slice.

fn vnoise2(p: vec2<f32>, seed: f32) -> f32 {
    return 0.65 * vnoise(p, seed) + 0.35 * vnoise(p * 2.07 + 3.1, seed + 9.0);
}
// Divergence-free curl of a noise potential: swirls without smearing.
fn curl(p: vec2<f32>, seed: f32) -> vec2<f32> {
    let e = 0.08;
    let dx = vnoise2(p + vec2<f32>(e, 0.0), seed) - vnoise2(p - vec2<f32>(e, 0.0), seed);
    let dy = vnoise2(p + vec2<f32>(0.0, e), seed) - vnoise2(p - vec2<f32>(0.0, e), seed);
    return vec2<f32>(dy, -dx) / (2.0 * e);
}

fn warp_domain(u: f32, tb: f32) -> Warped {
    let seed = S.seed_a;

    // 1. SLITHER — lateral spine wiggle (+ a slow fbm drift).
    var uu = u + S.w_slither * (
        S.slither_amp * sin(TAU * (tb * S.slither_freq - S.slither_phase))
      + S.slither_amp * 0.6 * (vnoise2(vec2<f32>(tb * 0.35, 7.0), seed) - 0.5));

    // 2. ROLL — each band is the front face of a turning cylinder:
    //    θ = asin(2u-1), pattern at θ/π + roll_phase (alternating direction
    //    per band = counter-rotating gears). asin gives edge foreshortening.
    let bands = max(S.roll_bands, 1.0);
    let bi = floor(uu * bands);
    let ub = uu * bands - bi;
    let x  = clamp(ub * 2.0 - 1.0, -0.999, 0.999);
    let th = asin(x);
    let dir = select(-1.0, 1.0, (i32(bi) & 1) == 0) * S.roll_dir_flip;
    let u_roll = th / PI + 0.5 + dir * S.roll_phase;
    let ux = mix(ub, u_roll, S.w_roll);
    var p = vec2<f32>((bi * 3.17 * S.w_roll + bi + ux) / bands, tb) * S.scale;
    let sin_th = sin(th) * S.w_roll;
    let cos_th = sqrt(max(1.0 - sin_th * sin_th, 0.0));

    // 3. CHURN — iterated curl-noise advection + drifting vortices.
    let kc = S.w_churn * S.churn;
    if kc > 0.0 {
        for (var i = 0; i < 2; i = i + 1) {
            let q = p * 0.35 + vec2<f32>(0.0, tb * 0.15) + f32(i) * 11.3;
            p = p + kc * 0.55 * curl(q, seed + f32(i) * 31.0);
        }
        // Vortices: centres on a 2.5-body-width lattice along t (3 nearest).
        let P = 2.5;
        let k0 = floor(tb / P);
        for (var j = -1; j <= 1; j = j + 1) {
            let kk = vec2<i32>(i32(k0) + j, 3);
            let hv = hash2v(kk, seed + 41.0);
            let c = vec2<f32>(0.2 + 0.6 * hv.x, (k0 + f32(j) + hv.y) * P) * S.scale;
            let dv = p - c;
            let sig = 0.35 * S.scale;
            let strength = kc * (1.6 + 2.0 * S.vortex_kick)
                         * sin(tb * (0.6 + hv.y) + hv.x * TAU);
            let ang = strength * exp(-dot(dv, dv) / (sig * sig));
            p = c + rot2(ang) * dv;
        }
    }
    return Warped(p, sin_th, cos_th);
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

// One luminance definition: BT.709, as in frame_metric.rs / echo_composite.rs.
fn luminance(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }

fn base_colour(id: f32, h: f32, pal: i32) -> vec3<f32> {
    if id < 0.0 { return palette(0.62, pal) * 0.12; }  // background: dark variant
    return palette(id + h * 0.25, pal);
}

fn halo_tone(id: f32, pal: i32) -> vec3<f32> {
    // Unshaded base colour of the casting shape → stable, no glint flicker.
    let l = luminance(palette(id + 0.2, pal));
    let tint = palette(id, pal);
    let dark  = mix(vec3<f32>(S.halo_dark_r,  S.halo_dark_g,  S.halo_dark_b),  tint * 0.25, 0.15);
    let light = mix(vec3<f32>(S.halo_light_r, S.halo_light_g, S.halo_light_b), tint, 0.10);
    return select(light, dark, l > 0.5);
}

// Halo width in px for a shape of `size` pattern units.
fn halo_width_px(size: f32, px: f32) -> f32 {
    return clamp(S.halo_k * size / px, S.halo_w_min, S.halo_w_max) * (1.0 + 0.2 * S.halo_kick);
}
fn size_fade(size: f32) -> f32 {
    return smoothstep(S.halo_size_min, S.halo_size_min * 1.5, size);
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

    // Warped pattern-space coordinate; finite differences are taken in
    // (u, t) so the bump normal follows the warp.
    let du = 1.0 / S.cross_px;
    let W  = warp_domain(u, tb);
    let Wx1 = warp_domain(u + du, tb);
    let Wx0 = warp_domain(u - du, tb);
    let Wy1 = warp_domain(u, tb + du);
    let Wy0 = warp_domain(u, tb - du);

    // 5 taps (centre, +x, -x, +t, -t) × up to 2 seeds, one family_pat site.
    let morphing = mm > 0.0 && mm < 1.0;
    let nseeds = select(1, 2, morphing);
    var c0 = pat_bg();
    var hs = array<f32, 5>(0.0, 0.0, 0.0, 0.0, 0.0);
    for (var tap = 0; tap < 5; tap = tap + 1) {
        var tp = W.p; var tt = tb;
        if tap == 1 { tp = Wx1.p; }
        else if tap == 2 { tp = Wx0.p; }
        else if tap == 3 { tp = Wy1.p; tt = tb + du; }
        else if tap == 4 { tp = Wy0.p; tt = tb - du; }
        var ha = 0.0;
        var pa = pat_bg();
        for (var si = 0; si < nseeds; si = si + 1) {
            var seed = select(S.seed_b, S.seed_a, si == 0 && mm < 1.0);
            let r = family_pat(tp, seed, tt);
            if si == 0 { ha = r.h; pa = r; }
            else {
                ha = mix(ha, r.h, mm);
                if mm >= 0.5 { pa = r; }
            }
        }
        // Fold-over: the surface appears to curl back over itself (kneading).
        ha = ha + S.w_churn * S.churn * 0.12 * sin(ha * PI * 3.0 + tt * 2.0);
        hs[tap] = ha;
        if tap == 0 { c0 = pa; c0.h = ha; }
    }
    let hx1 = hs[1]; let hx0 = hs[2]; let hy1 = hs[3]; let hy0 = hs[4];
    let px = S.scale / S.cross_px;            // one texel in (unwarped) pattern units

    // Halo distances in px, corrected for the warp's local stretch: the
    // warp Jacobian's column lengths (from the taps above) give pattern
    // units per texel, so halos keep a constant on-screen thickness at
    // roll edges and inside churn swirls. Analytic — no fwidth spikes.
    let sx = length(Wx1.p - Wx0.p) / (2.0 * px);
    let sy = length(Wy1.p - Wy0.p) / (2.0 * px);
    let ppx = px * clamp(sqrt(sx * sy), 0.2, 8.0);  // pattern units per texel
    let nd_px = c0.nd / ppx;
    let d_px  = c0.d / ppx;

    let k = S.depth * 0.6 / (2.0 * px);      // slope → normal tilt
    let nb = normalize(vec3<f32>(-(hx1 - hx0) * k, -(hy1 - hy0) * k, 1.0));
    // Bump normal expressed in the roll cylinder's frame.
    let tangent = vec3<f32>(W.cos_th, 0.0, -W.sin_th);
    let ncyl    = vec3<f32>(W.sin_th, 0.0, W.cos_th);
    var n = normalize(tangent * nb.x + vec3<f32>(0.0, 1.0, 0.0) * nb.y + ncyl * nb.z);
    let lap = (hx1 + hx0 + hy1 + hy0 - 4.0 * c0.h);
    let ao = clamp(1.0 - max(lap, 0.0) * 18.0 * S.depth, 0.35, 1.0)
           * mix(0.55, 1.0, smoothstep(0.0, 0.35, c0.h));

    let v = vec3<f32>(0.0, 0.0, 1.0);
    let base = base_colour(c0.id, c0.h, pal);
    let is_candy = select(0.0, 1.0, i32(S.family) == 2);

    // Two lights: key orbits slowly, fill fixed opposite.
    let la = S.light_angle;
    let l1 = normalize(vec3<f32>(cos(la) * 0.7, sin(la) * 0.7, 0.75));
    let l2 = normalize(vec3<f32>(-0.5, -0.6, 0.6));
    // Wrap lighting for candy/gummy (subsurface-ish).
    let wrap = 0.5 * is_candy;
    let diff = max((dot(n, l1) + wrap) / (1.0 + wrap), 0.0) * 0.85
             + max((dot(n, l2) + wrap) / (1.0 + wrap), 0.0) * 0.3;
    let shin = mix(12.0, 160.0, S.gloss);
    let h1 = normalize(l1 + v);
    let h2 = normalize(l2 + v);
    let spec = pow(max(dot(n, h1), 0.0), shin) + 0.4 * pow(max(dot(n, h2), 0.0), shin);

    let r = reflect(-v, n);
    let env = sky(r, pal, tb);
    let ndv = clamp(n.z, 0.0, 1.0);
    let fres = pow(1.0 - ndv, 3.0);
    let thick = S.irid * (1.0 + S.irid_kick);
    let film = palette(ndv * (1.5 + 2.0 * thick) + tb * 0.07 + c0.id, 7);

    let is_bg = c0.id < 0.0;
    var col = base * (0.18 + diff) * ao;
    if !is_bg {
        col = mix(col, env * mix(base, vec3<f32>(1.0), 0.5), 0.25 + 0.45 * S.gloss * (0.4 + 0.6 * fres));
        col = col + film * fres * thick * 0.9;
        col = mix(col, col * film * 1.6, thick * 0.25);
        col = col + vec3<f32>(spec) * S.gloss * 0.9;
        // Candy inner glow.
        col = col + base * is_candy * 0.35 * smoothstep(0.2, 1.0, c0.h);
    }

    // Glints: sparse hashed sparkles where the surface faces the key light.
    let gp = vec2<f32>(u, tb) * S.cross_px / 3.0;
    let gh = hash2i(cell_of(gp), S.seed_a + 77.0);
    if !is_bg && gh < 0.04 * S.glints && spec > 0.15 {
        let tw = 0.5 + 0.5 * sin(tb * 40.0 + gh * 600.0);
        col = col + vec3<f32>(1.0) * smoothstep(0.5, 0.0, length(fract(gp) - 0.5)) * tw * 2.0;
    }

    // ── Contrast halos (underlay outside the casting shape + keyline) ──────
    if S.halo_on > 0.5 {
        let soft = max(S.halo_soft, 0.25);
        // Halo cast by an upper neighbour onto this pixel.
        if c0.nsize > 0.0 {
            let w = halo_width_px(c0.nsize, px);
            let a = size_fade(c0.nsize)
                  * (1.0 - smoothstep(w - soft, w + soft, nd_px))
                  * smoothstep(-soft, soft, nd_px);
            let flat = 0.88 + 0.12 * max(dot(n, l1), 0.0);   // barely bevelled
            col = mix(col, halo_tone(c0.nid, pal) * flat, a);
        }
        // Inner keyline on the top shape.
        if S.halo_keyline > 0.5 && c0.size > 0.0 && !is_bg {
            let w = halo_width_px(c0.size, px) * 0.25;
            let a = size_fade(c0.size)
                  * smoothstep(-w - soft, -w + soft, d_px)
                  * (1.0 - smoothstep(-soft, soft, d_px));
            col = mix(col, halo_tone(c0.id, pal), a * 0.9);
        }
    }

    // Roll: contact-shadow groove where neighbouring cylinders meet.
    if S.w_roll > 0.0 && S.roll_bands > 1.5 {
        col = col * mix(1.0, smoothstep(0.0, 0.45, W.cos_th), S.w_roll);
    }

    // Body taper: envelope across u; outside reads as darker background.
    if S.taper > 0.0 {
        let e = smoothstep(0.0, S.taper * 0.5, u) * smoothstep(0.0, S.taper * 0.5, 1.0 - u);
        col = mix(base_colour(BG_ID, 0.0, pal), col, e);
    }

    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
