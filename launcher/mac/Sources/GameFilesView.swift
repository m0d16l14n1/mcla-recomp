// Choosing the game: a folder that has it, or a disc image to take it from. Either way it is checked against
// the supported release before the game is pointed at it.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GameFilesModel: ObservableObject {
    struct CheckState {
        var result = GameCheck()
        var checkingNow = false
        var done: Int64 = 0
        var total: Int64 = 0
        var file = ""
    }
    struct ExtractState {
        var running = false
        var done: Int64 = 0
        var total: Int64 = 0
        var file = ""
        var error: String?
    }

    @Published var check = CheckState()
    @Published var extract = ExtractState()
    private var cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    var manifest: GameManifest? { GameManifest.shared }

    var canPlay: Bool { check.result.allGood || (!check.result.finished && !check.checkingNow) }

    func cancel() { cancelFlag.set() }

    func quickCheck(_ folder: URL?) { run(folder, full: false) }

    func run(_ folder: URL?, full: Bool, then: ((GameCheck) -> Void)? = nil) {
        guard let folder, let manifest, !check.checkingNow else {
            check = CheckState()
            return
        }
        let flag = CancelFlag()
        cancelFlag = flag
        check = CheckState(result: GameCheck(), checkingNow: true, done: 0, total: full ? manifest.totalSize : 0, file: "")
        Task.detached(priority: .userInitiated) {
            var last = Date.distantPast
            let result = GameFiles.check(folder: folder, manifest: manifest, full: full, cancelled: { flag.isSet }) { done, file in
                guard Date().timeIntervalSince(last) > 0.1 else { return }
                last = Date()
                Task { @MainActor in
                    self.check.done = done
                    self.check.file = file
                }
            }
            await MainActor.run {
                self.check.result = result
                self.check.checkingNow = false
                then?(result)
            }
        }
    }

    func extract(image: URL, to folder: URL, then: @escaping () -> Void) {
        guard !extract.running else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        extract = ExtractState(running: true)
        Task.detached(priority: .userInitiated) {
            do {
                let disc = try XboxDiscImage(url: image)
                let total = disc.totalSize
                await MainActor.run { self.extract.total = total }
                var last = Date.distantPast
                try disc.extract(to: folder, cancelled: { flag.isSet }) { done, file in
                    guard Date().timeIntervalSince(last) > 0.1 else { return }
                    last = Date()
                    Task { @MainActor in
                        self.extract.done = done
                        self.extract.file = file
                    }
                }
                let cancelled = flag.isSet
                await MainActor.run {
                    self.extract.running = false
                    if !cancelled { then() }
                }
            } catch {
                await MainActor.run {
                    self.extract.running = false
                    self.extract.error = error.localizedDescription
                }
            }
        }
    }
}

struct GameFilesView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var files: GameFilesModel
    @State private var confirmUse: URL?

    var body: some View {
        Page(title: "Game Files",
             subtitle: "The game itself comes from your own copy: an Xbox 360 disc image (.iso) of Midnight Club: Los Angeles "
                     + "Complete Edition, or a folder with its files. Nothing is changed in them.") {
            Card(title: "Where the game is") {
                if let folder = launcher.gameFolder {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(folder.path).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                } else {
                    Text("No game chosen yet.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Take It from a Disc Image…", action: chooseImage)
                    Button("Use a Folder…", action: chooseFolder)
                    Spacer()
                }
                .disabled(files.extract.running || files.check.checkingNow)
            }

            if files.extract.running || files.extract.error != nil {
                Card(title: "Taking the files out of the image") {
                    if files.extract.running {
                        ProgressView(value: Double(files.extract.done), total: Double(max(files.extract.total, 1))) {
                            Text(files.extract.file.isEmpty ? "Reading the image…" : files.extract.file)
                        } currentValueLabel: {
                            Text("\(formatSize(files.extract.done)) of \(formatSize(files.extract.total))")
                        }
                        Button("Stop") { files.cancel() }
                    }
                    if let e = files.extract.error {
                        Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }

            checkCard
        }
        .confirmationDialog("These files aren't the supported release.", isPresented: Binding(
            get: { confirmUse != nil }, set: { if !$0 { confirmUse = nil } }), presenting: confirmUse) { url in
            Button("Use Them Anyway") { setFolder(url) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The game is made for one release: \(files.manifest?.title ?? "Midnight Club: Los Angeles Complete Edition"). "
                 + "Other files may not start, or may crash.")
        }
    }

    private var checkCard: some View {
        Card(title: "Check", footer: "The quick check compares names and sizes; Verify reads all \(formatSize(files.manifest?.totalSize ?? 0)) "
             + "and compares each file's SHA-256 with the release's (a minute or two).") {
            HStack {
                Button("Quick Check") { files.run(launcher.gameFolder, full: false) }
                Button("Verify Contents") { files.run(launcher.gameFolder, full: true) }
                Spacer()
                if files.check.checkingNow { Button("Stop") { files.cancel() } }
            }
            .disabled(launcher.gameFolder == nil || files.extract.running)
            if files.check.checkingNow && files.check.total > 0 {
                ProgressView(value: Double(files.check.done), total: Double(files.check.total)) {
                    Text(files.check.file)
                }
            }
            if let manifest = files.manifest {
                let r = files.check.result
                if r.finished {
                    Label(r.allGood ? (r.full ? "All \(manifest.files.count) files are the supported release, byte for byte."
                                              : "All \(manifest.files.count) files are there, at the right sizes.")
                                    : "\(r.problems.count) of \(manifest.files.count) files have a problem.",
                          systemImage: r.allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.allGood ? .green : .orange)
                    if let id = r.titleId {
                        Text("Title id \(id)" + (id == manifest.titleId ? " (Midnight Club: Los Angeles)" : " — expected \(manifest.titleId)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(manifest.files, id: \.path) { (f: GameManifest.File) in
                        fileRow(f, r.states[f.path] ?? .unknown)
                    }
                }
                .font(.callout)
            } else {
                Text("The list of the release's files (game-files.json) isn't in the launcher, so only the program's title id can be checked.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileRow(_ f: GameManifest.File, _ state: FileState) -> some View {
        let unknown = state == .unknown
        return GridRow {
            Image(systemName: state.good ? "checkmark.circle" : unknown ? "circle" : "xmark.circle")
                .foregroundStyle(state.good ? Color.green : unknown ? Color.secondary : Color.red)
            Text(f.path).font(.system(.body, design: .monospaced))
            Text(formatSize(f.size)).foregroundStyle(.secondary).monospacedDigit()
            Text(state.label).foregroundStyle(state.good || unknown ? Color.secondary : Color.red)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder with the game's files (default.xex and the xarchive_*.rpf files)."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        files.run(url, full: false) { result in
            if result.allGood { setFolder(url) } else { confirmUse = url }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data, .data]
        panel.message = "Choose the Xbox 360 disc image (.iso) of Midnight Club: Los Angeles Complete Edition."
        panel.prompt = "Take the Files"
        guard panel.runModal() == .OK, let image = panel.url else { return }
        let dest = launcher.paths.extractedGame
        // Room for the files (about 6.1 GB).
        if let free = try? dest.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, let need = files.manifest?.totalSize, free < need {
            files.extract.error = "Not enough free space: the game needs \(formatSize(need)), and \(formatSize(free)) is free."
            return
        }
        files.extract(image: image, to: dest) {
            files.run(dest, full: true) { result in
                if result.allGood { setFolder(dest) } else { confirmUse = dest }
            }
        }
    }

    private func setFolder(_ url: URL) {
        launcher.set("game_data_root", .string(url.path))
        files.quickCheck(url)
    }
}
