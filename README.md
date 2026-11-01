# MCLA for macOS (Apple Silicon)

*Midnight Club: Los Angeles Complete Edition* (Xbox 360, title `545407F8`) running natively on Apple Silicon Macs, as an arm64 app. This is the macOS fork ([m0d16l14n1/mcla-recomp](https://github.com/m0d16l14n1/mcla-recomp)) of [RenanQueiroz/mcla-recomp](https://github.com/RenanQueiroz/mcla-recomp), itself a fork of [holdmysocks/mcla-recomp](https://github.com/holdmysocks/mcla-recomp): a static recompilation of the game to native code, built on the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk). The game draws through the SDK's Xbox 360 GPU emulation, either on Vulkan through MoltenVK or on a native Metal backend written for this fork (and meant for other ReXGlue ports on the Mac too).

The upstream projects also build for Windows, Linux and the PS5; this fork keeps their code but documents and tests only macOS. For the other platforms, see [RenanQueiroz/mcla-recomp](https://github.com/RenanQueiroz/mcla-recomp).

**This repository contains no game code, assets or keys.** You supply your own legally obtained disc image (`.iso`); the game is built on your Mac from it, and the recompiled code is generated locally and never committed. What you build is for you, not for sharing.

## Which release of the game

Only **Midnight Club: Los Angeles Complete Edition, USA/Europe, for Xbox 360** (title id `545407F8`), as a disc image (`.iso`). The fixes in `config/` are addresses in that release's executable; another region or revision would need them checked again.

The copy this fork is built and tested with, so that you can compare yours (`rexglue codegen` prints the first four):

| | |
|---|---|
| Title id | `545407F8` |
| Media id | `5940C9DB` |
| `default.xex` version | 8 (base version 8), disc 1 of 1, built 2009-07-17 22:23 UTC |
| `default.xex` SHA-1 | `03e5e2c6a5666edc79bd3b230ffaa5fcc03ef7e6` (9,252,864 bytes) |
| Disc image | XGD2, 7,838,695,424 bytes; 15 files, 6.12 GiB extracted |

No title update is needed or used.

## Status

Measured on an M5 Mac (4 performance and 6 efficiency cores), free roam at native 720p with MSAA 2x, uncapped (`--mcla_fps=0`):

| Graphics | State |
|---|---|
| Vulkan on MoltenVK (the default) | Plays from boot to free roam: title, menus, the city, HUD, audio, controller. About 20 FPS with MSAA 2x, 31 with anti-aliasing off. GPU-bound. |
| Native Metal (`--mcla_gpu_backend=metal`) | The same picture as MoltenVK at the spawn point (shadows, colour grading, minimap, HUD); plays from boot to free roam. **About 60 to 63 FPS** on a cool Mac with MSAA 2x, **about 76 with MetalFX anti-aliasing** (`--mcla_anti_aliasing=fsr`), **86 to 91 with MetalFX upscaling** (add `--mcla_upscaling=quality` or `performance`), 80 with anti-aliasing off; 35 to 45 once it has warmed up or is busy. In development. A known bug: the player's car sometimes falls through the road (see below). |

Work in progress, and the measurements behind it: [docs/metal-backend.md](docs/metal-backend.md), [docs/macos.md](docs/macos.md), [docs/BACKLOG.md](docs/BACKLOG.md).

## Building and running

You need a Mac with Apple Silicon, Xcode 16 or newer (or its command line tools), Homebrew and about 12 GB of free disk besides the game:

```bash
git clone https://github.com/m0d16l14n1/mcla-recomp.git
cd mcla-recomp
bash scripts/make_mac.sh --iso /path/to/your.iso
bash scripts/play_mac.sh                              # Vulkan on MoltenVK
bash scripts/play_mac.sh --mcla_gpu_backend=metal     # the native Metal backend
```

`make_mac.sh` checks the tools and offers to install what is missing, applies the fork's patches to the ReXGlue SDK and builds it, then extracts and recompiles your game and builds it. `play_mac.sh` starts the game with a log (`run.log` in the build folder). Any option after it goes to the game, for example `--fullscreen=false` for a window or `--mcla_fps=0` for no frame-rate cap. It also has switches for lldb (`MCLA_LLDB=1`), MoltenVK's debug output (`MCLA_MVK_DEBUG=1`) and Apple's Metal HUD (`MCLA_METAL_HUD=1`).

| | |
|---|---|
| Macs | Apple Silicon (M1 and later), arm64 only. Intel Macs are not a target. |
| Graphics | Vulkan through MoltenVK, or the native Metal backend. On Metal, the game's FSR settings are MetalFX: `--mcla_anti_aliasing=fsr` temporal anti-aliasing, with `--mcla_upscaling=quality`, `balanced` or `performance` upscaling to the window's 720p. Planned: EDR (HDR). |
| Input, audio | SDL3: Xbox and DualSense controllers, keyboard. |
| Not on macOS | Direct3D 12, FSR 3.1 and frame generation, NVIDIA Reflex, AMD Anti-Lag 2, the Windows launcher and installer. |

Every step, building by hand, and debugging: [docs/macos.md](docs/macos.md).

## Metal backend options

The Metal backend's speed-ups are on by default, and each has an off switch for testing:

| Option | What it does |
|---|---|
| `--metal_texture_watches=false` | Hash every texture once a frame instead of watching its memory for CPU writes |
| `--metal_persistent_vertex_size=0` | Copy every vertex range every frame instead of keeping unwritten ones |
| `--metal_snapshot_trust_size=0xFFFFFFFF` | Check every vertex range at every draw (and count the ones that changed) |
| `--metal_pass_merge=false` | Start a render pass for every change of targets |
| `--metal_compose_resolves=false` | Load surfaces the game assembles from resolves from guest memory instead of copying the resolves' textures (`--metal_compose_gaps=false`: only when the resolves cover the whole surface) |
| `--metal_transfers_in_pass=false` | Give each EDRAM transfer a render pass of its own instead of drawing it in the draw's pass |
| `--metal_texture_pool=false` | Make a new texture for every resolve instead of reusing freed ones |
| `--metal_fast_texture_frames=false` | Look every texture up again each frame instead of trusting its write watch |
| `--metal_clears_in_pass=false` | Give each resolve's clear a render pass of its own instead of drawing it in the next pass |
| `--metal_texture_work_before_pass=false` | End and reopen a render pass for a texture load a draw needs, instead of loading it in a command buffer before the pass |
| `--metal_compose_columns=false` | Load a surface resolved in side-by-side pieces (the shadow atlas) from memory instead of making it from the pieces |
| `--metal_constant_generations=false` | Compare all shader constants at every draw instead of only the blocks written since |
| `--metal_cp_qos=0` | Leave the GPU command thread at the default QoS class (4: user interactive) |
| `--mcla_fence_sleep_us=0` | Spin while the game waits for the GPU, as before |
| `--metal_edram_transfers=false` | No EDRAM ownership transfers between targets (the minimap goes wrong) |
| `--metal_shader_storage=false` | No shader storage and warm-up at boot |
| `--metal_taa_upscale=false` | No MetalFX upscaling (the scene drawn at full size whatever `mcla_upscaling` says) |
| `--metal_msaa=true` | MSAA surfaces as Metal multisample textures instead of supersampling (correct, but about half the frame rate; for testing) |
| `--metal_shader_math=1` or `2` | Relaxed or fast math in the shader compiler (shifts the colour grading; for testing) |

Every 150 frames the log has a `Metal frame time` line (frame time, GPU time, texture loads, copies, transfers, render passes) and a `Metal command processor` line with the GPU command thread's CPU time. Diagnostics (frame dumps, GPU traces with `--metal_debug_labels=true`): [docs/metal-backend.md](docs/metal-backend.md).

## Known issues

- **On Metal, the player's car sometimes falls through the road.** This is a race between the game's own threads that the Metal backend's timing exposes; MoltenVK never shows it. It is parked for now: [launcher/dev/metal-car-falls-2026-11-01.md](launcher/dev/metal-car-falls-2026-11-01.md).
- Frame rates vary a lot with what else the Mac runs and with its temperature: with four performance cores, a VM or a busy WindowServer pushes the game's threads onto the efficiency cores, and after a few minutes of load the CPU slows down.
- The Metal backend draws MSAA as supersampling (2x as 1x2, 4x as 2x2): real multisample textures are an option (`--metal_msaa=true`) but half as fast on Apple's GPUs here. It still lacks EDRAM transfers of 64-bit formats, 3D textures, the UI overlays and EDR.
- On a first run, or in new places, objects can be missing for a moment while their shaders compile; the Metal backend translates the shaders of earlier runs at boot.

## More documentation

- [docs/macos.md](docs/macos.md): the macOS build, its plan and debugging.
- [docs/metal-backend.md](docs/metal-backend.md): the Metal backend, its design and its measurements.
- [docs/BACKLOG.md](docs/BACKLOG.md): the macOS work list.
- [patches/README.md](patches/README.md): the SDK patches. [FORK.md](FORK.md): the order of the patches and syncing with upstream.
- [docs/settings.md](docs/settings.md) and [docs/off-switches.md](docs/off-switches.md): the game's settings and the upstream fork's off switches (written for Windows; most apply on the Mac too).
- [Issues](https://github.com/m0d16l14n1/mcla-recomp/issues) for questions and macOS reports.

## Credits

- [mcla-recomp](https://github.com/holdmysocks/mcla-recomp) by holdmysocks, the project this fork builds on; the Linux build is by [@MoonFuji](https://github.com/MoonFuji).
- [RenanQueiroz/mcla-recomp](https://github.com/RenanQueiroz/mcla-recomp), the fork this one follows: its performance work, fixes, settings and launcher.
- ReXGlue SDK by Tom Clay and contributors; Xenia by Ben Vanik and contributors; XenonRecomp by hedge-dev, on which ReXGlue's analysis builds.
- [LARecomp](https://github.com/mzzvxm/LARecomp) by mzzvxm and contributors, whose fixes several parts of this project are ported from.
- [PS5_Vulkan](https://github.com/mihawk-99/PS5_Vulkan) by mihawk-99 (GPL-3): the RADV port and toolchain the upstream PS5 version is built on.
- [LibertyRecomp](https://github.com/hamishakl/LibertyRecomp) (GTA IV, GPL-3.0): the macOS port of ReXGlue and the Metal presenter this fork's macOS work learns from.
- [ForzaHorizon1-ReImagined](https://github.com/Dyotson/ForzaHorizon1-ReImagined) and [RecompiledHaloReach](https://github.com/Dyotson/RecompiledHaloReach) by Dyotson and contributors (MIT), and [xenia-canary](https://github.com/xenia-canary/xenia-canary) and [Xenia](https://github.com/xenia-project/xenia): code and approaches the fork's changes are ported from.

What was taken from each: [docs/fork-changes.md](docs/fork-changes.md#credits-in-detail).

## Licence

GPL-3.0-or-later; see [`LICENSE`](LICENSE). The parts ported from MIT-licensed projects are listed under Credits, and their licence notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). *Midnight Club* is a trademark of Take-Two Interactive. This project is not affiliated with or endorsed by Rockstar Games or Take-Two.
