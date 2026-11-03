# Metal backend

A native Metal backend for the ReXGlue SDK's Xbox 360 GPU emulation (Xenos), next to its Vulkan and Direct3D 12
ones, for macOS on Apple Silicon. It is an SDK patch, [`patches/rexglue-metal-backend.patch`](../patches/rexglue-metal-backend.patch),
written so that it can be offered upstream: nothing in it is specific to Midnight Club. Progress is tracked in
[BACKLOG.md](BACKLOG.md), phase 3.

```bash
bash scripts/play_mac.sh --mcla_gpu_backend=metal
bash scripts/play_mac.sh --mcla_gpu_backend=metal --mcla_anti_aliasing=fsr --mcla_upscaling=quality   # MetalFX
```

## Where it stands (2026-11-01)

Free roam at native 720p on an M5 (4 performance and 6 efficiency cores), uncapped (`--mcla_fps=0`), on a cool
Mac with a virtual machine running beside it; MoltenVK for comparison:

| Anti-aliasing | MoltenVK | Metal |
|---|---|---|
| MSAA 2x (the game's default; on Metal drawn as 1x2 supersampling) | 19.6 FPS | 62 to 63 FPS |
| Off | 31.3 FPS | about 80 FPS |
| MetalFX temporal AA at 720p (`--mcla_anti_aliasing=fsr`) | — | about 77 FPS |
| MetalFX upscaling, Quality, 853x480 to 720p (`--mcla_upscaling=quality`) | — | 86 FPS |
| MetalFX upscaling, Performance, 640x360 to 720p (`--mcla_upscaling=performance`) | — | 91 to 93 FPS; 94 with the tenth pass |

The picture at the spawn point matches MoltenVK's (shadows, colour grading, minimap, HUD), and the game plays
from boot to free roam and drives. A warm or busy Mac loses up to a third of these frame rates. At MetalFX
Performance the GPU is the limit again: the GPU command thread uses 7.4 ms a frame, 3.4 of it waiting for the GPU.
The rows above are before the tenth pass (the 4x reflections at one sample a pixel, now the default), which adds
5% with MSAA 2x and 16% at Performance on the same Mac in the same hour. What is still missing: 3D textures (none
sampled in free roam, drives or races so far) and frame pacing with `CAMetalDisplayLink` (put off; see
the tenth pass). The car falling through the road ([BACKLOG](BACKLOG.md) 27) has not come back since the speed
passes, in the route tests or in play, so it is no longer a known issue. The passes below, first to twentieth, record how it got here; the nineteenth has a race benchmark of every mode on a warm Mac, the twentieth the occlusion queries (the sun's glare). HDR output (EDR) came with the fourteenth.

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
its author's own words: "there's a big performance penalty". Pipelines were to go into `MTLBinaryArchive`s in place
of the shader pack; deferred, as the shader storage's warm-up and Apple's per-app shader cache leave little to gain
(a shader compiles in 0.1 ms on average).

**Tile-based rules, from the start:**
- One render encoder per run of draws to the same guest render targets. Shared memory uploads, texture loads and
  the resolves' copies go into blit or compute encoders *before* it, planned when the run is known (what
  `rexglue-vulkan-hoist-shared-memory-uploads.patch` and `rexglue-vulkan-render-pass-breaks.patch` do after the
  fact on Vulkan).
- Load actions from what the guest does: `DontCare` when the run begins with a clear or covers the target, `Load`
  only otherwise; store actions `DontCare` for attachments nothing reads later (depth after a scene, MSAA samples
  after a resolve: `StoreAndMultisampleResolve`).
- Memoryless textures for MSAA and depth that live only inside a pass. (In practice: MSAA is drawn as supersampling,
  since the EDRAM emulation loads and stores its targets in every pass; real multisample textures, tried as
  `metal_msaa`, ran at half the frame rate.)
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
| M1 | First picture: shared memory buffer, primitive processor, SPIR-V to MSL pipelines, host render targets without MSAA and without EDRAM transfers, resolves to memory, texture loads for the common formats, the swap from the front buffer | done 2026-11-01 (the first picture, then 28 to 30 FPS in free roam) |
| M2 | Correct picture: EDRAM ownership transfers, MSAA 2x/4x, float24 depth, every texture format, memexport, occlusion queries, gamma ramp | mostly done: EDRAM transfers between formats and depth and color, MSAA as supersampling (real MSAA as an option), float24 depth (D24FS8), the gamma ramp, the spawn point matching MoltenVK, occlusion queries (twentieth pass). To do: EDRAM transfers of 64bpp formats, 3D textures |
| M3 | Fast: the encoder planning above, binary archives, frame pacing with `CAMetalDisplayLink`, MetalFX upscaling | mostly done: nine speed passes (below), MetalFX temporal AA and upscaling; binary archives deferred. To do: `CAMetalDisplayLink` pacing |
| M4 | The rest: the immediate drawer (ImGui overlays), guest output captures (`dev_pad`'s `shot`), EDR (HDR) | done (EDR in the fourteenth pass) |

### M1 to M3, as it went (2026-10-31 and 2026-11-01)

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

**The car fell through the city** (2026-11-01; not seen since the speed passes, closed for now). On Metal the player's car sometimes loses its collision and falls through the road, uncapped in nearly every drive of the test route, capped in about half. It is not anything the GPU writes: it happens with no GPU work at all when the command processor is made to pause briefly at resolves, fences or draws, and never when it is always ahead or stalls for long. A race between the game's own threads, then, that the command processor's timing exposes. The unattended test (a recorded drive replayed by the dev pad: `launcher/dev/drive-test/route-test.sh`), every result and the diagnostic switches are in `launcher/dev/metal-car-falls-2026-11-01.md`.

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
  and an unknown one then reloads it. 0 MB of textures hashed a frame, about 1,150 checks skipped. (Since the thirteenth
  pass only tiled textures are watched; linear ones, the movie planes among them, are hashed every frame.)
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
- *Persistent vertex copies* (`metal_persistent_vertex_size`, 16 KB then; 1 KB since the twentieth pass). The snapshots are one buffer: a ring per
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

**Fifth pass (2026-11-01): about 60 FPS in free roam when the Mac is cool** (57 to 60 in single runs after a pause;
GPU time about 17 ms a frame, from 19 to 20).

- *Surfaces made from resolves* (`metal_compose_resolves`). The game draws the 720p scene in two EDRAM tiles and
  resolves each to its rows of one surface (512 and 208 rows), then samples the whole surface. Such a texture was
  untiled from guest memory every time a resolve had touched it, about 30 loads a frame. Now, when resolves wrote
  pieces of it (each starting a whole number of 32-row macro tile rows in, with its width, pitch and format), it is
  made by copying the pieces' textures; rows no piece covers (the surface is also read while only its top tile is
  resolved, its other rows holding an older resolve, as on the console) are untiled from memory alone
  (`metal_compose_gaps`). 12 real loads a frame are left, and 18 surfaces made from resolves. Resolves now write
  whole words where a texel lies inside the destination.
- *EDRAM transfers drawn in the draw's pass* (`metal_transfers_in_pass`). A transfer was a render pass of its own,
  loading and storing its target from row 0 to its last row, before the draw's pass loaded it again. Now the
  transfers a pass needs are drawn first in that pass, into their attachment only (pipelines for the pass's
  attachment formats; shaders `transfer_color_from_*_N` for color attachment N). Transfers that read a target of
  the pass, or reach past its rows, keep their own passes. 38 of 50 a frame are in a draw's pass; the transfers'
  GPU time went from about 3 ms to 0.6 (the passes gained about 0.3).
- *Rectangle draws claim the rows they cover.* The rows of a screen-space draw (a clear drawn as a rectangle) are
  bounded by its vertices; the bound took one row more than `ceil(bottom)`, which for a 512-row depth clear reached
  into the next 16-row EDRAM tile, owned by the color target placed after it. Each such draw then handed the tile
  back and forth with a transfer and a new pass. Transfers 65 to 50 a frame, passes 70 to 58, passes restarted for
  transfers 11 to 0.
- *Pass checks without walking the EDRAM.* A draw that stays in the open pass checks that no other target wrote
  its rows since; that walked every EDRAM tile the rows cover, for each attachment (2 million tiles a frame, 15% of
  the command thread). Each target now keeps the range other targets may have written since it last took its
  tiles over, and the last range it found current; most checks are a comparison.
- *Resolve textures from a pool* (`metal_texture_pool`). About 50 resolve destinations a frame were each made and
  freed (an IOKit call apiece on the command thread). Freed ones go to a pool and are taken again when the pool
  holds the last reference (no cached view of them, no command buffer using them still running).

**Sixth pass (2026-11-01): the command thread, for a warm Mac.** On a cool Mac the GPU is the limit (the command
thread waits for it 3 to 5 ms a frame); once the Mac is warm, macOS reports heavy thermal pressure
(`notifyutil -g com.apple.system.thermalpressurelevel` gives 2, which `scripts/mac_bench.sh` now prints with each
result) and the same work on the command thread takes about three times as long, so it sets the frame rate.

- *Texture lookups* (`metal_fast_texture_frames`): the lookup cache was emptied by every resolve and every frame,
  and with 1,024 direct-mapped entries for about 2,000 fetch constants a frame it also lost a fifth of its
  lookups to collisions: 2,270 lookups a frame took the slow path (string keys, several hash maps). Now a resolve
  drops only the lookups of textures in its memory, an entry stays good across frames while the texture's write
  watch has seen no CPU write, and the cache has 8,192 entries in sets of four: about 180 slow lookups a frame.
  The textures a draw looks up before its pass (for loads) are the ones `Bind` binds, not looked up again.
- *Bindings*: textures and samplers already bound in the encoder are not set again; the float, bool and fetch
  constants are not gathered and compared when no register of theirs was written since the encoder got them
  (`metal_constant_generations`): the Metal command processor now writes register blocks in bulk, as the D3D12
  one does (`gpu_regwrite_bulk`), and counts writes to each constant block.
- *Resolves*: the scan for cached lookups over a resolved range reads a compact array, and the texture range index
  keeps lengths, so textures outside the range cost no hash lookup. `resolved_` is ordered, so making a surface
  from resolves looks only at resolves inside it.

In a paired run with the Mac hot, the command thread's busy time was 25.7 ms a frame against 26.4 with these off;
cool, it is about 8 ms busy of a 17 ms frame. Anti-aliasing off (`--mcla_anti_aliasing=off`): 80.8 FPS on a cool
Mac, GPU 13.6 ms a frame, since the game then draws its scene in one EDRAM tile (fewer passes, resolves and
transfers) and shades half the samples. Real MSAA is deferred: EDRAM is kept in sample-space textures that a
multisampled Metal texture cannot alias, so it needs either a new EDRAM model or conversions at every scene pass.

How these were measured matters: this Mac heats up, and in a series of back-to-back benchmark runs each run is
slower than the one before (the command thread's CPU time per frame goes from about 13 ms to 25 for the same
build), so a variant always run first in its pair wins. Use a pause of a couple of minutes between runs, or
A-B-B-A ordering, and the GPU time from a trace.

**Where the GPU time goes**, from a Metal System Trace (`xcrun xctrace record --template 'Metal System Trace'
--attach <pid>`, with `--metal_debug_labels=true` so encoders have names; `out/research/parse_gputrace.py` sums
the exported `metal-gpu-intervals` table by label), per frame before the clears and pass merging: render passes
12.9 ms of fragment and 5.8 of vertex work (the scene's 1280x1024 pass 5.2 ms), resolves 3.1, EDRAM transfers
2.9, texture loads 2.4 (a 1280x720 surface the game assembles from resolves, loaded again about 5 times a frame),
resolve clears 2.4. After the fifth pass: render passes 14.8 ms of fragment and 5.6 of vertex work (the scene's
1280x1024 pass 5.3 and 1.6), resolves 2.3, surfaces made from resolves 2.5 (copies 1.4, rows from memory 1.1),
resolve clears 0.9, texture loads 0.7, transfers in passes of their own 0.6. These sum to more than the frame,
since the stages of different passes overlap. Anti-aliasing off saves about 5 ms of GPU time (MSAA 2x is drawn as
1x2 supersampling).
**Seventh pass (2026-11-01): about 62 to 63 FPS on a cool Mac** (with a UTM virtual machine running beside it;
GPU busy about 17.8 ms a frame, the command thread 11 ms of CPU time of which 4.5 waiting for the GPU).

- *Resolve clears in the next pass* (`metal_clears_in_pass`): the clear after a resolve was a render pass of its
  own that loaded and stored its target from the first row to the last cleared one. It now waits for the next
  pass on that target and is drawn first in it (scissored), or becomes that pass's load action when it covers the
  pass; it is drawn on its own only before something reads the target first (a resolve, an EDRAM transfer from
  it) or when it is wider than the pass. 28 clears a frame move into passes, so 28 fewer encoders (each costs
  the command thread, more so with the Metal HUD's per-encoder hooks).
- *Shadow atlas from its resolves* (`metal_compose_columns`): the 1280x1280 shadow map is four 640x640 depth
  resolves side by side. Each resolve's memory range covers whole 32-row macro tile rows, so every resolve
  dropped its neighbour and the atlas was untiled from memory 2.5 times a frame (0.5 ms). A resolve now keeps
  the earlier ones whose 32x32 tiles it does not touch (`TilesDisjoint`: in the tiled layout a piece is a set of
  tiles `base + row * P + column`), and `ComposeResolves` places pieces at their tile column as well as their row
  (rows no piece covers across the whole width are still loaded from memory). Texture loads 12 to 10 a frame.
- *Command thread*: the five hash maps keyed by a texture's string key (texture, hash, frame checked, range,
  watch) are one entry per key; the texture signs of the system constants are made for the fetch constants the
  draw's shaders sample, not for all 32 (the game writes fetch constants nearly every draw, so caching them by
  generation did not help); the system constants are built into a kept buffer; dropping the fast texture
  lookups a resolve covers compares 16 entries at a time without branches. The slow texture path went from 12.5%
  to 8.6% of the thread's busy time, the whole texture lookup from 17% to 11%, and the scan at resolves
  (`InvalidateRange`, 4.4%) left the profile.

A-B-A with the shadow atlas composition off in the middle (150 s pauses): 62.7, 62.5, 63.1 FPS; the command
thread 11.1 against 11.7 ms. The clears in the next pass measured the same as without (59.7 against 59.9 FPS):
the GPU is the limit, and the clears were small.

Where the scene's passes break, from the trace and a debug frame: the 1280x1024 scene target (RGBA16F and
D32S8) is opened about 11 times a frame. Resolves need it closed (they are compute work reading it), and so do
the surfaces made from resolves and texture loads a draw needs while the pass is open (compute and blit work
cannot run inside a render pass), which split the post-processing passes. The remaining GPU work, by size:
render passes (16 ms of fragment and 5.7 of vertex work a frame on this run), resolves 2.9, composed surfaces
about 2.4 (rows loaded from memory 1.1: during the scene's top tile the game reads the whole 1280x720 surface,
whose other rows hold an earlier depth resolve's bits, which only a load from memory reproduces), texture loads
0.7, EDRAM transfers 0.6.

The Metal HUD, if `MetalForceHudEnabled` is set for the whole system, is loaded into the game whatever
`MTL_HUD_ENABLED` says and costs the command processor 4 to 5%.

**Eighth pass (2026-11-01): MetalFX temporal anti-aliasing, about 76 FPS** (`--mcla_anti_aliasing=fsr`, which
on Metal means MetalFX; MSAA 2x stays the default).

- *MetalFX temporal AA*: the SDK's temporal AA path (`temporal_aa.cpp`, written for FSR 3.1 on D3D12 and Vulkan)
  picks the scene's draws and gives a sub-pixel jitter each frame; the Metal backend applies the jitter to the
  viewport before the system constants are built (about 3,100 of 3,100 scene draws a frame), and at the end of
  the scene runs `TaaRun`: a compute kernel makes motion vectors from depth and the previous and current camera
  (`taa_motion_vectors`), the depth is copied to Depth32Float, an `MTLFXTemporalScaler` at native size (input
  and output 1280x720, auto exposure, reversed depth) blends the frame with its history, and the result is
  copied back into the scene's target. The scene is then drawn without supersampling, so: **76.5 FPS against
  62.6 with MSAA 2x** (+22%), the command thread 8 against 10.5 ms. The still picture matches, and in motion
  there are no trails; objects that move with the camera (the player's car) are a little softer than with MSAA,
  since the motion vectors know only the camera's motion. The jitter keeps FSR's sign convention
  (`temporal_aa_flip_jitter` flips it). Upscaling from below native: the ninth pass, below.
- *Texture work before the pass* (`metal_texture_work_before_pass`): a texture load, a surface made from
  resolves or the TAA run that a draw needs while a pass is open used to end the pass (compute and blit work
  cannot run in a render pass) and reopen it, which stores and reloads its targets. The backend now remembers,
  per pass of the frame, which passes were split that way, and at the same pass of the next frame opens a
  separate command buffer before the pass; texture work for that pass is encoded there and committed first.
  About 39 loads a frame then run before their pass, and about 5 passes a frame are still ended for texture
  work. 62.5 against 61.6 FPS. A first version also put a
  later pass's work in an earlier pass's buffer, ahead of the resolves it reads: the minimap showed stale tiles
  every other frame. Only the pass split off just now takes work into its buffer.
- *Shader math* (`metal_shader_math`: 0 safe, the default; 1 relaxed; 2 fast): relaxed and fast math in the
  Metal compiler shift the colour grading (the sky and shadows go pink), and relaxed gained only 1% (68.1
  against 67.3 FPS). Kept safe.
- The stats line counts passes ended for texture work (`ended for texture loads`) and loads encoded before
  their pass (`loads before their pass`).

**Ninth pass (2026-11-01): MetalFX upscaling, 86 to 91 FPS** (`--mcla_anti_aliasing=fsr` with
`--mcla_upscaling=quality` or `performance`, the game's FSR upscaling settings, which set the SDK's
`temporal_aa_upscale`; `--metal_taa_upscale=false` turns it off on Metal).

The SDK's upscaling path (written for FSR 3.1 on Vulkan and D3D12) is used as it is: the scene's draws go into the
top-left render-size corner of the output-size render targets (`TaaSqueeze` on the host viewport and scissor, and
`ps_param_gen` scaled), the scene's resolves read that corner through a nearest-neighbour stretch back to the
output size so that every texture the game makes of the scene is a full-size one, and at the motion blur draw the
render-size samples are gathered out of those textures (render pixel i is output pixel
`(2 * output * i + render - 1) / (2 * render)`, the first to show it). On Metal:

- `MetalDraw::taa_draw_` (every draw: the jitter, then the squeeze) and `taa_resolve_stretch_` (every resolve
  while the scene may be squeezed); the resolve kernels read `min(((2q + 1) * render) / (2 * output), render - 1)`
  for a stretched resolve (`ResolveConstants.stretch`, single-sampled sources).
- The motion vector kernel gathers too (the depth, the stencil and, when upscaling, the colour into a
  render-size texture), and so does the depth copy for MetalFX; at the native size the gather is the identity.
- The `MTLFXTemporalScaler` is made for the render size and the output (`TaaReady` compares both); a frame that
  asks for upscaling and was not squeezed makes the scaler and returns `u`, the next one is squeezed.
- Rectangle lists do not go to the jitter: the scene's first draw is a 4x MSAA rectangle clear of the EDRAM, which
  the Vulkan backend turns into a clear without a draw, and which here decided that no frame was squeezed.

Free roam, uncapped, 150 s pauses: MetalFX at the native size 77.3 and 76.9 FPS, Quality (853x480 to
1280x720) **86.0**, Performance (640x360) **91.3**. The command thread stays at 8 ms a frame, so it is the next
limit (about 125 FPS). The spawn point's picture at Performance has the same mean colour as MSAA 2x to a tenth,
and the minimap is stable over 10 frames.
No mips are sampled on Metal yet, so the SDK's LOD bias for the squeezed scene (`TaaLodBias`) is not applied.

After it, the command thread's per-draw maps keyed by strings (the vertex snapshots, rebuilt every frame; the
samplers; the depth-stencil states) take 64-bit keys, and the pipeline key is six words instead of a 69-byte
string (a heap allocation a draw): 92.6 FPS at Performance (91.3), the command thread 7.4 ms (8.0), of which 3.4
waiting for the GPU. So at Performance the GPU is the limit again. A trace of it (`gputrace.sh`): the scene pass
at 640x360 is about 1 ms; the largest item is the game's 4x MSAA targets, drawn here as 2x2 supersampling (about
25 passes of 160x128 reflections a frame, 320x256 here, about 1.8 ms; a 520-pitch surface about 1 ms; others),
about 4 ms together. Real MSAA (Metal multisample textures, shaded once a pixel) is the next GPU step.

**Real MSAA, tried (2026-11-01): slower; kept as `--metal_msaa=true`, off by default.** 2x and 4x surfaces become
multisample textures of their pitch in pixels (`Target(..., samples)`, keyed with the sample count); draws use a
host scale of 1 and pipelines the target's sample count; the EDRAM bookkeeping keeps texture rows and converts
them to tile rows through the target's samples down (`TargetLayout.ssx`, `ssy`); EDRAM transfers work in sample
space as before, with variants that read a multisample source (`_sm`) and write a multisample destination per
sample (`_dm`; guest 2x sample 0 is Metal's sample 1, the upper left; 4x is in the same order); resolves read
samples (`resolve_color_ms`, `resolve_depth_ms`); clears and their pipelines take the sample count. The spawn
point's picture matches MSAA as supersampling. But free roam runs at **30 to 31 FPS against 62.6**, the GPU
busy about 75 to 104 ms a frame against 41: the 160x128 4x reflection passes cost 5.9 ms a frame against 1.8 as
320x256 supersampling, the scene's 1280x512 2x passes 9.3 ms against about 5. Two causes:

- The translator's `sample_rate_shading` makes every pixel shader write a sample mask, so SPIRV-Cross reads
  `[[sample_id]]` and the shader runs once per sample. Turning it off removed that and changed nothing in speed,
  but it turns the spawn point's colour grading purple (some shader depends on it), so it stays on.
- Each of the frame's 60-odd passes loads and stores its multisample targets in full: an EDRAM emulation cannot
  keep MSAA in tile memory and resolve at the end of a pass, which is where Apple's GPUs make MSAA cheap, and
  loading and storing multisample textures costs far more than the same samples in a plain texture.

So supersampling stays. The 4x passes could get cheaper by drawing fewer passes or smaller ones, not with
multisample textures.

**4x surfaces at one sample a pixel, tenth pass (2026-11-01): on by default, `--metal_4x_as_1x=false` turns it
off.** The game's MSAA 4x targets (the 160x128 reflections and a few others) are drawn as plain textures of
their size in pixels, one texel for the pixel's 2x2 EDRAM samples, instead of 2x2 supersampling: a quarter of
their pixel work, and the reflections lose only their own anti-aliasing. The pieces: `SurfaceSamples` picks the
texture's samples a texel (`Target(..., samples, multisample)`, keyed with both); draws take the pipeline's
raster samples from it; resolves divide their reads by `tex_ss` (`ResolveConstants`, 104 bytes); EDRAM transfers
read a sample's texel at `s / ss` and write each texel once (`DST_COORD_P` scaled by `dst_ss`); a depth clear
matches its target by samples and multisampling. Same Mac, same hour, VM running:

| Mode | Off | On |
|---|---|---|
| MSAA 2x | 56.5 FPS, GPU busy 45.8 ms | 59.6 FPS, GPU busy 41.6 ms |
| MetalFX Performance | 81.0 FPS, GPU busy 24.5 ms | 94.4 FPS, GPU busy 19.4 ms |

The spawn point's mean colour is 1.22 from the reference against 0.63 (the car and the street look the same;
the difference is in the reflections), the minimap is steady (ten shots 150 ms apart, 52.0 to 52.2), and the
route test passes at MetalFX Performance uncapped.

**64bpp EDRAM transfers, eleventh pass (2026-11-01).** Counters first (the 150-frame stats now warn with EDRAM
transfers dropped and texture fetches sampled as zero): free roam dropped about 4 transfers a frame, between the
scene's 32bpp targets and a 640-wide target that held a 64bpp format in a texture laid out for 32bpp. The cause
was the target key (base, Metal format, width): `k_2_10_10_10_FLOAT_AS_16_16_16_16` (32bpp) and
`k_16_16_16_16_FLOAT` (64bpp) are both `RGBA16Float`, so a 64bpp surface could take a 32bpp surface's texture,
with the wrong tile pitch. The key now has the 64bpp flag, and transfers work in EDRAM dwords: a tile row is 80
dwords, 80 samples of a 32bpp format or 40 of a 64bpp one (sample x in dwords 2x and 2x + 1); each destination
sample takes its one or two dwords from whichever source samples hold them (`TransferConstants.dst_dw`,
`src_dw`), with transfer kinds 8 `k_16_16_16_16`, 9 `k_16_16_16_16_FLOAT` and 10 `k_32_32_FLOAT`. After it: no
transfer dropped and no texture sampled as zero, in free roam, the route drive or a rainy arcade race; the spawn
point's picture away from passing traffic is 0.62 from the reference. **3D textures** come back as zero (a
1x1x1 fallback), but nothing the game drew in these runs sampled one, so they wait until something does.

**The immediate drawer, twelfth pass (2026-11-01): the SDK's ImGui overlays on Metal.** `MetalProvider` now
makes a `MetalImmediateDrawer` (metal_presenter.mm): ImGui's textures as RGBA8 textures, each batch's vertices
(`setVertexBytes` up to 4 KB, else a buffer) and indices in buffers the command buffer keeps alive, one
alpha-blended pipeline for triangles and lines, scissors through `ScissorToRenderTarget`. The presenter runs
the UI drawers in its paint pass after the guest output (`MetalUIDrawContext` carries the encoder). F3 (debug)
and F4 (settings) were checked; the console (Backtick) and the achievement toasts use the same drawer. F4's Input, Keybinds,
Controller page lists every button's keys with Rebind and Reset, and "Save to config" writes `mcla.toml`.
`--metal_present_capture=<file.ppm>` writes what the presenter painted (overlays included) at most every 2
seconds, for checking overlays without screen recording (it makes the layer's drawables readable). The F4
picture over free roam was checked that way, and the FPS with the overlays closed is unchanged.

**Story videos, thirteenth pass (2026-11-01): the Bink movies of the story mode.** The story's intro movie (after
a new save is made: Carney's garage, the race through the hills) played as a black picture with sound on Metal, while the
boot logos and the attract movie looked right. The Bink decoder writes each frame's planes (Y at 1280x720, U and V
at 640x360, 8-bit, linear, not tiled) with the CPU, and those writes don't always reach the texture write watches
(the decoder reuses the same pages for every frame, written in ways the watch doesn't see), so the first upload
of each plane stayed in the cache: the black of the first frame. `--metal_texture_watches=false` showed it. Now
linear textures are hashed once a frame instead of watched (`metal_hash_linear_textures`, default on): the game's
own textures are tiled and keep their watches, and the few linear ones (the movie planes and some small UI
textures) cost about 8 MB of hashing a frame in free roam and 3 MB during a movie. The intro now plays, and
the in-engine cutscene after it (the characters at Carney's) draws as it should; free roam at MetalFX
Performance is unchanged (93.4 FPS).

**HDR output with EDR, fourteenth pass (2026-11-01).** The Windows builds' HDR (launcher/dev/hdr-2026-10-16.md:
the game's HUD and menus separated into a layer, the scene rebuilt in HDR from the tone map draw's inputs, HDR10
output) is mostly in the SDK's shared `CommandProcessor`; Metal now gives it what a backend has to:

- *The UI layer's target operations* (`MetalDraw::HdrCopyFromTarget`, `HdrClearTarget`, `HdrRestoreTarget`, on the
  8_8_8_8 target of `HdrColorTargetKey`, 1x or 4x as 1x): each ends the open pass, draws that target's waiting
  clears and takes over its EDRAM tiles first, then blits, clears or draws the put-back (target + underlay x (1 -
  target alpha), by the blend). Draw calls the command processor's `HdrRenderTargetsReady` once its targets are
  known, before its pass.
- *The scene pass* after the tone map draw: the SDK's `hdr_scene_mcla.cs`, and at the swap its refresher
  `hdr_refresh.cs`, are the Vulkan backend's SPIR-V turned into MSL by the same SPIRV-Cross (`MetalSpirvComputeToMsl`,
  descriptor sets mapped to texture slots, the gamma ramp as a texture buffer), so the HDR math is the Windows
  builds' exactly. The scene pass reads the tone map draw's own textures.
- *The presenter*: with HDR output on, the `CAMetalLayer` is BGR10A2 in the ITU-R 2100 PQ colour space with
  `wantsExtendedDynamicRangeContent`, and HDR10 metadata (`CAEDRMetadata`) whose optical output scale is paper
  white: the game's white lands on the display's SDR white and macOS maps the highlights into whatever EDR headroom
  the display has at its brightness. The guest output is RGB10A2 (PQ code values from the refresher, or SDR ones,
  which the paint places at the SDR level). The ImGui overlays are blended in light over the PQ picture in the
  fragment shader (reading the attachment, which Apple GPUs keep in tile memory).
- *macOS has no HDR switch*: `hdr = auto` (now the game's default on macOS too) turns HDR output on when the
  display can show EDR at all (`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` above 1:
  the MacBook Air M5's panel reports 2.0, XDR panels and HDR monitors more); `metal_hdr_auto_edr=false` keeps auto
  SDR. The display's nits aren't reported, so the peak and paper white are the SDK's defaults (1,000 and 200 nits)
  unless set; with the metadata only their ratio matters.

Checked in free roam, MSAA 2x and MetalFX Performance: the log says the frames are put together from the UI layer
and the scene is in HDR, with no fallback; the F4 overlay draws over the HDR picture; `set hdr off` and `set hdr on`
during play switch the layer in place, and the captures (HDR10 turned back into SDR at paper white) match the SDR
frame (mean RGB 38.5, 30.2, 24.6 against 38.3, 30.6, 25.5). It costs about 4% at MetalFX Performance (89.3 FPS
against 93.4). `--metal_present_capture` and `shot` captures convert HDR10 back to SDR, so highlights are clipped in
them.

**Frame pacing:** `CAMetalDisplayLink` is put off. The Mac here has a 60 Hz panel, the presenter's layer has
display sync on, and the game already holds each frame to its target at the swap with a precise clock
(`mcla_pace_at_swap`, src/frame_timing.cpp). Uncapped, the frames over 60 a second are drawn and not shown, and
the shown ones are unevenly spaced; `--mcla_fps=60` gives even frames. A display link would matter for 120 Hz
ProMotion panels and for lower latency; it stays in [BACKLOG](BACKLOG.md) 16.

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

**Compile stalls, fifteenth pass (2026-11-02): pipeline storage and asynchronous compiles.** A play session from
`MCLA.app` froze for up to 4.7 s while driving (46 pipelines in one 150-frame window, about 100 ms each), with
0.3 to 0.7 s freezes after. Render pipelines were built with the synchronous `newRenderPipelineStateWithDescriptor:`
on the command thread, and a pipeline macOS hasn't compiled before costs 50 to 100+ ms; `MCLA.app` has its own
per-app shader cache (`$(getconf DARWIN_USER_CACHE_DIR)/local.mcla-recomp`), separate from the build folder's, so
its first sessions met far more cold compiles than the test runs. Reproduced with that cache emptied, on the drive
route: 246 pipelines built in draws in 11.6 s, freezes of 4.9, 3.0 and 1.7 s. Two changes:
- **Pipeline storage** (`metal_pipeline_storage`, on): each pipeline a run builds goes to
  `<cache>/shaders/metal/<title>.mcla-metal-pipelines` (magic `MCLAMTP1`; records of the vertex and pixel shader
  hashes and modifications and the key's words 2 to 5, which the descriptor is now made from, `PipelineDescriptor`).
  At boot, after the shader warm-up, a thread waits for the warm-up's libraries and builds them with the
  asynchronous `newRenderPipelineStateWithDescriptor:completionHandler:`, half the cores' worth in flight; a draw that
  needs one being built waits for it, one not started yet the draw builds itself. 363 pipelines in 0.4 s with a warm
  cache, 313 in 11 s with a cold one (in the background, during the intro).
- **Asynchronous compiles** (`metal_async_compile`, on): a draw whose shader library or pipeline is still compiling
  waits only within the frame's budget (`metal_async_compile_budget_ms`, 4 ms in all), then is left out; new
  pipelines are started on Metal's threads (and stored) instead of built synchronously. The shader path no longer
  waits for every pending compile (`MetalShaderCompiler::Wait`) but for the draw's own translations
  (`WaitForLibrary`). Cold cache, storage off: no freeze; at most 115 ms waited in a 150-frame window, a few hundred
  draws left out in the windows where new pipelines appeared, route finished. A later play session: 337 pipelines from
  the storage, 12 new, 140 draws left out after boot, no stall.
The 150-frame `Metal frame time` line now ends with the pipelines created, those taken from the storage (and the time
waited for them) and the draws left out. What remains in long sessions is heat: after about 2 minutes the MacBook Air
reaches thermal pressure 2 and the command thread's CPU time goes from about 9 to 19-25 ms a frame (37 to 54 FPS).

**Sixteenth pass (2026-11-02): command-thread trims.** A profile of the command thread while driving (8 s, hot Mac):
the Metal Performance HUD's interposition (`MetalForceHudEnabled`, a system-wide setting on the test Mac) was about
12% of it; vertex snapshot copies about 7%; shader constants compared, copied into a `std::vector` and copied again by
`setVertexBytes` about 6%; the fifteenth pass's per-draw library lookup (a mutex) and budget clock about 4%. Now the
libraries a draw has seen are cached on the command thread (no lock or clock for them), and constants go into a
per-frame ring (`metal_constant_ring`, 2 x 16 MB, 256-byte aligned) bound with `set*BufferOffset`, compared with the
slot's last upload there. Same picture (mean RGB of the spawn shot within 0.1), route test passes; no measurable FPS
change at thermal pressure 2 (runs of one build differ by 20%). The pipeline storage builds two pipelines at a time
(five starved the game's threads, audio among them, with a cold cache). `MCLA.app` also opts into Game Mode
(`LSSupportsGameMode`; macOS turns it on in full screen only).

**Seventeenth pass (2026-11-02): MetalFX frame generation.** The SDK's `frame_generation` (FSR 3.1 on D3D12 and
Vulkan) is MetalFX's frame interpolator on Metal (`MTLFXFrameInterpolator`, macOS 26; `SupportsFrameGeneration`). At
the swap the SDK's refresher with frame generation (`hdr_refresh_fg.cs`, its SPIR-V through SPIRV-Cross like
`hdr_refresh.cs`) also writes the scene's code values without the UI (flag bit 13; in SDR after the normal present,
bits 13 to 15), into one of two RGBA16Float images. MetalFX makes the frame between the last image and this one from
the temporal AA's depth (Depth32Float, reversed) and motion vectors (pixels at the render size, the scaler's), its
jitter, and the camera the SDK's TAA reads (near, far, vertical FOV, cuts reset the history); the refresher then
composes it under this frame's UI layer (bit 12, bit 15 in SDR) into the presenter's texture for the generated frame
of that mailbox image. Only frames whose temporal AA ran and that are put together from the UI layer (or have no UI)
with the tone map are generated; menus and loading screens are shown alone. In SDR the presenter keeps the UI layer
apart while frame generation is on (`SetFrameGenerationUiSeparation`), as Vulkan does.
Presenting: two drawables a frame is more than CAMetalLayer's three allow without waiting, and a first version that
presented both from the UI thread waited up to a whole frame there for every paint. Now the UI thread copies the new
frame and the generated one (two 1280x720 blits) and gives them to a present thread, which gets the drawables and
presents each with `presentDrawable:afterMinimumDuration:` (90% of half the time between the guest's frames, measured
at the refresher, not at the paints: a paint-measured interval fed back into the durations and settled at 133 ms). A
job the thread hasn't started when the next comes is replaced; a late paint (it skipped refreshes) and paints with
the presenter's UI drawers present the new frame alone. At exactly half the display's rate (30 on 60 Hz) the queue
never catches up after a late frame (5 to 9 frames skipped in 10 s); HALF DISPLAY (`mcla_fps_frame_generation = -1`,
floor of 97% of half the refresh) now applies on macOS from 50 Hz, the refresh read from CoreGraphics (the SDK's
display reader has none on macOS): 29 rendered, 0 to 1 skipped in 10 s. The game counts frame generation as on only
with MetalFX anti-aliasing (`MclaFrameGenerationRuns`).
Measured on the MacBook Air M5 (route test, MetalFX Performance 640x360 to 1280x720, 60 Hz): every frame of free roam
generated, 290 generated frames presented in 10 s, UI thread paint 25 us (it was up to 33 ms); GPU busy 25.2 ms a
frame at 30 FPS without and 26.0 with it (the interpolation's command buffer spans 4.4 to 6 ms, overlapping the
frame); the command thread's CPU time +2 ms a frame. Generated frames captured with `--frame_generation_debug=3`
(only generated frames shown) and `--metal_present_capture` look like the real ones, HUD included, in HDR and SDR.
The log has a `Metal frame generation` line every 150 frames (generated, and why not) and one every 10 s from the
presenter (presented, held back, skipped).

**Eighteenth pass (2026-11-02): the car's lamps, plate and reflections.** Bugs seen since the first Metal builds:
blurred streaks like rain drops near the rear lamps that slid onto the plate and bumper when steering, glaring and
blinking lamps (ours and the traffic's), a gold sheen on bumpers.
- Streaks: a pixel shader's own depth output (oDepth) is scaled from guest [0, 1] to the host's [0, 0.5] float24
  range only with `kSysFlag_DepthFloat24`, which Vulkan sets (`rexglue-vulkan-odepth-scale.patch`, issue #11) and
  Metal didn't. The game's wheel pass after the car body (stencil and depth test, no colour, the shader writes depth)
  then compared twice its depth and passed behind the body, writing the wheels' object IDs into the stencil there:
  two vertical lines inside the car. The motion blur reads object IDs from the stencil and blurred along them. Now set
  from `RB_DEPTH_INFO` (and the MSAA sample count, as Vulkan); the stencil's car is one ID, and the plate is readable
  in every frame of a night drive (`--vulkan_odepth_float24_scale=false` turns the scaling off on both backends).
- Gold sheen and square glows: MIN/MAX blending with a SrcAlpha factor (`kSysFlag_MinMax*TimesSrcAlpha`, the port of
  `rexglue-minmax-blend-factor.patch`). The car's environment map draws its light glows that way, and every glow was
  a solid square mirrored by the paint, the lenses and the bumpers.
- Blinking lamps and shimmer: textures had no mip levels on Metal. Now loaded with their mips (`--metal_texture_mips`,
  default on; resolved and composed surfaces stay one level) and sampled with the fetch's mip filter, the proper
  clamp, mirror and border modes, and anisotropic filtering (`anisotropic_override`, 4x by default, as Vulkan). The
  rear lamps' frame-to-frame flicker went from 20% to 11% of their pixels (MetalFX Performance with frame
  generation), 6% to 4% without AA; GPU time unchanged in the route test (21.2 ms against 21.8 without mips).
- Motion blur length (`--metal_motion_blur_fps`, default 60): MCLA blurs by one frame's motion, so at 29 or 30 FPS
  twice as long as at 60. The backend scales the blur's matrices (keyed by the game's motion blur shader, the only
  game-specific code in the backend; 0 turns it off).
- Frame generation: camera cuts (the title and loading fly-throughs, about one a minute when driving) aren't
  generated, and the interpolator's history restarts; the presenter's 10 s line splits frames held back into UI,
  late paints and too fast for the display.

Still missing (then): occlusion queries. Metal answered every query with a fixed count, so the sun's glare (the
only use in MCLA) showed at 80% even behind buildings ([BACKLOG](BACKLOG.md) 35; done in the twentieth pass).

**Nineteenth pass (2026-11-03): a race benchmark over every mode, and the stutter it found.**
- *Race benchmark* (`scripts/mac_race_bench.py`): each run boots the game windowed with a scratch copy of the save
  (`out/bench-race/user`), goes through the pause menu's Arcade into "Sunset and Vine" (7 opponents, rain, midnight;
  `launcher/dev/scripts/boot-to-race.pad`) and drives the player's car along the leading opponent's route
  (`sunset-and-vine.route`, about 100 km/h on average) with the dev pad's follower, for `--race-seconds` of the
  race's own clock (default 60). From the race's start to its end mark it reports the guest swaps (FPS, median,
  p99, 1% low, the longest frame, hitches: frames over twice the median and 25 ms, freezes over 100 ms), what
  reached the display (from the presenter's drawables: frames shown a second, the longest gap, gaps over 1.5 and
  3 refreshes), and from the log the GPU busy time, the command thread's CPU time, pipelines made and draws left
  out, warnings and errors, and the thermal pressure at the start and end. Twenty named modes (`--list`: MSAA 2x,
  AA off, MetalFX TAA, Quality, Performance at 30, 45, 60, 120 and uncapped, frame generation, SDR, single tile,
  the low preset, smooth UI off), `quick`, `all`, or `name=<options>`. `--cool-to 1` waits before each run until
  thermal pressure is down (a run that starts at level 0 makes 57 FPS at Performance, one at level 2 37 to 49:
  that, not the build, is most of the run-to-run spread on this Mac). `--sample N` takes a CPU profile 15 s into
  the race, `--gputrace` a 3 s Metal System Trace summed by encoder label. Diagnostics: `cpu-only` (draws stop
  after the primitive processor), `nodraw`.
- *What reached the display*: `--metal_present_times=<csv>` writes each drawable's presented time (normal and
  generated), and every 10 s the log says how many frames were shown, the longest gap and the late ones
  (`metal_present_stats`, on).
- *Slow frames*: a swap over `metal_slow_frame_ms` (50) is logged with its command-thread CPU time, the wait for the
  GPU, the rest (the game), shaders translated, pipelines made, texture loads and hashing, passes and transfers.
- *The stutter*: every 10 s in a race, a frame of 110 to 130 ms on the command thread (2,300 to 2,800 texture loads,
  700 to 850 passes) and a 50 to 65 ms GPU frame after it. The texture cache dropped every texture once it held
  4,096. It now evicts the least recently used down to three quarters of `metal_texture_cache_size` (4,096),
  keeping anything used in the last two frames: Performance went from a longest frame of 122 to 126 ms, 10 to 12
  hitches, 2 to 3 freezes and a 183 to 200 ms gap on the display a minute, to 39.5 ms, 1 hitch, none and 50 ms.

The matrix after the fix, 60 s of the race each, a minute's pause between runs, the Mac warm (thermal pressure 1
to 2 in every run; `out/bench-race/20261102-233722-matrix1`):

| Mode | FPS | p99 ms | 1% low | Longest ms | Hitches | Shown/s | Longest gap ms | GPU ms | CP ms |
|---|---|---|---|---|---|---|---|---|---|
| MSAA 2x, 60 cap | 28.7 | 48.2 | 19.0 | 67.8 | 0 | 28.7 | 83.3 | 43.0 | 34.6 |
| MSAA 2x, 30 cap | 30.0 | 42.2 | 23.4 | 43.7 | 0 | 30.0 | 50.0 | 41.8 | 16.4 |
| MSAA 2x, uncapped | 33.8 | 42.8 | 21.2 | 65.9 | 2 | 33.8 | 50.0 | 42.8 | 28.1 |
| AA off, 60 | 46.1 | 31.8 | 28.1 | 53.9 | 1 | 46.3 | 50.0 | 33.8 | 20.7 |
| MetalFX TAA, 60 | 40.8 | 47.7 | 17.1 | 72.7 | 25 | 40.9 | 83.3 | 29.4 | 22.8 |
| MetalFX Quality, 60 | 46.3 | 33.4 | 25.8 | 57.4 | 6 | 46.4 | 50.0 | 22.1 | 20.9 |
| MetalFX Performance, 60 (MCLA.app's default) | 49.4 | 29.4 | 29.2 | 49.4 | 7 | 49.5 | 50.0 | 20.3 | 18.6 |
| Performance, uncapped | 47.7 | 32.3 | 26.7 | 59.9 | 4 | 47.7 | 50.0 | 20.5 | 20.0 |
| Performance, 45 | 45.0 | 28.8 | 33.5 | 33.0 | 0 | 44.9 | 33.3 | 20.6 | 15.1 |
| Frame generation, half display (29 + 29) | 29.0 | 43.4 | 22.7 | 45.6 | 0 | 57.9 | 33.3 | 21.9 | 11.2 |
| Frame generation, 30 + 30 | 30.0 | 41.7 | 23.5 | 44.2 | 0 | 59.9 | 33.3 | 20.9 | 11.3 |
| MSAA 2x, SDR | 36.8 | 39.0 | 23.0 | 58.1 | 2 | 36.9 | 83.3 | 38.4 | 25.1 |
| Performance, SDR | 51.4 | 27.8 | 32.9 | 42.3 | 1 | 51.5 | 50.0 | 20.0 | 18.1 |
| Low preset, 60 | 44.9 | 34.6 | 24.9 | 62.8 | 5 | 44.9 | 50.0 | 33.2 | 21.3 |

Every mode reached the race's end with no freeze, no warning or error in the race, no pipeline compiled after the
first run and no draw left out. Frame generation at 30 is the smoothest on a 60 Hz panel (59.9 frames shown a
second, 5 late in a minute); Performance at 60 holds 45 to 52 on a warm Mac, so its frames land unevenly on the
display. MSAA 2x is GPU-bound (43 ms of GPU work a frame in the race against 21 at Performance).

*Where the race's time goes, at Performance uncapped.* With draws stopped after the primitive processor the game
runs at 84 FPS and the command thread uses 2.3 ms a frame: the game's own threads are not the limit, the command
thread is. By stage (`metal_draw_stop`, `metal_draw_calls`): 2.5 ms up to the shaders, +4.4 with textures and
targets, +0.3 pipeline and pass, +3.9 state and bindings, +6.1 for the draw calls themselves (17.2 ms, 50 FPS).
But a CPU profile (`sample`, which slows the game about threefold) misleads here: the command thread's CPU time a
frame follows the whole chip's load, not only its own work. The same draws cost it 34.6 ms a frame with MSAA 2x
at a 60 cap and 16.4 at a 30 cap, 18.6 at Performance and 11 with frame generation; on a MacBook Air the CPU and
GPU share one power budget and the memory, so GPU work slows the command thread. Tried, and kept only as options:

- *An encoder thread* (`--metal_encoder_thread=true`, off; `metal_encoder_queue.h`): the render encoder's
  per-draw calls (state, buffers, textures, samplers, the draw, about 30,000 a frame) queued and made on a thread
  of their own, handed over every `metal_encoder_batch` calls and drained at each pass's end. It moved 6 ms a frame
  off the command thread, which stayed at 18 to 20 ms: 46.6 and 45.5 FPS against 47.3 and 48.3 without it.
- *The game's threads at user-interactive QoS* (an SDK runtime change, not kept): 53.3 and 37.1 against 46.7,
  48.9 and 57.1; the spread is thermal.

Kept, for less work a draw at no cost: samplers looked up by their fetch constant (`Sampler` was a fifth of the
bindings' time), the encoder's fixed-function state (pipeline, depth-stencil, stencil reference, clip mode,
viewport, scissor, winding, culling, blend colour) and the memory buffer's slot sent only when changed in the pass
(`metal_encoder_state_cache`), the float constants gathered as runs of registers straight into the constant ring,
and linear textures (hashed every frame since the thirteenth pass) hashed once a frame when two fetch layouts read
the same memory (13.9 MB of hashing a frame to about 7). None shows in the FPS beyond the spread. A GPU trace of
the race at Performance (about 94% of the GPU's time is the game's): the scene's 1280x384 tiles about 4 ms a
frame, 30 reflection passes of 160x128 about 2, the 520x256 and 320x512 passes about 1.5 each, resolves 2.3, the
HDR scene 0.7, MetalFX 0.6. So the next speed is on the GPU: fewer and cheaper passes (the reflections),
attachments not stored when nothing reads them back.

**Twentieth pass (2026-11-03): occlusion queries, and two tries for the command thread that were not kept.**

*Occlusion queries* (`--metal_occlusion_queries`, on; [BACKLOG](BACKLOG.md) 35). The backend now has the SDK's
host query hooks (`HostOcclusionQuery*`, the asynchronous path Direct3D 12 and Vulkan use): a query's draws count
the samples that pass the depth and stencil tests into a slot of a shared visibility buffer
(`setVisibilityResultMode:MTLVisibilityResultModeCounting`), every pass of the query adding to the same slot
(`visibilityResultType = MTLVisibilityResultTypeAccumulate`, macOS 26; the default reset type cleared another
pass's slot in a test program), zeroed by the CPU at the begin. A query starts a pass if the open one has no
visibility buffer, and clears and EDRAM transfers drawn at a pass's start are not counted. The count is read
without waiting once the command buffer of the query's last draw has completed (a completion handler per query).
With MetalFX upscaling the scene is drawn at the render size, so a query of a squeezed draw is scaled to the output
size (Performance counts a quarter of the pixels). In 60 s drives at a 60 FPS cap: every query paired and
delivered (4,688 at Performance, no cut, dropped or unpaired one), the sun's quad counts 0 behind buildings and up
to about 3,200 samples in view, the same at Performance (upscaled) and at native size (p99 2,060 and 1,888; the
game's full view is 1,250, so the glare reaches full strength); the count reaches the game 17 to 22 ms after the
end (about one frame: the frame's command buffer is committed at its end), and 78% are written into the record
before the game reads it (the rest give the next query's guess, as on the other backends). FPS unchanged (56.0
and 55.4 in those drives). Works with `metal_encoder_thread` too.

*Tried, not kept:*

- *Texture loads batched into one compute encoder* (each load is a compute dispatch, and a blit for its mips, in
  encoders of their own): the loads in a row shared one compute encoder and their blits were encoded at its end.
  In a 30 s race 58.3 against 54.2 FPS (inside the thermal spread), and the frame that loads the city at the race's
  start got worse: 157 ms of command thread with 2,948 loads in one frame and 1,112 passes, against 83 ms with the
  loads split over two frames. Reverted.
- *Passes bounded to the columns their draws reach* (`--metal_pass_columns`, off): with MetalFX upscaling the scene
  is drawn into the left part of 1280-wide targets, and a pass loads and stores its whole width. The trace shows
  the narrower passes, but 50.6 and 50.2 FPS against 50.0 and 49.9 (GPU 20.3 to 20.5 ms either way): the GPU
  skips tiles nothing touched. Kept as an option.

*The picture enlarged with MetalFX* (`--metal_present_scaling`, `metalfx` by default, or `bilinear`; the macOS
launcher's Screen scaling). The game's picture is 1280x720 and the presenter stretched it bilinearly to the window
(2560x1440 for a 1280x720-point window on a Retina panel): soft, the HUD's text too. Now MetalFX's spatial upscaler
(`MTLFXSpatialScaler`, perceptual mode, SDR and PQ alike) enlarges it by up to 2x a side before the paint (the rest,
on a bigger screen, bilinear); it only enlarges. Edge detail in the window (mean |Laplacian|) 3.49 against 1.41,
with no halos on the HUD's digits. Cost not measurable: Performance 60 45.7 and 47.4 FPS against 47.8 and 45.2
bilinear, frame generation 60.0 shown a second either way, GPU 20.5 to 21.3 ms in all (`20261103-025919-spatial2`
in out/bench-race). The SDK's FSR 1 and CAS `present_effect` filters stay unbuilt on macOS (their macro changes
the presenter's class layout in shared headers). A paint capture (`metal_present_capture`) every 2 s costs a
freeze each (an 11 MB readback written on Metal's completion thread): not for benchmarks.

*What the hitches left in a race are.* With `--metal_slow_frame_ms=34` the frames over 34 ms in a Performance 60
race (4 to 12 a minute over twice the median) have no single cause: the command thread at 20 to 37 ms against its
usual 17, and the worst while the city streams in (160 to 340 texture loads in a frame, +8 to 12 ms). The slow
frame line now times the texture lookups the fast table missed, the write watches they set up and the loads: a
load costs the command thread 30 to 50 µs (a texture made, 2 to 5 µs in a test program; a compute and a blit
encoder, 10 to 15 µs; the dispatches and copies), the watches nothing measurable. The game's own threads use
about 3 cores in a race, waiting on condition variables most of the time and otherwise running the game: no
spinning to remove.

*Resolves and Metal's hazard tracking, tried.* Resolves write both their texture and the guest memory (tiled,
for the CPU and for textures loaded from it); without the memory write (`--metal_resolve_to_memory=false`, a
diagnostic) the command buffers' GPU time falls from 20.4 to 16.7 ms a frame, but the GPU's actual resolve work
only from 2.13 to 1.28 ms (trace), and the minimap loses its roads: some resolves are read from memory. The 512 MB
guest memory buffer was then made untracked (`--metal_memory_untracked`, off), its users ordered by the backend's
own fences (writers, the resolves and fence writes, after every earlier user; readers, the texture loads, after
the writes only). Untracked without any fence won three pairs (46.1, 48.2, 49.0 against 42.7, 43.4, 41.8 FPS) but
is not safe; with the fences the uncapped races are inside the spread (46.2 and 46.6 against 42.9 and 47.7), and
at a 30 FPS cap, where the chip's load is the same for every variant and the command thread's time compares, it
saves 0.6 ms of the command thread's 10.8 a frame. The CPU-written buffers (vertex snapshots, constants, index
buffers) untracked (`--metal_ring_untracked`, off): nothing measurable. Both kept as options, off. Uncapped FPS on a
warm Air cannot tell a 5% change from the spread; a capped run's command thread time can.

*The guest's exact float operations inlined: +20% in races* (`--metal_shader_precise_inline`, on). The SDK's SPIR-V
translator marks the guest shaders' multiplies and adds NoContraction (as the Xenos computes them: no fused
multiply-add, so a position computed in two passes matches). SPIRV-Cross writes those as `spvFMul` (`fma(l, r, 0)`)
and `spvFAdd` (`fma(1, l, r)`) in `[[clang::optnone]]` functions: 91,000 calls in MCLA's 633 shaders, each a real
function call on the GPU. With safe math (`metal_shader_math` 0, the default) the fma forms alone already keep the
rounding (the compiler may not drop the signed zero `fma(l, r, 0)` keeps, nor fuse an fma with an add), so the
backend now rewrites `[[clang::optnone]]` to `inline` in the guest shaders' MSL. In a race at Performance 60: 56.8
and 60.0 FPS against 47.5 and 50.7 (the second run held 60 with no hitch, its longest frame 28 ms), GPU 13.7 and
16.4 ms a frame against 20.7 and 20.3; the scene passes' fragment work 7.6 ms a frame against 11.9 in a trace. In
free roam at sunset, 59.2 FPS. Pictures checked: races and a sunset drive, no z-fighting or flicker on decals,
plates, road markings and shadows. Off brings the calls back.

Check after the pass (a VM running, before the inlining): Performance 60 47.1 FPS, MSAA 2x 29.6, frame generation
29.0 (57.9 shown a second), every mode with no warning or error.

The modes again after the inlining (one race each, cooled to nominal first, M5 Air):

| mode | FPS | GPU ms | command thread ms | notes |
|---|---|---|---|---|
| MSAA 2x, 60 | 39.5 | 19.4 | 24.9 | was about 30 |
| TAA, 60 | 47.4 | 17.3 | 20.0 | |
| MetalFX Quality, 60 | 51.7 | 15.6 | 17.7 | 18 hitches (texture streaming) |
| MetalFX Performance, 60 | 58.9 | 13.7 | 13.9 | 1 hitch, longest frame 35 ms; was 45 to 50 |
| MetalFX Performance, uncapped | 56.9 | 15.1 | 16.1 | |
| frame generation (30 drawn) | 29.0 | 16.1 | 10.6 | |
| no AA, 60 | 59.7 | 20.1 | 12.4 | no hitch |

No warning or error, no new pipeline in the race and no draw left out in any of them.

*Checked after it, not changed:*

- *Pixel shaders at pixel rate.* Every pixel shader's MSL reads `[[sample_id]]` (SPIRV-Cross reads the translator's
  SampleRateShading capability, declared for alpha to mask's sample mask, as per-sample shading). Removing the
  capability where the shader does not read the sample index made no difference in a trace (the scene passes'
  fragment work 6.3 against 6.4 ms a frame): the targets are single-sample, MSAA being drawn as supersampling, so
  it would matter only with `--metal_msaa`. Not kept.
- *What a texture load costs.* The slow frame log now splits off making the texture
  (`newTextureWithDescriptor`): 11 of 89 ms in the race's first frame (2,938 loads), 7 of 24 ms in a frame
  with 468, so 12 to 28%. The rest is encoding the untiling dispatch and the blit. Reusing textures would save
  little.

*Vertex ranges of 1 KB and up kept from frame to frame* (`metal_persistent_vertex_size`, 1 KB, was 16 KB). A CPU
profile of the command thread in a race: texture lookups 15%, vertex copies 8% (7 to 10 MB a frame, the ranges
under 16 KB), resolves 8%, Metal encoders about 10%. With the persistent copies (a write watch each) from 1 KB the
copies are 0.6 to 1.2 MB a frame (about 1,900 ranges kept against 300). At 30 FPS, MetalFX Performance, two runs
each: command thread 10.5 and 10.0 ms a frame against 11.1 and 11.6 (4 KB: 9.9 and 10.2), 1% low 25.1 and 26.0
FPS against 19.1 and 14.3. Uncapped races and a free roam drive on a busy Mac: even (54.1 against 54.0 FPS in the
drive). Pictures checked. The log says when the 192 MB persistent region fills (everything is copied again).
Also: a texture load no longer scans the 8,192 fast lookups when it makes a new texture (only when it replaces
one); that was 1.4% of the thread. A texture made from a resolve is viewed once (the resolve's 2D texture, its swizzled
view a 2D array), not through a 2D array view and then a swizzled view of that: two view objects a frame for each
of the 8 or so, 2.7% of the thread in the profile. Capped, on a quiet Mac: command thread 10.4 ms. The minimap and
the road's reflections checked. The textures hashed every frame are the linear ones (about 6 MB: 1024x1024 DXT5,
512x640 RGBA8 and smaller, the game's CPU-written pictures), as intended; 2% of the thread.
