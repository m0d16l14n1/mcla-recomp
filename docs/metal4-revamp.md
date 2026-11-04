# Metal 4 revamp of the Metal backend (design, 2026-11-03)

Asked for by the user on 2026-11-03: Metal 4 by default for everything, Metal 3 kept behind a switch, and **not a
1:1 port**: where Metal 4 has a better way, the backend is rebuilt around it. This is the plan; the state of each stage
is at the end.

## Where we start

- The backend (`third_party/rexglue-sdk/src/graphics/metal/`, 8,200 lines; `metal_draw.mm` alone 5,000) is Metal 3:
  `MTLCommandQueue` command buffers made per pass, `set*Bytes` (25 places), per-encoder binding (`setVertexBuffer`,
  `setFragmentTexture`, samplers: about 55 places, every draw), 13 blit encoders, Metal's automatic hazard tracking for
  everything but the guest memory buffer (that one is untracked, ordered by `memory_fence_` and `memory_read_fence_`),
  `addCompletedHandler` for completion, 21 places that make pipelines with `newRenderPipelineState` /
  `newComputePipelineState`, and swizzle views made with `newTextureView` (`View()`).
- What already points the Metal 4 way: the shader constants go through a per-frame ring (`metal_constant_ring`: a
  transient allocator), the guest memory buffer is untracked with explicit fences, an encoder thread
  (`EncoderQueue`) replays the in-pass calls off the command thread, and the pipeline storage builds pipelines ahead.
- Since 2026-11-03 the MetalFX effects (temporal scaler, frame interpolator, spatial scaler) are Metal 4 by default
  (`metal_metal4`), each on a Metal 4 queue of its own beside the Metal 3 one (`metal_fx4.h`), ordered by a shared
  event both ways. Frame generation measured 16.3 ms of GPU a frame against 17.0 on Metal 3 (race bench, two runs
  each), with the same pacing.
- The limit in a race is the command thread: 18 to 23 ms of CPU a frame at MetalFX Performance (bench
  20261103-184044), much of it the cost of Metal 3's per-call encoding and tracking. That is what Metal 4 is for.

## What Metal 4 changes that matters here

| Metal 4 | What it replaces here | Why it is better for this backend |
|---|---|---|
| `MTL4CommandQueue`, reusable `MTL4CommandBuffer`s with `MTL4CommandAllocator`s, batched `commit:count:` | a command buffer per pass segment from the queue, `addCompletedHandler` | no per-buffer allocation; the frame's buffers committed together; completion and GPU time from `MTL4CommitFeedback` and one shared event per frame |
| `MTL4ArgumentTable` (GPU addresses and resource IDs) | ~55 `set*Buffer` / `set*Texture` / `setSamplerState` calls a draw, `set*Bytes` | a binding is a write into a table, snapshotted at the draw; constants are ring addresses; most of the encoder thread's reason to exist goes |
| `MTLResidencySet` | Metal's per-encoder resource tracking | the render targets, rings, guest memory and cached textures are made resident once, as they are made and evicted |
| explicit barriers (consumer/producer queue barriers, intra-pass barriers, fences) | automatic hazard tracking | the backend already knows every dependency (EDRAM tiles per pass, resolves to textures, texture loads before draws, guest memory writes): it says them, and Metal stops tracking ~10,000 bindings a frame |
| one compute encoder for blits and dispatches | 13 blit encoders beside compute ones | texture loads, composes, copies and resolves grouped in one encoder per gap between passes, with intra-pass barriers |
| `MTL4Compiler` with function descriptors, compiler tasks, unspecialised (flexible) render pipelines, `MTL4Archive` / `MTL4PipelineDataSetSerializer` | our async compile threads, a pipeline per blend and format variant, our pipeline storage | one pipeline per shader pair, specialised cheaply per blend/format; the system's binary archives in place of rebuilding at start |
| colour attachment mapping (`MTLLogicalToPhysicalColorAttachmentMap`) | a new pass whenever the set of bound render targets changes | passes over the same targets with different subsets merge: fewer tile flushes on the TBDR GPU |
| `MTLTextureViewPool` | `newTextureView` per texture and swizzle (`View()`) | views are cheap resource IDs from a pool |
| `MTL4CounterHeap` timestamps | per-command-buffer GPU times (`metal_debug_profile`) | per-pass GPU time without splitting command buffers |
| the queue's `waitForDrawable` / `signalDrawable` | the presenter's Metal 3 drawable path | MetalFX and the paint on the same queue as the frame: no cross-queue events |

What it costs: Metal 4 command buffers don't retain resources (everything the GPU may still read is kept until its
frame's event says it is done: deferred release, frame by frame), and nothing is tracked (a missing barrier shows as
stale tiles or random corruption, not an error).

## Shape of the code

Not a copy of `metal_draw.mm` with the calls renamed. The backend splits into:

1. **Xenos emulation, API-neutral** (taken out of `metal_draw.mm` with no change in behaviour first, the Metal 3 path
   checked for zero difference): the EDRAM tile tracker and transfers' bookkeeping, the texture cache's keys, watches,
   hashes and resolve bookkeeping (`resolved_`, composes), the draw state decisions (what a draw needs, which pass,
   which clears and transfers go first). It produces *what* to encode and the dependencies between them.
2. **Encoding**, two implementations of one small internal interface: begin/end pass (targets, load/store), draw,
   dispatch, copy, clear, barrier, signal. The Metal 3 one is today's code, kept as the switch's fallback. The Metal 4
   one is written natively: argument tables, residency, explicit barriers from the dependencies part 1 reports, one
   compute encoder between passes, batched commits.
3. **Pipelines**: the Metal 4 path through `MTL4Compiler` (flexible pipelines specialised per blend and formats,
   archives); the Metal 3 path as today.

## Synchronisation plan

Start correct and coarse, then narrow, as Apple's guidance says:

- Every encoder starts with a consumer barrier after the queue's `Dispatch | Blit | Fragment` before its own stages,
  visibility `Device`. Correct whatever the order; slower.
- Then each barrier only where part 1 reports a dependency: a pass loading a target another pass or a transfer wrote
  (`Fragment` to `Fragment`), a draw sampling a resolve's texture (`Dispatch` to `Fragment|Vertex`), a texture load
  before its draw, guest memory written by a resolve before a vertex fetch or a load (the existing memory fences'
  places).
- Cross-queue (the presenter, readbacks): events. CPU waits (fences the guest polls, occlusion results): shared events.

## Stages

Each stage keeps the game playable on the default path, and the new path is checked against the old by the regression
set below before the default moves.

0. **MetalFX on Metal 4** (done 2026-11-03): `metal_metal4`, `metal_fx4.h`.
1. **Split out the API-neutral part** of `metal_draw.mm`; Metal 3 path unchanged (same pictures, same bench).
2. **Metal 4 frame infrastructure** behind `metal_metal4_draws` (off while in development): queue, allocators per
   frame in flight, frame events, deferred release, residency sets, argument tables, the ring as the only constant
   path, commit feedback for GPU time and errors.
3. **Draws, passes, resolves, texture loads on Metal 4** with coarse barriers; presenter and MetalFX on the same
   queue. Goal: the same picture as Metal 3.
4. **Narrow the barriers** from the dependencies; group compute work; batch commits; decide the encoder thread's fate
   by measurement.
5. **Pipelines on `MTL4Compiler`**: flexible pipelines, archives, compiler tasks in place of our compile threads.
6. **View pool and attachment mapping** (pass merging), by measurement.
7. **Default to Metal 4** for the draws once the regression set passes; Metal 3 stays as `metal_metal4=false`.

## Regression set (every stage)

- Spawn picture: mean RGB against the reference of the same settings (colour grading canary), minimap stable over 10
  shots 150 ms apart (pass order), the pause menu (the flicker of 2026-11-03), lamp glows behind moving cars.
- MSAA 2x, MetalFX native and Performance, frame generation, HDR, `resolution_scale` 2.
- Race bench (`scripts/mac_race_bench.py --cool-to 1`) against the Metal 3 path in alternating runs: FPS, 1% low,
  hitches, GPU and command-thread time.
- Metal API validation (`MTL_DEBUG_LAYER=1`) and shader validation clean on a drive.

## Not in this plan

- **Ray tracing and the denoising upscaler** (`MTL4FXTemporalDenoisedScaler`): the M5 has hardware ray tracing, but
  the denoiser cleans noisy ray-traced lighting and needs normals, roughness and diffuse/specular albedo per pixel,
  which the game doesn't make. Ray-traced reflections or shadows would mean building acceleration structures from
  the game's draws every frame and writing new lighting: a research item of its own ([BACKLOG](BACKLOG.md)).

## State

| Stage | State |
|---|---|
| 0 MetalFX on Metal 4 | done 2026-11-03 |
| 1 encoding seam | done 2026-11-03: `metal_gpu.h` (GpuQueue, GpuCommands, GpuEncoder); every command buffer, encoder, binding and wait in `metal_draw.mm` goes through it; Metal 3 path unchanged (spawn 54.0/45.2/33.2) |
| 2-3 Metal 4 draws | done, on by default (`metal_metal4_draws`): the same picture as Metal 3 (spawn 53.9/45.1/33.1 and the night variant), API validation clean. Argument tables per command buffer, sized per stage; the residency set as the lifetime tracker (deferred release by the frame event); transient constants; one compute encoder between passes; MetalFX and frame generation in the same command buffer; events to the presenter's Metal 3 queue. The first stall (resources piling up in the set) was the set's own retain on top of ours. |
| 4 narrow barriers, CPU | done: a pass waits for earlier compute and copies (vertex and fragment) and earlier fragments (fragment only), the encoder after MetalFX for everything. Textures the draws make often (resolves, composites, loads) come from 256 MB heaps resident as a whole: the residency set is committed 0 times a frame in a race (was every frame, 4.9% of the command thread). Bindings: a table slot that already holds the binding is skipped, and a draw pass keeps the previous pass's bindings in the same command buffer (about 250 passes a second); redundant render and compute state calls are skipped; views are tracked through their texture; commits go to a serial queue of their own (`metal_metal4_submit_thread`: a commit with MetalFX runs its ML setup, an MPSGraph, on the committing thread). Race bench, MetalFX Performance: GPU 12.0 to 12.6 ms a frame against 15.0 to 16.2 on Metal 3; FPS within the runs' noise of Metal 3 (51.8/50.6 against 56.0/49.2, bench 20261103-205815) before the submit thread. With the submit thread, CPU parity: 49.8/51.2 FPS against 52.0/50.6 (bench 20261103-211832). Commits batched (`commit:count:`): 2.5 a frame, was 3.5. No encoder thread on Metal 4: Metal 3's (`metal_encoder_thread`, off) moved 6 ms a frame of calls off the command thread on this M5 Air and gained nothing (CPU and GPU share one power budget); Metal 4's encoder calls are about a sixth of that |
| 5 MTL4Compiler | done (`metal_metal4_pipelines`, on): `metal_pipelines4.h`, the draws' and fixed pipelines through `MTL4Compiler`, `MTL4Archive` generations with a sidecar index (a warm run writes nothing). Whole pipelines by default: flexible ones (`metal_metal4_flexible_pipelines`) cost 2 to 3 ms of CPU and 0.8 ms of GPU a frame (bench 20261103-213431). Cold 6.2 s, warm 45 ms (Metal 3 with Apple's cache: 47 ms), same picture. A Metal bug makes compiler tasks fault with a pipeline data set serializer: the builds are synchronous calls on GCD workers |
| 6 view pool, attachment mapping | attachment mapping dropped: no pipeline keys differ only by slot order (Xenos writes oC_i to slot i). View pool wired (`metal_texture_view_pool`, `metal_views4.h`): swizzle views are pool slots bound by resource ID, retired by serial; MetalFX and the swap get objects on demand. GPU phase times (`metal_gpu_phase_times`, `MTL4CounterHeap`) added |
| 7 default | done: the regression harness passes Metal 4 against Metal 3 in all eight rows (2026-11-03, two runs each): default, MetalFX native and Performance, frame generation, MSAA textures, HDR, resolution scale 2 (picture within 0.2 to 2.6% of pixels, mean RGB within 0.4; minimap and pause flicker as Metal 3), and the validation layer with 0 errors (only the known depth-clip "unused" notices). The spawn has two lighting variants (mean RGB 53.9/45.1/33.1 and 53.1/41.8/27.6, 3 apart in luma): the harness pairs shots by the closest means |
| 8 presenter | stays on its own Metal 3 queue, by measurement: the two cross-queue hops a frame (`WaitForMetal3`, `SignalMetal3`) are 0.1% of the command thread each, and the GPU is not the limit (10.7 to 11.6 ms of a 16 to 19 ms frame). Moving it means porting the ImGui drawer and frame generation's present thread to argument tables and residency for no measured gain; `waitForDrawable`/`signalDrawable` is the way if that changes |
| 9 shader validation with ray tracing | fixed 2026-11-04: with `metal_rt` on, Metal's shader validation (`MTL_SHADER_VALIDATION=1`) stopped the game at a commit (`MTL4GPUDebugCommandBuffer applyResidencySets`, a freed object). Every fourth frame the sweep took idle resources out of the residency set and let them go at once, but a removal counts only from the set's next commit, and commits already on their way read the set as it was. Evicted acceleration structures die there (textures mostly live on in caches), so ray tracing showed it. What leaves the set is now kept until the next sweep (`retired_`, 4 frames). Also under shader validation: the pipelines' lookup archives are left out (its compiler throws on `MTL4Archive` lookups, macOS 27.2). A drive with ray tracing, AO and sun shadows then ran clean under shader validation, and under API validation. |
