// The settings pages: Graphics, Display & HDR, Game, Controls, Advanced, and About.

import AppKit
import SwiftUI

/// mcla_anti_aliasing and mcla_upscaling as one choice: what the player picks is one thing.
struct AntiAliasing: Identifiable, Hashable {
    let aa: String
    let up: String
    var id: String { aa + "/" + up }

    static let all: [AntiAliasing] = [
        .init(aa: "off", up: "off"), .init(aa: "msaa", up: "off"), .init(aa: "fsr", up: "off"),
        .init(aa: "fsr", up: "ultra_quality"), .init(aa: "fsr", up: "quality"), .init(aa: "fsr", up: "balanced"),
        .init(aa: "fsr", up: "performance"),
    ]

    @MainActor static func current(_ l: Launcher) -> AntiAliasing {
        let aa = l.value("mcla_anti_aliasing")?.asString ?? "msaa"
        let up = aa == "fsr" ? (l.value("mcla_upscaling")?.asString ?? "off") : "off"
        return AntiAliasing(aa: aa, up: up)
    }

    /// The scene's size: the game draws 1280×720; the upscalers draw it smaller and scale it back up.
    var sceneSize: String {
        switch up {
        case "ultra_quality": return "960×540"
        case "quality": return "853×480"
        case "balanced": return "753×424"
        case "performance": return "640×360"
        default: return "1280×720"
        }
    }

    func label(metal: Bool) -> String {
        let t = metal ? "MetalFX" : "FSR 3.1"
        switch (aa, up) {
        case ("off", _): return "No anti-aliasing"
        case ("msaa", _): return "MSAA 2x (the console's)"
        case ("fsr", "off"): return "\(t) anti-aliasing (no upscaling)"
        case ("fsr", "ultra_quality"): return "\(t) Ultra Quality (from 960×540)"
        case ("fsr", "quality"): return "\(t) Quality (from 853×480)"
        case ("fsr", "balanced"): return "\(t) Balanced (from 753×424)"
        case ("fsr", "performance"): return "\(t) Performance (from 640×360)"
        default: return "\(aa) / \(up)"
        }
    }

    @MainActor func apply(_ l: Launcher) {
        l.setMany([("mcla_anti_aliasing", aa == "msaa" ? nil : .string(aa)),
                   ("mcla_upscaling", up == "off" ? nil : .string(up))])
    }
}

// MARK: Graphics

struct GraphicsView: View {
    @EnvironmentObject var launcher: Launcher

    private var metal: Bool { (launcher.value("mcla_gpu_backend")?.asString ?? "metal") != "vulkan" }
    private var screen: ScreenInfo? {
        let screens = ScreenInfo.all()
        let i = Int(launcher.value("monitor")?.asDouble ?? 0)
        return i > 0 && i <= screens.count ? screens[i - 1] : screens.first
    }

    var body: some View {
        Page(title: "Graphics", subtitle: "Take effect the next time the game starts, except those marked \"also in game\", "
             + "which the pause menu changes during play too.") {
            suggestionCard
            Card(title: "Renderer") {
                SettingRow(setting: Catalogue.backend)
                Divider()
                antiAliasingRow
                Divider()
                resolutionRow
                Divider()
                SettingRow(setting: Catalogue.fps)
                Divider()
                SettingRow(setting: Catalogue.vsync)
                Divider()
                SettingRow(setting: Catalogue.anisotropic)
            }
            SettingsCard(title: "Effects", settings: Catalogue.detail)
            SettingsCard(title: "Detail and distance", settings: Catalogue.distance,
                         footer: "Lower values help a base M1 or M2 hold its frame rate in the busiest parts of the city.")
        }
    }

    private var suggestionCard: some View {
        let mac = MacInfo.current
        let s = Suggestion.make(mac: mac, screen: screen)
        let aa = AntiAliasing(aa: s.antiAliasing, up: s.upscaling)
        let matches = metal && AntiAliasing.current(launcher) == aa && Int(launcher.value("mcla_fps")?.asDouble ?? 30) == s.fps
        return Card(title: "For this Mac") {
            HStack(alignment: .top) {
                Image(systemName: "laptopcomputer").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(mac.chip)\(mac.gpuCores.map { ", \($0)-core GPU" } ?? ""), \(mac.memoryGB) GB").font(.headline)
                    Text("Suggested: Metal, \(aa.label(metal: true)), \(s.fps) FPS cap.")
                    Text(s.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(matches ? "In Use" : "Use These") {
                    launcher.set("mcla_gpu_backend", .string("metal"))
                    aa.apply(launcher)
                    launcher.set("mcla_fps", s.fps == 30 ? nil : .int(s.fps))
                }
                .disabled(matches)
            }
        }
    }

    private var antiAliasingRow: some View {
        let current = AntiAliasing.current(launcher)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Anti-aliasing and upscaling")
                LiveBadge()
                Spacer()
                Picker("", selection: Binding(get: { current }, set: { $0.apply(launcher) })) {
                    ForEach(AntiAliasing.all) { Text($0.label(metal: metal)).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            Text(metal
                 ? "MetalFX (Apple's temporal upscaler) smooths edges and can draw the 3D scene smaller and scale it up, "
                   + "while the HUD and menus stay sharp. Performance is the fastest and is about 50% faster than MSAA on an "
                   + "M5; Ultra Quality looks closest to the full scene. The pause menu (DISPLAY) changes it during play."
                 : "FSR 3.1 through MoltenVK. With Vulkan on a Mac, MSAA is the tested choice.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var resolutionRow: some View {
        let aa = AntiAliasing.current(launcher)
        let shown = screen.map { "\(Int($0.pixels.width))×\(Int($0.pixels.height))" } ?? "the screen"
        if metal {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Resolution")
                    Spacer()
                    Text("Scene \(aa.sceneSize) → game 1280×720 → \(shown)").monospacedDigit().foregroundStyle(.secondary)
                }
                Text("On Metal the game draws at the console's 1280×720 and the picture is scaled to the screen, Retina or "
                     + "4K, with the HUD and menus drawn at that size. Drawing the game itself at 1440p or 4K (resolution "
                     + "scale) is Vulkan-only for now; it is the Metal backend's next big step.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            SettingRow(setting: Setting("resolution_scale", "Resolution scale", .choice([
                Choice(label: "1x (1280×720, as on the console)", value: .int(1)),
                Choice(label: "2x (2560×1440)", value: .int(2)),
                Choice(label: "3x (3840×2160, 4K)", value: .int(3)),
            ]), .int(1), "Draws the game at a multiple of its 1280×720 (Vulkan). Each step costs about the square of it in GPU time: "
                + "3x is for a Max or Ultra chip."))
        }
    }
}

// MARK: Display

struct DisplayView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var screens = ScreenInfo.all()

    private static let windowSizes: [(Int, Int)] = [(1280, 720), (1600, 900), (1920, 1080), (2560, 1440), (3200, 1800)]

    var body: some View {
        Page(title: "Display & HDR", subtitle: "Which screen the game opens on, full screen or in a window, and HDR.") {
            Card(title: "Screen", footer: "Screens are numbered in the order macOS lists them; the first has the menu bar. "
                 + "Connect or disconnect a screen and this list follows.") {
                screenPicker
                Divider()
                SettingRow(setting: Catalogue.fullscreen)
                Divider()
                windowSizeRow
            }
            SettingsCard(title: "Picture", settings: [Catalogue.gamma, Catalogue.uiInterpolate])
            Card(title: "HDR") {
                hdrStatus
                Divider()
                ForEach([Catalogue.hdr, Catalogue.hdrPeak, Catalogue.hdrPaperWhite, Catalogue.hdrHighlights]) { s in
                    if s.key != "hdr" { Divider() }
                    SettingRow(setting: s, disabled: s.key != "hdr" && launcher.value("hdr")?.asString == "off")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenInfo.all()
        }
    }

    private var monitor: Int { Int(launcher.value("monitor")?.asDouble ?? 0) }

    private var chosen: ScreenInfo? { monitor > 0 && monitor <= screens.count ? screens[monitor - 1] : screens.first }

    private var screenPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Open the game on")
                Spacer()
                Picker("", selection: Binding(get: { monitor }, set: { launcher.set("monitor", $0 == 0 ? nil : .int($0)) })) {
                    Text("The main screen").tag(0)
                    ForEach(screens) { s in Text("\(s.index). \(s.name)").tag(s.index) }
                    if monitor > screens.count { Text("Screen \(monitor) (not connected)").tag(monitor) }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            ForEach(screens) { s in
                HStack(spacing: 8) {
                    Image(systemName: s.builtIn ? "laptopcomputer" : "display").frame(width: 22)
                    Text("\(s.index). \(s.name)").fontWeight(s.index == (chosen?.index ?? 0) ? .semibold : .regular)
                    Text(s.summary).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    private var windowSizeRow: some View {
        let w = Int(launcher.value("window_width")?.asDouble ?? 0)
        let h = Int(launcher.value("window_height")?.asDouble ?? 0)
        let fit = chosen?.points ?? CGSize(width: 10000, height: 10000)
        let sizes = DisplayView.windowSizes.filter { CGFloat($0.0) <= fit.width && CGFloat($0.1) <= fit.height - 60 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Window size")
                Spacer()
                Picker("", selection: Binding(get: { "\(w)x\(h)" }, set: { v in
                    let p = v.split(separator: "x").compactMap { Int($0) }
                    if p.count == 2, p[0] > 0 {
                        launcher.setMany([("window_width", .int(p[0])), ("window_height", .int(p[1]))])
                    } else {
                        launcher.setMany([("window_width", nil), ("window_height", nil)])
                    }
                })) {
                    Text("Automatic").tag("0x0")
                    ForEach(sizes, id: \.0) { s in Text("\(s.0)×\(s.1)").tag("\(s.0)x\(s.1)") }
                    if w > 0, !sizes.contains(where: { $0.0 == w && $0.1 == h }) { Text("\(w)×\(h)").tag("\(w)x\(h)") }
                }
                .labelsHidden().frame(maxWidth: 300)
                .disabled(launcher.value("fullscreen")?.asBool ?? true)
            }
            Text("The window's size in points when the game isn't full screen; on a Retina screen it has twice as many pixels "
                 + "each way. The window can be resized while playing.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hdrStatus: some View {
        let s = chosen
        let canHdr = (s?.edr ?? 1) > 1.01
        return HStack(alignment: .top) {
            Image(systemName: canHdr ? "sun.max.fill" : "sun.min").foregroundStyle(canHdr ? .yellow : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(canHdr ? "\(s?.name ?? "This screen") can show HDR" : "\(s?.name ?? "This screen") shows SDR only")
                    .font(.headline)
                Text(canHdr
                     ? "It can go \(String(format: "%.1f", s?.edr ?? 1))x above white right now. With HDR on Auto, the game uses it."
                     : "With HDR on Auto the game stays SDR here. An external HDR monitor shows HDR when \"High Dynamic Range\" "
                       + "is on for it in System Settings > Displays.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Game

struct GameView: View {
    var body: some View {
        Page(title: "Game", subtitle: "The player, the language, and the start.") {
            SettingsCard(title: "Player", settings: [Catalogue.userName, Catalogue.language])
            SettingsCard(title: "Start-up", settings: [Catalogue.intro])
        }
    }
}

// MARK: Controls

struct ControlsView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var capturing: Keybind?

    private var layout: String { launcher.value("mcla_keyboard_layout")?.asString ?? "driving" }

    var body: some View {
        Page(title: "Controls", subtitle: "A controller (Xbox, DualSense, others macOS knows) works as it is. The keyboard plays "
             + "as a controller when it is turned on below.") {
            SettingsCard(title: "Controller", settings: [Catalogue.prompts, Catalogue.vibration, Catalogue.triggers, Catalogue.hideCursor])
            SettingsCard(title: "Keyboard", settings: [Catalogue.keyboard, Catalogue.keyboardLayout])
            keysCard
        }
        .sheet(item: $capturing) { bind in
            KeyCaptureSheet(bind: bind) { name in
                guard let name else { return }
                var keys = keys(of: bind)
                if !keys.contains(name) { keys.append(name) }
                write(bind, keys)
            }
        }
    }

    private func keys(of bind: Keybind) -> [String] {
        let raw = launcher.value(bind.key)?.asString ?? (layout == "controller" ? bind.controller : bind.driving)
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func write(_ bind: Keybind, _ keys: [String]) {
        let def = layout == "controller" ? bind.controller : bind.driving
        let joined = keys.joined(separator: ",")
        launcher.set(bind.key, joined == def ? nil : .string(joined))
    }

    private var keysCard: some View {
        let all = Keybinds.all
        let set = all.filter { launcher.config.contains($0.key) }.count
        return Card(title: "Keys", footer: "Click + and press a key to add it; click a key to take it away. Shift, Control and Option "
                    + "held with a key make a combination. A key in two places presses both (W is gas and up in menus, on purpose). "
                    + "The F4 overlay in the game has the same list.") {
            HStack {
                Text(set == 0 ? "All keys are the \(layout) layout's." : "\(set) changed from the \(layout) layout.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All Keys") { launcher.setMany(all.map { ($0.key, nil) }) }.disabled(set == 0)
            }
            .disabled(!(launcher.value("mnk_mode")?.asBool ?? false))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(all) { bind in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bind.button)
                            if !bind.action.isEmpty { Text(bind.action).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(width: 150, alignment: .leading)
                        HStack(spacing: 6) {
                            ForEach(keys(of: bind), id: \.self) { k in
                                Button {
                                    write(bind, keys(of: bind).filter { $0 != k })
                                } label: {
                                    Text(k).font(.system(.callout, design: .rounded).weight(.medium))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.18)))
                                }
                                .buttonStyle(.plain)
                                .help("Take \(k) away")
                            }
                            Button { capturing = bind } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless).help("Add a key")
                        }
                        Button("Reset") { launcher.set(bind.key, nil) }
                            .buttonStyle(.borderless)
                            .opacity(launcher.config.contains(bind.key) ? 1 : 0)
                    }
                }
            }
            .disabled(!(launcher.value("mnk_mode")?.asBool ?? false))
        }
    }
}

/// Waits for one key press and names it as the game does.
private struct KeyCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bind: Keybind
    let done: (String?) -> Void
    @State private var monitor: Any?
    @State private var unknown = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Press a key for \(bind.button)").font(.headline)
            Text(unknown ? "That key can't be used by the game; try another." : "Hold Shift, Control or Option with it for a combination.")
                .font(.caption).foregroundStyle(unknown ? .orange : .secondary)
            Button("Cancel") { finish(nil) }
        }
        .padding(28)
        .frame(width: 340)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                let f = e.modifierFlags
                if let name = Keybinds.name(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers,
                                            shift: f.contains(.shift), control: f.contains(.control), option: f.contains(.option)) {
                    finish(name)
                } else {
                    unknown = true
                }
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func finish(_ name: String?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        done(name)
        dismiss()
    }
}

// MARK: Advanced

struct AdvancedView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var args = ""
    @State private var confirmReset = false

    var body: some View {
        Page(title: "Advanced", subtitle: "Files, logs, and options for testing.") {
            Card(title: "When the game starts") {
                Picker("", selection: Binding(get: { launcher.afterLaunch }, set: { launcher.afterLaunch = $0 })) {
                    ForEach(Launcher.AfterLaunch.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Card(title: "Files") {
                pathRow("Settings", launcher.paths.config, open: true)
                Divider()
                pathRow("Log", launcher.logFile, open: true)
                Divider()
                pathRow("Saves and profile", launcher.userDataRoot, open: false)
                Divider()
                pathRow("The game's program", launcher.paths.programDir, open: false)
            }
            SettingsCard(title: "Logging", settings: [Setting("log_level", "Log detail", .choice([
                Choice(label: "Errors only", value: .string("error")), Choice(label: "Warnings", value: .string("warn")),
                Choice(label: "Information (default)", value: .string("info")), Choice(label: "Debug (large)", value: .string("debug")),
            ]), .string("info"), "How much the game writes to its log. Debug is for chasing a problem; it makes the log large.")])
            Card(title: "More options for the game", footer: "Command-line options the game gets when it starts from the launcher, "
                 + "for example --mcla_title_fps=60 or --hdr_test_pattern=true. Separate them with spaces.") {
                TextField("--option=value", text: $args)
                    .font(.system(.body, design: .monospaced))
                    .onAppear { args = launcher.extraArguments }
                    .onSubmit { launcher.extraArguments = args }
                    .onChange(of: args) { _, v in launcher.extraArguments = v }
            }
            Card(title: "Start over") {
                HStack {
                    Text("Every setting back to the launcher's defaults. The game's place and the log stay; a copy of the "
                         + "old settings is kept beside them (mcla.toml.bak).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: resetAll)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your saves aren't touched.") }
    }

    private func pathRow(_ title: String, _ url: URL, open: Bool) -> some View {
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if open { Button("Open") { NSWorkspace.shared.open(url) } }
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func resetAll() {
        let fm = FileManager.default
        let backup = launcher.paths.config.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: launcher.paths.config, to: backup)
        var doc = TomlDocument(text: "# Midnight Club: LA (recomp) settings; the launcher and the game's settings menu both write here.\n")
        let keep = ["game_data_root", "log_file", "user_data_root"]
        for k in keep { if let v = launcher.value(k) { doc.set(k, v) } }
        doc.set("mcla_gpu_backend", .string("metal"))
        doc.set("mcla_anti_aliasing", .string("fsr"))
        doc.set("mcla_upscaling", .string("performance"))
        doc.set("mcla_fps", .int(60))
        doc.set("mnk_mode", .bool(true))
        try? doc.text.write(to: launcher.paths.config, atomically: true, encoding: .utf8)
        launcher.loadConfig()
    }
}

// MARK: About

struct AboutView: View {
    var body: some View {
        Page(title: "About", subtitle: "Midnight Club: Los Angeles, recompiled from the Xbox 360 to run natively on Apple silicon.") {
            Card(title: "This launcher") {
                Text("Chooses and checks the game's files, keeps your saves, and holds the settings that need the game to start "
                     + "again. What can change during play is in the game itself: the pause menu, and the F4 overlay.")
                Text("It owes its idea to the Mac launchers that came before it for other racing games: the Need for Speed: "
                     + "Underground 2 launcher for macOS, and Speedbreaker for Most Wanted and Carbon. Thanks to their authors "
                     + "for showing how good a game launcher on a Mac can be. This one is written from scratch for this game.")
                    .foregroundStyle(.secondary)
            }
            Card(title: "Credits") {
                credit("mcla-recomp", "by holdmysocks: the project this port builds on; the Linux build by MoonFuji.")
                credit("RenanQueiroz/mcla-recomp", "the fork this one follows: performance work, fixes, settings and the Windows launcher.")
                credit("ReXGlue SDK", "by Tom Clay and contributors; Xenia by Ben Vanik and contributors; XenonRecomp by hedge-dev.")
                credit("LARecomp", "by mzzvxm and contributors, whose fixes several parts of the project are ported from.")
                credit("LibertyRecomp", "(GTA IV): the macOS port of ReXGlue and the Metal presenter this port learns from.")
                credit("ForzaHorizon1-ReImagined, RecompiledHaloReach", "by Dyotson and contributors; xenia-canary and Xenia.")
                credit("PS5_Vulkan", "by mihawk-99: the RADV port the PS5 version is built on.")
            }
            Text("Midnight Club: Los Angeles is Rockstar Games' (Take-Two Interactive). This project has no game data in it; "
                 + "you need your own copy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func credit(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.body.weight(.medium))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
