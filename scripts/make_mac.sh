#!/usr/bin/env bash
# One command from your own disc image to the game built for macOS on Apple
# Silicon (arm64).
#
#   bash scripts/make_mac.sh --iso /path/to/your.iso
#
# Host: macOS on Apple Silicon with Xcode (or its command line tools) and
# Homebrew. Everything is built on your Mac from your own copy of the game:
# nothing of the game is in this repository, and what this script produces from
# it is yours to keep, not to share.
#
# Every step is skipped when its result is already there, so the script can be
# run again after a failure, or after a change, and continues from that step.
#
#   --iso PATH        your disc image (Midnight Club: Los Angeles Complete
#                     Edition, USA/Europe, Xbox 360). Not needed once game/
#                     has been extracted.
#   --config NAME     Debug, RelWithDebInfo (default) or Release
#   --jobs N          parallel compile jobs (default: all cores)
#   --no-install      do not offer to install missing Homebrew packages
#
# The SDK is checked out in third_party/rexglue-sdk (gitignored), built in
# third_party/rexglue-sdk/out/build/mac-arm64 and installed in
# third_party/rexglue-sdk/out/install/mac-arm64. The game is built in
# out/build/mac-arm64-<config>. Graphics: Vulkan through MoltenVK (the SDK
# builds the pinned MoltenVK and Vulkan loader itself and puts them next to the
# game). docs/macos.md has the details and the debugging recipes.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)
rex_src="$repo/third_party/rexglue-sdk"
rex_build="$rex_src/out/build/mac-arm64"
rex_install="$rex_src/out/install/mac-arm64"
rex_tag=v0.10.0
rex_commit=f5337cdc947ff6d4c4196737e2c807a48f2a1fc2

iso= config=RelWithDebInfo jobs=$(sysctl -n hw.ncpu) offer_install=1
while [ $# -gt 0 ]; do
    case $1 in
        --iso) iso=$2; shift 2 ;;
        --config) config=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        --no-install) offer_install=; shift ;;
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
case $config in Debug|RelWithDebInfo|Release) ;; *) echo "--config: Debug, RelWithDebInfo or Release" >&2; exit 2 ;; esac
preset="mac-arm64-$(echo "$config" | tr '[:upper:]' '[:lower:]')"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }
logs="$repo/out/logs"; mkdir -p "$logs"
# Run a long command with its output in a log; on failure show the end of it.
logged() {
    local name=$1; shift
    if ! "$@" > "$logs/$name.log" 2>&1; then
        tail -25 "$logs/$name.log" >&2
        fail "$name (full log: $logs/$name.log)"
    fi
}

[ "$(uname -s)" = Darwin ] || fail "this script is for macOS; see docs/building.md for the others"
[ "$(uname -m)" = arm64 ] || fail "this script builds for Apple Silicon (arm64); this Mac is $(uname -m)"

# ---------------------------------------------------------------------------
step "1/7 build tools"
xcode-select -p > /dev/null 2>&1 || fail "no Xcode command line tools: run 'xcode-select --install'"
missing=()
for tool in cmake ninja git python3; do command -v "$tool" > /dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    command -v brew > /dev/null || fail "missing: ${missing[*]}; install Homebrew (https://brew.sh) or the tools themselves"
    [ -n "$offer_install" ] || fail "missing: ${missing[*]} (brew install ${missing[*]})"
    echo "installing with Homebrew: ${missing[*]}"
    logged brew-install brew install "${missing[@]}"
fi
clang_major=$(clang --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)
[ "${clang_major:-0}" -ge 18 ] || fail "the SDK needs Clang 18 or newer (Xcode 16 or newer); found ${clang_major:-none}"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || fail "Python 3.10 or newer is needed"
free_gb=$(df -g "$repo" | awk 'NR==2 {print $4}')
[ "$free_gb" -ge 12 ] || echo "warning: ${free_gb} GB free; the SDK and the game's build need about 12 GB more"
echo "clang $clang_major, $(cmake --version | head -1), python $(python3 -c 'import platform; print(platform.python_version())')"

# ---------------------------------------------------------------------------
step "2/7 ReXGlue SDK $rex_tag with this project's patches"
# Same patches and order as the Linux and PS5 builds: upstream's base patches,
# the two POSIX ones (the Linux-only code in them is behind REX_PLATFORM_LINUX),
# then the fork's, read from the table in ps5/make_ps5.sh so that the list is
# kept in one place for the non-Windows builds.
records="$rex_src/.mcla-patches"
patch_hash() { shasum -a 256 < "$1" | cut -d' ' -f1; }
record_patch() {
    local leaf; leaf=$(basename "$1")
    { grep -v " $leaf\$" "$records" 2> /dev/null || true; echo "$(patch_hash "$1") $leaf"; } > "$records.new"
    mv "$records.new" "$records"
}
check_patch() {
    local leaf record again; leaf=$(basename "$1")
    again="Patch the SDK afresh: delete $rex_src and run this again."
    record=$(grep " $leaf\$" "$records" 2> /dev/null | head -1 | cut -d' ' -f1 || true)
    [ -n "$record" ] || fail "$leaf is in the SDK without a record in $records. $again"
    [ "$record" = "$(patch_hash "$1")" ] || fail "patches/$leaf has changed since it was applied to the SDK. $again"
}
if [ ! -d "$rex_src/.git" ]; then
    logged sdk-clone git clone --recursive --depth 1 --shallow-submodules --branch "$rex_tag" \
        https://github.com/rexglue/rexglue-sdk.git "$rex_src"
fi
[ "$(git -C "$rex_src" rev-parse HEAD)" = "$rex_commit" ] || fail "the SDK checkout is not $rex_tag ($rex_commit)"
if [ ! -f "$rex_src/.mcla-patched" ]; then
    for p in rexglue-v0.10.0-mcla.patch rexglue-minmax-blend-factor.patch \
             rexglue-linux-procmap-query.patch rexglue-linux-wait-sleep.patch; do
        git -C "$rex_src" apply "$repo/patches/$p" || fail "$p does not apply (is the checkout clean?)"
        record_patch "$repo/patches/$p"
    done
    git -C "$rex_src/thirdparty/FFmpeg" apply "$repo/patches/rexglue-ffmpeg-ps5-config.patch" || fail "the FFmpeg patch does not apply"
    record_patch "$repo/patches/rexglue-ffmpeg-ps5-config.patch"
    touch "$rex_src/.mcla-patched"
else
    for p in rexglue-v0.10.0-mcla.patch rexglue-minmax-blend-factor.patch rexglue-linux-procmap-query.patch \
             rexglue-linux-wait-sleep.patch rexglue-ffmpeg-ps5-config.patch; do
        check_patch "$repo/patches/$p"
    done
fi
later=$(sed -n "/^done <<'LATER'\$/,/^LATER\$/p" "$repo/ps5/make_ps5.sh" | grep '^rexglue-')
[ -n "$later" ] || fail "the patch table was not found in ps5/make_ps5.sh"
while read -r patch file adds; do
    if grep -qsF "$adds" "$rex_src/$file"; then
        check_patch "$repo/patches/$patch"
        continue
    fi
    git -C "$rex_src" apply --whitespace=nowarn "$repo/patches/$patch" || fail "$patch does not apply (is the checkout clean?)"
    record_patch "$repo/patches/$patch"
    echo "applied: $patch"
done <<< "$later"
# The macOS fork's own, after the shared ones (same format: patch, file, a name it adds).
while read -r patch file adds; do
    if grep -qsF "$adds" "$rex_src/$file"; then
        check_patch "$repo/patches/$patch"
        continue
    fi
    git -C "$rex_src" apply --whitespace=nowarn "$repo/patches/$patch" || fail "$patch does not apply (is the checkout clean?)"
    record_patch "$repo/patches/$patch"
    echo "applied: $patch"
done <<'MAC'
rexglue-vulkan-render-pass-breaks.patch src/graphics/vulkan/command_processor.cpp vulkan_hoist_read_granularity_log2
rexglue-macos-audio-threads.patch src/audio/audio_thread.cpp ApplyAppleAudioScheduling
rexglue-ppc-barriers-arm64.patch src/codegen/builders/system.cpp REX_LWSYNC
rexglue-fence-hook.patch include/rex/graphics/command_processor.h WriteFenceValue
rexglue-metal-backend.patch src/graphics/plugin_main.cpp CreateMetalGraphicsSystem
MAC

# ---------------------------------------------------------------------------
step "3/7 build the SDK (the long step, once)"
if [ ! -f "$rex_build/build.ninja" ]; then
    logged sdk-configure cmake -S "$rex_src" --preset mac-arm64 \
        -DREXGLUE_USE_VULKAN=ON -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_ENABLE_FSR=OFF
fi
logged sdk-build cmake --build "$rex_build" --config "$config" -j "$jobs"
logged sdk-install cmake --install "$rex_build" --config "$config"
[ -x "$rex_install/bin/rexglue" ] || fail "the recompiler was not installed at $rex_install/bin/rexglue"

# ---------------------------------------------------------------------------
step "4/7 your game: extract from the disc image"
if [ ! -f "$repo/game/default.xex" ]; then
    [ -n "$iso" ] || fail "game/ is empty: give your disc image with --iso"
    logged extract python3 -I "$repo/scripts/extract_game.py" "$iso" "$repo/game"
fi
echo "game files: $repo/game"

# ---------------------------------------------------------------------------
step "5/7 recompile the game's code"
(cd "$repo" && logged codegen "$rex_install/bin/rexglue" codegen mcla_manifest.toml)

# ---------------------------------------------------------------------------
step "6/7 build the game ($config)"
logged game-configure cmake -S "$repo" --preset "$preset" -DCMAKE_PREFIX_PATH="$rex_install"
logged game-build cmake --build --preset "$preset" -j "$jobs"

# ---------------------------------------------------------------------------
step "7/7 done"
exe="$repo/out/build/$preset/mcla"
[ -x "$exe" ] || fail "the game was not built at $exe"
echo "start it with:  bash scripts/play_mac.sh            (logs in out/build/$preset/run.log)"
echo "or by hand:     cd out/build/$preset && ./mcla --log_file=run.log --log_level=info"
