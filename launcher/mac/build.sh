#!/bin/sh
# Builds the macOS launcher (SwiftUI, no Xcode project): out/launcher-mac/MCLA Launcher, a plain executable that
# scripts/make_app.sh puts into MCLA.app as its main program.
#
#   sh launcher/mac/build.sh [output]      # default out/launcher-mac/mcla-launcher
#
# Run on its own (outside the app) it looks for the game's program in MCLA_DIR (default: the folder it is in) and for
# the list of the release's files in MCLA_GAME_FILES_JSON.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-$root/out/launcher-mac/mcla-launcher}"
mkdir -p "$(dirname "$out")"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  -framework SwiftUI -framework AppKit -framework IOKit -framework CryptoKit \
  -o "$out" "$here"/Sources/*.swift
echo "built $out"
