// The career save and the library of copies: back up, load, play with, rename, import, export, delete.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SavesView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var saves: SaveStore
    @State private var naming: Naming?
    @State private var confirm: Confirm?
    @State private var error: String?

    struct Naming: Identifiable {
        let id = UUID()
        let slot: SaveSlot?   // nil: a new backup of the current save
        var name: String
        var note: String
    }

    enum Confirm: Identifiable {
        case load(SaveSlot, play: Bool), delete(SaveSlot), newGame
        var id: String {
            switch self {
            case .load(let s, let p): return "load\(s.id.path)\(p)"
            case .delete(let s): return "delete\(s.id.path)"
            case .newGame: return "new"
            }
        }
    }

    private var busy: Bool { launcher.running != nil }

    var body: some View {
        Page(title: "Saves",
             subtitle: "The game keeps one career save. Here you can keep copies of it, switch between them, and move them "
                     + "between Macs. Loading a copy keeps the save it replaces in the library first.") {
            if busy {
                Label("The game is running: saves can be looked at, but not changed, until it ends.", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            }
            currentCard
            libraryCard
        }
        .sheet(item: $naming) { n in NamingSheet(naming: n) { result in commitNaming(result) } }
        .alert(item: $confirm) { c in confirmAlert(c) }
        .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .onAppear { saves.refresh() }
    }

    private var currentCard: some View {
        Card(title: "The game's save", footer: "In \(saves.currentFolder.path)") {
            if let cur = saves.current {
                HStack(alignment: .top) {
                    Image(systemName: "flag.checkered.circle.fill").font(.largeTitle).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Career").font(.headline)
                        Text("Last saved \(formatDate(cur.saved)) · \(formatSize(cur.size))").foregroundStyle(.secondary)
                        Text(saves.currentIsInLibrary ? "A copy of it is in the library." : "Not backed up yet.")
                            .font(.caption).foregroundStyle(saves.currentIsInLibrary ? Color.secondary : Color.orange)
                    }
                    Spacer()
                }
                HStack {
                    Button("Back Up…") { naming = Naming(slot: nil, name: SaveStore.defaultName(), note: "") }
                    Button("Export…") { export(nil) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([cur.folder]) }
                    Spacer()
                    Button("New Game…", role: .destructive) { confirm = .newGame }
                }
                .disabled(busy)
            } else {
                Text("No save yet. The game makes one when a career starts; or load one from the library below.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var libraryCard: some View {
        Card(title: "Library", footer: "Kept in \(saves.library.path). Export makes a .zip that Import (here or on another Mac) takes back.") {
            HStack {
                Button("Import…", action: importSave)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saves.library]) }
                Spacer()
            }
            .disabled(busy)
            if saves.slots.isEmpty {
                Text("No copies yet.").foregroundStyle(.secondary)
            }
            ForEach(saves.slots) { slot in
                Divider()
                slotRow(slot)
            }
        }
    }

    private func slotRow(_ slot: SaveSlot) -> some View {
        let isCurrent = saves.current.flatMap { cur in slot.info.map { SaveStore.sameContents($0, cur) } } ?? false
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "externaldrive.fill")
                .foregroundStyle(isCurrent ? .green : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(slot.meta.name).font(.headline)
                    if isCurrent { Text("loaded").font(.caption).foregroundStyle(.green) }
                }
                Text("Saved \(formatDate(slot.info?.saved)) · kept \(formatDate(slot.meta.created)) · \(formatSize(slot.info?.size ?? 0))")
                    .font(.caption).foregroundStyle(.secondary)
                if !slot.meta.note.isEmpty { Text(slot.meta.note).font(.caption) }
                if slot.info == nil { Text("This copy has no save in it.").font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            HStack {
                Button("Play") { confirm = .load(slot, play: true) }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(slot.info == nil || !launcher.programPresent)
                Button("Load") { confirm = .load(slot, play: false) }.disabled(slot.info == nil || isCurrent)
                Menu {
                    Button("Rename…") { naming = Naming(slot: slot, name: slot.meta.name, note: slot.meta.note) }
                    Button("Export…") { export(slot) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([slot.id]) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { confirm = .delete(slot) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .disabled(busy)
        }
    }

    private func confirmAlert(_ c: Confirm) -> Alert {
        switch c {
        case .load(let slot, let play):
            let isCurrent = saves.current.flatMap { cur in slot.info.map { SaveStore.sameContents($0, cur) } } ?? false
            if play && isCurrent {
                return Alert(title: Text("Play \(slot.meta.name)?"), message: Text("It is the save that's loaded."),
                             primaryButton: .default(Text("Play")) { launcher.play() }, secondaryButton: .cancel())
            }
            let keep = saves.current != nil && !saves.currentIsInLibrary
                ? " The save there now goes into the library first, as \"Before \(slot.meta.name)\"." : ""
            return Alert(title: Text("Load \(slot.meta.name)?"),
                         message: Text("It becomes the game's save." + keep),
                         primaryButton: .default(Text(play ? "Load and Play" : "Load")) {
                             do {
                                 try saves.load(slot)
                                 if play { launcher.play() }
                             } catch { self.error = error.localizedDescription }
                         },
                         secondaryButton: .cancel())
        case .delete(let slot):
            return Alert(title: Text("Move \(slot.meta.name) to the Trash?"),
                         message: Text("It can be put back from the Trash until the Trash is emptied."),
                         primaryButton: .destructive(Text("Move to Trash")) {
                             do { try saves.delete(slot) } catch { self.error = error.localizedDescription }
                         },
                         secondaryButton: .cancel())
        case .newGame:
            return Alert(title: Text("Start a new career?"),
                         message: Text("The game's save is taken away, so the game starts from the beginning. "
                                       + (saves.currentIsInLibrary ? "A copy of it is already in the library."
                                                                   : "It goes into the library first.")),
                         primaryButton: .destructive(Text("New Game")) {
                             do { try saves.newGame() } catch { self.error = error.localizedDescription }
                         },
                         secondaryButton: .cancel())
        }
    }

    private func commitNaming(_ n: Naming) {
        do {
            if let slot = n.slot {
                try saves.update(slot, name: n.name, note: n.note)
            } else {
                try saves.backUpCurrent(name: n.name, note: n.note)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func export(_ slot: SaveSlot?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "MCLA " + (slot?.meta.name ?? SaveStore.defaultName()) + ".zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try saves.export(slot, to: url) } catch { self.error = error.localizedDescription }
    }

    private func importSave() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a save: a .zip from Export, or a folder with a 545407F8 folder in it (from another copy of the game)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try saves.importSave(from: url) } catch { self.error = error.localizedDescription }
    }
}

private struct NamingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var naming: SavesView.Naming
    let commit: (SavesView.Naming) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(naming.slot == nil ? "Back up the save" : "Rename").font(.headline)
            TextField("Name", text: $naming.name)
            TextField("Note (optional)", text: $naming.note)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(naming.slot == nil ? "Back Up" : "Save") { commit(naming); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(naming.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
