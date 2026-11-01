# The macOS launcher

A SwiftUI app with no Xcode project: `sh launcher/mac/build.sh` compiles `Sources/*.swift` with `swiftc` (macOS 14
or later, Apple silicon), and `scripts/make_app.sh` puts the result into `MCLA.app` as its main program, with the
game (`mcla`) beside it in `Contents/MacOS` and the list of the release's files (`scripts/ci/game-files.json`) in
`Contents/Resources`.

| File | What it does |
|---|---|
| `App.swift` | The window, the sidebar, and the pieces the pages share (a setting's row, cards) |
| `Model.swift` | Where things are, `mcla.toml` (read again when the game or its overlay changed it), starting the game and noticing its end |
| `Toml.swift` | Edits `mcla.toml` in place: only the top-level lines the launcher sets change; comments, other options and tables stay (as the SDK's own `MergeIntoToml`) |
| `Settings.swift` | Every option the launcher offers, with its default, choices and description; the keys of the keyboard controller, and the SDK's names for keys |
| `SystemInfo.swift` | The Mac's chip and GPU cores, the connected screens (pixels, refresh rate, EDR), and the settings suggested for them |
| `GameFiles.swift`, `GameFilesView.swift` | The check against the supported release (sizes, SHA-256), and taking the files out of an Xbox 360 disc image (XDVDFS, as `scripts/extract_game.py`) |
| `Saves.swift`, `SavesView.swift` | The career save and the library of copies |
| `PlayView.swift`, `SettingsViews.swift` | The pages |

Run on its own (not inside the app), it finds the game through environment variables:

```bash
sh launcher/mac/build.sh
MCLA_DIR=out/MCLA.app/Contents/MacOS MCLA_GAME_FILES_JSON=scripts/ci/game-files.json out/launcher-mac/mcla-launcher
```

`MCLA_LAUNCHER_PAGE=graphics` (or `play`, `gameFiles`, `saves`, `display`, `gameplay`, `controls`, `advanced`,
`about`) opens a page, and `MCLA_LAUNCHER_PLAY=1` presses Play when the window is up; both are for tests and
screenshots.

The launcher's own preferences (what it does when the game starts, extra options for the game) are in its user
defaults (`local.mcla-recomp`), not in `mcla.toml`.
