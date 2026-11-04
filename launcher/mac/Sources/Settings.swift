// The options the launcher offers: each one a key of mcla.toml, the game's default for it, the choices,
// and what it does. "Live" marks the ones the game's pause menu or F4 overlay also changes during play; the
// rest take effect the next time the game starts, which is why they live here.

import Foundation

struct Choice: Identifiable, Hashable {
    let label: String
    let value: TomlValue
    var id: String { value.key }
    static func == (a: Choice, b: Choice) -> Bool { a.value.key == b.value.key }
    func hash(into h: inout Hasher) { h.combine(value.key) }
}

enum SettingKind {
    case choice([Choice])
    case toggle
    /// A number in steps; `autoLabel` names 0 (what the display reports) when there is one.
    case level(min: Double, max: Double, step: Double, unit: String, autoLabel: String?, start: Double)
    case text(placeholder: String)
}

struct Setting: Identifiable {
    let key: String
    let title: String
    let kind: SettingKind
    let defaultValue: TomlValue
    let info: String
    var live = false
    /// Written even when it is the value shown as the default (mcla_gpu_backend: the game's own default, any,
    /// means MoltenVK on a Mac, so the launcher's Metal has to be in the file).
    var explicit = false
    var id: String { key }

    init(_ key: String, _ title: String, _ kind: SettingKind, _ defaultValue: TomlValue, live: Bool = false, _ info: String) {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.live = live
        self.info = info
    }
}

private func on(_ v: Bool) -> TomlValue { .bool(v) }
private func s(_ v: String) -> TomlValue { .string(v) }
private func n(_ v: Int) -> TomlValue { .int(v) }
private func d(_ v: Double) -> TomlValue { .double(v) }
private func c(_ label: String, _ value: TomlValue) -> Choice { Choice(label: label, value: value) }

enum Catalogue {
    // MARK: Graphics

    static let backend: Setting = { var b = backendRow; b.explicit = true; return b }()
    private static let backendRow = Setting("mcla_gpu_backend", "Graphics API", .choice([
        c("Metal (native, recommended)", s("metal")),
        c("Vulkan (through MoltenVK)", s("vulkan")),
    ]), s("metal"),
        "Metal is this port's own backend for Apple GPUs: faster, with MetalFX upscaling and HDR. Vulkan runs the "
        + "game's Vulkan renderer through MoltenVK; it is slower, but it is there to compare with if something "
        + "looks wrong on Metal.")

    static let metalVersion = Setting("metal_metal4", "Metal version", .choice([
        c("Metal 4 (macOS 26, recommended)", on(true)), c("Metal 3", on(false)),
    ]), on(true),
        "Metal 4 records the game's drawing with Apple's newest API: argument tables, explicit residency and "
        + "barriers, and Metal 4's MetalFX in the same command buffers, for about a fifth less GPU time a frame on "
        + "an M5. Metal 3 is the earlier path, kept to compare with if something looks wrong. On macOS before 26 "
        + "the game uses Metal 3 whatever this says.")

    static let frameGeneration = Setting("frame_generation", "Frame generation", .choice([
        c("Off", s("off")), c("MetalFX (macOS 26)", s("fsr")),
    ]), s("off"), live: true,
        "MetalFX frame interpolation: the game draws just under half the display's frames (29 FPS on a 60 Hz screen, "
        + "58 on 120 Hz) and Apple's MetalFX makes one between every two, so motion looks as smooth as at the full "
        + "rate while the GPU does about half the work: cooler and steadier on a MacBook Air. It adds about half a "
        + "frame of delay. Needs Metal with MetalFX anti-aliasing (it works from its depth and motion). Changes during "
        + "play in the pause menu (DISPLAY).")
    static let fpsFrameGeneration = Setting("mcla_fps_frame_generation", "Frames drawn with frame generation", .choice([
        c("Half the display's rate (29 on 60 Hz, 58 on 120 Hz)", n(-1)), c("30 FPS", n(30)), c("40 FPS", n(40)),
        c("60 FPS", n(60)), c("Uncapped", n(0)),
    ]), n(-1), live: true,
        "The cap while frame generation is on (the frame rate cap above applies while it is off). Just under half "
        + "the display's rate keeps the generated and drawn frames evenly paced; higher rates are for a 120 Hz screen.")
    static let fps = Setting("mcla_fps", "Frame rate cap", .choice([
        c("30 FPS (as on the console)", n(30)), c("40 FPS", n(40)), c("45 FPS", n(45)), c("50 FPS", n(50)),
        c("60 FPS", n(60)), c("120 FPS (ProMotion displays)", n(120)), c("Uncapped", n(0)),
    ]), n(30), live: true,
        "The most frames a second the game draws. The game runs at the same speed whatever this is. 60 suits most "
        + "Mac displays; 120 is for a MacBook Pro's ProMotion panel or a 120 Hz monitor. Changes during play in "
        + "the pause menu (PERFORMANCE).")

    static let vsync = Setting("vsync", "Vertical sync", .toggle, on(true),
        "Shows each frame when the display refreshes, so the picture never tears. Off can lower input lag a little "
        + "with an uncapped frame rate.")

    static let anisotropic = Setting("anisotropic_override", "Texture filtering", .choice([
        c("As the game asks", n(-1)), c("Bilinear", n(0)), c("Anisotropic 2x", n(2)), c("4x", n(3)),
        c("8x", n(4)), c("16x (default)", n(5)),
    ]), n(5),
        "Keeps roads and walls sharp when seen at an angle. 16x costs little on Apple GPUs.")

    static let screenScaling = Setting("metal_present_scaling", "Screen scaling", .choice([
        c("MetalFX (sharper)", s("metalfx")), c("Bilinear (softer)", s("bilinear")),
    ]), s("metalfx"),
        "How the game's 720p picture is enlarged to the window or screen (a Retina or 4K screen has two or three "
        + "times its pixels across). MetalFX's spatial upscaler keeps edges and the HUD's text sharp; bilinear is "
        + "the plain stretch, softer. Metal only.")

    static let performanceHud = Setting("metal_performance_hud", "Metal performance HUD", .choice([
        c("As macOS is set", s("system")), c("Off for this game", s("off")), c("On", s("on")),
    ]), s("system"),
        "Apple's frame-rate overlay. When it is switched on for every app (the Developer settings, or "
        + "MetalForceHudEnabled), its hooks cost this game's renderer about 15% of its CPU time; Off for this game "
        + "removes them here only. Metal only; takes effect at the next start.")

    static let shadows = Setting("mcla_shadows", "Shadows", .toggle, on(true), live: true,
        "Real-time shadows of the city, cars and people.")
    static let foliageShadows = Setting("mcla_foliage_shadows", "Tree and plant shadows", .toggle, on(true), live: true,
        "The shadows of trees and plants (a good part of the shadows' cost in green areas).")
    static let raceShadows = Setting("mcla_race_shadows", "Shadows during races", .toggle, on(true),
        "Off drops the shadows only in races, where the most cars are on screen.")
    static let fastCarShadows = Setting("mcla_fast_car_shadows", "Simpler car shadows", .toggle, on(false),
        "Draws the cars' shadows from fewer triangles. Faster, slightly blockier.")
    static let foliageImpostors = Setting("mcla_foliage_impostors", "Distant trees as cards", .toggle, on(true),
        "Far trees are drawn as flat pictures, as on the console. Off draws them in full: slower.")
    static let fullscreenBlur = Setting("mcla_fullscreen_blur", "Full-screen blur", .toggle, on(true),
        "The blur behind menus and the glow passes that use it.")
    static let motionBlur = Setting("mcla_motion_blur", "Motion blur", .toggle, on(true), live: true,
        "The blur at speed.")
    static let depthOfField = Setting("mcla_depth_of_field", "Depth of field", .toggle, on(true), live: true,
        "The soft focus of distant things in cut scenes and the garage.")
    static let cityLod = Setting("mcla_city_lod", "City detail distance", .choice([
        c("Near (faster)", d(0.5)), c("Medium", d(0.75)), c("As on the console", d(1.0)),
        c("Far (1.5x)", d(1.5)), c("Farther (2x)", d(2.0)), c("Very far (3x)", d(3.0)), c("Farthest (4x, about 18% more GPU time)", d(4.0)),
    ]), d(1.0), live: true, "How far away buildings keep their full detail.")
    static let trafficLod = Setting("mcla_traffic_lod", "Traffic detail distance", .choice([
        c("Near (faster)", d(0.5)), c("Medium", d(0.75)), c("As on the console", d(1.0)),
        c("Far (1.5x)", d(1.5)), c("Farther (2x)", d(2.0)), c("Very far (3x)", d(3.0)), c("Farthest (4x)", d(4.0)),
    ]), d(1.0), live: true, "How far away cars keep their full detail.")
    static let trafficDistance = Setting("mcla_traffic_distance", "Traffic distance", .choice([
        c("250 m", d(250)), c("325 m", d(325)), c("400 m (as on the console)", d(400)), c("500 m", d(500)), c("600 m", d(600)),
    ]), d(400), live: true, "How far away traffic is drawn.")
    static let pedestrians = Setting("mcla_pedestrians", "Pedestrians", .choice([
        c("None", d(0)), c("Half", d(0.5)), c("All", d(1.0)),
    ]), d(1.0), live: true, "How many people walk the streets.")
    static let parkedCars = Setting("mcla_parked_cars", "Parked cars", .choice([
        c("None", d(0)), c("Half", d(0.5)), c("All", d(1.0)),
    ]), d(1.0), live: true, "How many cars are parked along the streets.")
    static let farShadows = Setting("mcla_far_shadow_interval", "Far shadows update", .choice([
        c("Every frame", n(0)), c("Every 2nd frame", n(2)), c("Every 4th", n(4)), c("Every 8th", n(8)),
    ]), n(0), live: true, "How often the far shadow cascade is drawn again; less often is faster.")
    static let envMap = Setting("mcla_env_map_interval", "Environment map update", .choice([
        c("Every frame", n(0)), c("Every 2nd frame", n(2)), c("Every 4th", n(4)), c("Every 8th", n(8)),
    ]), n(0), live: true, "How often the sky and city reflected on the cars are drawn again.")
    static let reflections = Setting("mcla_reflection_interval", "Reflections update", .choice([
        c("Every frame", n(0)), c("Every 2nd frame", n(2)), c("Every 4th", n(4)), c("Every 8th", n(8)),
    ]), n(0), live: true, "How often the reflections on wet roads and windows are drawn again.")

    static let detail: [Setting] = [shadows, foliageShadows, raceShadows, fastCarShadows, foliageImpostors,
                                    fullscreenBlur, motionBlur, depthOfField]
    static let distance: [Setting] = [cityLod, trafficLod, trafficDistance, pedestrians, parkedCars,
                                      farShadows, envMap, reflections]

    // MARK: Display

    static let fullscreen = Setting("fullscreen", "Full screen", .toggle, on(true),
        "Starts the game full screen (in its own Space). Off starts it in a window. Either way, the green button "
        + "or Control-Command-F switches during play.")
    static let gamma = Setting("mcla_display_gamma", "Display gamma", .choice([
        c("TV (as on the console)", s("tv")), c("PC monitor (brighter shadows)", s("pc")),
    ]), s("tv"), live: true,
        "The console's picture was made for a TV. PC lifts dark areas the way a computer monitor expects.")
    static let uiInterpolate = Setting("mcla_ui_interpolate", "Smooth HUD and menus", .toggle, on(true), live: true,
        "Moves the HUD and menus at the full frame rate instead of the console's 30 or 60 steps a second.")
    static let hdr = Setting("hdr", "HDR", .choice([
        c("Off", s("off")), c("Auto (when the display can show it)", s("auto")), c("On", s("on")),
    ]), s("auto"), live: true,
        "Shows lights, the sun and skies brighter than white on a display with extended dynamic range: the "
        + "Liquid Retina XDR of a MacBook Pro, a Pro Display XDR or Studio Display, or an HDR monitor with HDR on "
        + "in System Settings. Auto turns it on where the display can show it and keeps SDR elsewhere.")
    static let hdrPeak = Setting("hdr_peak_nits", "HDR peak brightness",
        .level(min: 200, max: 4000, step: 50, unit: "nits", autoLabel: "What the display reports", start: 1000), d(0), live: true,
        "The brightest the display can show. The default reads it from macOS. Set it lower if highlights look "
        + "clipped, or to your monitor's real peak if it reports less than it can do.")
    static let hdrPaperWhite = Setting("hdr_paper_white_nits", "HDR paper white",
        .level(min: 80, max: 480, step: 10, unit: "nits", autoLabel: "Follow the screen brightness", start: 200), d(0), live: true,
        "How bright the game's white (the HUD and menus) is. The default follows the display's brightness, so "
        + "the game matches the desktop.")
    static let hdrHighlights = Setting("mcla_hdr_highlights", "HDR highlights", .choice([
        c("Normal", d(1.0)), c("Bright", d(1.5)), c("Brighter (default)", d(2.0)), c("Brightest", d(3.0)),
    ]), d(2.0), live: true, "How far above white the brightest parts of the scene go. A matter of taste.")

    // MARK: Game

    static let userName = Setting("user_name", "Player name", .text(placeholder: "User"), s("User"),
        "The name the game shows for you (the gamertag): 1 to 15 letters, digits and spaces.")
    static let language = Setting("user_language", "Language", .choice([
        c("English", n(1)), c("Français", n(4)), c("Deutsch", n(3)), c("Italiano", n(6)), c("Español", n(5)),
    ]), n(1), "The language of the game's menus and text: the five it was made in.")
    static let intro = Setting("mcla_intro", "Start-up", .choice([
        c("Normal", s("normal")), c("Fast (speeds through the logos)", s("fast")),
        c("Skip (no logos, no title logo)", s("skip")),
    ]), s("normal"), "What plays when the game starts.")

    // MARK: Controls

    static let keyboard = Setting("mnk_mode", "Play with the keyboard", .toggle, on(false),
        "Makes the keyboard a controller. A connected controller works either way.")
    static let keyboardLayout = Setting("mcla_keyboard_layout", "Keyboard layout", .choice([
        c("Driving (W gas, S brake, A and D steer)", s("driving")),
        c("Controller (the SDK's: gas on E, W A S D the left stick)", s("controller")),
    ]), s("driving"), "The keys the layout starts from. Keys you set below stay as you set them.")
    static let prompts = Setting("mcla_button_prompts", "Button prompts", .choice([
        c("Follow the controller", s("auto")), c("Xbox", s("xbox")), c("PlayStation", s("playstation")),
    ]), s("auto"), live: true, "Which button symbols the game shows.")
    static let vibration = Setting("mcla_vibration", "Controller vibration", .toggle, on(true), live: true,
        "The game's rumble, on any controller.")
    static let triggers = Setting("mcla_adaptive_triggers", "DualSense adaptive triggers", .toggle, on(true), live: true,
        "On a DualSense, R2 (gas) pushes back like a light spring and L2 (brake) is firmer.")
    static let hideCursor = Setting("mcla_hide_cursor", "Hide the mouse pointer", .toggle, on(true), live: true,
        "Hides the pointer over the game while you play; it comes back when the mouse moves.")
}

/// The keys of the keyboard controller, in the order the F4 overlay shows them.
struct Keybind: Identifiable {
    let key: String
    let button: String
    let action: String
    let driving: String
    let controller: String
    var id: String { key }
}

enum Keybinds {
    static let all: [Keybind] = [
        Keybind(key: "keybind_right_trigger", button: "Right trigger", action: "Gas", driving: "W,Up", controller: "E,O"),
        Keybind(key: "keybind_left_trigger", button: "Left trigger", action: "Brake, reverse", driving: "S,Down", controller: "Q,I"),
        Keybind(key: "keybind_lstick_left", button: "Left stick left", action: "Steer left", driving: "A,Left", controller: "A"),
        Keybind(key: "keybind_lstick_right", button: "Left stick right", action: "Steer right", driving: "D,Right", controller: "D"),
        Keybind(key: "keybind_lstick_up", button: "Left stick up", action: "Up in menus", driving: "W,Up", controller: "W"),
        Keybind(key: "keybind_lstick_down", button: "Left stick down", action: "Down in menus", driving: "S,Down", controller: "S"),
        Keybind(key: "keybind_a", button: "A", action: "Handbrake; confirm", driving: "Space", controller: "Semicolon,Space"),
        Keybind(key: "keybind_b", button: "B", action: "Back", driving: "B,Backspace", controller: "Quote,Backspace"),
        Keybind(key: "keybind_x", button: "X", action: "Nitrous", driving: "X,N", controller: "L"),
        Keybind(key: "keybind_y", button: "Y", action: "Headlights", driving: "Y", controller: "P"),
        Keybind(key: "keybind_left_shoulder", button: "LB", action: "Special ability", driving: "Q", controller: "1"),
        Keybind(key: "keybind_right_shoulder", button: "RB", action: "Camera view", driving: "E,C", controller: "3"),
        Keybind(key: "keybind_lstick_press", button: "Left stick press", action: "", driving: "F", controller: "F"),
        Keybind(key: "keybind_rstick_press", button: "Right stick press", action: "Horn", driving: "H", controller: "K"),
        Keybind(key: "keybind_rstick_up", button: "Right stick up", action: "Camera", driving: "I", controller: "Up"),
        Keybind(key: "keybind_rstick_down", button: "Right stick down", action: "Camera", driving: "K", controller: "Down"),
        Keybind(key: "keybind_rstick_left", button: "Right stick left", action: "Camera", driving: "J", controller: "Left"),
        Keybind(key: "keybind_rstick_right", button: "Right stick right", action: "Camera", driving: "L", controller: "Right"),
        Keybind(key: "keybind_dpad_up", button: "D-pad up", action: "Map", driving: "M,Shift+Up", controller: "Shift+Up"),
        Keybind(key: "keybind_dpad_down", button: "D-pad down", action: "", driving: "Shift+Down", controller: "Shift+Down"),
        Keybind(key: "keybind_dpad_left", button: "D-pad left", action: "", driving: "Shift+Left", controller: "Shift+Left"),
        Keybind(key: "keybind_dpad_right", button: "D-pad right", action: "", driving: "Shift+Right", controller: "Shift+Right"),
        Keybind(key: "keybind_back", button: "Back", action: "", driving: "Tab", controller: "Z,Tab"),
        Keybind(key: "keybind_start", button: "Start", action: "Pause; menus", driving: "Escape,Return", controller: "X,Return"),
    ]

    /// The SDK's name for a key pressed in the launcher (the names of src/ui/keybinds.cpp), with Shift, Control
    /// or Alt in front when held. Nil for a key the game doesn't know.
    static func name(keyCode: UInt16, characters: String?, shift: Bool, control: Bool, option: Bool) -> String? {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape", 117: "Delete", 115: "Home",
            119: "End", 116: "PageUp", 121: "PageDown", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
            50: "Backtick", 27: "Minus", 24: "Plus", 43: "Comma", 47: "Period", 41: "Semicolon", 44: "Slash",
            42: "Backslash", 33: "LBracket", 30: "RBracket", 39: "Quote", 57: "CapsLock",
            82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4", 87: "Numpad5",
            88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 76: "NumpadEnter", 69: "NumpadPlus",
            78: "NumpadMinus", 67: "NumpadStar", 75: "NumpadSlash",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12",
        ]
        // Letters and digits by key position (the US layout's names), so that a key means the same key
        // whatever the keyboard's language.
        let positional: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
            7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
            28: "8", 25: "9",
        ]
        guard let base = special[keyCode] ?? positional[keyCode] else { return nil }
        var mods = ""
        if control { mods += "Control+" }
        if option { mods += "Alt+" }
        if shift { mods += "Shift+" }
        return mods + base
    }
}
