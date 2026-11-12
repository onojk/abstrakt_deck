# Jewel skins — Stage 8 perf + verify

Machine: Intel Arc 140V (Lunar Lake), Mesa / Vulkan, X11, 2560×1600 @ 90 Hz.
Date: 2026-11-12.

## FPS (uncapped)

`ABSTRAKT_NO_VSYNC=1`, default window, release build, 5 samples of the
title-bar fps after a 7 s warm-up. The jewel cost does not scale with window
size: the slice pass writes `cross × rows` texels (256 × ~2 per frame at
defaults) and the painter blit is the same fixed 4096×256 pass an image skin
uses, so an image-vs-jewel comparison at any window size isolates it.

| Source | fps samples | mean |
|---|---|---|
| default painter (no skin) | 530 493 481 491 505 | 500 |
| **image skin** (qbist jpg) | 492 505 483 481 491 | **490** |
| jewel — faceted gems | 499 492 459 477 480 | 481 |
| jewel — snake scales | 487 464 469 489 508 | 483 |
| jewel — glossy candy | 507 501 474 508 494 | 497 |
| jewel — chrome ribbons | 486 488 462 489 489 | 483 |
| jewel — pastel primitives | 461 498 459 464 489 | 474 |
| jewel — woven braid | 482 451 415 450 456 | 451 |

Run-to-run noise is ±5 %. Five families are inside the noise. Woven is
about 8 % lower at uncapped ~450 fps, which is still ~5× the 90 Hz vsync cap.
With vsync on, every family holds 90 fps.

The one-time full ring fill (on enabling the jewel skin or a ring
resize) renders 256×4096 texels in one frame. It shows as a single short
hitch, not a stall.

Shader compile: `family_pat` has a single call site (one loop over 5 taps ×
≤2 morph seeds). An earlier version that inlined it 10× made Mesa's
pipeline compile take over 30 s at startup.

## Verify

* **F12 recording:** captures the jewel skin (Recorder → 1280×720 H.264,
  checked with ffprobe and extracted frames). Pre-existing, unrelated: the
  recorder writes every rendered frame at a fixed 30 fps, so a 7 s capture at
  90 fps plays back as 20.8 s.
* **Export determinism:** the ring advances by `1/fps` per output frame in
  both the single and the grid export (`jewel_tick(…, 1.0 / fps, …)`), never
  by wall time. *Not run end-to-end here*: export needs the file dialogs.
* **Image-skin path:** unchanged by construction — `bind_skin_painter`'s
  Image arm issues the identical `set_pipeline` / `set_bind_group` calls,
  and `painter_skin.wgsl` / `load_skin` / `crop_skin_image` are untouched.
  *No pixel diff was run*: the live frame is time-animated, and the
  pre-change build has no non-interactive way to load a skin.
* **Seam:** every time term is a function of absolute row time, never ring
  index. Ring dumps (`ABSTRAKT_JEWEL_DUMP`) show no seam at the wrap.

## Test hooks (env vars)

| Var | Effect |
|---|---|
| `ABSTRAKT_JEWEL=<family word>` | start on a jewel skin (`faceted`, `snake`, `candy`, `chrome`, `pastel`, `woven`) |
| `ABSTRAKT_JEWEL_MOTION=Slither\|Roll\|Churn\|All` | with the above |
| `ABSTRAKT_JEWEL_DUMP=<file.png>` | save the ring (time left→right) ~4 s in |
| `ABSTRAKT_SKIN=<image>` | start on an image skin |
| `ABSTRAKT_NO_VSYNC=1` | uncapped present mode for fps measurement |

## Builds

* `cargo +1.75 build --locked --release --ignore-rust-version`: **passes**.
  This is how the noble PPA builds, because egui-wgpu 0.29.1 declares 1.76
  but compiles on 1.75. Plain `--locked` without the flag already failed on
  `main` before this work, for that reason. No crates were added.
* `cargo test`: 95 passed (3 new jewel tests: uniform layout = whole vec4s,
  family name round-trip, params deserialize from `{}`).
* windows-port: a trial merge of `main` into `origin/windows-port` conflicts
  only in `Cargo.toml` / `Cargo.lock` (version bumps). The merged tree
  `cargo check`s on Linux. DX12 and the MSIX were not built (needs the Shadow PC).
* Flatpak: a scratch copy of the manifest, with the app source pointed at
  the local git commit (jewel stage 7, `6b5a026`), builds offline in the
  25.08 SDK with the existing `cargo-sources.json`. That works because no
  crates were added. The committed manifest still points at the v0.1.8 tag
  and must be re-pointed once a jewel release is tagged and pushed.
* Snap: not built in this session (snapcraft needs its LXD/multipass build
  VM). Same Cargo.lock, no new crates, so no dependency risk is expected.
