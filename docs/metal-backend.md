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
sampled in free roam, drives or races so far), EDR, frame pacing with `CAMetalDisplayLink` (put off; see
the tenth pass). The car falling through the road ([BACKLOG](BACKLOG.md) 27) has not come back since the speed
passes, in the route tests or in play, so it is no longer a known issue. The passes below, first to twelfth, record how it got here.

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
| M2 | Correct picture: EDRAM ownership transfers, MSAA 2x/4x, float24 depth, every texture format, memexport, occlusion queries, gamma ramp | mostly done: EDRAM transfers between formats and depth and color, MSAA as supersampling (real MSAA as an option), float24 depth (D24FS8), the gamma ramp, the spawn point matching MoltenVK. To do: EDRAM transfers of 64bpp formats, 3D textures |
| M3 | Fast: the encoder planning above, binary archives, frame pacing with `CAMetalDisplayLink`, MetalFX upscaling | mostly done: nine speed passes (below), MetalFX temporal AA and upscaling; binary archives deferred. To do: `CAMetalDisplayLink` pacing |
| M4 | The rest: the immediate drawer (ImGui overlays), guest output captures (`dev_pad`'s `shot`), EDR (HDR) | captures and the immediate drawer done; EDR to do |

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
