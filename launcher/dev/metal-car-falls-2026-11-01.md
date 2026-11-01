# The car falls through the city on Metal (2026-11-01, open, parked)

**Symptom.** On the Metal backend (`--mcla_gpu_backend=metal`) the player's car sometimes loses its
collision: traffic drives through it, the game puts it back on the road about 100 m away, and it then
falls through the road again and again (Y down to about -75; the road on the test route is at 14.5 to 18).
Twice a run instead ended in a guest null-pointer loop that filled the log until it rotated:
`read of guest 0x000004E8` on a worker thread in physics code (thread entry sub_82460F08, ...,
sub_825A3838, sub_825904F8), and once `write of guest 0x00000002` on another thread.

**Where it stands.** Not fixed, and parked on purpose (2026-11-01): the GPU work goes on and the route test
below says whether a later change made it go away. It is a race between the game's own threads that the
Metal command processor's timing exposes; nothing the GPU writes is involved.

## The test

A drive of the user's, recorded once, is replayed by the dev pad's route follower, so it runs unattended:

1. `sh launcher/dev/drive-test/record-drive.sh <name>`: the game on Metal with keyboard and trackpad, the
   car's position logged 4 times a second from free roam on, the pad recorded. You drive, then quit.
2. `python3 launcher/dev/route.py from-pos out/research/drives/<name>.log launcher/dev/drive-test/<name>.route`:
   positions to a route (split at jumps of more than 60 m or 8 m in height, the longest piece kept).
   `drive-capped.route` is the user's drive (321 points, 1,275 m); `drive-short.route` its first 55%
   (176 points, 695 m), about a minute of driving.
3. `sh launcher/dev/drive-test/route-test.sh <label> <runs> [game options]` (`BACKEND=vulkan` for
   MoltenVK, `ROUTE=` for another route): boots to free roam, follows the route, logs 240 positions, prints
   `N/240 below Y 10, min Y`, the frame time, whether the route was finished and the guest access
   violations. Logs in `out/research/drives/t-<label>-<run>.log`.

One run takes about 3 minutes. A clean run proves little (capped Metal fell in about half the runs):
use 3 or more.

## Results

Uncapped is `--mcla_fps=0`. "Falls" counts runs with positions under the road.

| Setup | Falls | Frame time | What it tells |
|---|---|---|---|
| Metal uncapped | ~8/8 | 25-35 ms | the bug |
| Metal capped (30 FPS) | ~3/5 | 33 ms | not only uncapped |
| `--mcla_fps=60`, `--mcla_fixed_dt=30` | fall | 32-33 ms | not the frame rate or the simulation step |
| MoltenVK (`BACKEND=vulkan`) uncapped | 0/4 | ~50 ms | Metal only |
| `--metal_resolve_wait=true`, and the other wait-for-the-GPU variants | 0/6 | 57-81 ms | long stalls never trigger it |
| `--metal_resolve_to_memory=false` (resolves write nothing to guest memory) | falls | 29 ms | GPU writes to guest memory are not it |
| `--metal_gpu_fences=true` (fences written by the GPU, after the work before them) | 2/2 | 33 ms | fence order is not it |
| `MTL_SHADER_VALIDATION=1` | 0/1, no errors | 338 ms | no out-of-bounds GPU access |
| hot-page watches off | 1/2 | 25-30 ms | not the write watches |
| `--metal_texture_loads=false`, `--metal_draw_calls=false` | 2/2, 2/2 | 15-35 ms | not textures, not the draws themselves |
| `--metal_draw=false` (no draws, no resolves) | 0/2 | 33 ms | |
| `--metal_draw_cpu_only=true` (draws stop after the CPU side) | 0/2 | 8 ms | 120 FPS does not trigger it |
| `--metal_draw_stop=2` (no render targets, so resolves do nothing) | 1/2 (11 samples) | 8 ms | |
| `--metal_draw_stop=3` (resolves run, draws don't) | 2/2 | 8-12 ms | |
| the same, `--metal_resolve_to_memory=false` | 4/4 | 9-15 ms | |
| the same, `--metal_cp_qos=2` (command processor at utility QoS) | 1/1 | 10-14 ms | |
| `--metal_draw_stop=3 --metal_resolves=false` | 0/2 | 8-9 ms | no GPU work at all: never |
| the same plus `--metal_frame_sleep_ms=18` | 0/2 | 24-26 ms | a pause at the frame's end: never |
| the same plus 6 `yes` processes loading the CPU | 0/3 | 11-13 ms | CPU load: never |
| the same plus `--metal_resolve_spin_us=60` | 1/3 | 8-10 ms | **a pause at every resolve: falls, without any GPU work** |
| the same plus `--metal_resolve_spin_us=200` | 1/3, and 1 crash | 12-19 ms | |
| the same plus `--metal_fence_spin_us=1000` | **3/3** | 29-32 ms | a pause before every fence: falls |
| the same plus `--metal_draw_spin_us=2` | 1/1 | 24 ms | a pause at every draw: falls |
| PowerPC barriers made real on ARM64 (below), uncapped | 3/4 | 26-54 ms | not memory ordering |

The falls happen all along the route (x 816 to 1111), not at one place.

**Reading it.** The car falls when the command processor falls behind the game in the middle of a frame,
by a little: at resolves, before fences or at draws, with or without GPU work. It does not fall when the
command processor is always ahead (no GPU work: `draw_cpu_only`, `draw_stop=3` without resolves), when the
pause is at the end of the frame, or when the stalls are long (waiting for the GPU at every resolve, or
MoltenVK). A fast repro without the GPU: `route-test.sh fencespin 3 --mcla_fps=0 --metal_draw_stop=3
--metal_resolves=false --metal_fence_spin_us=1000`.

## What was ruled out, and how

- **GPU writes to guest memory.** Resolves bounded to their destination extent (a counter of bytes outside
  it: always 0), resolves not writing memory at all (still falls), memexport (none in free roam), shader
  validation (clean), GPU command buffer errors (none).
- **Fence order.** `patches/rexglue-fence-hook.patch` (SDK) adds `CommandProcessor::WriteFenceValue`;
  Metal's override writes the fence with a blit after the work before it (`--metal_gpu_fences=true`, off by
  default: about 10 ms a frame). Still falls. LARecomp (below) retires every fence the moment it is issued
  and the game is fine.
- **PowerPC memory barriers.** The recompiler emitted `sync`, `lwsync` and `eieio` as nothing ("x86 keeps
  stores in order"), which is wrong on ARM64: the guest's lock release is `lwsync; stw 0, lock`.
  `patches/rexglue-ppc-barriers-arm64.patch` makes them `REX_SYNC()`, `REX_LWSYNC()`, `REX_EIEIO()`
  (`__atomic_thread_fence`, `dmb ish` on ARM64, nothing on x86; 58 lwsync, 9 sync, 14 eieio in the game).
  Kept, as it is correct, but it did not stop the falls.
- **ABA through the reservation emulation.** `lwarx` is a plain load and `stwcx.` a compare-and-swap, so a
  lock-free pop through the reserved pointer could succeed wrongly. The game has 45 reservation sites; all
  are counters, exchanges or compare-and-swaps against values loaded earlier, which behave the same.
- **The interrupt callback** (sub_82411478) runs on the vsync thread and the command processor's, but
  `FunctionDispatcher::ExecuteInterrupt` holds the global lock, as do the guest's `mtmsrd` critical sections.
- **The SDK's multi-object wait** (`PosixConditionBase::WaitMultiple`, polling in 1 ms sleeps) locks every
  handle before it checks and consumes them: slow, not wrong. The game's job wait (sub_821C4338 ->
  sub_8244ED48 -> `NtWaitForMultipleObjectsEx`, infinite, retried on alerts) is straightforward too.

## What is known about the game side

- The crash: sub_825904F8 walks a node's children (pointers at node+760, stored as child+48; count at
  node+1304) and recurses; a child pointer was 0 while the count said there were more. Either the list is
  being changed by another thread while a worker walks it, or a node was freed and reused.
- Thread sampling (`sample <pid> 4 1`) of the main thread in free roam: about half the time waiting on a
  single object in sub_82305D00 -> sub_823057E8 (the render side), about a quarter in physics
  (sub_8258D1A0 -> sub_8258E4D0 -> sub_8258D9F0) waiting for its jobs on about ten worker threads
  (sub_824E6A80) through the polling multi-object wait.
- The game moves threads between processors about 1,000 times a second (`XSetThreadProcessor`,
  sub_82131E48), raises IRQL to DPC level at 92 call sites and disables interrupts with `mtmsrd` for
  per-processor work. The SDK ignores guest affinities and priorities (`ignore_thread_affinities`,
  `ignore_thread_priorities`; macOS has no affinity API anyway), so threads the console kept on one
  hardware thread run in parallel here. The likeliest family of cause, not proven.

## From LARecomp (github.com/mzzvxm/LARecomp, Windows, ReXGlue 0.10.0)

Our frame timing hooks already come from it (`config/frame_timing.toml`), and the vblank-loop fix its notes
describe is in our SDK. Facts from it that matter here: the guest's retired fence is the dword at
D3DDevice+0x2A90, and its no-command-processor mode retires every fence at once without trouble; the game's
frame pacing is built on the vblank counter; the vblank handler retires flips by writing register 0x1844;
physics integrates the measured delta, capped at 0.1 s by the engine. Its notes do not mention the car
falling through the city.

## Next, if it is picked up again

1. Log, per frame, the guest waits of the main and render threads (object, caller, how long) in a falling
   and a clean run, to find the wait whose order changes.
2. Find who writes the child list of the node in sub_825904F8 and from which thread (a watch on the node
   once the crash path sees a null child).
3. Try making guest threads that share a hardware thread exclude each other (a mutex per guest processor,
   taken while a thread runs guest code at raised IRQL or with interrupts disabled).

## Diagnostic switches (Metal backend, all off by default)

`metal_draw`, `metal_resolves`, `metal_draw_cpu_only`, `metal_draw_stop` (2, 3, 4), `metal_texture_loads`,
`metal_draw_calls`, `metal_resolve_to_memory`, `metal_resolve_wait`, `metal_gpu_fences`, `metal_cp_qos`,
`metal_frame_sleep_ms`, `metal_resolve_spin_us`, `metal_fence_spin_us`, `metal_draw_spin_us`; in
`metal_command_processor.mm` and `metal_draw.mm`.
