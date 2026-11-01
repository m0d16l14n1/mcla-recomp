// The career save, and a library of copies of it.
//
// The game keeps one save: <user data>/B13EBABEBABEBABE/545407F8 (the SDK's one profile, the game's title id),
// mc4.sav in 00000001 with its header in Headers. The library keeps whole copies of that folder in
// ~/Library/Application Support/MCLA/Saves/<name>/545407F8, each with a slot.json. Loading one puts it in the
// game's place; what was there is first kept in the library (as "Before <name>", unless an equal copy is there
// already), so nothing is ever lost by a click. Deleting moves to the Trash.

import AppKit
import Foundation

let kTitleId = "545407F8"
let kProfile = "B13EBABEBABEBABE"

struct SaveInfo: Equatable {
    let folder: URL          // the 545407F8 folder
    let saved: Date?         // mc4.sav's modification date
    let size: Int64
    let fingerprint: String  // size and date of every file, to tell copies apart

    static func read(_ folder: URL) -> SaveInfo? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return nil }
        var size: Int64 = 0
        var newest: Date?
        var parts: [String] = []
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) {
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true else { continue }
                let s = Int64(v.fileSize ?? 0)
                size += s
                if url.lastPathComponent == "mc4.sav", url.deletingLastPathComponent().lastPathComponent == "mc4.sav" {
                    newest = v.contentModificationDate
                }
                let rel = url.path.replacingOccurrences(of: folder.path, with: "")
                parts.append("\(rel):\(s):\(Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0))")
            }
        }
        guard size > 0 else { return nil }
        return SaveInfo(folder: folder, saved: newest, size: size, fingerprint: parts.sorted().joined(separator: "|"))
    }
}

struct SaveSlot: Identifiable, Equatable {
    struct Meta: Codable, Equatable {
        var name: String
        var created: Date
        var note: String
    }
    let id: URL        // the slot's folder
    var meta: Meta
    let info: SaveInfo?
}

@MainActor
final class SaveStore: ObservableObject {
    @Published private(set) var current: SaveInfo?
    @Published private(set) var slots: [SaveSlot] = []
    @Published var message: String?

    let library: URL
    private let userDataRoot: () -> URL

    init(library: URL, userDataRoot: @escaping () -> URL) {
        self.library = library
        self.userDataRoot = userDataRoot
        refresh()
    }

    var currentFolder: URL {
        userDataRoot().appendingPathComponent(kProfile, isDirectory: true).appendingPathComponent(kTitleId, isDirectory: true)
    }

    func refresh() {
        current = SaveInfo.read(currentFolder)
        let fm = FileManager.default
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        var out: [SaveSlot] = []
        for dir in (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let meta = SaveStore.readMeta(dir)
            out.append(SaveSlot(id: dir, meta: meta, info: SaveInfo.read(dir.appendingPathComponent(kTitleId))))
        }
        slots = out.sorted { $0.meta.created > $1.meta.created }
    }

    private static func readMeta(_ dir: URL) -> SaveSlot.Meta {
        let url = dir.appendingPathComponent("slot.json")
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let m = try? d.decode(SaveSlot.Meta.self, from: data) { return m }
        let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        return SaveSlot.Meta(name: dir.lastPathComponent, created: created, note: "")
    }

    private static func writeMeta(_ meta: SaveSlot.Meta, to dir: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(meta).write(to: dir.appendingPathComponent("slot.json"), options: .atomic)
    }

    /// A folder name for a slot: the name without what a path can't hold, made unique.
    private func folderFor(_ name: String) -> URL {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base.hasPrefix(".") { base = "Save" + base }
        var url = library.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = library.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    static func defaultName(_ prefix: String = "Career") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(f.string(from: Date()))"
    }

    /// Copies the game's current save into the library.
    @discardableResult
    func backUpCurrent(name: String, note: String = "") throws -> SaveSlot? {
        guard let current else { return nil }
        let dir = folderFor(name)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: current.folder, to: dir.appendingPathComponent(kTitleId))
            try SaveStore.writeMeta(SaveSlot.Meta(name: name, created: Date(), note: note), to: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        refresh()
        return slots.first { $0.id == dir }
    }

    /// Whether the library has a copy equal to the current save.
    var currentIsInLibrary: Bool {
        guard let current else { return true }
        return slots.contains { $0.info.map { SaveStore.sameContents($0, current) } ?? false }
    }

    static func sameContents(_ a: SaveInfo, _ b: SaveInfo) -> Bool {
        guard a.size == b.size else { return false }
        let fa = a.folder.appendingPathComponent("00000001/mc4.sav/mc4.sav")
        let fb = b.folder.appendingPathComponent("00000001/mc4.sav/mc4.sav")
        return FileManager.default.contentsEqual(atPath: fa.path, andPath: fb.path)
    }

    /// Puts a slot in the game's place. The save that was there goes into the library first, unless an
    /// equal copy is there already.
    func load(_ slot: SaveSlot) throws {
        guard let info = slot.info else { throw CocoaError(.fileReadNoSuchFile) }
        let fm = FileManager.default
        if current != nil && !currentIsInLibrary {
            try backUpCurrent(name: "Before \(slot.meta.name)", note: "Kept automatically when \(slot.meta.name) was loaded.")
        }
        let target = currentFolder
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(kTitleId).loading")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: info.folder, to: staging)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        refresh()
    }

    /// Starts the career over: the current save goes into the library (unless an equal copy is there) and
    /// then out of the game's place.
    func newGame() throws {
        guard current != nil else { return }
        if !currentIsInLibrary {
            try backUpCurrent(name: SaveStore.defaultName("Before new game"), note: "Kept automatically when a new game was started.")
        }
        try FileManager.default.removeItem(at: currentFolder)
        refresh()
    }

    func delete(_ slot: SaveSlot) throws {
        try FileManager.default.trashItem(at: slot.id, resultingItemURL: nil)
        refresh()
    }

    func update(_ slot: SaveSlot, name: String, note: String) throws {
        var meta = slot.meta
        meta.name = name
        meta.note = note
        try SaveStore.writeMeta(meta, to: slot.id)
        refresh()
    }

    /// A .zip of the slot (or of the current save), with the 545407F8 folder and slot.json in it.
    func export(_ slot: SaveSlot?, to zip: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("mcla-export-\(UUID().uuidString)", isDirectory: true)
        let inner = tmp.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        if let slot {
            guard let info = slot.info else { throw CocoaError(.fileReadNoSuchFile) }
            try fm.copyItem(at: info.folder, to: inner.appendingPathComponent(kTitleId))
            try SaveStore.writeMeta(slot.meta, to: inner)
        } else {
            guard let current else { throw CocoaError(.fileReadNoSuchFile) }
            try fm.copyItem(at: current.folder, to: inner.appendingPathComponent(kTitleId))
            try SaveStore.writeMeta(SaveSlot.Meta(name: SaveStore.defaultName(), created: Date(), note: ""), to: inner)
        }
        try? fm.removeItem(at: zip)
        try SaveStore.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", inner.path, zip.path])
    }

    /// Adds a save from a .zip (as Export makes) or a folder: anything that has a 545407F8 folder with the
    /// game's save in it, or is one.
    func importSave(from url: URL) throws -> SaveSlot? {
        let fm = FileManager.default
        var source = url
        let tmp = fm.temporaryDirectory.appendingPathComponent("mcla-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        if url.pathExtension.lowercased() == "zip" {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try SaveStore.run("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path])
            source = tmp
        }
        guard let title = SaveStore.findTitleFolder(in: source) else {
            throw NSError(domain: "MCLA", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No Midnight Club: LA save was found there (a \(kTitleId) folder with 00000001/mc4.sav in it)."])
        }
        let parent = title.deletingLastPathComponent()
        var meta = SaveStore.readMeta(parent)
        if !fm.fileExists(atPath: parent.appendingPathComponent("slot.json").path) {
            meta = SaveSlot.Meta(name: url.deletingPathExtension().lastPathComponent, created: Date(), note: "Imported from \(url.lastPathComponent).")
        }
        let dir = folderFor(meta.name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: title, to: dir.appendingPathComponent(kTitleId))
            try SaveStore.writeMeta(meta, to: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        refresh()
        return slots.first { $0.id == dir }
    }

    private static func findTitleFolder(in root: URL) -> URL? {
        let fm = FileManager.default
        func isSave(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("00000001/mc4.sav/mc4.sav").path) }
        if root.lastPathComponent == kTitleId, isSave(root) { return root }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let u as URL in e where u.lastPathComponent == kTitleId && isSave(u) {
            if e.level > 4 { break }
            return u
        }
        return nil
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "MCLA", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }
}
