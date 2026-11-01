// The first page: whether everything is ready, the save that will load, a summary of the settings, Play.

import AppKit
import SwiftUI

struct PlayView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var files: GameFilesModel
    @EnvironmentObject var saves: SaveStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let problem = launcher.configProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Card(title: "Ready to play?") {
                    check(launcher.programPresent, "The game's program",
                          launcher.programPresent ? launcher.paths.program.path
                              : "Not found in \(launcher.paths.programDir.path). Build it (scripts/make_mac.sh) and make the app again (scripts/make_app.sh).")
                    Divider()
                    gameFilesRow
                    Divider()
                    check(true, "Career save", saves.current.map { "Last saved \(formatDate($0.saved)) · \(formatSize($0.size))" }
                          ?? "No save yet: the game starts a new career.", neutral: saves.current == nil)
                }
                Card(title: "Settings for this run", footer: "Change them in the pages on the left; the game reads them when it starts.") {
                    summaryRow("Graphics", graphicsSummary)
                    summaryRow("Frame rate", fpsSummary)
                    summaryRow("Screen", screenSummary)
                    summaryRow("HDR", launcher.value("hdr")?.asString ?? "auto")
                    summaryRow("Input", (launcher.value("mnk_mode")?.asBool ?? false)
                               ? "Keyboard (\(launcher.value("mcla_keyboard_layout")?.asString ?? "driving") layout) and controllers"
                               : "Controllers (keyboard off)")
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.32, green: 0.08, blue: 0.35),
                                    Color(red: 0.95, green: 0.45, blue: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // City lights: a row of soft dots, drawn, not an image from the game.
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 7)
                for _ in 0..<70 {
                    let x = CGFloat.random(in: 0...size.width, using: &rng)
                    let h = CGFloat.random(in: 20...size.height * 0.55, using: &rng)
                    let w = CGFloat.random(in: 10...34, using: &rng)
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: w, height: h)), with: .color(.black.opacity(0.45)))
                }
            }
            .drawingGroup()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MIDNIGHT CLUB").font(.system(size: 34, weight: .heavy, design: .rounded)).italic()
                    Text("LOS ANGELES · recompiled for Apple silicon").font(.headline).opacity(0.85)
                }
                .foregroundStyle(.white)
                Spacer()
                playButton
            }
            .padding(22)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var playButton: some View {
        if launcher.running != nil {
            VStack(alignment: .trailing, spacing: 6) {
                Label("Running", systemImage: "circle.fill").foregroundStyle(.green).font(.headline)
                Button("Quit the Game") { launcher.stop() }
            }
        } else {
            Button {
                launcher.play()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 26).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!launcher.programPresent || !files.canPlay)
        }
    }

    @ViewBuilder private var gameFilesRow: some View {
        let folder = launcher.gameFolder
        if folder == nil {
            check(false, "Game files", "Not chosen yet.", action: ("Choose…", { launcher.section = .gameFiles }))
        } else if files.check.checkingNow {
            HStack { ProgressView().controlSize(.small); Text("Checking the game files…") }
        } else if files.check.result.allGood {
            check(true, "Game files", "\(folder!.path)\(files.check.result.full ? " · contents verified" : "")")
        } else {
            check(false, "Game files", files.check.result.finished
                  ? "Problems: \(files.check.result.problems.joined(separator: ", "))" : "Not checked.",
                  action: ("Fix…", { launcher.section = .gameFiles }))
        }
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String, neutral: Bool = false,
                       action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: neutral ? "circle.dashed" : ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(neutral ? Color.secondary : ok ? Color.green : Color.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
        }
    }

    private var graphicsSummary: String {
        let backend = launcher.value("mcla_gpu_backend")?.asString ?? "metal"
        let aa = AntiAliasing.current(launcher)
        return (backend == "vulkan" ? "Vulkan (MoltenVK)" : "Metal") + " · " + aa.label(metal: backend != "vulkan")
    }

    private var fpsSummary: String {
        let fps = Int(launcher.value("mcla_fps")?.asDouble ?? 30)
        return fps == 0 ? "Uncapped" : "\(fps) FPS cap"
    }

    private var screenSummary: String {
        let full = launcher.value("fullscreen")?.asBool ?? true
        let index = Int(launcher.value("monitor")?.asDouble ?? 0)
        let screens = ScreenInfo.all()
        let screen = index > 0 && index <= screens.count ? screens[index - 1] : screens.first
        return (full ? "Full screen" : "Window") + (screen.map { " on \($0.name) (\($0.summary))" } ?? "")
    }
}

/// The same "random" skyline every time it is drawn.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
