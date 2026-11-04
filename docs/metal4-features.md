# Metal 4-only features for MCLA: what each would buy, and how (design, 2026-11-03)

Research only (written by a helper session for the Metal 4 revamp, [metal4-revamp.md](metal4-revamp.md)); no game or GPU capture was run for it. The build and trace costs in the ray tracing part come from a standalone probe on the M5 ([BACKLOG](BACKLOG.md) 38).

Sources:
- the macOS 27.2 SDK headers (Metal, MetalFX);
- mcla-recomp's `launcher/dev/frame-structure-2026-10-16.md`, a D3D12 frame investigation with phase timings at 3x;
- `src/render_markers.cpp`, `docs/metal-backend.md` and `include/rex/graphics/command_processor.h` (TaaCheckDraw);
- `temporal_aa.cpp`, and `metal_draw.h/.mm`, `metal_gpu.h/.mm` and `metal_fx4.mm`, all read only.

"Measured" means somebody measured it and the note says where. Everything else is a plan or a hypothesis, and is marked that way.

## 0. Ranking

| # | Feature | What it buys MCLA | Effort | Risk | Recommendation |
|---|---|---|---|---|---|
| 1 | **MTL4CounterHeap** timestamps | Per-phase GPU times on Metal: the D3D12 `gt-phases.py` table, using the guest markers that already exist | S | none | do first: every later item needs it to show its cost |
| 2 | **MTLTextureViewPool** | Removes `newTextureView…` objects and their residency entries: the stencil views, the 16x4F view of the 7e3 scene, the MetalFX/FG input views (the residency churn of review item 4) | S–M | low | do |
| 3 | **RT sun shadows into the game's own shadow mask** | Sharp, stable daytime shadows with no cascade resolution limit (four 640x640 cascades today), and no game shader changes | L | medium | the first RT feature; prototype after a geometry probe |
| 4 | **Drawable signalling** on the MTL4 queue | Presenting from the Metal 4 queue removes the Metal 3 presenter queue's shared-event hops (`WaitForMetal3`/`SignalMetal3`) | M | medium (frame generation's present thread) | after Metal 4 is the default |
| 5 | **RTAO** before translucents | Contact darkening under cars, kerbs and walls. The game has no AO | M (once #3's geometry exists) | low | second RT feature |
| 6 | **RT reflections + MTL4FXTemporalDenoisedScaler** | Wet-road and glass reflections; the denoiser replaces the temporal scaler in `TaaRun` | XL | high: hit shading has no materials | last; only if 3 and 5 are cheap enough |
| 7 | Colour attachment mapping | Fewer pipelines across EDRAM slot layouts | M | low | maybe, after the MTL4Compiler module lands |
| 8 | Placement sparse | Memory for resolution-scaled targets only where drawn | M | medium | no for now |
| 9 | ML encoder (MTL4MachineLearningCommandEncoder) | Nothing MetalFX doesn't already do for this game | L | — | no |
| — | Flexible pipelines, MTL4Archive, MTL4FX scalers, commit feedback | done or in progress (piece 1; `metal_fx4.mm`) | — | — | — |

## 1. What MCLA's frame gives us (facts)

From `frame-structure-2026-10-16.md` (D3D12, measured) and `TaaCheckDraw`:

- **Phases** (`render_markers.cpp` emits markers at each phase start):
  - 0x1–0x400: off-screen work.
    - 0x2: a 256x256 7e3 reflection view.
    - 0x4/0x8: a 512x256 environment map `032E2000`, used by car paint and the HUD gauge.
    - 0x20–0x100: four 640x640 D24S8 sun cascades into a 1280x1280 atlas.
    - 0x400: a 256x256 night shadow.
  - 0x800: the main view starts (`kSceneBegin`). At night it holds the depth pre-pass, 210–250 draws per tile.
  - **0x1000 (day only): the depth pre-pass, then screen-space sun-shadow collection into the colour target, resolved at 0x4000 to an `8_8_8_8` mask (`06ACD000`) that about 520 draws per tile in 0x20000–0x100000 sample by projected position.**
  - 0x10000: vehicles (stencil ref = 4·k + {0,1}).
  - 0x20000–0x80000: the opaque and alpha-tested world.
  - 0x100000: translucents (`kSceneTranslucent`).
  - 0x02000000: depth resolved, then particles, rain and light volumes.
  - 0x04000000: fog (`kSceneComposite`), then the final resolves.
  - 0x08000000: post (`kSceneEnd`), including motion blur `A6B9B6B0FA692C54`, which is where `TaaRun` runs.
  - 0x10000000: tonemap. 0x20000000: UI.
- **Forward renderer, no G-buffer.**
  - Scene colour is 7e3 with bias 4 and 2x MSAA, in two predicated tiles.
  - Depth is D24FS8.
  - There are no normal, albedo or roughness targets.
  - There is no velocity target. `taa_motion_vectors` makes the vectors from depth, the camera and the per-vehicle matrices.
- **The camera, at the motion blur draw:**
  - pixel constants c4–c7 = view;
  - c8–c11 = view-projection;
  - c14 = forward;
  - c15 = position;
  - c62 = size;
  - c69+4k…c72+4k = per-vehicle previous-frame matrices (k from the stencil).
  - `TaaCheckDraw` already inverts these and derives near, far and the vertical FOV.
- **Already on Metal:**
  - `taa_depth_` (Depth32Float, reversed) and `taa_motion_` (render-size pixels);
  - the jitter;
  - an `MTL4FXTemporalScaler` and an `MTL4FXFrameInterpolator` on their own Metal 4 queues (`metal_fx4.mm`);
  - `addFeedbackHandler` for commit timing.
- **GPU time is per-draw-bound, not pixel-bound** (measured, D3D12 at 1x/2x/3x): scene day 2.61/3.21/3.90 ms, race 5.76/6.32/6.66 ms. Pixel-rate effects at 1280x720 have room. Per-draw CPU work does not.

## 2. Ray tracing

### 2.1 Where RT plugs in without touching the game's shaders

| Effect | Insertion point | Output | Who consumes it |
|---|---|---|---|
| Sun shadows (day) | The 0x4000 resolve of the screen-space shadow mask | Write our mask into the same resolve destination (`06ACD000`, `8_8_8_8`) in place of, or min()'d with, the game's | ~520 world draws per tile already sample it |
| AO | `kSceneTranslucent` (after opaque world and vehicles, before glass, particles and fog) | Multiply the HDR scene target by AO in a full-screen pass | Everything after it |
| Reflections | `TaaRun` (motion blur draw, HDR scene in shader units) | Add to the scene before the denoising scaler | The denoiser, then post |

The shadow-mask route is the attractive one. The game already does deferred-style screen-space shadow collection, and its shaders already apply the mask, so an RT shadow needs no lighting re-implementation. Its cost is one ray per pixel plus the AS.

Facts to confirm with a capture (R2 in section 5):
- What the mask's channels mean. It is probably shadow in R or A, maybe cascade blend.
- Whether the mask is resolved per tile. It is resolved at 0x4000 inside the tiled pass, so our write must cover both tiles' rects.
- The sun direction. Its likely source is the cascade view matrices in the 0x1000 collection shader's constants (the light's forward vector), or the scene shaders' light constant.

### 2.2 Geometry: where the triangles come from

Xenos vertex data lives big-endian in guest memory, and the MTL4 AS builders take host-endian `MTLAttributeFormat` positions (default Float3) and UInt16/UInt32 triangle-list indices (`MTL4AccelerationStructureTriangleGeometryDescriptor`: `vertexBuffer`, `vertexFormat`, `vertexStride`, `indexBuffer`, `indexType`, `triangleCount`, `transformationMatrixBuffer` float4x3). So there is always a conversion pass. The question is where the positions come from.

**A. Clip-space capture (simplest; everything is "dynamic").**
- A capture variant of each scene VS (the translator emits it) writes its output position to a per-frame buffer at `vertex_id + draw_base`. Metal vertex functions may write device memory.
- A compute pass then:
  - turns clip positions into world positions with each draw's inverse (world-)view-projection;
  - expands the Xenos primitive type into triangle lists (strip, fan, rect list and quad list rules are the primitive processor's);
  - writes host indices.
- One BLAS per frame, rebuilt, holding everything that was drawn.
- Only on-screen geometry, because the game frustum-culls. That is fine for AO and for reflections near the screen. For sun shadows it misses casters behind the camera (tall buildings), and they would pop.
- **Shadow casters in light space:** capture the cascade caster draws (phases 0x20–0x100) the same way, inverting the cascade's view-projection. That is exactly the set of casters the game picked, off-screen ones included.

**B. Object-space cached BLAS + per-frame TLAS (cheapest per frame, most work).**
- Decode each draw's position fetch from guest memory. The translator knows the vfetch format and stride. Byteswap it into a host buffer.
- Build a BLAS per unique mesh, keyed by vertex address, size, format, stride and index range. Drop it when the shared memory's write watches see the range change (the texture cache already uses such watches).
- Per frame, the TLAS takes each draw's world matrix (`MTL4InstanceAccelerationStructureDescriptor`).
- Vehicles: refit or rebuild their BLAS when skinned, or treat them as rigid with their matrix.
- Needs the world matrix per draw (2.3), and fails for shaders that transform in odd ways (skinning, wind, impostors). Those fall back to A.

**C. Captured once, cached (A's generality at B's per-frame cost; 2026-11-03).**
- Every translated vertex shader ends in the same epilogue, which turns the Xenos clip position (`out.gl_Position`)
  into host NDC (`ndc_scale`/`ndc_offset`, the 1/W flags). A capture variant writes the position just before it to
  a buffer at `gl_VertexIndex`: the game's own decode, skinning and transform, any vertex format.
- Only for a draw whose mesh isn't cached: the key is the vertex shader, its vertex fetch ranges and the draw's index
  range and primitive type (the dump's `VD` lines). Object-space positions are clip · inverse(the draw's
  world-view-projection), and the instance transform is its world matrix (2.3's hypothesis, which the dump checks).
- The BLAS is built from the captured buffer in the same command buffer, after the pass (a barrier from vertex to
  acceleration structure), within `MetalRt4`'s per-frame triangle budget. The TLAS is rebuilt every frame from all
  of the frame's placements of cached meshes.
- The triangles come from the draw's own index stream (the host index buffer it was drawn with, or the sequence for
  auto-indexed and shader-fetched indices), expanded from strips, fans, rectangles and quads by the primitive
  processor's rules.
- `metal_rt4.h` (written, not wired yet) is the cache and the TLAS.

**Recommendation:**
- Start with A for one feature (AO, on-screen geometry, no light-space capture), measuring capture, conversion and build per frame with the counter heap (#1).
- Move the static world to B only if A's rebuild cost is too high.
- For sun shadows, use A on the cascade caster draws. Those are ~4 views of the casters, so use the closest one or two cascades for near detail and keep the game's shadow for the far ones (the min() of the two masks).

### 2.3 Matrices (hypothesis, to check with a constant dump)

`TaaCheckDraw` reads c4–c7 as view, c8–c11 as view-projection, c14 as forward and c15 as position. On a full-screen draw, world is the identity. That matches RAGE's usual shader globals:

| Register | Value |
|---|---|
| c0–c3 | gWorld |
| c4–c7 | gWorldView |
| c8–c11 | gWorldViewProj |
| c12–c15 | gViewInverse (row 2 forward, row 3 position) |

**Hypothesis:** the scene's VS and PS banks use the same layout. If so:
- every draw's c0–c3 is its world matrix (B's instance transform);
- c8–c11 is its clip transform, so A's clip-to-world is inverse(c8–c11) · c0–c3, with no frame lag;
- c12–c15 is constant across the frame (the camera).

The dumped MSL can't settle this: SPIRV-Cross packs the used constants, so `float_constants[n]` is not register n. It needs the per-draw dump R1.

**Verified (R1, 2026-11-04):** W·VP equals WVP for every scene draw (5,905 of 5,905 in a race, 2,413 of 2,414 in free
roam), rows as vectors (p' = p·M). The camera's VP is the motion blur draw's VS c8–c11 (its world is the identity), its
position VS c15. The dump's PS bank is not usable; the VS bank is.

### 2.4 Static and dynamic objects

| Class | How to tell | AS treatment |
|---|---|---|
| World (streamed city) | phases 0x20000–0x80000, not stencil-tagged | A: rebuilt each frame. B: cached BLAS, invalidated by write watches when the streamer reuses memory |
| Vehicles | phase 0x10000, stencil 4·k+{0,1}, per-vehicle matrices c69+ | rebuilt each frame (A) or refit (B). Few triangles |
| Translucent, particles, rain, light volumes | 0x100000+, 0x02000000 | excluded (no AS) |
| Alpha-tested foliage and fences | 0x20000–0x80000 with alpha test | first version: opaque or excluded. Later: an intersection function with a texture lookup (costly; needs UVs, so B only) |
| Impostors (0x20–0x100 tiles) | billboard draws | excluded |

### 2.5 AS cost on M5: unknown, to measure (R3)

No published numbers fit this case, so they were measured with a standalone probe (no game, about a minute of GPU; results in [BACKLOG](BACKLOG.md) 38). It measures:
- a BLAS build (`buildAccelerationStructure` on an `MTL4ComputeCommandEncoder`) of 0.25, 0.5, 1 and 2 M triangles, PreferFastBuild versus default, and a refit;
- a TLAS of 1k, 3k and 6k instances, since the scene has ~2.7k draws over its two tiles;
- one shadow ray and one AO ray (short tmax) per pixel at 1280x720 and 2560x1440, with an `intersection_query` in a compute kernel, against the 1 M-triangle BLAS.

The decision rule is a budget. A, plus the rays, plus our filter, must fit in about 1.5 ms at 1280x720. The race scene is 5.8 ms of the frame's GPU time, measured on D3D12. If A doesn't fit, it's B or nothing.

Triangle counts per phase are also unknown. R2, a GPU capture or a counter in the capture pass, gives them.

### 2.6 Denoising: MTL4FXTemporalDenoisedScaler

The API (`MTLFXTemporalDenoisedScaler.h`, Metal 4: `MTL4FXTemporalDenoisedScaler encodeToCommandBuffer:`):
- **Textures:** colour, depth and motion; diffuse albedo, specular albedo, normal and roughness; optional specular hit distance, denoise strength mask (1 = ignore the pixel), transparency overlay (linear RGBA), reactive mask and exposure. Plus output.
- **Settings:** `worldToViewMatrix` and `viewToClipMatrix`, the jitter, the motion vector scale, `depthReversed`, `shouldResetHistory` and `preExposure`.
- **What it does:** it denoises, anti-aliases and upscales in one pass, so it would replace the `MTL4FXTemporalScaler` in `TaaRun` when an RT effect is on.

| Input | MCLA source | Status |
|---|---|---|
| colour | the HDR scene at `TaaRun` (16x4F view of the 7e3 resolve) | have |
| depth, motion, jitter, reset | `taa_depth_`, `taa_motion_`, `TaaInputs` | have |
| worldToView, viewToClip | c4–c7, and `inverse(view)·viewProj` as `TaaCheckDraw` computes | have (needs a transpose to simd column-major) |
| normal | depth-reconstructed (noisy at edges), or a primary ray against the AS (exact geometric normal, one extra ray per pixel) | buildable |
| roughness | none. A constant per class: world 0.6, vehicles 0.15 by stencil, wet road from a weather flag (RE) | heuristic |
| diffuse, specular albedo | none in a forward renderer | the open problem, below |
| specular hit distance | from our reflection rays | buildable (reflections only) |
| transparency overlay | translucents are drawn into the same target. Splitting them out needs a second target from `kSceneTranslucent` on | hard; skip in v1 |

**The albedo problem, and a way round it for multiplicative terms.** The denoiser divides out albedo to find noisy lighting. For shadows and AO the noisy part is a visibility factor V, and colour = raster · V. If we keep the noise-free raster colour from just before V is applied and give it as the diffuse albedo (normalised to [0,1]), the denoiser divides out exactly the clean part. This is an experiment, not a known property of MetalFX.

Shadows don't need it anyway. The mask is consumed mid-scene, long before `TaaRun`, so the shadow mask must be clean when the game samples it. Plan:
- a near-point sun (a cone of about 0.5°);
- 1 spp with a per-frame blue-noise rotation;
- our own depth-aware 3x3 spatial filter plus a short temporal accumulation reprojected with `taa_motion_`'s matrices, at the 0x4000 point.

AO gets the same own-filter treatment. **The MetalFX denoiser only earns its place with reflections**, which are high-frequency, need hit distance and are applied late. That is why it is last in the ranking.

### 2.7 Hit shading for reflections

The captured AS has positions only, with no UVs, textures or materials. Options, cheapest first:
1. **Screen-space hit lookup.** Project the hit into the current frame. If it is on screen and the depth matches, take the scene colour there. This is SSR with an exact hit, and it fails where SSR does, off-screen.
2. **Off-screen miss.** Sample the game's environment map `032E2000` (512x256 7e3, rendered each frame at 0x4/0x8), which the car paint already reflects.
3. **Real materials.** B plus a per-draw record of texture fetch 0 and the UV fetch. That is a large translator change.

1+2 is a reasonable v1 for wet roads at night, where neon and headlights are mostly on screen.

### 2.8 As built (2026-11-04): `metal_rt`, `metal_rt_ao`, `metal_rt_shadows`

**Geometry** (`metal_rt`, off by default, restart):
- Section C, wired. Scene draws (guest marker 7) whose mesh isn't cached run the capture variant of their vertex
  shader (`MetalRtCaptureMsl`) once; the kernel also writes the mesh's bounds (atomics). Meshes are cached by the
  shader, index range and vertex fetch constants; the BLAS is built from the capture in the same command buffer.
  In a race, 87% of meshes are reused a second later; about 12 new meshes (3 K triangles) a frame are built.
- The placements (mesh, world matrix c0–c3) go into **two TLASes**, each ray query traces both, the nearer hit
  counts:
  - a static one of what was drawn in two frames or more, kept while out of view for 150 frames (off-screen
    occluders), dropped when in view and not drawn (bounds against the frustum: a level of detail swapped, or it
    moved) or when the same mesh appears within 30 m; rebuilt every 15 frames, or 4 after a drop;
  - the frame's, of the rest (new placements, what moves): about 350 to 950 instances.
- Not one TLAS holding the other: multi-level instancing (`max_levels<3>`) works, but rays through three levels were
  3 to 5 times slower in a race. A TLAS build costs about 0.4 ms however few its instances (probe: 151 instances
  0.16 to 0.25 ms, 3,000 0.3 to 0.9 ms, clock-dependent); the two are built concurrently.
- `metal_rt_check` traces from the camera to each 4th pixel's depth: 80 to 99% of rays hit at the depth, 1 to 15%
  in front (alpha-tested and translucent geometry, what the depth doesn't hold). The depth texture holds 1 − z/w over
  the full range (twice the host depth of the scene's viewport).

**AO** (`metal_rt_ao`, off by default):
- Half resolution (640x360 at 720p), one cosine-weighted ray a pixel a frame on a checkerboard (half the pixels a
  frame), 2.5 m, none beyond 100 m (`metal_rt_ao_distance`, faded over its last quarter).
- Temporal accumulation of 16 frames (`metal_rt_ao_history`), reprojected with the last frame's camera, history
  dropped where its stored distance doesn't match; a depth-aware 5x5 blur, narrower as frames accumulate; a depth-
  aware upsample multiplies the HDR scene before the motion blur reads it.
- Ray cost: about 0.5 ms per 230 K rays in a race, the same at 0.25 m as at 2.5 m (the cost is entering the many
  overlapping mesh boxes around each origin, not the distance). Any-hit, a TLAS built for tracing, and dropping the
  largest instances didn't help.

**GPU time in a race at 720p** (`metal_gpu_phase_times`, 150-frame windows; the stamps between the steps add a
little):

| Step | ms |
|---|---|
| Captures and BLAS builds | 0.2–0.4 |
| TLAS builds (static when due, frame's) | 0.5–0.65 |
| AO rays | 0.27–0.61 |
| AO filters (temporal, blur) | 0.1 |
| AO applied (upsample, copy back) | 0.16 |
| **Total** | **about 1.3–1.9** |

Before this pass (6 rays a pixel, no history, one TLAS): 4.4 to 8.9 ms.

**Sun shadows** (`metal_rt_shadows`, off by default; the game then marks every render phase):
- The sun: a cascade draw's (phases 0x20 to 0x100, depth only) world-view-projection times the inverse of its world
  is the light's; taken when orthographic, not the identity, and the same for two draws of different worlds or of
  the identity world (MetalFX's performance mode draws the cascades so: world constants left at the identity). Toward
  the sun is across clip x and y, against the depth's gradient; one along an axis is a 2D quad's, not the sun. It
  follows the time of day (logged when it turns). The depth-only gate matters: the phases also hold colour passes
  and quads with identity worlds and other projections (one turned with the car).
- The game's mask (phase 0x4000, each predicated tile's resolve: 1280x512 then 1280x208, one 1280x720 under MetalFX;
  8888 with exponent −4; lit about 66 to 71/255, up to about 128 far) is changed in place after its resolve: each lit texel within 250 m
  (`metal_rt_shadow_reach`) is put back in the world from the tile's depth, and a ray toward the sun through the
  static TLAS (what moves is in the cascades already; one level costs about 20% less) turns it sunless when blocked.
- Traced only where the game has sun and the surface faces it (its normal from the neighbours' depth, the nearer of
  each pair; facing at least 0.2). The game's mask is its cascades' shadows alone: surfaces turned from the sun are
  lit there and its lighting darkens them softly; rays found them behind themselves and darkened whole facades.
- The origin leaves the surface along the normal and toward the sun, (0.04 + 0.002 × distance) m scaled up to 3× at
  grazing sun; hits nearer than that don't count.
- Mistakes found on the way (each checked with a debug mode or a dump of the mask): the tile's guest NDC needs the
  translator's Metal y flip (`ndc_scale`/`ndc_offset` y negated); without it 10 to 20% of the texels' positions met
  a camera ray, with it 75 to 90% (the rest mostly the player's car, in the static TLAS but not yet in the depth).
- Captures now invert a perspective draw's clip x, y and w only (w is the view depth: well conditioned in floats; z
  and w nearly cancel far away). It changed the check's numbers little, but it is the right inverse.
- The sunless value moves with the light (16/255 in one frame, 4 in another, both modes): the kernel samples a
  histogram of the mask's dark values (one texel in 64) and the most common becomes the value blocked texels get
  (and the lit threshold) a few frames later.
- MetalFX upscaling: the mask resolve stretches the render-size corner to the output (`stretch_num`/`stretch_den`);
  the kernel maps each texel the same way, and takes the normal's neighbours a depth texel apart (a mask texel apart,
  two neighbours read the same depth: no normal, nothing traced).
- Checked in MSAA (default), MetalFX native and performance, and resolution scale 2: blocked 0.3 to 6% of game-lit
  texels along the drive (up to 40% in shaded streets), no acne in the shots.
- Agreement in a standing day scene (`metal_rt_shadows_debug` 1): the game lit and the ray blocked 2 to 11% of
  texels (awnings, poles, recessed windows the cascades miss), the game shadowed and the ray lit 0.1 to 3%.
- Cost: 0.5 to 2 ms (80 K to 360 K rays a frame), on top of the TLAS builds that AO shares. Validation layer clean.
- `metal_rt_shadows_debug`: 1 the rays' verdict alone, 2 only the shadows rays add, 3 only the sun rays find where
  the game has none.

**Cost on the CPU** (race bench `20261104-055635-rt-cpu`, 30 FPS cap, two alternating runs, the night race so the
shadows only mark phases): command thread 14.1/13.4 → 15.6/14.5 ms a frame with `metal_rt`, AO and shadows (+1.1 to
1.5 ms), command-buffer GPU span 15.0/14.3 → 18.8/17.2 ms; FPS held at 30, no hitches added.

**Launcher:** Graphics, Ray tracing: Off / Ambient occlusion / Ambient occlusion and sun shadows (sets `metal_rt`,
`metal_rt_ao`, `metal_rt_shadows`; shown with Metal on macOS 26, disabled with Metal 3).

**MetalFX's denoising scaler, tried** (`metal_rt_ao_denoiser`, off; 2026-11-04): with MetalFX anti-aliasing at the
native size, the AO is traced raw (one ray a half-size pixel, no history or blur) and applied before the
anti-aliasing (ray tracing then runs before `TaaRun`), and `MTL4FXTemporalDenoisedScaler` replaces the temporal
scaler. Its guides (`rt_denoise_inputs`): diffuse albedo = the colour over the AO's multiplier (scaled into 0 to 1),
world normals from the depth, no specular, roughness 1; `worldToView` from the blur's pixel constants 4 to 7,
`viewToClip` = view⁻¹ × view-projection (8 to 11) with z reversed. It works, and is not worth it: the frame's GPU
time went from about 14.5 to 24 ms (the denoiser alone some 8 ms at 720p), and it smoothed the road's and the
pavement's texture away and darkened shaded pavement where our own filters keep the texture. Without real albedo
and roughness (a forward renderer has neither) it has nothing to tell noise from texture by. Left in, off.

**Reflections: not now.** Ray hits carry no materials, so a reflection could only look up the screen (exact-hit SSR)
or the 512x256 environment map; the game already draws its wet-road reflection with full materials (phase 0x2,
256x256) and its car paint reflects the environment map. Without a material record per draw (a translator change,
2.7's option 3) RT reflections would stack a second, poorer reflection on the game's own.

## 3. The other Metal 4 features

### 3.1 MTL4CounterHeap (recommend: first)

- **The API:**
  - `MTL4CounterHeapDescriptor{type = Timestamp, count}` → `[device newCounterHeapWithDescriptor:]`;
  - `-[MTL4CommandBuffer writeTimestampIntoHeap:atIndex:]` between encoders;
  - `-[MTL4RenderCommandEncoder writeTimestampWithGranularity:afterStage:intoHeap:atIndex:]` and the compute equivalent, with `Relaxed` or `Precise` granularity;
  - `-[MTL4CounterHeap resolveCounterRange:]` → NSData on the CPU once the work is done, or `-[MTL4CommandBuffer resolveCounterHeap:withRange:intoBuffer:…]` to resolve on the GPU;
  - `invalidateCounterRange:` before reuse.
- **For MCLA:** on each guest marker (`OnGuestMarker`, both tiles), write a timestamp at the current encoder position. Encoder boundaries are cheap with `Relaxed`. A render pass that a marker falls inside gets `afterStage:Fragment`. Resolve in the commit's completion and log per-phase ms: the Metal version of the D3D12 phase table.
- **Why first:**
  - Every later decision here (RT budget, view pools, signalling) needs per-phase GPU numbers.
  - Today's `GpuDone` gives only command buffer start and end.
  - It also gives `TaaRun`, the frame interpolator and the resolves their own costs.
- **Watch for:** a ring of heaps per frame in flight (3), and timestamps at encoder boundaries only, never per draw.

### 3.2 MTLTextureViewPool (recommend: do)

- **The API:** `[device newTextureViewPoolWithDescriptor:(MTLResourceViewPoolDescriptor{resourceViewCount})]`, then:
  - `-setTextureView:atIndex:` or `-setTextureView:descriptor:atIndex:` (an `MTLTextureViewDescriptor`: format, type, levels, slices, swizzle);
  - `-setTextureViewFromBuffer:descriptor:offset:bytesPerRow:atIndex:`.

  Each returns an `MTLResourceID` for `-[MTL4ArgumentTable setTexture:atIndex:]`. There is no `MTLTexture` object per view.
- **For MCLA:**
  - the X32_Stencil8 views (metal_draw.mm ~2558, 3020, 3082);
  - the RGBA16Float view of the scene base for MetalFX (3250);
  - the frame generation source view (3495);
  - `View()` (2375).

  Today each is an ObjC object. The residency set tracks them, and the pool test (`Idle`) has to reason about them (review item A).

  With a pool, a view is a slot. The parent texture is the only resident object, and a view slot can be rewritten when the parent's lifetime ends. That ends both the churn and the `Idle(parent)` subtlety.
- **Where the pool doesn't fit:** MetalFX and the frame interpolator take `id<MTLTexture>` properties. Their inputs keep real views, made once per scaler size and not per frame.
- **Sizing:** one pool, a few hundred slots, a free list. Slots are reused only after the GPU passes the serial that last used them (the queue already has serials).

### 3.3 Drawable signalling (recommend: after Metal 4 becomes the default)

- **The API:** `-[MTL4CommandQueue waitForDrawable:]` and `-signalDrawable:`. Then `[drawable present]` on the CPU side, with the commit between them on the same Metal 4 queue.
- **For MCLA:** the presenter has its own Metal 3 queue, and the backend orders against it with `WaitForMetal3`/`SignalMetal3` (two shared events a frame; review item E was about their order).
- **Change:** move the present copy, the gamma, HDR refresh and compose onto a Metal 4 command buffer: waitForDrawable, encode into the drawable texture, signalDrawable, commit, present. That removes a queue, its events and a cross-queue hop per frame.
- **Frame generation** presents twice from its present thread: two drawables, each with its own wait/signal pair. It also needs the interpolator's queue (`metal_fx4.mm`) to signal the present queue, so measure the frame pacing with presents.py before and after.

### 3.4 Placement sparse (recommend: not now)

- **The API:** `MTLHeapTypePlacement` heaps with `maxCompatiblePlacementSparsePageSize`, sparse buffers and textures, and `-[MTL4CommandQueue updateTextureMappings:heap:operations:count:]` and `updateBufferMappings:…` (barrier on `MTLStageResourceState`).
- **Possible use:**
  - resolution-scaled targets (`resolution_scale` 2–3) and the EDRAM's host targets, mapping pages only for rects the guest draws (the bottom tile is 1280x208);
  - aliasing transient textures (TAA, FG, HDR) that are never live together.
- **Why not now:** the memory isn't the bottleneck on a unified-memory Mac (vram notes: the game is far below limits), and mapping updates are queue operations with their own sync. Revisit only if `resolution_scale` 3 hits memory pressure.

### 3.5 Colour attachment mapping (recommend: maybe)

`MTL4RenderPipelineDescriptor.colorAttachmentMappingState = Inherited`, `MTLRenderPassDescriptor.supportColorAttachmentMapping`, then `-[MTL4RenderCommandEncoder setColorAttachmentMap:]`.

Xenos pixel shaders write oC0–oC3 to whatever EDRAM slots the RB registers bind. A pipeline keyed on logical outputs, with the slot mapping set per draw, folds keys that differ only in which slot is which. The pipeline key would need to drop the slot permutation, and the gain is worth measuring first: how many pipeline keys differ only that way? It is a counting job on the pipeline storage, no GPU needed, and I can do it if you want.

### 3.6 ML encoder (recommend: no)

`MTL4MachineLearningCommandEncoder` (setPipelineState, setArgumentTable, `dispatchNetworkWithIntermediatesHeap:`) runs a CoreML-derived network from an `MTL4MachineLearningPipelineDescriptor` on the GPU timeline, with `MTLTensor` inputs. MetalFX already covers upscaling, AA, interpolation and denoising, and there is no game-specific network to run. The game's own textures could be upscaled offline instead.

## 4. A phased plan

1. **Counter heap timestamps** at guest markers, then a per-phase Metal table, day free roam and race (after the M4 default). The RT budget comes from this.
2. **Texture view pool** for the stencil and format views, then the harness (Task 3) for pictures and the bench for CPU.
3. **RT probe** (R3, standalone): build and trace costs on M5. Go/no-go for A.
4. **Capture pass (A)** behind `metal_rt_capture`: the scene draws' clip positions, then world, triangle lists and one BLAS. A debug view draws the AS hit distance at 1280x720 to show it matches the raster depth (a Metal-side correctness test: depth from our primary rays against `taa_depth_`).
5. **RTAO** at `kSceneTranslucent`, with our own filter. A/B pictures, plus its cost in the phase table.
6. **RT sun shadow mask** at the 0x4000 resolve, from the cascade casters (2.2 A), min() with the game's mask, day only. Pictures at noon, dusk and under the overpasses.
7. **Reflections and the denoised scaler**, only if steps 5–6 cost under budget.

Kill criteria:
- If step 4's capture, conversion and build cost more than 1.5 ms at 1x in the race, stop RT, or move the static world to B.
- If the shadow mask channels turn out to carry cascade blending that our mask can't reproduce, fall back to modulating the scene (like AO) instead.

## 5. Requests (asking first; none of these has run)

- **R1. A constant dump (game run, ~2 min, free roam by day).**
  - For one frame: each scene draw's VS c0–c15 and PS c0–c15, the motion blur draw's c4–c15, and the 0x1000 shadow-collection draws' constants.
  - The question it settles is 2.3, the RAGE layout.
  - Metal has no frame log. The D3D12 `frame-log.sdk.patch` is Windows-only. A dev-only patch that logs these behind a cvar (`metal_debug_dump_constants`) exists outside the tree, to be applied for a run and reverted.
- **R2. A GPU capture (`out/research/gputrace.sh`) of one day frame and one night race frame.** It answers:
  - the triangle count per phase;
  - the position vfetch formats;
  - the shadow mask's channels at the 0x4000 resolve;
  - whether the mask is per tile.
- **R3. The AS probe (2.5), about one minute of GPU, no game.** Done 2026-11-03: the numbers are in [BACKLOG](BACKLOG.md) 38.
- **R4 (no GPU).** Count pipeline keys that differ only in the colour slot permutation (3.5) from the pipeline storage file. I can do it now, read-only, if you say where it lives.
