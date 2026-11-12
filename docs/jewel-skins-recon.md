# Jewel Skins — Stage 0 recon

Read-only survey of the skin path, done before any code change. Line numbers
refer to `main` at `b3c5413`.

## 1. How a frame reaches the screen

```
 painter pass ──► painter FBO (Rgba8Unorm, 4096×256 | HD 8192×512)
   (one fullscreen tri; pipeline chosen by params.painter_kind)
        │  + ribbons composite / palette pass (LoadOp::Load on the same FBO)
        ▼
 shape pass   shape.wgsl samples painter_tex at
              (fract(uv.x*0.25 + painter_scroll_phase), uv.y)   ← wraps it round the mesh
        ▼
 kaleido pass kaleido.wgsl folds the *shape render* into fold_count wedges
              (theta % wedge, mirrored) and samples shape_tex
        ▼
 frame / overlays / egui → swapchain (and → recorder / export readback)
```

So the "slice" a kaleidoscope wedge shows is a wedge of the shape render, and
the shape in turn shows a 0.25-wide horizontal window of the painter strip
that slides as the shape rotates. The painter strip is the only thing a skin
feeds. **Nothing downstream of the painter FBO needs to change for jewel
skins** — fold math, shape UVs and the grid export are all untouched.

## 2. Image skins today

| Piece | Where |
|---|---|
| `PainterKind::Skin` (one of 7 painters) | `main.rs:249` |
| Decode + validate image | `decode_and_validate_skin` `main.rs:1433` |
| Crop to a 16:1 strip, Lanczos resize to painter dims | `crop_skin_image` `main.rs:1775` |
| GPU state: `skin_tex`, `skin_view`, `skin_bgl`, `skin_bind_group`, `skin_sampler` (Repeat u / Clamp v, linear, mipmapped) | `GpuState` `main.rs:2121`, created `main.rs:3274` |
| (Re)upload: `load_skin` (new texture + mips + bind group), `upload_skin_bytes` (crop slider) | `main.rs:8264`, `main.rs:8324` |
| Painter pipeline: `painter_skin.wgsl` — straight `textureSample(skin_tex, in.uv)` → applied-harmony recolor | `main.rs:3343` |
| Draw sites (all identical `if painter_kind == Skin { set skin pipeline + skin_bind_group + harmony }`) | live `main.rs:4928`, grid export `main.rs:6807`, single export `main.rs:7318` |
| UI: File → Open Skin…, Skin section (thumbnail, crop slider, HD toggle, Generate Qbist Skin), Painter combo | `menu_bar.rs:409`, `menu_bar.rs:2728`, `menu_bar.rs:775` |
| Persistence: `Preset` (serde, `#[serde(default)]` per field) stores `hd_skin_enabled`; the skin image itself is **not** persisted | `main.rs:770`, `save_preset` `main.rs:1836` |

The skin painter's UV is the plain fullscreen-triangle uv (u along the 16:1
long axis, v across it); there is no scroll in the skin painter itself — the
scroll happens later in `shape.wgsl` via `painter_scroll_phase`.

`skin_bgl` (texture + filtering sampler) is also reused by the ribbon
composite and a few export bind groups — it is a generic "one texture + one
sampler" layout, which is exactly what a ring texture needs.

## 3. Multi-panel grid

The N-panel grid export (`render_export_frame`, `main.rs:6555`) loops panels,
re-running the painter pass per panel into the same `painter_view` with that
panel's `p_params`. All panels share the single `skin_bind_group`. A jewel
stream can be shared the same way (one ring, every Skin panel samples it);
per-panel rings would be a later option, not needed for parity.

## 4. Where a procedural texture swaps in

The cleanest seam is **the bind group + pipeline selected at the three Skin
draw sites**. Everything a skin contributes flows through
`(pipeline, group0 = skin_bind_group, group1 = applied_harmony)`.

Plan:

1. `SkinSource { Image, Jewel }` on `GpuState`. `Image` keeps the exact
   current pipeline/bind group (byte-identical output — the image pipeline
   and shader are not edited).
2. `Jewel` owns a ring texture `R` (Rgba8Unorm, `RENDER_ATTACHMENT |
   TEXTURE_BINDING`), a `skin_bgl`-compatible bind group over it with a
   Repeat/Repeat sampler, and a tiny uniform for the scroll offset.
3. A helper `GpuState::bind_skin_painter(&mut pass)` replaces the three
   duplicated `set_pipeline/set_bind_group` blocks. It picks either the
   existing skin pipeline or a `painter_jewel.wgsl` pipeline that is the skin
   shader plus `uv.x' = fract(uv.x + head/L)` (same harmony recolor).
4. A separate slice-writer pass (before the painter pass) renders only the
   new strip of `R` with a scissor rect.

Smallest interface change: one enum, one helper replacing three copy-pasted
blocks, one extra (tiny) bind group on the jewel pipeline. No changes to
`shape.wgsl`, `kaleido.wgsl`, the grid loop, or the recorder.

## 5. Axis mapping (deviation from the brief, deliberate)

The brief describes the ring as `W × H` with time running down **rows**
(`v`). The painter strip, however, is 16:1 and its **long axis is u** — that
is the axis that wraps around the shape and already scrolls with rotation.
For the snake to travel along the body, ring *time* must land on painter *u*.

So the ring is stored as **`W_cross × L_time`** (cross-body × time), and the
jewel painter shader samples `R` at `(cross = painter.v, time = fract(painter.u + head/L))`.
In ring-texture terms "a slice of N rows at head h" is a strip of N *rows*
of `R`, exactly as specified; only the final blit transposes it onto the
painter. Defaults:

* `W_cross` = painter height (256, HD 512) → 1:1 texels, no minification.
* `L_time` = painter width (4096, HD 8192) → 1:1 along the body.
* VRAM: 4 MiB (SD) / 16 MiB (HD), one ring per stream. Configurable as
  ½× / 1× / 2× length ("ring memory").

## 6. Timing hooks

* Live: `render()` has wall `dt`; bands in `bands_smoothed`, beat envelope in
  `shader_beat_decay`, tempo/PLL phase via `phase_lock_signal()`
  (`main.rs:4865`).
* Export: `render_export_frame` steps everything with `dt = 1/fps`
  (`main.rs:6529`). The ring must advance from that dt so exports are
  deterministic per output frame.
* Recording (F12, `main.rs:9144`) reads back the swapchain path, so it
  captures whatever the painter shows — no special handling needed.

## 7. Risks noted

* Uniform layout: follow CLAUDE.md (flat `f32`s, `array<vec4<f32>,N>` only).
  New uniform structs need a real `cargo run` to validate.
* DX12: render-pass + scissor only; no storage textures, no compute.
* MSRV: no new crates needed.
* Fresh ring is black until it wraps — fill the whole ring once on
  creation/reset (one-time O(W·L)).

## 8. Addendum folded in — motion + the "all depth is illusion" rule

* **Rule:** every 3D effect is UV distortion + shading on the 2D slice. No
  meshes, depth buffer, raymarching or 3D textures. The jewel slice shader is
  a pure function `colour = f(u_cross, t_abs, params)`.
* **Motion modes:** `Slither | Roll | Churn | All`, default `All` (the
  "Churn" preset: 2 counter-rotating roll bands + per-cell turn + curl churn,
  snake-scale or faceted-gem family, holo / jewel-tone palette).
  * Roll: `theta = asin(2u-1)` per band, pattern sampled at
    `theta/π + roll_phase(t)`; shading normal = cylinder normal ⊕ bump normal.
  * Turn: per-cell rotation by `hash·τ ± spin·t` in the Voronoi/scale/blob
    families, tilt vector spun too; light rig orbits the opposite way.
  * Churn: 2–3 iterations of curl-noise warp + 1–3 drifting vortices +
    fold-over `h' = h + fold·sin(hπn + t)`.
* **Seam safety:** every time-varying term is a function of *absolute*
  time `t_abs` (rows since stream start, carried in a uniform as
  `base_row + local_row`), never of ring index — so the wrap point is
  invisible and history stays continuous. `t_abs` is kept as two floats
  (integer epoch + fraction) so precision does not degrade on long runs.
