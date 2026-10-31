# macOS (Apple Silicon)

This fork's own target: *Midnight Club: Los Angeles Complete Edition* built and run natively on a Mac with
Apple Silicon. The game's PowerPC code is recompiled to arm64 C++ by the same ReXGlue SDK v0.10.0 and the same
patches as the Windows, Linux and PS5 builds. Status, what was checked and what was not: the macOS row of the
README's status table and [BACKLOG.md](BACKLOG.md).

## The plan

| Phase | What | Graphics |
|---|---|---|
| 1. Boot | The SDK and the game build for `mac-arm64`; the game starts, loads, and reaches the menus | Xenos GPU emulation on **Vulkan through MoltenVK** (the SDK builds its pinned MoltenVK and Vulkan loader and puts them next to the game) |
| 2. Play | Career, races, garage, audio, controller; the fork's settings that make sense on a Mac | MoltenVK, with the fixes it needs (no geometry shaders on Metal: the SDK's vertex-shader expansion of point and rectangle lists is used) |
| 3. Native Metal | A Metal backend for the SDK's Xenos emulation, next to the Vulkan one, picked with `--mcla_gpu_backend=metal`; design and milestones in [metal-backend.md](metal-backend.md) (M0, the game running on it without drawing, is done) | **Metal**: presentation through `CAMetalLayer`, then `CAMetalDisplayLink` pacing, EDR (HDR), MetalFX upscaling, Metal binary archives in place of the shader pack |

Phase 3 is the part meant to be shared. The other Apple Silicon ports of Xbox 360 games all draw through MoltenVK
([SpeedBreaker](https://github.com/SpeedBreakerProject/speedbreaker), Need for Speed: Most Wanted, built on
XenonRecomp), or through a renderer written for their one game
([LibertyRecomp](https://github.com/hamishakl/LibertyRecomp)'s `gta4-metal`, GTA IV). A Metal backend for the
SDK's generic Xenos emulation would serve every ReXGlue title on macOS. It goes in as SDK patches
(`patches/rexglue-metal-*.patch`) so that it can be offered upstream like the fork's other SDK changes. macOS is
the only target of this fork; other platforms are out of scope.

What can be taken from LibertyRecomp (a ReXGlue 0.9 fork; GPL-3.0) without the GTA IV parts: the Metal presenter
and frame ring (`src/ui/metal/`), the pipeline archive store and the clearing of Apple's per-app shader cache before
a rebuild, the CAMetalDisplayLink pacing, the HUD re-exec (`MTL_HUD_ENABLED` is read before `main()`), and the
always-on errors log. Its `gta4_metal` renderer replaces the game's own draw calls and is not reusable as it is.

## Building

You need macOS on Apple Silicon, Xcode 16 or newer (or its command line tools; Clang 18+), Homebrew, CMake 3.25+,
Ninja, Python 3.10+, Git, and about 12 GB of free disk besides the game (the SDK checkout and its build about
3 GB, the extracted game 6.1 GB, the game's build 2 to 3 GB). Optional for debugging: `brew install vulkan-tools`
(`vulkaninfo`).

```bash
bash scripts/make_mac.sh --iso /path/to/your.iso
```

It checks the tools (and offers to install what Homebrew can), clones the SDK at v0.10.0 into
`third_party/rexglue-sdk`, applies the patches in the same order as the Linux and PS5 builds (the list is read
from the table in `ps5/make_ps5.sh`), builds and installs the SDK (the long step, once), extracts your game into
`game/`, recompiles it and builds `out/build/mac-arm64-relwithdebinfo/mcla`. Run it again after a failure and it
continues; `--config Debug` or `--config Release` builds another configuration. The logs of each step are in
`out/logs/`.

By hand, the same steps:

```bash
git clone --recursive --depth 1 --shallow-submodules --branch v0.10.0 https://github.com/rexglue/rexglue-sdk.git third_party/rexglue-sdk
# the patches: see scripts/make_mac.sh, step 2
cd third_party/rexglue-sdk
cmake --preset mac-arm64 -DREXGLUE_USE_VULKAN=ON -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_ENABLE_FSR=OFF
cmake --build out/build/mac-arm64 --config Release
cmake --install out/build/mac-arm64 --config Release
cd ../..
python3 scripts/extract_game.py /path/to/your.iso
third_party/rexglue-sdk/out/install/mac-arm64/bin/rexglue codegen mcla_manifest.toml
cmake --preset mac-arm64-relwithdebinfo -DCMAKE_PREFIX_PATH=$PWD/third_party/rexglue-sdk/out/install/mac-arm64
cmake --build --preset mac-arm64-relwithdebinfo
```

The SDK installs the recompiler (`rexglue`), MoltenVK and the Vulkan loader from its Release configuration only,
so build Release first; a RelWithDebInfo SDK build (`--config RelWithDebInfo` in the two SDK commands) beside it
gives the runtime's symbols to the debugger.

On macOS the game changes a few defaults (`src/mcla_app.cpp`; anything set by hand wins): the audio threads at QoS
user-interactive (`audio_thread_priority`, `audio_mixer_priority` 2), a 256-sample output buffer
(`audio_device_sample_frames`) and a 4-frame queue (`audio_maxqframes`), for about 27 ms from the game's mixer to the
speakers instead of about 64. If the sound crackles, `--audio_maxqframes=8` is the PC default.

FSR 3.1 is not built on macOS (FidelityFX's Vulkan library is not made for MoltenVK); the game offers MSAA and off.
NVIDIA Reflex, AMD Anti-Lag, D3D12 and the Windows launcher do not apply.

## Running and debugging

```bash
bash scripts/play_mac.sh
```

starts the game from its build folder with `--log_file=run.log --log_level=info` (the log is
`out/build/mac-arm64-relwithdebinfo/run.log`). Other options are passed on to `mcla`; every one is in
[off-switches.md](off-switches.md) and [settings.md](settings.md). Switches for research:

| Variable | What |
|---|---|
| `MCLA_LLDB=1` | Start under `lldb`; on a crash, `bt all` gives every thread's stack, and the guest's function names are the `sub_XXXXXXXX` in the stack |
| `MCLA_MVK_DEBUG=1` | MoltenVK's debug logging and Metal's API validation (slow; for rendering bugs) |
| `MCLA_METAL_HUD=1` | Apple's Metal performance HUD (frame time, GPU time, memory) |
| `MCLA_BUILD=debug` | Use the Debug build folder (`--config Debug` in `make_mac.sh`) |
| `--log_level=debug` | More of the SDK's logging; `trace` for everything |

For unattended research runs the fork's scripted controller (`src/dev_pad.cpp`) works on macOS as it is:
`--mcla_pad_script=<file.pad>` presses buttons, waits for game states (`left_title`, `roam`, ...), takes
screenshots of the game's output (`shot name.png`) and quits. Example scripts are in `launcher/dev/scripts/`; a
boot-to-free-roam one:

```
wait 30s
press_until start left_title every=2s timeout=90s
press_until a roam every=3s timeout=240s
wait 10s
shot roam.png
quit
```

### Measuring

- `sh scripts/mac_bench.sh "" "--mcla_anti_aliasing=off" ...` runs the free-roam benchmark once per quoted set
  of options (the first, empty, is the baseline): a fresh start each time, driven to the spawn point, uncapped,
  engine frames counted over 10 s. Results print as `n: FPS [options]`; logs and the final picture are in
  `out/bench/`. A run takes about 3 minutes.
- `--vulkan_pass_stats=true` logs, per frame, the render passes and what ended them. On Apple's tile-based GPUs
  each render pass break stores and reloads the attachments, so that number is the first thing to look at.
- `--audio_stats=true` logs the audio pump's rounds, late wake-ups and the output queue every 10 s.
- `xcrun xctrace record --template 'Metal System Trace' --attach $(pgrep -x mcla) --time-limit 6s --output
  roam.trace` records the GPU timeline (about 500 MB for 6 s); open it in Instruments.

A Metal frame capture for Xcode: `MTL_CAPTURE_ENABLED=1` and Xcode's *Debug › Attach to Process*, then the
capture button; or Instruments' *Metal System Trace* for timing. If the game stops with *Call to invalid or
unregistered function at guest address ...*, the recompiler missed a function; that is not macOS-specific and is
reported upstream.

Your game files are in `game/` (extracted from your disc image; gitignored, like `MCLA/` where the image is kept).
Never commit or share them.
