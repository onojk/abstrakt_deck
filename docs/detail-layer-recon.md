# Detail layer / distortion recon (ghost, distortion defaults, detail shading)

Read-only Step 0 for three addenda: **Spaghettification ghost layer**,
**Distortion on by default**, and **Part B — details get 2.5D shading**.
No code was changed for these. Line numbers are `main.rs` at the time of
writing (after jewel stage 7).

## Live pass order (`GpuState::render`)

| # | Pass | Target | Notes |
|---|---|---|---|
| 0 | Jewel slice writer | jewel ring | only when Skin + Jewel |
| 1 | Painter | painter FBO 4096×256 | skin / procedural painters |
| 1a/b | Ribbon update + composite | painter FBO | |
| 1c | Palette | painter FBO | |
| 2 | Shape (mesh / myocyte / prime-helix / accents splats) | shape FBO | **"Accents" decorative grid is drawn here** |
| 2b | Shape effects — contrast/sat/invert/colorize **+ sine "Distortion"** | shape_post | Effects → Distortion checkbox |
| 2c | **Lyric text (SDF glyphs)** | shape_post (drawn *on top* of shape_post) | `main.rs:5392` |
| 2.5 | **Distortion Plus** (equirect yaw/pitch/roll) | dp FBO | |
| 3 | Kaleido fold | scene | |
| 3b | SpinTrail | scene | |
| 4 | Frame (border shape) | scene | |
| 4b | Bezold contrast | | hue-only, not a warp |
| 4c | **Micro Swirl** (per-cell swirl warp) | ms FBO | |
| 4d | DepthShade (lit bumps from the micro-swirl field) | | already a "2.5D shading" pass, gated on Micro Swirl |
| 5 | **Blackhole** video-feedback ping-pong (or Phantom, or plain blit) | swapchain | |
| 5.5 | Explosion sparks overlay (additive) | swapchain | |
| 6 | Help overlay, egui | swapchain | |

## What is distorted, and by what

Warp-type tools, in chain order:

1. **Effects → Distortion** (sine wobble, shape-effects pass) — affects the shape only.
2. **Distortion Plus** (equirectangular rotation).
3. **Kaleido fold** (always on; not usually called a distortion tool).
4. **Micro Swirl** (screen-space swirl; hotkey U).
5. **Blackhole** (feedback zoom/warp around a wandering centre).
6. **Jewel roll / turn / churn / slither** — internal to the jewel skin, pre-fold.

Layers and what reaches them:

| Layer | Sine distortion | Distortion Plus | Kaleido | Micro Swirl | Blackhole |
|---|---|---|---|---|---|
| Skin / painter / shape | yes | yes | yes | yes | yes |
| Lyric text | **no** (drawn after 2b) | yes | yes | yes | yes |
| Frame border | no | no | no | yes | yes |
| Explosion sparks | no | no | no | no | **no** |

So **no layer bypasses "the distortion tools" as a whole except the
explosion sparks** (and UI). The lyric text bypasses only the sine wobble.

## Open questions (need answers before building)

1. **Which layer is "the detail layer on top"?** Candidates: lyric text
   (most likely — it's crisp, on top of the shape, and skips the sine
   wobble), explosion sparks, or the frame border.
2. **Which two tools are "the TWO existing distortion tools"?** Best guess
   from the UI naming: **Distortion Plus** and **Micro Swirl** (the two
   panels whose whole job is warping). Alternatives: Micro Swirl + Blackhole
   (the ghost addendum talks about "blackhole center"), or Effects →
   Distortion + Distortion Plus.
3. If it is the lyric text: it currently *is* fed through Distortion Plus,
   Micro Swirl and the blackhole. Making it a crisp undistorted anchor means
   **moving the text draw after the distortion chain** — a visible change to
   the current look, so it's your call.

## Facts relevant to each addendum

* **Preset schema:** `Preset` has **no version field**. Every field uses
  `#[serde(default…)]`, so "migration" = add fields with defaults; old
  `preset.json` files keep their values. Presets are only loaded on demand
  (L key / menu) — a fresh launch always uses `VisualParams::default()`.
  "Distortion on by default" therefore only needs `VisualParams::default()`
  changes; adding a `schema_version` is optional.
* **Current defaults:** `distortion_enabled = false`,
  `distortion_plus_enabled = false`, `micro_swirl_enabled = false`,
  `blackhole_enabled = false`.
* **Existing 2.5D shading for details:** `DepthShade` already lights the
  micro-swirl field (Lambert, configurable light). Part B's detail shading
  should share the jewel light rig (orbiting key light, analytic sky); the
  jewel uniform's `light_angle` is the value to share.
* **Ghost memory:** a half-res RGBA8 detail texture + two half-res ping-pong
  feedback textures at 1080p ≈ 3 × 2 MiB; 4K export ≈ 3 × 8 MiB.
* **Determinism:** blackhole feedback already steps per export frame in
  `render_export_frame`; a ghost feedback must follow the same pattern
  (`dt = 1/fps`).
* **Luminance:** no shared helper exists (Bezold is hue-based). BT.709 is
  used by `frame_metric.rs` / `echo_composite.rs` and the jewel halos;
  `shape_effects.wgsl` uses BT.601.
