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
| M1 | First picture: shared memory buffer, primitive processor, SPIR-V to MSL pipelines, host render targets without MSAA and without EDRAM transfers, resolves to memory, texture loads for the common formats, the swap from the front buffer | doing: **the first picture, 2026-11-01**: the title screen and free roam draw (below), 28 to 30 FPS in free roam (MoltenVK: 19.6) |
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
hashing it). The frame is now CPU-bound in the command
processor: hashing the per-draw vertex snapshots (about 10%), 40 to 80 texture loads a frame, the draws' own
encoding. The GPU reads textures from guest memory when it runs the frame, up to a frame after the game wrote
them; the vertices and indices are copied at the draw (`metal_snapshot_vertices`).

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

**Diagnosis:** `--metal_debug_dir=<folder>` with `--metal_debug_frame=<n>`, or `set metal_debug_capture true` from a
pad script for the next frame, logs that frame's passes (render targets, MSAA, viewport, scissor, window offset),
resolves and clears, the textures of its full-screen draws, and writes each resolve as a PPM.

Shadows work (the title's plaza scene shows the palm trees' shadows). Still to do in M1: the stencil in depth resolves,
clears of only the resolved rectangle (the whole surface is cleared), EDRAM shared between formats (a surface
reinterpreted as another format starts from its own texture), and pixel positions in shaders drawn with MSAA (the
shaders are translated for 1x).

Known gaps in M0: no captures (`shot` in a pad script answers "no guest output yet"), no ImGui overlays (the
provider has no immediate drawer), and the picture is a placeholder that pulses with the swaps.
