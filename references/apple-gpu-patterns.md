# Apple GPU optimization patterns (measured, M5, Oct 2026)

Numbers are exact per-encoder medians from Metal System Trace unless noted. Treat them as priors, not facts about a new scene: re-measure.

## Big wins

- **`discard` disables hidden surface removal (HSR).** Any `discard` in an Apple fragment shader turns off HSR for that draw, so occluded fragments get shaded. Removing a never-firing `discard` (a nodata/height-mask check) cut a terrain pass by ~28% (another measure: 10–16%). Move masking to geometry (cull triangles, degenerate vertices) or alpha-to-coverage only where really needed.
- **Light once per pixel: deferred instead of in-pass lighting.** Bevy's `apply_pbr_lighting` inside a heavy material draw cost ~5 ms; the same lighting as a fullscreen deferred pass cost ~1.1–1.5 ms. Reasons: overdraw and quad overshading from small triangles multiply in-pass lighting. Pattern used: the material writes an unlit G-buffer; a custom fullscreen lighting pass reads it (extra factors like a terrain shadow travel in a spare G-buffer byte). Terrain fragment 6.55 → 2.18 ms + 1.07 ms lighting pass.
- **Quad overshading from small triangles.** Per-pixel work in a draw with tiny triangles costs far more than the same work fullscreen. Coarser meshing / larger LOD morph distance helps (morph_distance 16 → 24: −2.8 ms; going lower causes cracks).
- **Skip work whose inputs didn't change.** A shadow-map raymarch re-run every frame (1.4 ms) dropped out entirely when skipped for a static sun/terrain. Same for environment/radiance maps: filter once (−2.3 ms) instead of every frame.
- **Cheaper texture formats with hardware filtering.** Rgba16Float LOD with hardware sampling instead of manual taps took a water prepass 21 → 4.5 ms (together with a narrower blend band and passing undisplaced XZ through UVs).
- **Skip near-zero contributions.** Triplanar mapping that skipped near-zero projection weights cut a ground pass from 20–45 ms to ~8.5 ms.
- **Shorter ray marches, cheaper hit shading.** Water SSR/refraction marched in clip space with fewer steps (12+5): −0.8 ms. One environment-map sample instead of a second full PBR lighting call on SSR hits: −2.9 ms.
- **Write only what changed.** A forcing pass that wrote the whole grid was fixed to write only the edge strip. Shared wrapped taps in an LOD write: −0.27 ms.

## Tried, no measurable effect (don't re-try first)

- Fresnel-gating a reflection trace; marking water `NotShadowReceiver`; shorter shadow cascades; deduping ground layers; removing water `discard`s (water had no HSR to win back); collapsing the water's single lighting call.
- Bevy cascade PCF was not a factor when the main geometry (bevy_terrain) doesn't draw into Bevy's shadow phase.
- Per-pixel normal taps on terrain were negligible.

## Format notes

- BC4/BC6H break height-derived normals (6–20° mean error). R16 is near-lossless for height at half size; BC7/BC1 are fine for albedo/landcover.

## Where to look first in a Bevy frame

Sort the per-pass table by ms/frame. Typical heavy hitters were: transmissive/water fragment, terrain/material fragment with in-pass lighting, sky/atmosphere render, shadow maps re-rendered every frame, SSR, and simulation compute passes. Check whether a pass is even needed (e.g. SSR on a camera where no material uses its define only re-added environment specular — it was dropped).
