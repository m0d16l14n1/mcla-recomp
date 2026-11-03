#!/usr/bin/env python3
"""Race benchmark for macOS: the game's settings ("modes") in a high-speed arcade race.

Each run is a fresh start of the game, windowed: boot, the pause menu's Arcade, the ordered race
"Sunset and Vine" (7 opponents, rain, midnight; launcher/dev/scripts/boot-to-race.pad), and the
player's car driven at race speed (about 100 km/h on average, up to 120) by the dev pad's route
follower along the route the leading opponent drove (sunset-and-vine.route), for --race-seconds of
the race's own clock. Scenario "drive" instead drives a route in free roam (drive-short.route).

    python3 scripts/mac_race_bench.py msaa60 perf60 fg              # named modes (--list)
    python3 scripts/mac_race_bench.py --runs 2 --cooldown 120 all   # every named mode
    python3 scripts/mac_race_bench.py "mine=--mcla_fps=0 --metal_texture_mips=false"
    python3 scripts/mac_race_bench.py --runs 2 --cool-to 1 perf60 "b=<options>"  # an A/B on a cooled Mac
    python3 scripts/mac_race_bench.py --sample 8 perf60      # a CPU profile 15 s into the race
    python3 scripts/mac_race_bench.py --gputrace perf-unc    # a 3 s Metal System Trace, by encoder label
    python3 scripts/mac_race_bench.py cpu-only nodraw        # diagnostics: where the limit is

This Mac's thermal pressure decides more of a run's FPS than most changes do (a run starting at level 0 can be
20 to 35% faster than one at 2): compare variants in alternating runs with --cool-to.

For each run, from the race's start to its end mark:
  - guest swaps (the game's frames, --mcla_pad_frames_csv): mean FPS, median, 99th percentile and
    1% low, the longest frame, and hitches: frames over twice the median and over 25 ms, and over
    100 ms (freezes);
  - what reached the display (the Metal presenter's drawables, --metal_present_times): frames shown
    a second, the longest gap, gaps over 1.5 and 3 refreshes; generated frames with frame generation;
  - from the log: the Metal stats lines (GPU busy, command thread CPU time), pipelines compiled and
    draws left out while compiling, the route follower's recoveries, warnings and errors, guest
    access violations, and whether the run reached the end (a crash or hang does not).
The save data is a scratch copy (out/bench-race/user, from ~/.local/share/mcla once); the shader
and pipeline storage is a persistent one (out/bench-race/cache), so after the first run it is warm,
as for a player; --cold empties it (and the build's Metal shader cache can't be emptied: it's the
system's shared one for unbundled programs). Results: out/bench-race/<stamp>/summary.md and .json.
"""

import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "launcher" / "dev" / "scripts"
DRIVE = REPO / "launcher" / "dev" / "drive-test"
ROOT = REPO / "out" / "bench-race"
REAL_USER = Path.home() / ".local" / "share" / "mcla"

# The modes: the settings a player can pick (launcher, pause menu, mcla.toml) on Metal. Every run
# also gets --mcla_gpu_backend=metal --fullscreen=false; the rest are the game's defaults (MSAA 2x,
# HDR auto, 4x anisotropic, smooth UI on) unless a mode sets them.
FG = "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --frame_generation=fsr"
MODES = {
    # MSAA 2x (the game's default)
    "msaa60": "--mcla_fps=60",
    "msaa30": "--mcla_fps=30",
    "msaa-unc": "--mcla_fps=0",
    # anti-aliasing off
    "off60": "--mcla_anti_aliasing=off --mcla_fps=60",
    "off-unc": "--mcla_anti_aliasing=off --mcla_fps=0",
    # MetalFX temporal AA at 720p, and upscaling
    "taa60": "--mcla_anti_aliasing=fsr --mcla_fps=60",
    "taa-unc": "--mcla_anti_aliasing=fsr --mcla_fps=0",
    "quality60": "--mcla_anti_aliasing=fsr --mcla_upscaling=quality --mcla_fps=60",
    "perf60": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=60",  # MCLA.app's default
    "perf-unc": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=0",
    "perf120": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=120",
    "perf45": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=45",
    # MetalFX frame generation: HALF DISPLAY (29 rendered on 60 Hz), and 30 rendered
    "fg": FG + " --mcla_fps_frame_generation=-1",
    "fg30": FG + " --mcla_fps_frame_generation=30",
    "fg-taa": "--mcla_anti_aliasing=fsr --frame_generation=fsr --mcla_fps_frame_generation=-1",
    # HDR off (SDR output) in the two main modes
    "msaa60-sdr": "--mcla_fps=60 --hdr=off",
    "perf60-sdr": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=60 --hdr=off",
    # Single-tile rendering with MSAA, the low-end preset, smooth UI off
    "msaa60-1tile": "--mcla_fps=60 --mcla_single_tile=true",
    "low60": "--mcla_preset=low --mcla_fps=60",
    "perf60-nosmooth": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=60 --mcla_ui_interpolate=false",
}
QUICK = ["msaa60", "perf60", "perf-unc", "fg", "taa60", "off-unc"]
# Diagnostics, not in "all": where the limit is. cpu-only: draws stop after the primitive processor (no
# Metal work: the game's own threads and the command thread's front end); nodraw: no draws or resolves at all.
DIAG = {
    "cpu-only": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=0 --metal_draw_cpu_only=true",
    "nodraw": "--mcla_anti_aliasing=fsr --mcla_upscaling=performance --mcla_fps=0 --metal_draw=false",
}


def thermal():
    try:
        out = subprocess.run(["notifyutil", "-g", "com.apple.system.thermalpressurelevel"],
                             capture_output=True, text=True, timeout=5).stdout.split()
        return int(out[-1])
    except Exception:
        return -1


def race_pad(out, seconds):
    lines = [
        "# Generated by scripts/mac_race_bench.py: the race benchmark.",
        f"include {SCRIPTS / 'boot-to-race.pad'}",
        "autocontinue on",
        f"follow {SCRIPTS / 'sunset-and-vine.route'}",
        "wait_until f32 0x827D7510 >= 9.3 300s",
        "mark race",
        f"wait_until f32 0x827D7510 >= {9.3 + seconds:.1f} {int(seconds * 4 + 60)}s",
        "mark race_end",
        "follow status",
        f"shot {out / 'race-end.png'} 0.5",
        "follow stop",
        "quit",
    ]
    return "\n".join(lines) + "\n"


def drive_pad(out, seconds):
    lines = [
        "# Generated by scripts/mac_race_bench.py: a drive in free roam.",
        "wait 30s",
        "press_until start left_title every=2s timeout=120s",
        "press_until a roam every=3s timeout=240s",
        "wait 3s",
        f"follow {DRIVE / 'drive-capped.route'}",
        "wait 2s",
        "mark race",
        f"wait {seconds}s",
        "mark race_end",
        "follow status",
        f"shot {out / 'race-end.png'} 0.5",
        "follow stop",
        "quit",
    ]
    return "\n".join(lines) + "\n"


def segment(frames_csv, start="race", end="race_end"):
    """Swap times (ms) and the steady-clock window (ns) between two marks of a frames.csv."""
    t0 = None
    frames, inside, window = [], False, [None, None]
    last_s = 0
    for line in Path(frames_csv).read_text().splitlines()[1:]:
        parts = line.split(",")
        if len(parts) < 4:
            continue
        kind = parts[0]
        try:
            if kind == "t0":
                t0 = int(parts[1])
            elif kind == "s":
                last_s = int(parts[1])
                if inside and int(parts[2]) > 0:
                    frames.append(int(parts[2]) / 1000.0)
            elif kind == "mark":
                if parts[1] == start:
                    inside = True
                    window[0] = (t0 or 0) + last_s * 1000
                elif parts[1] == end and inside:
                    inside = False
                    window[1] = (t0 or 0) + last_s * 1000
        except ValueError:
            continue
    return frames, window


def frame_stats(frames):
    if len(frames) < 10:
        return None
    ordered = sorted(frames)
    med = statistics.median(frames)
    worst = ordered[-max(1, len(ordered) // 100):]
    return {
        "frames": len(frames),
        "seconds": round(sum(frames) / 1000.0, 2),
        "fps": round(1000.0 * len(frames) / sum(frames), 1),
        "median_ms": round(med, 2),
        "p99_ms": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))], 2),
        "low1_fps": round(1000.0 / statistics.mean(worst), 1),
        "max_ms": round(ordered[-1], 1),
        "hitches": sum(1 for f in frames if f > 2 * med and f > 25.0),
        "freezes": sum(1 for f in frames if f > 100.0),
    }


def present_stats(path, window, refresh_hz=60.0):
    if not path.exists() or not window[0] or not window[1]:
        return None
    shown, gen, dropped = [], 0, 0
    for line in path.read_text().splitlines()[1:]:
        parts = line.split(",")
        if len(parts) < 3:
            continue
        try:
            ns, kind, steady = int(parts[0]), parts[1], int(parts[2])
        except ValueError:
            continue
        if not (window[0] <= steady <= window[1]):
            continue
        if ns == 0:
            dropped += 1
            continue
        shown.append(ns)
        gen += kind == "g"
    if len(shown) < 10:
        return None
    shown.sort()
    gaps = [(b - a) / 1e6 for a, b in zip(shown, shown[1:]) if b > a]
    span = (shown[-1] - shown[0]) / 1e9
    refresh = 1000.0 / refresh_hz
    return {
        "shown_fps": round(len(gaps) / span, 1) if span > 0 else 0,
        "generated": gen,
        "dropped": dropped,
        "max_gap_ms": round(max(gaps), 1),
        "gaps_1_5": sum(1 for g in gaps if g > 1.5 * refresh),
        "gaps_3": sum(1 for g in gaps if g > 3 * refresh),
        "gap_p99_ms": round(sorted(gaps)[int(len(gaps) * 0.99)], 1),
    }


NUM = r"([0-9.]+)"


def log_stats(log):
    text = log.read_text(errors="replace") if log.exists() else ""
    lines = text.splitlines()
    # The race window in the log: after the follow's start and the race mark.
    start = next((i for i, l in enumerate(lines) if "dev pad: mark race at" in l), 0)
    end = next((i for i, l in enumerate(lines) if "dev pad: mark race_end at" in l), len(lines))
    body = lines[start:end + 1]
    r = {}
    gpu = [float(m.group(1)) for l in body if (m := re.search(r"GPU busy " + NUM + " ms", l))]
    cpu = [float(m.group(1)) for l in body if (m := re.search(r"Metal command processor: " + NUM + " ms of CPU", l))]
    created = [int(m.group(1)) for l in body if (m := re.search(r"; (\d+) pipelines created", l))]
    left = [int(m.group(1)) for l in body if (m := re.search(r"(\d+) draws left out while Metal compiled", l))]
    r["gpu_busy_ms"] = round(statistics.mean(gpu), 1) if gpu else None
    r["cp_cpu_ms"] = round(statistics.mean(cpu), 1) if cpu else None
    r["pipelines_new"] = sum(created)
    r["draws_left_out"] = sum(left)
    r["warnings"] = sum(1 for l in body if "] [warning]" in l and "NtCreateFile" not in l)
    r["errors"] = sum(1 for l in body if "] [error]" in l or "] [critical]" in l)
    r["access_violations"] = text.count("Unhandled guest access")
    m = None
    for l in lines:
        if "dev pad: follow" in l:
            m = re.search(r"recoveries=(\d+)", l) or m
    r["follow_recoveries"] = int(m.group(1)) if m else None
    r["reached_end"] = any("dev pad: mark race_end at" in l for l in lines)
    warn_kinds = {}
    for l in body:
        if "] [warning]" in l or "] [error]" in l:
            key = re.sub(r"\[t[0-9a-f]+\]", "", l.split("] ", 1)[-1])
            key = re.sub(r"0x[0-9A-Fa-f]+|\d+", "#", key)[:140]
            warn_kinds[key] = warn_kinds.get(key, 0) + 1
    r["warning_kinds"] = dict(sorted(warn_kinds.items(), key=lambda kv: -kv[1])[:8])
    return r


def prepare_user(fresh):
    user = ROOT / "user"
    pristine = ROOT / "user-pristine"
    if fresh or not pristine.exists():
        shutil.rmtree(pristine, ignore_errors=True)
        shutil.copytree(REAL_USER, pristine, ignore=shutil.ignore_patterns("cache"))
    shutil.rmtree(user, ignore_errors=True)
    shutil.copytree(pristine, user)
    return user


def kill_game():
    subprocess.run(["pkill", "-9", "-x", "mcla"], capture_output=True)
    time.sleep(1)


def profile_race(out, seconds, log, gputrace=False):
    """--sample: 15 s into the race, the game's threads (ps -M) and a CPU profile (sample). --gputrace: a 3 s
    Metal System Trace instead, summed by encoder label (out/research/parse_gputrace.py) into gputrace.txt."""
    deadline = time.time() + 400
    while time.time() < deadline:
        if log.exists() and "dev pad: mark race at" in log.read_text(errors="replace"):
            break
        time.sleep(1)
    else:
        return
    time.sleep(15)
    pid = subprocess.run(["pgrep", "-x", "mcla"], capture_output=True, text=True).stdout.split()
    if not pid:
        return
    if gputrace:
        trace = out / "gpu.trace"
        t0 = time.time()
        subprocess.run(["xcrun", "xctrace", "record", "--template", "Metal System Trace", "--attach", pid[0],
                        "--time-limit", "3s", "--output", str(trace)], capture_output=True)
        (out / "gputrace-window.txt").write_text(f"{t0} {time.time()}\n")
        return
    with open(out / "threads.txt", "w") as f:
        subprocess.run(["ps", "-M", "-p", pid[0]], stdout=f, stderr=subprocess.STDOUT)
    subprocess.run(["sample", pid[0], str(seconds), "-file", str(out / "sample.txt")], capture_output=True)


def watch_load(stop, into):
    """While a run plays: the 1-minute load average, and other processes busier than half a core (another
    session's game or build skews a run's numbers; the summary flags it)."""
    while not stop.wait(5):
        into["load"].append(os.getloadavg()[0])
        try:
            ps = subprocess.run(["ps", "-Ao", "pcpu=,comm="], capture_output=True, text=True, timeout=5).stdout
        except Exception:
            continue
        for line in ps.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2:
                continue
            try:
                cpu = float(parts[0])
            except ValueError:
                continue
            comm = parts[1].rsplit("/", 1)[-1]
            if cpu >= 50 and comm not in ("mcla", "WindowServer", "kernel_task", "sample", "xctrace"):
                into["others"][comm] = max(into["others"].get(comm, 0), round(cpu))


def run_one(name, extra, out, a):
    out.mkdir(parents=True, exist_ok=True)
    user = prepare_user(False)
    cache = ROOT / ("cache-cold" if a.cold else "cache")
    if a.cold:
        shutil.rmtree(cache, ignore_errors=True)
    cache.mkdir(parents=True, exist_ok=True)
    pad = out / "bench.pad"
    pad.write_text((race_pad if a.scenario == "race" else drive_pad)(out, a.race_seconds))
    args = [
        "--fullscreen=false", "--mcla_gpu_backend=metal",
        f"--user_data_root={user}", f"--cache_root={cache}",
        f"--log_file={out / 'game.log'}", f"--mcla_pad_script={pad}",
        "--mcla_pad_exit_on_end=true", f"--mcla_pad_frames_csv={out / 'frames.csv'}",
        f"--metal_present_times={out / 'present.csv'}",
        f"--mcla_pad_timeout_shot={out / 'timeout.png'}",
    ]
    if a.gputrace:
        args.append("--metal_debug_labels=true")
    # One value per option, the mode's last (the SDK's parser fails on a repeated option).
    merged = {}
    env = dict(os.environ)
    for arg in args + extra.split():
        if arg.startswith("env:"):  # env:NAME=VALUE, for this run's game (MTL_HUD_ENABLED=0, say)
            k, _, v = arg[4:].partition("=")
            env[k] = v
            continue
        merged[arg.split("=", 1)[0]] = arg
    th0 = thermal()
    t0 = time.time()
    load = {"load": [], "others": {}}
    load_stop = threading.Event()
    load_thread = threading.Thread(target=watch_load, args=(load_stop, load), daemon=True)
    load_thread.start()
    with open(out / "stdout.txt", "w") as so:
        proc = subprocess.Popen(["sh", str(REPO / "scripts" / "play_mac.sh"), *merged.values()],
                                stdout=so, stderr=subprocess.STDOUT, start_new_session=True, env=env)
        profiler = None
        if a.sample or a.gputrace:
            profiler = threading.Thread(target=profile_race, args=(out, a.sample, out / "game.log", a.gputrace),
                                        daemon=True)
            profiler.start()
        try:
            proc.wait(timeout=a.timeout)
            hung = False
        except subprocess.TimeoutExpired:
            hung = True
            os.killpg(proc.pid, signal.SIGKILL)
    load_stop.set()
    if profiler:
        profiler.join(timeout=180)  # xctrace writes its trace for a while after recording
    kill_game()
    if a.gputrace and (out / "gpu.trace").exists():
        xml = out / "gpu-int.xml"
        with open(xml, "w") as f:
            subprocess.run(["xcrun", "xctrace", "export", "--input", str(out / "gpu.trace"), "--xpath",
                            '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]'], stdout=f)
        frames = 3 * 50
        with open(out / "gputrace.txt", "w") as f:
            subprocess.run([sys.executable, str(REPO / "out" / "research" / "parse_gputrace.py"), str(xml), "mcla",
                            str(frames)], stdout=f, stderr=subprocess.STDOUT)
    result = {"mode": name, "args": extra, "thermal_start": th0, "thermal_end": thermal(),
              "wall_s": round(time.time() - t0), "hung": hung, "exit": proc.returncode,
              "load": round(sum(load["load"]) / len(load["load"]), 1) if load["load"] else None,
              "others": load["others"]}
    return analyze_run(out, result)


def analyze_run(out, result):
    """The per-run figures from a run's folder (frames.csv, present.csv, game.log) into result."""
    frames_csv = out / "frames.csv"
    if frames_csv.exists():
        frames, window = segment(frames_csv)
        result["swaps"] = frame_stats(frames)
        result["display"] = present_stats(out / "present.csv", window)
    result["log"] = log_stats(out / "game.log")
    return result


def fmt(r):
    s, d, l = r.get("swaps") or {}, r.get("display") or {}, r.get("log") or {}
    ok = "ok" if l.get("reached_end") and not r.get("hung") else ("HUNG" if r.get("hung") else "FAILED")
    return (f"| {r['mode']} | {ok} | {s.get('fps', '-')} | {s.get('median_ms', '-')} | {s.get('p99_ms', '-')} | "
            f"{s.get('low1_fps', '-')} | {s.get('max_ms', '-')} | {s.get('hitches', '-')} | {s.get('freezes', '-')} | "
            f"{d.get('shown_fps', '-')} | {d.get('max_gap_ms', '-')} | {d.get('gaps_1_5', '-')} | {d.get('gaps_3', '-')} | "
            f"{l.get('gpu_busy_ms', '-')} | {l.get('cp_cpu_ms', '-')} | {l.get('pipelines_new', '-')} | "
            f"{l.get('draws_left_out', '-')} | {l.get('warnings', '-')}/{l.get('errors', '-')} | "
            f"{r.get('thermal_start')}->{r.get('thermal_end')} | {r.get('load', '-')} |")


HEADER = ("| mode | run | FPS | median ms | p99 ms | 1% low | max ms | hitches | freezes | shown/s | "
          "max gap ms | gaps>1.5r | gaps>3r | GPU ms | CP ms | new PSOs | draws left out | warn/err | thermal | load |\n"
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")


def write_summary(folder, results, what):
    md = [f"# Race bench {folder.name} ({what})", "", HEADER, *[fmt(r) for r in results], ""]
    busy = [r for r in results if r.get("others")]
    if busy:
        md.append("## Other busy processes during runs (more than half a core; the numbers may be skewed)")
        md += [f"- {r['mode']} run {r.get('run')}: " + ", ".join(f"{k} {v}%" for k, v in r["others"].items())
               for r in busy]
        md.append("")
    for r in results:
        kinds = (r.get("log") or {}).get("warning_kinds") or {}
        if kinds:
            md.append(f"## {r['mode']} run {r['run']}: warnings and errors in the race")
            md += [f"- {n}x {k}" for k, n in kinds.items()]
            md.append("")
    (folder / "summary.md").write_text("\n".join(md))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("modes", nargs="*", help="mode names (see --list), 'all', 'quick', or name=<options>")
    p.add_argument("--runs", type=int, default=1)
    p.add_argument("--cooldown", type=int, default=60, help="seconds between runs (the Mac heats up)")
    p.add_argument("--race-seconds", type=float, default=60.0)
    p.add_argument("--cool-to", type=int, default=None, metavar="LEVEL",
                   help="before each run, wait until thermal pressure is at most LEVEL (0 nominal)")
    p.add_argument("--cool-max", type=int, default=600, help="the longest wait for --cool-to, seconds")
    p.add_argument("--scenario", choices=["race", "drive"], default="race")
    p.add_argument("--cold", action="store_true", help="empty shader and pipeline storage before each run")
    p.add_argument("--timeout", type=int, default=480)
    p.add_argument("--fresh-save", action="store_true", help="copy ~/.local/share/mcla again")
    p.add_argument("--label", default="")
    p.add_argument("--gputrace", action="store_true",
                   help="15 s into the race, a 3 s Metal System Trace by encoder label (gputrace.txt; adds "
                        "--metal_debug_labels=true)")
    p.add_argument("--peer-games", nargs="*", default=["fifa19", "SpeedBreaker", "Liberty Recompiled"], metavar="PROCESS",
                   help="before each run, wait while any of these processes (other sessions' games) runs")
    p.add_argument("--sample", type=int, default=0, metavar="SECONDS",
                   help="15 s into the race, profile the game for SECONDS (sample.txt, threads.txt)")
    p.add_argument("--list", action="store_true")
    p.add_argument("--report", help="print the summary of an earlier results folder")
    p.add_argument("--reanalyze", action="store_true", help="with --report: recompute it from the run folders")
    a = p.parse_args()
    if a.list:
        for k, v in {**MODES, **DIAG}.items():
            print(f"{k:18} {v}")
        return
    if a.report:
        res = json.loads((Path(a.report) / "summary.json").read_text())
        if a.reanalyze:
            for r in res:
                analyze_run(Path(a.report) / f"{r['mode']}-{r['run']}", r)
            (Path(a.report) / "summary.json").write_text(json.dumps(res, indent=1))
            write_summary(Path(a.report), res, "reanalysed")
        print(HEADER)
        for r in res:
            print(fmt(r))
        return
    wanted = []
    for m in a.modes or QUICK:
        if m == "all":
            wanted += list(MODES.items())
        elif m == "quick":
            wanted += [(k, MODES[k]) for k in QUICK]
        elif "=" in m and m.split("=", 1)[0] not in MODES and not m.startswith("--"):
            name, opts = m.split("=", 1)
            wanted.append((name, opts))
        elif m in MODES:
            wanted.append((m, MODES[m]))
        elif m in DIAG:
            wanted.append((m, DIAG[m]))
        else:
            raise SystemExit(f"unknown mode {m!r} (--list)")
    ROOT.mkdir(parents=True, exist_ok=True)
    prepare_user(a.fresh_save)
    stamp = time.strftime("%Y%m%d-%H%M%S") + (f"-{a.label}" if a.label else "")
    folder = ROOT / stamp
    folder.mkdir(parents=True)
    kill_game()
    results = []
    first = True
    for run in range(1, a.runs + 1):
        for name, opts in wanted:
            if not first and a.cooldown:
                time.sleep(a.cooldown)
            # Other sessions on this Mac bench their own games: wait until none of them runs.
            waited = 0
            while any(subprocess.run(["pgrep", "-x", g], capture_output=True).returncode == 0 for g in a.peer_games):
                if not waited:
                    print(f"[{time.strftime('%H:%M:%S')}] waiting for another game to exit ({', '.join(a.peer_games)})",
                          flush=True)
                time.sleep(15)
                waited += 15
            if waited:
                print(f"[{time.strftime('%H:%M:%S')}] waited {waited} s for another game", flush=True)
            if a.cool_to is not None:
                # Thermal pressure decides the CPU's clocks (a run starting at level 2 is 20-35% slower than
                # one at 0): every run starts at the same level, or after --cool-max seconds.
                waited = 0
                while (thermal() or 0) > a.cool_to and waited < a.cool_max:
                    time.sleep(10)
                    waited += 10
                if waited:
                    print(f"[{time.strftime('%H:%M:%S')}] cooled {waited} s to thermal {thermal()}", flush=True)
            first = False
            out = folder / f"{name}-{run}"
            print(f"[{time.strftime('%H:%M:%S')}] {name} run {run}: {opts}", flush=True)
            r = run_one(name, opts, out, a)
            r["run"] = run
            results.append(r)
            (folder / "summary.json").write_text(json.dumps(results, indent=1))
            print(HEADER.splitlines()[0] if len(results) == 1 else "", end="\n" if len(results) == 1 else "")
            print(fmt(r), flush=True)
    write_summary(folder, results, f"{a.scenario}, {a.race_seconds:.0f} s, {a.runs} run(s), cooldown {a.cooldown} s")
    print(f"\n{folder / 'summary.md'}")


if __name__ == "__main__":
    main()
