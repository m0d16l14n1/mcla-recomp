#!/bin/sh
# Free-roam frame-rate benchmark on macOS: one run per variant, each a fresh start
# that drives the game to the spawn point (launcher/dev/scripts/mac-roam-bench.pad)
# and counts engine frames over 10 s, uncapped. Each variant is a quoted list of
# options for mcla; "" is the baseline.
#
#   sh scripts/mac_bench.sh "" "--occlusion_query_async=false" "--mcla_anti_aliasing=off"
#
# Prints one line per variant (engine FPS, and the picture saved at the end as
# out/bench/<n>.png); the logs are out/bench/<n>.log.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/out/build/mac-arm64-${MCLA_BUILD:-relwithdebinfo}"
out="$root/out/bench"; mkdir -p "$out"
n=0
for variant in "$@"; do
  n=$((n + 1))
  : > "$build/run.log"
  # shellcheck disable=SC2086 # the variant is a list of options
  sh "$root/scripts/play_mac.sh" --fullscreen=false --mcla_fps=0 \
    --mcla_pad_script="$root/launcher/dev/scripts/mac-roam-bench.pad" $variant > "$out/$n.stdout" 2>&1 || true
  cp "$build/run.log" "$out/$n.log"
  [ -f "$build/bench.png" ] && mv "$build/bench.png" "$out/$n.png"
  f0=$(sed -n 's/.*mark bench_start at engine frame \([0-9]*\).*/\1/p' "$out/$n.log" | head -1)
  f1=$(sed -n 's/.*mark bench_end at engine frame \([0-9]*\).*/\1/p' "$out/$n.log" | head -1)
  if [ -n "$f0" ] && [ -n "$f1" ]; then
    echo "$n: $(echo "scale=1; ($f1 - $f0) / 10" | bc) FPS  [${variant:-baseline}]"
  else
    echo "$n: no result (the script did not reach the benchmark; see out/bench/$n.log)  [${variant:-baseline}]"
  fi
done
