// Where things are, the settings file, and the game's process.

import AppKit
import Foundation

struct Paths {
    /// The folder with the game's program (mcla), its runtime and mcla.toml: Contents/MacOS of MCLA.app, or,
    /// for a launcher run on its own, MCLA_DIR or the launcher's own folder.
    let programDir: URL
    let support: URL
    let logsDir: URL

    var program: URL { programDir.appendingPathComponent("mcla") }
    var config: URL { programDir.appendingPathComponent("mcla.toml") }
    var savesLibrary: URL { support.appendingPathComponent("Saves", isDirectory: true) }
    var extractedGame: URL { support.appendingPathComponent("Game", isDirectory: true) }
    var defaultLog: URL { logsDir.appendingPathComponent("mcla.log") }

    static func current() -> Paths {
        let fm = FileManager.default
        var dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        if let env = ProcessInfo.processInfo.environment["MCLA_DIR"], !env.isEmpty {
            dir = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MCLA", isDirectory: true)
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MCLA", isDirectory: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        return Paths(programDir: dir.standardizedFileURL, support: support, logsDir: logs)
    }
}

/// The launcher's state: mcla.toml, and the game when it runs.
@MainActor
final class Launcher: ObservableObject {
    let paths = Paths.current()

    @Published private(set) var config = TomlDocument(text: "")
    @Published var configProblem: String?
    @Published private(set) var running: Process?
    @Published var lastExit: GameExit?
    @Published var section: Section? = .play

    private var configDate: Date?

    struct GameExit: Identifiable {
        let id = UUID()
        let status: Int32
        let crashed: Bool
        let logTail: String
    }

    enum Section: String, CaseIterable, Identifiable {
        case play, gameFiles, saves, graphics, display, gameplay, controls, advanced, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .play: return "Play"
            case .gameFiles: return "Game Files"
            case .saves: return "Saves"
            case .graphics: return "Graphics"
            case .display: return "Display & HDR"
            case .gameplay: return "Game"
            case .controls: return "Controls"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .play: return "play.circle"
            case .gameFiles: return "opticaldisc"
            case .saves: return "externaldrive"
            case .graphics: return "cube.transparent"
            case .display: return "sun.max"
            case .gameplay: return "flag.checkered"
            case .controls: return "gamecontroller"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    init() {
        loadConfig()
        // For screenshots and tests: MCLA_LAUNCHER_PAGE=graphics opens that page.
        if let page = ProcessInfo.processInfo.environment["MCLA_LAUNCHER_PAGE"], let s = Section(rawValue: page) { section = s }
    }

    // MARK: Settings file

    func loadConfig() {
        let url = paths.config
        configDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = TomlDocument(text: "# Midnight Club: LA (recomp) settings; the launcher and the game's settings menu both write here.\n")
            configProblem = nil
            return
        }
        do {
            config = TomlDocument(text: try String(contentsOf: url, encoding: .utf8))
            configProblem = nil
        } catch {
            configProblem = "Could not read \(url.path): \(error.localizedDescription)"
        }
    }

    /// The game's settings menu and the F4 overlay save into the same file: read it again when it changed.
    func reloadIfChanged() {
        let date = (try? FileManager.default.attributesOfItem(atPath: paths.config.path)[.modificationDate]) as? Date
        if date != configDate { loadConfig() }
    }

    func value(_ key: String) -> TomlValue? { config.value(key) }

    /// Sets (or, with nil, removes) one option and writes the file at once.
    func set(_ key: String, _ value: TomlValue?) {
        reloadIfChanged()
        var doc = config
        if let value { doc.set(key, value) } else { doc.remove(key) }
        write(doc)
    }

    func setMany(_ changes: [(String, TomlValue?)]) {
        reloadIfChanged()
        var doc = config
        for (key, value) in changes {
            if let value { doc.set(key, value) } else { doc.remove(key) }
        }
        write(doc)
    }

    private func write(_ doc: TomlDocument) {
        do {
            try FileManager.default.createDirectory(at: paths.programDir, withIntermediateDirectories: true)
            try doc.text.write(to: paths.config, atomically: true, encoding: .utf8)
            config = doc
            configDate = (try? FileManager.default.attributesOfItem(atPath: paths.config.path)[.modificationDate]) as? Date
            configProblem = nil
        } catch {
            configProblem = "Could not write \(paths.config.path): \(error.localizedDescription)"
        }
    }

    // MARK: Folders the game uses

    var gameFolder: URL? {
        guard let root = value("game_data_root")?.asString, !root.isEmpty else { return nil }
        let expanded = (root as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true) }
        return paths.programDir.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    /// Where the game keeps profiles and saves: user_data_root, or the SDK's default (XDG_DATA_HOME or
    /// ~/.local/share, then mcla).
    var userDataRoot: URL {
        if let root = value("user_data_root")?.asString, !root.isEmpty {
            return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        }
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("mcla", isDirectory: true)
    }

    var logFile: URL {
        if let path = value("log_file")?.asString, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return paths.defaultLog
    }

    // MARK: The game

    var programPresent: Bool { FileManager.default.isExecutableFile(atPath: paths.program.path) }

    enum AfterLaunch: String, CaseIterable, Identifiable {
        case stay, hide, quit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stay: return "Keep the launcher open"
            case .hide: return "Hide the launcher (it comes back when the game ends)"
            case .quit: return "Quit the launcher"
            }
        }
    }

    var afterLaunch: AfterLaunch {
        get { AfterLaunch(rawValue: UserDefaults.standard.string(forKey: "afterLaunch") ?? "") ?? .hide }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "afterLaunch"); objectWillChange.send() }
    }

    /// Extra command-line options for the game, as typed (split on spaces; quotes keep spaces).
    var extraArguments: String {
        get { UserDefaults.standard.string(forKey: "extraArguments") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "extraArguments"); objectWillChange.send() }
    }

    static func splitArguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var any = false
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; any = true
            } else if c == " " || c == "\t" || c == "\n" {
                if any || !current.isEmpty { out.append(current) }
                current = ""; any = false
            } else {
                current.append(c)
            }
        }
        if any || !current.isEmpty { out.append(current) }
        return out
    }

    func play() {
        guard running == nil else { return }
        reloadIfChanged()
        // The game's default backend (any) is MoltenVK on a Mac: the launcher's default is Metal.
        if value("mcla_gpu_backend") == nil || value("mcla_gpu_backend")?.asString == "any" {
            set("mcla_gpu_backend", .string("metal"))
        }
        let process = Process()
        process.executableURL = paths.program
        process.currentDirectoryURL = paths.programDir
        process.arguments = Launcher.splitArguments(extraArguments)
        // Apple's Metal HUD is decided when Metal loads: set here, before the game starts (metal_performance_hud).
        if let hud = value("metal_performance_hud")?.asString, hud == "off" || hud == "on" {
            var env = ProcessInfo.processInfo.environment
            env["MTL_HUD_ENABLED"] = hud == "on" ? "1" : "0"
            process.environment = env
        }
        // The game logs to its log file; what it prints goes nowhere.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            let crashed = p.terminationReason == .uncaughtSignal
            Task { @MainActor in
                guard let self else { return }
                self.running = nil
                self.loadConfig()
                let tail = Launcher.tail(of: self.logFile, lines: 40)
                if crashed || status != 0 {
                    self.lastExit = GameExit(status: status, crashed: crashed, logTail: tail)
                }
                if self.afterLaunch == .hide {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        do {
            try process.run()
            running = process
            lastExit = nil
            switch afterLaunch {
            case .stay: break
            case .hide: NSApp.hide(nil)
            case .quit: NSApp.terminate(nil)
            }
        } catch {
            lastExit = GameExit(status: -1, crashed: false, logTail: "Could not start \(paths.program.path): \(error.localizedDescription)")
        }
    }

    func stop() { running?.terminate() }

    static func tail(of url: URL, lines: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 64 * 1024 ? size - 64 * 1024 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
