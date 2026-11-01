#!/bin/sh
# Makes MCLA.app from the macOS build (scripts/make_mac.sh first). A double-click opens the launcher
# (launcher/mac: the game's files, saves, and the settings that need a restart), and its Play starts the game on
# the native Metal backend, with its log in ~/Library/Logs/MCLA/mcla.log. MCLA_NO_LAUNCHER=1 makes the old app,
# where a double-click starts the game at once.
#
#   sh scripts/make_app.sh [where]     # default: out/MCLA.app (drag it to the Dock or /Applications)
#
# The app holds copies of the program, the ReXGlue runtime and the GPU plugins, so it keeps working while the
# build folder is rebuilt; run this again after a build to update it. Its settings are
# MCLA.app/Contents/MacOS/mcla.toml (the game's settings menu saves there too); a new run of this script keeps
# that file. The game itself stays where it is (game/ in this repository): mcla.toml names it.
#   MCLA_BUILD=debug|release   another build folder (default relwithdebinfo)
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/out/build/mac-arm64-${MCLA_BUILD:-relwithdebinfo}"
app="${1:-$root/out/MCLA.app}"
sdk_lib="$root/third_party/rexglue-sdk/out/install/mac-arm64/lib"
game="$root/game"

[ -x "$build/mcla" ] || { echo "error: $build/mcla not found; build it first (bash scripts/make_mac.sh)" >&2; exit 1; }
# Without a game here, the launcher's Game Files page takes it from a disc image.
[ -f "$game/default.xex" ] || { echo "note: no game in $game; choose it in the launcher (Game Files)" >&2; game=""; }

macos="$app/Contents/MacOS"
mkdir -p "$macos" "$app/Contents/Resources"
# Copies, not links (the build folder links the plugins); the runtime is found through @executable_path.
cp -f "$build/mcla" "$macos/mcla"
cp -fL "$build"/librexruntime*.dylib "$macos/"
for lib in "$sdk_lib"/librexgpu-*.dylib; do
  [ -e "$lib" ] && cp -fL "$lib" "$macos/"
done

# The launcher is the app's program; the game (mcla) sits beside it and reads mcla.toml from this folder.
main=mcla
if [ -z "$MCLA_NO_LAUNCHER" ] && command -v xcrun >/dev/null; then
  sh "$root/launcher/mac/build.sh" "$macos/MCLA Launcher"
  cp -f "$root/scripts/ci/game-files.json" "$app/Contents/Resources/game-files.json"
  main="MCLA Launcher"
fi

version=$(git -C "$root" describe --always --dirty 2>/dev/null || echo dev)
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MCLA</string>
  <key>CFBundleDisplayName</key><string>Midnight Club: LA (recomp)</string>
  <key>CFBundleIdentifier</key><string>local.mcla-recomp</string>
  <key>CFBundleExecutable</key><string>$main</string>
  <key>CFBundleIconFile</key><string>MCLA</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.racing-games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>GCSupportsControllerUserInteraction</key><true/>
</dict>
</plist>
EOF

# The icon: the Windows launcher's, its largest image, as an .icns.
icon_src="$root/launcher/src/launcher.ico"
if [ -f "$icon_src" ] && command -v iconutil >/dev/null && python3 -c "import PIL" 2>/dev/null; then
  tmp=$(mktemp -d)
  python3 - "$icon_src" "$tmp/MCLA.iconset" <<'PY'
import os, sys
from PIL import Image
ico = Image.open(sys.argv[1])
best = max(ico.info.get("sizes", {ico.size}), key=lambda s: s[0])
ico.size = best
img = ico.convert("RGBA")
os.makedirs(sys.argv[2])
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        img.resize((size * scale,) * 2, Image.LANCZOS).save(
            os.path.join(sys.argv[2], f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"))
PY
  iconutil -c icns "$tmp/MCLA.iconset" -o "$app/Contents/Resources/MCLA.icns" && rm -rf "$tmp"
fi

# Settings: written once, so the player's own (and the settings menu's) stay.
logs="$HOME/Library/Logs/MCLA"
mkdir -p "$logs"
if [ ! -f "$macos/mcla.toml" ]; then
  game_line=""
  if [ -n "$game" ]; then game_line="game_data_root = \"$game\""; fi
  cat > "$macos/mcla.toml" <<EOF
# MCLA.app's settings (scripts/make_app.sh wrote them once; the launcher and the game's settings menu save here too).
$game_line
log_file = "$logs/mcla.log"
log_level = "info"
# Native Metal, MetalFX upscaling from 640x360 (about 90 FPS on an M5), held to an even 60 FPS.
mcla_gpu_backend = "metal"
mcla_anti_aliasing = "fsr"
mcla_upscaling = "performance"
mcla_fps = 60
# The keyboard as a controller, in the driving layout (W gas, S brake, A and D steer; README, Keyboard).
mnk_mode = true
EOF
fi

# The bundle as a whole is unsigned (built here, never quarantined); the program keeps the linker's ad-hoc signature.
touch "$app"
echo "made $app ($version)"
echo "settings: $macos/mcla.toml; log: $logs/mcla.log"
