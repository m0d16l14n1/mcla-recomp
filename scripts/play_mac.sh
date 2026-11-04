#!/bin/sh
# Starts the macOS build from a terminal, with a log. Options are passed on to
# mcla (for example --log_level=debug, or --gpu_plugin=... once there is more
# than one). The build folder defaults to the RelWithDebInfo one that
# scripts/make_mac.sh makes; MCLA_BUILD picks another (debug, release).
#
#   MCLA_LLDB=1      start under lldb (break on the first crash, 'bt all' for
#                    every thread's stack)
#   MCLA_MVK_DEBUG=1 MoltenVK's own logging at the debug level, and the Metal
#                    API validation layer (slow; for rendering bugs)
#   MCLA_METAL_HUD=1 Apple's Metal performance HUD over the game
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/out/build/mac-arm64-${MCLA_BUILD:-relwithdebinfo}"

if [ ! -x "$build/mcla" ]; then
  echo "error: $build/mcla not found; build it first (bash scripts/make_mac.sh)" >&2
  exit 1
fi
cd "$build"

# The SDK loads its GPU plugins from the executable's folder only, and the build
# copies the runtime there but not the plugins (librexgpu-xenos.dylib, with
# "rd" or "d" before the dot for a RelWithDebInfo or Debug SDK).
sdk_lib="$root/third_party/rexglue-sdk/out/install/mac-arm64/lib"
for lib in "$sdk_lib"/librexgpu-*.dylib; do
  [ -e "$lib" ] || continue
  [ -e "$(basename "$lib")" ] || ln -s "$lib" .
done

if [ -n "$MCLA_MVK_DEBUG" ]; then
  export MVK_CONFIG_LOG_LEVEL=4 MVK_CONFIG_DEBUG=1 MTL_DEBUG_LAYER=1
fi
if [ -n "$MCLA_METAL_HUD" ]; then
  export MTL_HUD_ENABLED=1
fi

# The SDK's command line parser fails on a repeated option, so the defaults are
# added only when not given.
case " $* " in *" --log_level="*) ;; *) set -- --log_level=info "$@" ;; esac
# The default log starts afresh each run; the last run's is kept as run.previous.log (the SDK appends to its log).
case " $* " in
  *" --log_file="*) ;;
  *) [ -f run.log ] && mv -f run.log run.previous.log
     set -- --log_file=run.log "$@" ;;
esac
if [ -n "$MCLA_LLDB" ]; then
  exec lldb -o run -- ./mcla "$@"
fi
exec ./mcla "$@"
