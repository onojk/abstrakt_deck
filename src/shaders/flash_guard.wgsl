// flash_guard.wgsl — Reduced Motion flash limiter (live path only).
//
// Two passes per frame, both full-screen triangles:
//   fs_state : 1×1 Rgba32Float. Measures the mean relative luminance of the
//              finished frame (768-tap grid) and slews the displayed target
//              luminance toward it at no more than `max_rate` per second.
//              Output: r = target (displayed) luminance, g = measured, a = 1.
//   fs_apply : writes the frame to the swapchain, uniformly scaled (when it
//              is brighter than the target) or lifted (when darker) so its
//              mean luminance equals the slew-limited target.
//
// With max_rate = 0.5/s a 10%-of-full-frame luminance change takes ≥ 0.2 s,
// so an opposing pair (one flash) takes ≥ 0.4 s → at most 2.5 flashes/s.

struct GuardUniforms {
    dt:       f32,   // offset  0: frame time, seconds
    reset:    f32,   // offset  4: 1.0 → snap target to measured (first frame)
    max_rate: f32,   // offset  8: max |Δ luminance| per second
    _pad:     f32,   // offset 12
};                   // 16 bytes — flat f32s only (see CLAUDE.md)

@group(0) @binding(0) var<uniform> u: GuardUniforms;
@group(0) @binding(1) var frame_tex: texture_2d<f32>;
@group(0) @binding(2) var state_tex: texture_2d<f32>;
@group(0) @binding(3) var samp:      sampler;

struct VertexOutput {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VertexOutput {
    let x = f32((vi << 1u) & 2u);
    let y = f32(vi & 2u);
    var out: VertexOutput;
    out.clip_position = vec4<f32>(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);
    out.uv = vec2<f32>(x, 1.0 - y);
    return out;
}

fn luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

const GRID_X: i32 = 32;
const GRID_Y: i32 = 24;

@fragment
fn fs_state(in: VertexOutput) -> @location(0) vec4<f32> {
    var sum = 0.0;
    for (var j = 0; j < GRID_Y; j = j + 1) {
        for (var i = 0; i < GRID_X; i = i + 1) {
            let uv = (vec2<f32>(f32(i), f32(j)) + vec2<f32>(0.5)) / vec2<f32>(f32(GRID_X), f32(GRID_Y));
            sum = sum + luma(textureSampleLevel(frame_tex, samp, uv, 0.0).rgb);
        }
    }
    let measured = sum / f32(GRID_X * GRID_Y);

    let prev = textureLoad(state_tex, vec2<i32>(0, 0), 0);
    var target_l = measured;
    if (u.reset < 0.5 && prev.a > 0.5) {
        let max_step = u.max_rate * u.dt;
        target_l = prev.r + clamp(measured - prev.r, -max_step, max_step);
    }
    return vec4<f32>(target_l, measured, 0.0, 1.0);
}

@fragment
fn fs_apply(in: VertexOutput) -> @location(0) vec4<f32> {
    let c = textureSample(frame_tex, samp, in.uv).rgb;
    let s = textureLoad(state_tex, vec2<i32>(0, 0), 0);
    let target_l = s.r;
    let measured = s.g;
    // Both branches are linear in c, so the frame's mean luminance lands
    // exactly on target_l with no clamping:
    //   darken: c * t/m              → mean = t
    //   lighten: mix(c, 1, k), k = (t-m)/(1-m) → mean = m + k(1-m) = t
    var out = c;
    if (measured > target_l) {
        out = c * (target_l / max(measured, 1e-4));
    } else if (measured < target_l) {
        let k = (target_l - measured) / max(1.0 - measured, 1e-4);
        out = mix(c, vec3<f32>(1.0), clamp(k, 0.0, 1.0));
    }
    return vec4<f32>(out, 1.0);
}
