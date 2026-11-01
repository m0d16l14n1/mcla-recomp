# Metal backend

A native Metal backend for the ReXGlue SDK's Xbox 360 GPU emulation (Xenos), next to its Vulkan and Direct3D 12
ones, for macOS on Apple Silicon. It is an SDK patch, [`patches/rexglue-metal-backend.patch`](../patches/rexglue-metal-backend.patch),
written so that it can be offered upstream: nothing in it is specific to Midnight Club. Progress is tracked in
[BACKLOG.md](BACKLOG.md), phase 3.

```bash
bash scripts/play_mac.sh --mcla_gpu_backend=metal
```

## Why

Through MoltenVK the game is GPU-bound at native 720p on an M5: 15.7 FPS in free roam as it was, 19.6 with
`rexglue-vulkan-render-pass-breaks.patch`, 31.3 with anti-aliasing off. Apple's GPUs draw in tiles, and a render
pass that ends writes its attachments out of tile memory and the next one reads them back. The Vulkan backend was
written for desktop GPUs, where that costs next to nothing; it ends a render pass about 265 times a frame, and
MoltenVK must turn each into a Metal encoder boundary. A backend written for Metal can decide where its encoders
start and end, choose load and store actions per pass, use memoryless attachments, and use unified memory.

What milestone M0 measured with draws skipped (the game's own CPU side, on the same M5):

| | MoltenVK (Vulkan) | Metal M0 (nothing drawn) |
|---|---|---|
| Map zoom-out (the loading after Start) to free roam | 92 s | 7.4 and 9.5 s (two runs) |
| Free roam, swaps a second (capped at 30) | 16 to 20 | 30 |
| Free roam, guest draws and resolves a frame | — | about 4,900 and 54 |

So the CPU side has room for 30 FPS and more; the work is all in drawing those 4,900 draws efficiently.

## Decisions

**In the xenos plugin, as backend `metal`.** It shares everything above the host API with the other backends:
the command stream, the register file, shader microcode analysis, the common render target, texture and shared
memory caches, the primitive processor. Picked by name only (`--mcla_gpu_backend=metal`, the SDK's backend
`metal`); Vulkan stays the default until Metal draws as well as it does. Objective-C++ (`.mm`, ARC), no metal-cpp.

**Shaders: the SDK's SPIR-V translator, then SPIRV-Cross to MSL.** The same translator the Vulkan backend uses, and
the same SPIR-V to MSL step MoltenVK performs (SPIRV-Cross is already built in the SDK), which already draws this
game correctly. Not the route of [xenia-alloy](https://github.com/DarthMDev/xenia-alloy) and its upstream
[pull request](https://github.com/xenia-project/xenia/pull/2332) (DXBC to DXIL with Microsoft's DirectX Shader
Compiler, then Apple's Metal Shader Converter): two large dependencies, one of them Apple's closed converter, and
its author's own words: "there's a big performance penalty". Pipelines go into `MTLBinaryArchive`s, which take the
place of the shader pack.

**Tile-based rules, from the start:**
- One render encoder per run of draws to the same guest render targets. Shared memory uploads, texture loads and
  the resolves' copies go into blit or compute encoders *before* it, planned when the run is known (what
  `rexglue-vulkan-hoist-shared-memory-uploads.patch` and `rexglue-vulkan-render-pass-breaks.patch` do after the
  fact on Vulkan).
- Load actions from what the guest does: `DontCare` when the run begins with a clear or covers the target, `Load`
  only otherwise; store actions `DontCare` for attachments nothing reads later (depth after a scene, MSAA samples
  after a resolve: `StoreAndMultisampleResolve`).
- Memoryless textures for MSAA and depth that live only inside a pass.
- The 512 MB shared memory as one `MTLStorageModeShared` buffer: unified memory makes uploads cheap copies, and
  later direct writes where no GPU work in flight reads the range.

**Reference, not a fork:** xenia-alloy's Metal backend (BSD-3, Xenia Canary based, about 35,000 lines; a local
read-only copy goes in `third_party/xenia-alloy/`, gitignored) is consulted for Metal specifics (formats, sample
positions, the EDRAM layout in MSL). Code taken from it keeps its BSD notice and is listed in
`THIRD-PARTY-NOTICES.md`.

## Milestones

| | What | State |
|---|---|---|
| M0 | Provider, presenter (CAMetalLayer, letterboxed bilinear guest output, the presenter's 3-image mailbox), graphics system, a command processor that runs the whole command stream and skips draws and resolves; game runs start to free roam | done 2026-10-31 |
| M1 | First picture: shared memory buffer, primitive processor, SPIR-V to MSL pipelines, host render targets without MSAA and without EDRAM transfers, resolves to memory, texture loads for the common formats, the swap from the front buffer | doing: **the first picture, 2026-11-01**: the title screen and free roam draw (below), 28 to 30 FPS in free roam, then 45 to 50 uncapped (MoltenVK: 19.6) |
| M2 | Correct picture: EDRAM ownership transfers, MSAA 2x/4x, float24 depth, every texture format, memexport, occlusion queries, gamma ramp | todo |
| M3 | Fast: the encoder planning above, binary archives, frame pacing with `CAMetalDisplayLink`, MetalFX upscaling | todo |
| M4 | The rest: the immediate drawer (ImGui overlays, the pause menu's settings), guest output captures (`dev_pad`'s `shot`), EDR (HDR) | todo |

### M1 so far (2026-10-31 and 2026-11-01)

**The shader path works for the whole game so far.** Each draw's vertex and pixel shader, with the modification
the Vulkan backend would choose for it, goes through the SDK's translator to SPIR-V, SPIRV-Cross to MSL and Metal's
compiler (asynchronous, `MTLMathModeSafe`, MSL 3.0) in `metal_shader_translator.cpp` and `metal_shaders.mm`. Four
runs from start to free roam: 352, 480, 375 and 346 translations, **none failed** at any of the three steps.
Translation takes 1.6 to 2.4 ms a shader on the command processor's thread; Metal's compile 0.7 to 2.4 ms a shader
once Apple's per-app cache has them (163 ms of queued wall time on a first run, with 350 at once). The libraries are
kept by translation, for the pipelines. `--metal_shader_dump_dir=<folder>` writes the MSL of any that fail (and of
all of them with `--metal_shader_dump_all=true`). The translator's headers bring Vulkan's C++ bindings, which do not
compile as Objective-C++, so the translation is a C++ unit behind a header without them.

**Shared memory needs no copies on Apple Silicon.** `metal_shared_memory_zero_copy` (default on) makes the guest's
512 MB of physical memory a Metal buffer with `newBufferWithBytesNoCopy`: instantly, as it is one page-aligned
mapping. In free roam the GPU read back the microcode of all 436 shaders loaded so far (236 KB in 436 places,
written by the game after the buffer was made) byte for byte as the CPU sees it. So the GPU can read the guest's
vertices, indices and constants where the game wrote them: no uploads, no write watches for buffers, none of the
render pass breaks they cost through Vulkan (about 85 a frame after `rexglue-vulkan-render-pass-breaks.patch`).
Still to check: GPU writes (resolves, memexport) seen by the CPU, and how the command processor running behind the
game interacts with buffers the game rewrites (the Vulkan path copies at the draw; here the GPU reads at execution).

**The draw path** (`metal_draw.mm`): render pipelines and depth-stencil states from the guest's registers,
the SDK's primitive processor, the guest's vertices and indices read from a per-draw snapshot of guest memory
(`metal_snapshot_vertices`, default on), resolves by a compute kernel that writes guest memory in the guest's tiled
layout, textures loaded from guest memory on the CPU, and the front buffer presented through the same texture
lookup. Every guest draw call becomes a Metal draw.

**Speed, first pass (2026-11-01): 3.5 to 4.7 FPS in free roam, now 28 to 30** (33 to 35 ms a frame, the GPU busy
17 to 21 ms of it; the stats line `Metal frame time` every 150 frames). The game's 30 FPS cap (`mcla_fps`, 0 for
uncapped) is not what holds it: uncapped, free roam ran at 27 to 30 FPS too, and the title screen (about 7,500
draws a frame) at 19 to 21. Measured with `sample` on the command processor's thread:
it waited for the GPU after every resolve (23%), untiled textures on the CPU (16%) and made an `MTLBuffer` for
every constant upload, five a stage a draw (13%). Now textures are untiled on the GPU by a compute kernel reading
guest memory directly (the no-copy buffer) into a staging buffer, then blitted, so it is ordered after the
resolves that wrote that memory and nothing on the CPU needs a resolve's result; constants go inline with
`setVertexBytes`/`setFragmentBytes` (all are 4 KB or less); and two frames are in flight, each with its own
snapshot buffer (`EndFrame` waits only for the frame before last; the front buffer's copy no longer waited for the
whole frame either, which had hidden the overlap at first). A texture is cached by its memory and layout and seen
through a view per swizzle, so the post-processing passes that sample the scene with different sampler settings
share one load. Tried and dropped: reusing a frame's vertex copies by the write watches' page validity instead of
a hash of the data, 23 to 24 FPS against 28 to 30 in the same run (watching every vertex range costs more than
hashing it).

**Second pass (2026-11-01): 25 to 26 ms a frame, then about 20 (45 to 50 FPS uncapped)**, all of it on the command
processor's CPU time (GPU busy 14 to 17 ms): the pipeline descriptor was built for every draw even when the pipeline
was cached (9% of the thread); a resolve looked at every cached texture to drop those it wrote over (10%; now
an index by address) and dropped a texture's swizzle views by scanning them all; and the vertex snapshots hashed
154 MB a frame to copy 20, the same few MB of static geometry again at every draw that used it. A range of 64 KB
or more is now hashed once a frame (`metal_snapshot_trust_size`; `0xFFFFFFFF` checks every draw as before),
small ranges, where dynamic vertices are, still at every draw; checked with a diagnostic that hashed the trusted
ranges anyway: no large range changed within a frame in free roam. The stats line also gives the texture loads
and the snapshot megabytes a frame (about 34 loads: surfaces the game resolves every frame and samples in another
format or size than the resolve wrote, read back from memory). The GPU reads textures from guest memory when it runs the frame, up to a frame after the game wrote
them; the vertices and indices are copied at the draw (`metal_snapshot_vertices`).

**Open: the car falls through the city** (2026-11-01, parked). On Metal the player's car sometimes loses its collision and falls through the road, uncapped in nearly every drive of the test route, capped in about half. It is not anything the GPU writes: it happens with no GPU work at all when the command processor is made to pause briefly at resolves, fences or draws, and never when it is always ahead or stalls for long. A race between the game's own threads, then, that the command processor's timing exposes. The unattended test (a recorded drive replayed by the dev pad: `launcher/dev/drive-test/route-test.sh`), every result and the diagnostic switches are in `launcher/dev/metal-car-falls-2026-11-01.md`.

**EDRAM is kept in samples.** Free roam first showed only the HUD over a flat colour: the scene's draws landed, but
always failed the depth and stencil tests. The game clears its 2x MSAA 1280-wide scene by drawing over the same
EDRAM tiles as a 4x MSAA surface of half the pitch (640), with a scissor 8192 rows high. Host render targets were
keyed by pixel width and the draw's height, so that clear went to another texture and the scene's depth and stencil
were never cleared. Now each surface is one texture per EDRAM base, format and width in *samples* (MSAA 2x drawn as
1x2 supersampling, 4x as 2x2), as tall as the EDRAM left after its base; the two views of the same tiles are one
texture, and resolves average the samples (or take the one the guest selects). The Metal command processor also
had never set the EDRAM tile count (0, where the other backends set it from their render target caches); it is the
console's 2048 now.

**A resolve's texture stands in only for exactly what it wrote.** The 720p scene does not fit in EDRAM with 2x
MSAA, so the game draws it in two tiles (predicated tiling: 1280x512, then 1280x208 with the window offset at
-512) and resolves each to its rows of one surface; it also reuses the same memory for depth copies within the
frame. A texture fetch now uses a resolve's own texture only when its address, size and format match that resolve;
otherwise it loads from guest memory, which the resolves write (depth resolves too now: 24-bit unorm or float24
over a zero stencil). A resolve drops the cached textures and resolve textures in the memory it writes.

**Fixes of 2026-11-01, the picture now matching MoltenVK at the spawn point (39 to 40 FPS uncapped, unchanged):**

- *Shadows.* The shadow maps were right all along (four 640x640 cascades of real depth in a 1280x1280 k_24_8
  atlas, about 0.0006 to 0.0016). The scene's shadow pass reads the atlas through the fetch constant's swizzle,
  and a texture view of a one-channel format gave 0 or 1 for G, B and A. Texture views now repeat the last channel
  of the format, like the Vulkan backend's host swizzles: RRRR for one channel (k_24_8, k_32_FLOAT, k_8, k_16...),
  RGGG for two (k_8_8, k_16_16, DXN...). Shadows and most of the warm colour grading came back with it.
- *16-bit packed textures.* k_1_5_5_5, k_5_6_5, k_6_5_5 and k_4_4_4_4 are expanded to RGBA8 by the load kernel
  (red in the low bits; the formats without alpha repeat blue there).
- *EDRAM shared between targets.* Host targets are one texture per EDRAM base, format and width, while Xenos has
  one EDRAM. The minimap's grey blocks are a depth clear (depth 0x006666 and its stencil) into the tiles of the
  color target at the same base, read back as RGBA8 (0x66 grey, alpha 0). Now every EDRAM tile has a version and
  its last writer; a target bound for a pass, or resolved, takes over the tiles another target wrote since it last
  had them, as raw 32 bits per sample (color to color, depth to color, color to depth, depth to depth; 8_8_8_8,
  2_10_10_10, 7e3, 16_16, 16_16_FLOAT, 32_FLOAT, D24S8, D24FS8; 64bpp formats not yet) with a small render pass.
  Screen-space rectangle draws (clears by drawing) are bounded by their vertices, not the window scissor, or a clear
  would claim all EDRAM after its base (that briefly made the cars glow). About 60 transfers a frame, no measurable
  cost. `--metal_edram_transfers=false` turns it off.
- *Depth clip:* clamp when PA_CL_CLIP_CNTL disables clipping. *Gamma ramp:* the swap applies the guest's 256-entry
  or PWL ramp (`metal_gamma_ramp`).

**Shader storage and warm-up (2026-11-01).** Translating a guest shader (microcode to SPIR-V to MSL) takes about
1.2 to 1.9 ms on the command processor thread, about 460 of them from boot to a drive: stutters whenever new ones
appear. Metal's own compile is asynchronous and cached by macOS (0.1 ms on later runs), render pipelines take about
0.1 ms. Each new translation's shader microcode and modification now go to
`<cache>/shaders/metal/<title>.mcla-metal-shaders` (append-only; a torn last record is cut off), and before the title
starts the next run translates all of them on worker threads (a shader's modifications on one thread, one translator
each): 339 translations in about 105 ms on 9 threads, then 14 new ones in the drive instead of 339.
`--metal_shader_storage=false` turns it off.

**Third pass (2026-11-01): about +35% in free roam** (paired runs, all of this against the old settings: 41.7
against 30.5 FPS, then 27.0 against 20.3; uncapped). `sample` on a running free roam showed two threads saturated: the
command processor (91% busy) and the game's render thread, spinning in `D3DDevice_BlockOnFence` for it; the GPU was
busy 22 to 25 ms of a frame and the command processor never waited for it. On this Mac (an M5: four performance
cores, six efficiency cores, with a VM and WindowServer taking a share) both matter more than they would on an idle
machine. The changes:

- *Texture write watches* (`metal_texture_watches`). Every texture used in a frame was hashed once in that frame,
  118 MB a frame, 13% of the thread. A texture loaded from guest memory now has a write watch on its pages
  (`SharedMemory::WatchMemoryRange`, one per texture key, then `RequestRange` to protect the pages, then the hash, in
  that order so no write is missed) and is hashed again only after a CPU write to them. A texture loaded anyway
  (new, or dropped by a resolve over its memory) isn't hashed at all: its hash would only be compared after a write,
  and an unknown one then reloads it. 0 MB of textures hashed a frame, about 1,150 checks skipped.
- *Large vertex ranges copied without a hash.* The hash of a range of 64 KB or more was never compared (the snapshot
  map starts empty every frame and later uses in the frame return before hashing).
- *Inline constants not resent.* `Bind` sent every constant block of both stages at every draw (up to 4 KB each,
  copied into the command buffer) and zero-filled a 4 KB array first; a block the encoder already holds is skipped.
- *Texture load staging* from one 64 MB buffer per frame slot instead of a new `MTLBuffer` (an IOKit call) for every
  load, and the load kernel copies 32-bit words with the endian swap done in the word, not one byte at a time.
- *The command processor thread at the user-interactive QoS class* (`metal_cp_qos`, now 4 by default; it was a
  diagnostic): at the default class it shares the performance cores with everything else and moves to the
  efficiency cores under load. About 10% in paired runs.
- *The fence wait sleeps* (`mcla_fence_sleep_us`, 100 by default, in `src/render_perf.cpp`): the game's fence poll
  (hooked by `mcla_fence_spin`) yielded only every 64th poll, so the render thread took a performance core from the
  command processor it waits for. A wait longer than 256 polls now sleeps between polls. The thread went from 96%
  busy to 30%.
- *Render passes only as tall as their draws* (`metal_pass_rows`): host targets are as tall as the EDRAM after
  their base (8,192 rows for some), and every pass loaded and stored the whole attachment; a pass now sets
  `renderTargetHeight` to the rows its draws reach (rounded up to 32, restarted taller if a later draw needs more),
  EDRAM transfer passes to the rows they copy.

The stats line now also gives the megabytes of textures hashed and the checks the watches skipped, and a second
line the command processor thread's own CPU time a frame (`CLOCK_THREAD_CPUTIME_ID`). On a busy machine FPS swings
by a third between identical runs, as the threads land on efficiency or performance cores, so changes are measured
in alternating pairs. `--metal_debug_profile=true` in a dumped frame gives each pass and resolve a command buffer
of its own with its GPU time logged, but on a shared GPU those times include other processes' work (a one-draw
64x64 pass showed 4 ms): good for finding passes, not for timing them. Still on the command processor: the small
vertex ranges (46 MB hashed and 20 MB copied a frame, about 15% of it), texture objects created for every resolve
(about 6%), and `std::string` keys for the texture, sampler and pipeline maps. The car-falls route test after
these changes: 0 of 240 samples under the road in 3 of 3 capped drives.

**Fourth pass (2026-11-01): up to 44 to 49 FPS in free roam, now GPU-bound when the Mac is quiet.**

- *Vertex ranges trusted within a frame* (`metal_snapshot_trust_size` now 0). With every range checked at every
  draw, no vertex or index range changed between two draws of a frame, in boot, menus, free roam or a drive
  (the stats line counts them when `metal_snapshot_trust_size=0xFFFFFFFF`). Each range is now copied at its first
  draw in a frame and reused: no hashing (46 MB a frame before). +15 to 18% in paired runs.
- *Persistent vertex copies* (`metal_persistent_vertex_size`, 16 KB). The snapshots are one buffer: a ring per
  frame slot and a 192 MB persistent region. A range of 16 KB or more is copied there once, with a write watch,
  and used from there in later frames until the CPU writes its pages; then it moves to a new copy (frames in
  flight keep the old one), and a range written three times goes back to the per-frame copies. Copies went from
  20 to 6 MB a frame, about 290 ranges a frame kept. +13 to 35% in paired runs.
- *Texture lookups* go through a 1,024-entry cache keyed by the raw fetch constant, valid until textures or
  resolves change (each draw asked twice, with a string key and three to four hash-map lookups each).
- *Resolve clears clear only the resolved rectangle* (a scissored draw in a pass limited to the resolve's rows),
  not the whole host target: a 320x7296 target was cleared 25 times a frame. This was also a correctness gap.
- *Draws join the open pass* (`metal_pass_merge`) when it already has their targets (a draw without depth, or
  with fewer colors, no longer ends the scene's pass): 84 to 70 passes a frame. A draw any of whose rows another
  target wrote since now starts a pass (which takes them over) instead of drawing over stale tiles; before, only
  the first draw of a pass had its rows synchronized.

**Where the GPU time goes**, from a Metal System Trace (`xcrun xctrace record --template 'Metal System Trace'
--attach <pid>`, with `--metal_debug_labels=true` so encoders have names; `out/research/parse_gputrace.py` sums
the exported `metal-gpu-intervals` table by label), per frame before the clears and pass merging: render passes
12.9 ms of fragment and 5.8 of vertex work (the scene's 1280x1024 pass 5.2 ms), resolves 3.1, EDRAM transfers
2.9, texture loads 2.4 (a 1280x720 surface the game assembles from resolves, loaded again about 5 times a frame),
resolve clears 2.4. Anti-aliasing off saves about 5 ms of GPU time (MSAA 2x is drawn as 1x2 supersampling).
The Metal HUD, if `MetalForceHudEnabled` is set for the whole system, is loaded into the game whatever
`MTL_HUD_ENABLED` says and costs the command processor 4 to 5%.

**Diagnosis:** `--metal_debug_dir=<folder>` with `--metal_debug_frame=<n>`, or `set metal_debug_capture true` from a
pad script for the next frame, logs that frame's passes (render targets, MSAA, viewport, scissor, window offset),
resolves and clears, the textures of its full-screen draws, and writes each resolve as a PPM. With it:
`--metal_debug_all_draws=true` logs every draw (blend, color mask, depth and viewport state, and the vertices of
small draws), `--metal_debug_depth_dumps=1` writes the depth target after each depth-ALWAYS draw and before each
depth resolve (PGM, plus raw floats), `--metal_debug_rt_base=<tiles>` writes color target 0 after every draw into
that EDRAM base, and the EDRAM transfers are logged.

Shadows work (the title's plaza scene shows the palm trees' shadows). Still to do in M1: the stencil in depth resolves,
clears of only the resolved rectangle (the whole surface is cleared), EDRAM transfers of 64bpp formats, and pixel positions in shaders drawn with MSAA (the
shaders are translated for 1x).

Known gaps in M0: no captures (`shot` in a pad script answers "no guest output yet"), no ImGui overlays (the
provider has no immediate drawer), and the picture is a placeholder that pulses with the swaps.
